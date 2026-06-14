// CLIJSONEventStream.swift
//
// WHAT THIS FILE DOES
// -------------------
// Emits newline-delimited JSON (NDJSON) events on stdout when --json is set.
// get, put, and sync write transfer.start/progress/complete (and sync.*) for automation.
//

import Foundation
import MacSCPCore

enum CLIJSONEventStream {
    private struct Event: Encodable {
        let event: String
        let timestamp: String
    }

    private struct TransferStartEvent: Encodable {
        let event: String
        let timestamp: String
        let transferId: String
        let direction: String
        let remotePath: String
        let localPath: String
    }

    private struct TransferProgressEvent: Encodable {
        let event: String
        let timestamp: String
        let transferId: String
        let direction: String
        let path: String
        let transferredBytes: Int64
        let totalBytes: Int64?
        let bytesPerSecond: Double?
        let percentComplete: Double?
    }

    private struct TransferCompleteEvent: Encodable {
        let event: String
        let timestamp: String
        let transferId: String
        let direction: String
        let remotePath: String
        let localPath: String
        let bytesTransferred: Int64
        let checksum: String?
        let resumedFrom: Int64?
    }

    private struct TransferErrorEvent: Encodable {
        let event: String
        let timestamp: String
        let transferId: String?
        let direction: String?
        let remotePath: String?
        let localPath: String?
        let message: String
    }

    private struct SyncPreviewEvent: Encodable {
        let event: String
        let timestamp: String
        let uploads: Int
        let downloads: Int
        let remoteDeletes: Int
        let localDeletes: Int
    }

    private struct SyncStartEvent: Encodable {
        let event: String
        let timestamp: String
        let uploads: Int
        let downloads: Int
        let remoteDeletes: Int
        let localDeletes: Int
        let preview: Bool
    }

    private struct SyncCompleteEvent: Encodable {
        let event: String
        let timestamp: String
        let filesTransferred: Int
        let remoteDeletes: Int
        let localDeletes: Int
    }

    private struct SessionEvent: Encodable {
        let event: String
        let timestamp: String
        let host: String
        let port: Int
        let username: String
        let protocolName: String
    }

    nonisolated(unsafe) private static var lastProgressEmit: [UUID: Date] = [:]
    private static let progressMinInterval: TimeInterval = 0.25

    static func emitSessionConnected(_ configuration: SessionConfiguration) {
        guard CLIRuntime.jsonOutput else { return }
        write(
            SessionEvent(
                event: "session.connected",
                timestamp: isoTimestamp(),
                host: configuration.host,
                port: configuration.port,
                username: configuration.username,
                protocolName: configuration.protocol.rawValue
            )
        )
    }

    static func emitSessionDisconnected() {
        guard CLIRuntime.jsonOutput else { return }
        write(Event(event: "session.disconnected", timestamp: isoTimestamp()))
    }

    static func emitTransferStart(
        transferID: UUID,
        direction: TransferDirection,
        remotePath: String,
        localPath: String
    ) {
        guard CLIRuntime.jsonOutput else { return }
        write(
            TransferStartEvent(
                event: "transfer.start",
                timestamp: isoTimestamp(),
                transferId: transferID.uuidString,
                direction: direction.rawValue,
                remotePath: remotePath,
                localPath: localPath
            )
        )
    }

    static func emitTransferProgress(transferID: UUID, progress: TransferProgress) {
        guard CLIRuntime.jsonOutput else { return }
        let now = Date()
        if let last = lastProgressEmit[transferID], now.timeIntervalSince(last) < progressMinInterval {
            if let total = progress.totalBytes, total > 0, progress.transferredBytes < total {
                return
            }
        }
        lastProgressEmit[transferID] = now

        let percent: Double?
        if let total = progress.totalBytes, total > 0 {
            percent = Double(progress.transferredBytes) / Double(total) * 100.0
        } else {
            percent = nil
        }

        write(
            TransferProgressEvent(
                event: "transfer.progress",
                timestamp: isoTimestamp(),
                transferId: transferID.uuidString,
                direction: progress.direction.rawValue,
                path: progress.path,
                transferredBytes: progress.transferredBytes,
                totalBytes: progress.totalBytes,
                bytesPerSecond: progress.bytesPerSecond,
                percentComplete: percent
            )
        )
    }

    static func emitTransferComplete(
        transferID: UUID,
        direction: TransferDirection,
        remotePath: String,
        localPath: String,
        result: TransferResult
    ) {
        guard CLIRuntime.jsonOutput else { return }
        lastProgressEmit.removeValue(forKey: transferID)
        write(
            TransferCompleteEvent(
                event: "transfer.complete",
                timestamp: isoTimestamp(),
                transferId: transferID.uuidString,
                direction: direction.rawValue,
                remotePath: remotePath,
                localPath: localPath,
                bytesTransferred: result.bytesTransferred,
                checksum: result.checksum,
                resumedFrom: result.resumedFrom
            )
        )
    }

    static func emitTransferError(
        transferID: UUID?,
        direction: TransferDirection?,
        remotePath: String?,
        localPath: String?,
        message: String
    ) {
        guard CLIRuntime.jsonOutput else { return }
        if let transferID {
            lastProgressEmit.removeValue(forKey: transferID)
        }
        write(
            TransferErrorEvent(
                event: "transfer.error",
                timestamp: isoTimestamp(),
                transferId: transferID?.uuidString,
                direction: direction?.rawValue,
                remotePath: remotePath,
                localPath: localPath,
                message: message
            )
        )
    }

    static func emitSyncPreview(
        uploads: Int,
        downloads: Int,
        remoteDeletes: Int,
        localDeletes: Int
    ) {
        guard CLIRuntime.jsonOutput else { return }
        write(
            SyncPreviewEvent(
                event: "sync.preview",
                timestamp: isoTimestamp(),
                uploads: uploads,
                downloads: downloads,
                remoteDeletes: remoteDeletes,
                localDeletes: localDeletes
            )
        )
    }

    static func emitSyncStart(
        uploads: Int,
        downloads: Int,
        remoteDeletes: Int,
        localDeletes: Int,
        preview: Bool
    ) {
        guard CLIRuntime.jsonOutput else { return }
        write(
            SyncStartEvent(
                event: "sync.start",
                timestamp: isoTimestamp(),
                uploads: uploads,
                downloads: downloads,
                remoteDeletes: remoteDeletes,
                localDeletes: localDeletes,
                preview: preview
            )
        )
    }

    static func emitSyncComplete(
        filesTransferred: Int,
        remoteDeletes: Int,
        localDeletes: Int
    ) {
        guard CLIRuntime.jsonOutput else { return }
        write(
            SyncCompleteEvent(
                event: "sync.complete",
                timestamp: isoTimestamp(),
                filesTransferred: filesTransferred,
                remoteDeletes: remoteDeletes,
                localDeletes: localDeletes
            )
        )
    }

    static func makeProgressHandler(transferID: UUID) -> ProgressHandler? {
        guard CLIRuntime.jsonOutput else { return nil }
        return { progress in
            emitTransferProgress(transferID: transferID, progress: progress)
        }
    }

    private static func isoTimestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }

    private static func write<T: Encodable>(_ payload: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload),
              let line = String(data: data, encoding: .utf8)
        else {
            return
        }
        print(line)
        fflush(stdout)
    }
}
