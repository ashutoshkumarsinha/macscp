// CitadelPipelinedReader.swift — Overlapping SFTP READ requests for faster downloads.

import Citadel
import Foundation
import MacSCPCore
import NIO

/// Pipelines SFTP READ requests at distinct offsets so multiple round-trips overlap per handle.
enum CitadelPipelinedReader {
    private struct ReadResult: Sendable {
        let offset: UInt64
        let data: Data
    }

    private final class ReadCoordinator: @unchecked Sendable {
        let file: SFTPFile

        init(file: SFTPFile) {
            self.file = file
        }

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
        let coordinator = ReadCoordinator(file: file)
        let window = max(1, maxConcurrentReads)
        var readOffset = startOffset
        var writeOffset = startOffset
        var inFlight: [Task<ReadResult, Error>] = []
        var inFlightHead = 0
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
                    transferredBytes: Int64(writeOffset),
                    bytesPerSecond: elapsed > 0
                        ? Double(writeOffset - UInt64(resumedFrom)) / elapsed : nil
                )
            )
        }

        defer {
            for index in inFlightHead ..< inFlight.count {
                inFlight[index].cancel()
            }
        }

        while writeOffset < totalSize || inFlightHead < inFlight.count {
            if cancellation?.isCancelled == true || Task.isCancelled {
                throw BackendError.cancelled
            }
            try cancellation?.throwIfCancelled()

            while inFlight.count - inFlightHead < window, readOffset < totalSize {
                let length = min(chunkSize, UInt32(totalSize - readOffset))
                let requestOffset = readOffset
                readOffset += UInt64(length)

                let readTask = Task {
                    let data = try await coordinator.read(from: requestOffset, length: length)
                    return ReadResult(offset: requestOffset, data: data)
                }
                inFlight.append(readTask)
            }

            guard inFlightHead < inFlight.count else { break }

            let nextTask = inFlight[inFlightHead]
            inFlightHead += 1
            let result: ReadResult
            do {
                result = try await nextTask.value
            } catch is CancellationError {
                throw BackendError.cancelled
            }

            // Tasks complete in submission order; writeOffset must match read offset.
            if result.offset != writeOffset {
                throw BackendError.transferFailed("Pipelined read out of order at \(result.offset)")
            }
            try writeHandle.write(contentsOf: result.data)
            writeOffset += UInt64(result.data.count)
            reportProgress()
        }

        return Int64(writeOffset - startOffset)
    }
}

private extension Data {
    init(buffer: ByteBuffer) {
        var copy = buffer
        self = copy.readData(length: copy.readableBytes) ?? Data()
    }
}
