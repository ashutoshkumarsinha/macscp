// WebDAVTransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// HTTPS WebDAV backend (PROPFIND, GET, PUT, MKCOL, DELETE, MOVE). TransferBackendFactory
// builds this for webdav:// sessions with resume and atomic rename capabilities.
//

import Foundation
import MacSCPCore

public final class WebDAVTransferBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier = "webdav-native"

    public var capabilities: BackendCapabilities {
        [.atomicRename, .chmod]
    }

    private var baseURL: URL?
    private var credentials: URLCredential?
    private var workingPath = "/"
    public private(set) var isConnected = false

    public init() {}

    public func connect(configuration: SessionConfiguration) async throws {
        let scheme = configuration.port == 443 || configuration.port == 0 ? "https" : "http"
        let port = configuration.port == 0 ? (scheme == "https" ? 443 : 80) : configuration.port
        var components = URLComponents()
        components.scheme = scheme
        components.host = configuration.host
        components.port = port
        components.path = configuration.initialRemotePath.hasSuffix("/")
            ? configuration.initialRemotePath
            : configuration.initialRemotePath + "/"
        guard let url = components.url else {
            throw BackendError.invalidConfiguration("Invalid WebDAV URL")
        }
        baseURL = url
        if let password = configuration.password {
            credentials = URLCredential(user: configuration.username, password: password, persistence: .forSession)
        }
        workingPath = url.path
        isConnected = true
    }

    public func disconnect() async throws {
        baseURL = nil
        credentials = nil
        isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        workingPath = WebDAVPath.join(base: workingPath, component: path)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return workingPath
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let url = try resolveURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>
            """.utf8
        )
        let (data, response) = try await perform(request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("PROPFIND failed (\(response.statusCode))")
        }
        return WebDAVXMLParser.parse(data, basePath: url.path)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let parent = (try resolveURL(for: path).path as NSString).deletingLastPathComponent
        let entries = try await listDirectory(at: parent)
        let name = (path as NSString).lastPathComponent
        if let match = entries.first(where: { $0.name == name }) {
            return match
        }
        throw BackendError.pathNotFound(path)
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        if recursive {
            var parts: [String] = []
            for component in path.split(separator: "/") {
                parts.append(String(component))
                try await mkcol(at: parts.joined(separator: "/"))
            }
        } else {
            try await mkcol(at: path)
        }
    }

    public func removeDirectory(at path: String, recursive: Bool) async throws {
        if recursive {
            let entries = try await listDirectory(at: path)
            for entry in entries where entry.type == .file {
                try await removeFile(at: entry.path)
            }
            for entry in entries where entry.type == .directory {
                try await removeDirectory(at: entry.path, recursive: true)
            }
        }
        try await removeFile(at: path.hasSuffix("/") ? path : path + "/")
    }

    public func removeFile(at path: String) async throws {
        let url = try resolveURL(for: path)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (_, response) = try await perform(request)
        guard (200 ... 299).contains(response.statusCode) || response.statusCode == 404 else {
            throw BackendError.transferFailed("DELETE failed")
        }
    }

    public func rename(from: String, to: String) async throws {
        let source = try resolveURL(for: from)
        let destination = try resolveURL(for: to)
        var request = URLRequest(url: source)
        request.httpMethod = "MOVE"
        request.setValue(destination.absoluteString, forHTTPHeaderField: "Destination")
        request.setValue("T", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await perform(request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("MOVE failed")
        }
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let url = try resolveURL(for: path)
        let mode = String(format: "%04o", permissions.octal)
        var request = URLRequest(url: url)
        request.httpMethod = "PROPPATCH"
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <D:propertyupdate xmlns:D="DAV:">
              <D:set>
                <D:prop>
                  <unixmode xmlns="http://apache.org/dav/props/">\(mode)</unixmode>
                </D:prop>
              </D:set>
            </D:propertyupdate>
            """.utf8
        )
        let (_, response) = try await perform(request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("PROPPATCH chmod failed (\(response.statusCode))")
        }
    }

    public func setOwnership(user: String?, group: String?, at path: String) async throws {
        throw BackendError.notImplemented("WebDAV chown")
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let url = try resolveURL(for: remotePath)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let bytes = try await HTTPClient.upload(from: localURL, request: request, options: options, remotePath: remotePath)
        return TransferResult(bytesTransferred: bytes, checksum: nil)
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let url = try resolveURL(for: remotePath)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let bytes = try await HTTPClient.download(to: localURL, request: request, options: options, remotePath: remotePath)
        return TransferResult(bytesTransferred: bytes, checksum: nil)
    }

    private func mkcol(at path: String) async throws {
        let url = try resolveURL(for: path.hasSuffix("/") ? path : path + "/")
        var request = URLRequest(url: url)
        request.httpMethod = "MKCOL"
        let (_, response) = try await perform(request)
        guard (200 ... 299).contains(response.statusCode) || response.statusCode == 405 else {
            throw BackendError.transferFailed("MKCOL failed")
        }
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var signed = request
        if let credentials {
            let login = "\(credentials.user ?? ""):\(credentials.password ?? "")"
            let encoded = Data(login.utf8).base64EncodedString()
            signed.setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
        }
        return try await HTTPClient.data(for: signed)
    }

    private func resolveURL(for path: String) throws -> URL {
        guard let baseURL else { throw BackendError.notConnected }
        let joined = WebDAVPath.join(base: workingPath, component: path)
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw BackendError.invalidConfiguration("Invalid base URL")
        }
        components.path = joined.hasPrefix("/") ? joined : "/" + joined
        guard let url = components.url else { throw BackendError.invalidConfiguration("Invalid path") }
        return url
    }

    private func requireConnected() throws {
        guard isConnected else { throw BackendError.notConnected }
    }
}

enum WebDAVPath {
    static func join(base: String, component: String) -> String {
        if component.hasPrefix("/") { return component }
        let trimmedBase = base.hasSuffix("/") ? String(base.dropLast()) : base
        if component.isEmpty || component == "." { return trimmedBase }
        if component == ".." { return (trimmedBase as NSString).deletingLastPathComponent }
        return trimmedBase + "/" + component
    }
}

enum WebDAVXMLParser {
    static func parse(_ data: Data, basePath: String) -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [RemoteEntry] = []
        let hrefPattern = #"<[^:>]*:?href>([^<]+)</[^:>]*:?href>"#
        let sizePattern = #"<[^:>]*:?getcontentlength>([0-9]+)</[^:>]*:?getcontentlength>"#
        let collectionPattern = #"<[^:>]*:?collection\s*/?>"#
        let hrefs = matches(text, pattern: hrefPattern)
        let sizes = matches(text, pattern: sizePattern)

        for (index, href) in hrefs.enumerated() {
            let decoded = href.removingPercentEncoding ?? href
            if decoded.hasSuffix("/") && (decoded == basePath || decoded == basePath + "/") { continue }
            let entryName = (decoded as NSString).lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if entryName.isEmpty || entryName == "." || entryName == ".." { continue }
            let slice = text[text.index(text.startIndex, offsetBy: max(0, text.distance(from: text.startIndex, to: text.range(of: href)?.lowerBound ?? text.startIndex)) )...]
            let snippet = String(slice.prefix(500))
            let isDirectory = snippet.range(of: collectionPattern, options: .regularExpression) != nil || decoded.hasSuffix("/")
            entries.append(
                RemoteEntry(
                    name: entryName,
                    path: entryName,
                    type: isDirectory ? .directory : .file,
                    size: isDirectory ? nil : (index < sizes.count ? Int64(sizes[index]) : nil)
                )
            )
        }
        return entries
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
