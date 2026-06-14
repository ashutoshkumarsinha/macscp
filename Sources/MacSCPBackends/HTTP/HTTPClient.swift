// HTTPClient.swift
//
// WHAT THIS FILE DOES
// -------------------
// Thin async wrapper around URLSession for WebDAV and object-storage HTTP calls.
// S3 and WebDAV backends use data(for:) and upload helpers with shared timeout handling.
//
import Foundation
import MacSCPCore

enum HTTPClient {
    static func data(for request: URLRequest, timeout: TimeInterval = 60) async throws -> (Data, HTTPURLResponse) {
        var sessionRequest = request
        sessionRequest.timeoutInterval = timeout
        let (data, response) = try await URLSession.shared.data(for: sessionRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BackendError.transferFailed("Invalid HTTP response")
        }
        return (data, http)
    }

    static func download(to localURL: URL, request: URLRequest, options: TransferOptions, remotePath: String) async throws -> Int64 {
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        guard let http = response as? HTTPURLResponse, (200 ... 299).contains(http.statusCode) else {
            throw BackendError.transferFailed("HTTP download failed")
        }
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: localURL.path) {
            try FileManager.default.removeItem(at: localURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: localURL)
        let size = (try? FileManager.default.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        options.progress?(
            TransferProgress(
                transferID: UUID(),
                direction: .download,
                path: remotePath,
                totalBytes: size,
                transferredBytes: size,
                bytesPerSecond: nil
            )
        )
        return size
    }

    static func upload(from localURL: URL, request: URLRequest, options: TransferOptions, remotePath: String) async throws -> Int64 {
        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        var uploadRequest = request
        uploadRequest.httpBody = nil

        let (_, http) = try await URLSession.shared.upload(for: uploadRequest, fromFile: localURL)
        guard let response = http as? HTTPURLResponse, (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("HTTP upload failed")
        }
        options.progress?(
            TransferProgress(
                transferID: UUID(),
                direction: .upload,
                path: remotePath,
                totalBytes: fileSize,
                transferredBytes: fileSize,
                bytesPerSecond: nil
            )
        )
        return fileSize
    }
}
