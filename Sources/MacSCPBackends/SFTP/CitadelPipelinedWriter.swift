// CitadelPipelinedWriter.swift — Read-ahead local disk reads while writing SFTP chunks.

import Citadel
import Foundation
import MacSCPCore
import NIO

/// Overlaps reading the next local chunk with writing the current chunk to SFTP.
/// Citadel SFTPFile does not support concurrent writes on one handle.
enum CitadelPipelinedWriter {
    private final class WriteCoordinator: @unchecked Sendable {
        let file: SFTPFile

        init(file: SFTPFile) {
            self.file = file
        }

        func write(_ buffer: ByteBuffer, at offset: UInt64) async throws {
            try await file.write(buffer, at: offset)
        }
    }

    static func upload(
        file: SFTPFile,
        readHandle: FileHandle,
        totalSize: Int,
        startOffset: UInt64,
        chunkSize: Int,
        transferID: UUID,
        remotePath: String,
        progress: ProgressHandler?,
        cancellation: TransferCancellation?
    ) async throws -> Int64 {
        let coordinator = WriteCoordinator(file: file)
        let readChunkSize = max(chunkSize, 256 * 1024)
        var offset = startOffset
        var prefetch: Task<Data, Error>?
        let startTime = Date()

        func reportProgress() {
            guard let progress else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            progress(
                TransferProgress(
                    transferID: transferID,
                    direction: .upload,
                    path: remotePath,
                    totalBytes: Int64(totalSize),
                    transferredBytes: Int64(offset),
                    bytesPerSecond: elapsed > 0
                        ? Double(offset - startOffset) / elapsed : nil
                )
            )
        }

        defer { prefetch?.cancel() }

        while offset < UInt64(totalSize) {
            if cancellation?.isCancelled == true || Task.isCancelled {
                throw BackendError.cancelled
            }
            try cancellation?.throwIfCancelled()

            let data: Data
            if let prefetch {
                do {
                    data = try await prefetch.value
                } catch is CancellationError {
                    throw BackendError.cancelled
                }
            } else {
                let toRead = min(readChunkSize, totalSize - Int(offset))
                guard let chunk = try readHandle.read(upToCount: toRead), !chunk.isEmpty else {
                    break
                }
                data = chunk
            }

            if data.isEmpty { break }

            let buffer = ByteBuffer(data: data)
            try await coordinator.write(buffer, at: offset)
            offset += UInt64(data.count)
            reportProgress()

            prefetch?.cancel()
            if offset < UInt64(totalSize) {
                let nextOffset = offset
                let nextLength = min(readChunkSize, totalSize - Int(nextOffset))
                prefetch = Task {
                    guard let chunk = try readHandle.read(upToCount: nextLength), !chunk.isEmpty else {
                        return Data()
                    }
                    return chunk
                }
            } else {
                prefetch = nil
            }
        }

        return Int64(offset - startOffset)
    }
}
