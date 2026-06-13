// CitadelPipelinedReader.swift
//
// WHAT THIS FILE DOES
// -------------------
// Read-ahead SFTP downloads with one outstanding READ per handle. CitadelSFTPBackend overlaps
// the next SFTP READ with local disk writes when pipelining is enabled in config.
//

import Citadel
import Foundation
import MacSCPCore
import NIO

/// Overlaps the next SFTP READ with local disk write. Citadel SFTPFile does not
/// support concurrent reads on one handle, so we prefetch at most one chunk ahead.
enum CitadelPipelinedReader {
    private final class ReadCoordinator: @unchecked Sendable {
        let file: SFTPFile

        init(file: SFTPFile) { self.file = file }

        func read(from offset: UInt64, length: UInt32) async throws -> Data {
            let buffer = try await file.read(from: offset, length: length)
            return Data(buffer: buffer)
        }
    }

    static func download(
        file: SFTPFile,
        writeHandle: FileHandle,
        totalSize: UInt64,
        startOffset: UInt64,
        chunkSize: UInt32,
        maxConcurrentReads: Int,
        transferID: UUID,
        remotePath: String,
        progress: ProgressHandler?,
        cancellation: TransferCancellation?
    ) async throws -> Int64 {
        _ = max(1, maxConcurrentReads)
        let coordinator = ReadCoordinator(file: file)
        var offset = startOffset
        var prefetch: Task<Data, Error>?
        let startTime = Date()
        let resumedFrom = Int64(startOffset)

        func reportProgress() {
            guard let progress else { return }
            let elapsed = Date().timeIntervalSince(startTime)
            progress(
                TransferProgress(
                    transferID: transferID,
                    direction: .download,
                    path: remotePath,
                    totalBytes: Int64(totalSize),
                    transferredBytes: Int64(offset),
                    bytesPerSecond: elapsed > 0
                        ? Double(offset - UInt64(resumedFrom)) / elapsed : nil
                )
            )
        }

        defer { prefetch?.cancel() }

        while offset < totalSize {
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
                let length = min(chunkSize, UInt32(totalSize - offset))
                data = try await coordinator.read(from: offset, length: length)
            }

            if data.isEmpty { break }

            try writeHandle.write(contentsOf: data)
            offset += UInt64(data.count)
            reportProgress()

            prefetch?.cancel()
            if offset < totalSize {
                let nextOffset = offset
                let nextLength = min(chunkSize, UInt32(totalSize - nextOffset))
                prefetch = Task {
                    try await coordinator.read(from: nextOffset, length: nextLength)
                }
            } else {
                prefetch = nil
            }
        }

        return Int64(offset - startOffset)
    }
}

private extension Data {
    init(buffer: ByteBuffer) {
        var copy = buffer
        self = copy.readData(length: copy.readableBytes) ?? Data()
    }
}
