import Citadel
import Foundation
import MacSCPCore
import NIO

/// Pipelines SFTP WRITE requests at distinct offsets so multiple round-trips overlap per handle.
enum CitadelPipelinedWriter {
    /// Citadel splits each `write()` into ~32 KB SFTP packets; pipeline at that granularity.
    static let sftpPacketSize = 32_000

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
        maxConcurrentWrites: Int,
        transferID: UUID,
        remotePath: String,
        progress: ProgressHandler?
    ) async throws -> Int64 {
        let coordinator = WriteCoordinator(file: file)
        let window = max(1, maxConcurrentWrites)
        var readOffset = startOffset
        var confirmedOffset = startOffset
        var inFlight: [(offset: UInt64, length: Int, task: Task<Void, Error>)] = []
        let startTime = Date()

        func reportProgress() {
            guard let progress else { return }
            let transferred = Int64(confirmedOffset)
            let elapsed = Date().timeIntervalSince(startTime)
            progress(
                TransferProgress(
                    transferID: transferID,
                    direction: .upload,
                    path: remotePath,
                    totalBytes: Int64(totalSize),
                    transferredBytes: transferred,
                    bytesPerSecond: elapsed > 0
                        ? Double(transferred - Int64(startOffset)) / elapsed : nil
                )
            )
        }

        do {
            while confirmedOffset < UInt64(totalSize) || !inFlight.isEmpty {
                while inFlight.count < window, readOffset < UInt64(totalSize) {
                    let remaining = totalSize - Int(readOffset)
                    let chunkLength = min(sftpPacketSize, remaining)
                    try readHandle.seek(toOffset: readOffset)
                    guard let chunk = try readHandle.read(upToCount: chunkLength), !chunk.isEmpty else {
                        break
                    }
                    let writeOffset = readOffset
                    let buffer = ByteBuffer(data: chunk)
                    readOffset += UInt64(chunk.count)

                    let writeTask = Task {
                        try await coordinator.write(buffer, at: writeOffset)
                    }
                    inFlight.append((writeOffset, chunk.count, writeTask))
                }

                guard !inFlight.isEmpty else { break }

                let next = inFlight.removeFirst()
                try await next.task.value
                confirmedOffset = next.offset + UInt64(next.length)
                reportProgress()
            }
        } catch {
            for item in inFlight {
                item.task.cancel()
            }
            throw error
        }

        return Int64(confirmedOffset - startOffset)
    }
}
