// DeltaSyncEngine.swift
//
// WHAT THIS FILE DOES
// -------------------
// rsync-style block delta upload and download over SFTP backends with ranged I/O.
// Falls back to full transfer when delta is inefficient or unsupported.
//

import Foundation
import MacSCPCore

public enum DeltaSyncEngine {
    public static func supportsDelta(on backend: TransferBackend) -> Bool {
        backend.asDeltaCapable != nil
    }

    public static func uploadDelta(
        localURL: URL,
        remotePath: String,
        backend: TransferBackend,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard let deltaBackend = backend.asDeltaCapable else {
            return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
        }

        let resolved = remotePath
        let remoteEntry = try await backend.stat(path: resolved)
        guard remoteEntry.type == .file, let remoteSize = remoteEntry.size else {
            return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
        }

        let localSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        guard localSize >= RsyncConstants.minimumFileSize, remoteSize >= RsyncConstants.minimumFileSize else {
            return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
        }

        let delta: RsyncDelta
        do {
            delta = try await RsyncDeltaGenerator.generateAsync(
                basisSize: remoteSize,
                readBasis: { offset, length in
                    try await deltaBackend.readRemoteRange(
                        remotePath: resolved,
                        offset: offset,
                        length: length
                    )
                },
                targetURL: localURL
            )
        } catch is RsyncDeltaError {
            return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
        }

        let tempPath = "\(resolved).macscp-delta-\(UUID().uuidString)"
        var transferred: Int64 = 0
        let transferID = UUID()
        let start = Date()

        do {
            var outputOffset: Int64 = 0
            for operation in delta.operations {
                try options.throwIfCancelled()
                switch operation.kind {
                case let .copy(sourceOffset, length):
                    let chunk = try await deltaBackend.readRemoteRange(
                        remotePath: resolved,
                        offset: sourceOffset,
                        length: length
                    )
                    try await deltaBackend.writeRemoteRange(
                        remotePath: tempPath,
                        offset: outputOffset,
                        data: chunk,
                        create: outputOffset == 0
                    )
                case let .data(payload):
                    try await deltaBackend.writeRemoteRange(
                        remotePath: tempPath,
                        offset: outputOffset,
                        data: payload,
                        create: outputOffset == 0
                    )
                    transferred += Int64(payload.count)
                }
                outputOffset += Int64(operationLength(operation))
                reportProgress(
                    options: options,
                    transferID: transferID,
                    direction: .upload,
                    path: resolved,
                    totalBytes: localSize,
                    transferredBytes: transferred,
                    start: start
                )
            }

            try await backend.rename(from: tempPath, to: resolved)
        } catch {
            try? await backend.removeFile(at: tempPath)
            throw error
        }

        return TransferResult(bytesTransferred: transferred, checksum: nil)
    }

    public static func downloadDelta(
        remotePath: String,
        localURL: URL,
        backend: TransferBackend,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard backend.asDeltaCapable != nil else {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        let resolved = remotePath
        guard FileManager.default.fileExists(atPath: localURL.path) else {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        let remoteEntry = try await backend.stat(path: resolved)
        guard remoteEntry.type == .file, let remoteSize = remoteEntry.size else {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        let localSize = try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        guard localSize >= RsyncConstants.minimumFileSize, remoteSize >= RsyncConstants.minimumFileSize else {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        let tempRemote = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-delta-remote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tempRemote) }

        _ = try await backend.download(
            remotePath: resolved,
            localURL: tempRemote,
            options: TransferOptions(overwrite: .overwrite, chunkSize: options.chunkSize)
        )

        let delta: RsyncDelta
        do {
            delta = try RsyncDeltaGenerator.generate(basisURL: localURL, targetURL: tempRemote)
        } catch is RsyncDeltaError {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        let tempLocal = localURL.deletingLastPathComponent()
            .appendingPathComponent(".macscp-delta-\(UUID().uuidString)-\(localURL.lastPathComponent)")

        let transferred = try RsyncDeltaApplier.apply(
            basisURL: localURL,
            delta: delta,
            outputURL: tempLocal
        )

        _ = try FileManager.default.replaceItemAt(localURL, withItemAt: tempLocal)
        try? FileManager.default.removeItem(at: tempLocal)

        return TransferResult(bytesTransferred: transferred, checksum: nil)
    }

    public static func syncUpload(
        localURL: URL,
        remotePath: String,
        backend: TransferBackend,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard options.useDeltaSync, supportsDelta(on: backend) else {
            return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
        }

        if (try? await backend.stat(path: remotePath)).map({ $0.type == .file }) == true {
            return try await uploadDelta(
                localURL: localURL,
                remotePath: remotePath,
                backend: backend,
                options: options
            )
        }
        return try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
    }

    public static func syncDownload(
        remotePath: String,
        localURL: URL,
        backend: TransferBackend,
        options: TransferOptions
    ) async throws -> TransferResult {
        guard options.useDeltaSync, supportsDelta(on: backend) else {
            return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
        }

        if FileManager.default.fileExists(atPath: localURL.path) {
            return try await downloadDelta(
                remotePath: remotePath,
                localURL: localURL,
                backend: backend,
                options: options
            )
        }
        return try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
    }

    private static func operationLength(_ operation: RsyncDeltaOperation) -> Int {
        switch operation.kind {
        case let .copy(_, length): length
        case let .data(data): data.count
        }
    }

    private static func reportProgress(
        options: TransferOptions,
        transferID: UUID,
        direction: TransferDirection,
        path: String,
        totalBytes: Int64,
        transferredBytes: Int64,
        start: Date
    ) {
        guard let progress = options.progress else { return }
        let elapsed = Date().timeIntervalSince(start)
        progress(
            TransferProgress(
                transferID: transferID,
                direction: direction,
                path: path,
                totalBytes: totalBytes,
                transferredBytes: transferredBytes,
                bytesPerSecond: elapsed > 0 ? Double(transferredBytes) / elapsed : nil
            )
        )
    }
}
