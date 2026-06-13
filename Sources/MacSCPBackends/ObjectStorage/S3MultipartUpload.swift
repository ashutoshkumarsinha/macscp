import Foundation
import MacSCPCore

enum S3MultipartUpload {
    private static let partSize = 8 * 1024 * 1024

    static func uploadFile(
        localURL: URL,
        remotePath: String,
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials,
        options: TransferOptions
    ) async throws -> TransferResult {
        let fileSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        if fileSize <= partSize {
            return try await uploadSingle(localURL: localURL, remotePath: remotePath, layout: layout, credentials: credentials, options: options)
        }

        let key = layout.objectKey(for: remotePath)
        let uploadID = try await initiateMultipart(key: key, layout: layout, credentials: credentials)

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }

        var partNumber = 1
        var uploaded: Int64 = 0
        var etags: [(Int, String)] = []

        while uploaded < fileSize {
            try options.throwIfCancelled()
            let chunk = try handle.read(upToCount: partSize) ?? Data()
            if chunk.isEmpty { break }
            let etag = try await uploadPart(
                key: key,
                uploadID: uploadID,
                partNumber: partNumber,
                body: chunk,
                layout: layout,
                credentials: credentials
            )
            etags.append((partNumber, etag))
            uploaded += Int64(chunk.count)
            partNumber += 1
            options.progress?(
                TransferProgress(
                    transferID: UUID(),
                    direction: .upload,
                    path: remotePath,
                    totalBytes: fileSize,
                    transferredBytes: uploaded,
                    bytesPerSecond: nil
                )
            )
        }

        try await completeMultipart(
            key: key,
            uploadID: uploadID,
            parts: etags,
            layout: layout,
            credentials: credentials
        )
        return TransferResult(bytesTransferred: uploaded, checksum: nil)
    }

    private static func uploadSingle(
        localURL: URL,
        remotePath: String,
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials,
        options: TransferOptions
    ) async throws -> TransferResult {
        let data = try Data(contentsOf: localURL)
        let key = layout.objectKey(for: remotePath)
        let signed = try AWSSignatureV4.sign(
            method: "PUT",
            path: "/\(layout.bucket)/\(key)",
            headers: ["content-type": "application/octet-stream"],
            body: data,
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = signed.body
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("Upload failed (\(response.statusCode))")
        }
        return TransferResult(bytesTransferred: Int64(data.count), checksum: nil)
    }

    private static func initiateMultipart(
        key: String,
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials
    ) async throws -> String {
        let signed = try AWSSignatureV4.sign(
            method: "POST",
            path: "/\(layout.bucket)/\(key)",
            queryItems: [URLQueryItem(name: "uploads", value: nil)],
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        let (data, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("Multipart initiate failed")
        }
        return try S3XMLParser.parseUploadID(data)
    }

    private static func uploadPart(
        key: String,
        uploadID: String,
        partNumber: Int,
        body: Data,
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials
    ) async throws -> String {
        let signed = try AWSSignatureV4.sign(
            method: "PUT",
            path: "/\(layout.bucket)/\(key)",
            queryItems: [
                URLQueryItem(name: "partNumber", value: String(partNumber)),
                URLQueryItem(name: "uploadId", value: uploadID),
            ],
            body: body,
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = signed.body
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode),
              let etag = response.value(forHTTPHeaderField: "ETag") else {
            throw BackendError.transferFailed("Multipart part upload failed")
        }
        return etag
    }

    private static func completeMultipart(
        key: String,
        uploadID: String,
        parts: [(Int, String)],
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials
    ) async throws {
        let xml = S3XMLParser.completeMultipartBody(parts: parts)
        let signed = try AWSSignatureV4.sign(
            method: "POST",
            path: "/\(layout.bucket)/\(key)",
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
            headers: ["content-type": "application/xml"],
            body: xml,
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = signed.body
        let (_, response) = try await HTTPClient.data(for: request)
        guard (200 ... 299).contains(response.statusCode) else {
            throw BackendError.transferFailed("Multipart complete failed")
        }
    }

    private static func abortMultipart(
        key: String,
        uploadID: String,
        layout: ObjectStorageLayout,
        credentials: ObjectStorageCredentials
    ) async throws {
        let signed = try AWSSignatureV4.sign(
            method: "DELETE",
            path: "/\(layout.bucket)/\(key)",
            queryItems: [URLQueryItem(name: "uploadId", value: uploadID)],
            credentials: credentials,
            layout: layout
        )
        var request = URLRequest(url: signed.url)
        request.httpMethod = signed.method
        signed.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        _ = try await HTTPClient.data(for: request)
    }
}
