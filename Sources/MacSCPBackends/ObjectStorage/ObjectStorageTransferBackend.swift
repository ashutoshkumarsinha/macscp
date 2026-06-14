// ObjectStorageTransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Amazon S3 and GCS (S3-compatible HMAC) object storage backend. TransferBackendFactory
// builds this for s3:// URLs; supports multipart resume via S3MultipartUpload helpers.
//

import Foundation
import MacSCPCore

public final class ObjectStorageTransferBackend: CapableTransferBackend, @unchecked Sendable {
    public let backendIdentifier: String

    public var capabilities: BackendCapabilities {
        [.resumeUpload, .resumeDownload, .chmod]
    }

    private let provider: ObjectStorageLayout.Provider
    private var layout: ObjectStorageLayout?
    private var credentials: ObjectStorageCredentials?
    private var workingPrefix = ""

    public private(set) var isConnected = false

    public init(provider: ObjectStorageLayout.Provider) {
        self.provider = provider
        self.backendIdentifier = provider == .aws ? "s3-native" : "gcs-native"
    }

    public func connect(configuration: SessionConfiguration) async throws {
        layout = try ObjectStorageLayout.resolve(from: configuration, provider: provider)
        credentials = ObjectStorageCredentials(
            accessKeyID: configuration.username,
            secretAccessKey: configuration.password ?? ""
        )
        workingPrefix = layout?.prefix ?? ""
        isConnected = true
    }

    public func disconnect() async throws {
        layout = nil
        credentials = nil
        workingPrefix = ""
        isConnected = false
    }

    public func changeDirectory(to path: String) async throws {
        workingPrefix = ObjectStorageLayout.normalizePrefix(path)
    }

    public func workingDirectory() async throws -> String {
        try requireConnected()
        return workingPrefix
    }

    public func listDirectory(at path: String) async throws -> [RemoteEntry] {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let prefix = listPrefix(for: path, layout: layout)
        let signed = try AWSSignatureV4.sign(
            method: "GET",
            path: "/\(layout.bucket)",
            queryItems: [
                URLQueryItem(name: "list-type", value: "2"),
                URLQueryItem(name: "prefix", value: prefix),
                URLQueryItem(name: "delimiter", value: "/"),
            ],
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("List objects failed (\(response.statusCode))")
        }
        return S3XMLParser.parseListObjects(data, layout: layout, prefix: prefix)
    }

    public func stat(path: String) async throws -> RemoteEntry {
        let entries = try await listDirectory(at: path)
        let name = (resolveKey(path) as NSString).lastPathComponent
        if let match = entries.first(where: { $0.name == name }) {
            return match
        }
        throw BackendError.pathNotFound(path)
    }

    public func createDirectory(at path: String, recursive: Bool) async throws {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let key = layout.objectKey(for: path).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/"
        let signed = try AWSSignatureV4.sign(
            method: "PUT",
            path: "/\(layout.bucket)/\(key)",
            body: Data(),
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = signed.body
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("Create folder failed")
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
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let key = layout.objectKey(for: path)
        let signed = try AWSSignatureV4.sign(
            method: "DELETE",
            path: "/\(layout.bucket)/\(key)",
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) || response.statusCode == 404 else {
            throw BackendError.transferFailed("Delete failed")
        }
    }

    public func rename(from: String, to: String) async throws {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let sourceKey = layout.objectKey(for: from)
        let destinationKey = layout.objectKey(for: to)
        let copySource = "/\(layout.bucket)/\(sourceKey)".addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sourceKey
        let signed = try AWSSignatureV4.sign(
            method: "PUT",
            path: "/\(layout.bucket)/\(destinationKey)",
            headers: ["x-amz-copy-source": copySource],
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("Copy failed")
        }
        try await removeFile(at: from)
    }

    public func setPermissions(_ permissions: FilePermissions, at path: String) async throws {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let key = layout.objectKey(for: path)
        let acl = S3ObjectACL.canned(for: permissions)
        let signed = try AWSSignatureV4.sign(
            method: "PUT",
            path: "/\(layout.bucket)/\(key)",
            queryItems: [URLQueryItem(name: "acl", value: nil)],
            headers: ["x-amz-acl": acl],
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("PutObjectAcl failed (\(response.statusCode))")
        }
    }

    public func setOwnership(user: String?, group: String?, at path: String) async throws {
        throw BackendError.notImplemented("Object storage chown")
    }

    public func upload(
        localURL: URL,
        remotePath: String,
        options: TransferOptions
    ) async throws -> TransferResult {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        return try await S3MultipartUpload.uploadFile(
            localURL: localURL,
            remotePath: remotePath,
            layout: layout,
            credentials: credentials,
            options: options
        )
    }

    public func download(
        remotePath: String,
        localURL: URL,
        options: TransferOptions
    ) async throws -> TransferResult {
        let layout = try requireLayout()
        let credentials = try requireCredentials()
        let key = layout.objectKey(for: remotePath)
        let signed = try AWSSignatureV4.sign(
            method: "GET",
            path: "/\(layout.bucket)/\(key)",
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let bytes = try await HTTPClient.download(to: localURL, request: request, options: options, remotePath: remotePath)
        return TransferResult(bytesTransferred: bytes, checksum: nil)
    }

    private func listPrefix(for path: String, layout: ObjectStorageLayout) -> String {
        let key = layout.objectKey(for: path)
        if key.isEmpty { return layout.prefix.isEmpty ? "" : layout.prefix + "/" }
        return key.hasSuffix("/") ? key : key + "/"
    }

    private func resolveKey(_ path: String) -> String {
        (try? requireLayout())?.objectKey(for: path) ?? path
    }

    private func requireLayout() throws -> ObjectStorageLayout {
        try requireConnected()
        guard let layout else { throw BackendError.notConnected }
        return layout
    }

    private func requireCredentials() throws -> ObjectStorageCredentials {
        guard let credentials else { throw BackendError.authenticationFailed("Missing credentials") }
        return credentials
    }

    private func requireConnected() throws {
        guard isConnected else { throw BackendError.notConnected }
    }
}

public typealias S3TransferBackend = ObjectStorageTransferBackend
public typealias GCSTransferBackend = ObjectStorageTransferBackend

public extension ObjectStorageTransferBackend {
    static func makeS3() -> ObjectStorageTransferBackend {
        ObjectStorageTransferBackend(provider: .aws)
    }

    static func makeGCS() -> ObjectStorageTransferBackend {
        ObjectStorageTransferBackend(provider: .gcs)
    }
}
