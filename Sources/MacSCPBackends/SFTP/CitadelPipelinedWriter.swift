// CitadelPipelinedWriter.swift — Overlapped local reads and sliding-window SFTP writes.

import Citadel
import Foundation
import MacSCPCore
import NIO

/// Overlaps disk read-ahead with up to `maxConcurrentWrites` in-flight SFTP WRITE requests.
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
        localURL: URL,
        totalSize: Int,
        startOffset: UInt64,
        chunkSize: Int,
        maxConcurrentWrites: Int,
        transferID: UUID,
        remotePath: String,
        progress: ProgressHandler?,
        cancellation: TransferCancellation?,
        checksum: StreamingSHA256?
    ) async throws -> Int64 {
        let coordinator = WriteCoordinator(file: file)
        let reader = try LocalFileSequentialReader(url: localURL)
        let readChunkSize = max(chunkSize, 256 * 1024)
        let window = max(1, maxConcurrentWrites)
        var offset = startOffset
        var readPrefetch: Task<Data, Error>?
        var writeTasks: [Task<Void, Error>] = []
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

        func drainOneWrite() async throws {
            guard !writeTasks.isEmpty else { return }
            let task = writeTasks.removeFirst()
            do {
                try await task.value
            } catch is CancellationError {
                throw BackendError.cancelled
            }
        }

        defer {
            readPrefetch?.cancel()
            writeTasks.forEach { $0.cancel() }
        }

        while offset < UInt64(totalSize) {
            if cancellation?.isCancelled == true || Task.isCancelled {
                throw BackendError.cancelled
            }
            try cancellation?.throwIfCancelled()

            let data: Data
            if let readPrefetch {
                do {
                    data = try await readPrefetch.value
                } catch is CancellationError {
                    throw BackendError.cancelled
                }
            } else {
                let toRead = min(readChunkSize, totalSize - Int(offset))
                data = try reader.read(from: Int(offset), count: toRead)
            }

            if data.isEmpty { break }

            checksum?.update(data)

            while writeTasks.count >= window {
                try await drainOneWrite()
            }

            let writeOffset = offset
            var buffer = TransferBufferPool.borrow(capacity: data.count)
            buffer.writeBytes(data)
            writeTasks.append(Task {
                try await coordinator.write(buffer, at: writeOffset)
                TransferBufferPool.recycle(buffer)
            })

            offset += UInt64(data.count)
            reportProgress()

            readPrefetch?.cancel()
            if offset < UInt64(totalSize) {
                let nextOffset = Int(offset)
                let nextLength = min(readChunkSize, totalSize - nextOffset)
                readPrefetch = Task {
                    try reader.read(from: nextOffset, count: nextLength)
                }
            } else {
                readPrefetch = nil
            }
        }

        while !writeTasks.isEmpty {
            try await drainOneWrite()
        }

        return Int64(offset - startOffset)
    }
}
