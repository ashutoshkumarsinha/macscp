// SyncCoordinator.swift — Directory compare and enqueue one-way sync jobs.

import Foundation
import MacSCPCore

@MainActor
@Observable
final class SyncCoordinator {
    var compareRows: [SyncCompareRow] = []
    var isComparing = false
    var syncDirection: SyncDirection = .mirrorLocalToRemote
    var showSyncSheet = false

    var onStatusMessage: ((String) -> Void)?

    func compare(
        localPath: URL,
        remotePath: String,
        backend: TransferBackend?
    ) async {
        guard let backend else {
            onStatusMessage?("Not connected")
            return
        }
        isComparing = true
        defer { isComparing = false }
        do {
            compareRows = try await DirectorySyncEngine.compare(
                localRoot: localPath,
                remoteRoot: remotePath,
                backend: backend
            )
            showSyncSheet = true
            onStatusMessage?("Compared \(compareRows.count) paths")
        } catch {
            onStatusMessage?("Compare failed: \(error.localizedDescription)")
        }
    }

    func enqueueSync(transferCoordinator: TransferCoordinator, previewOnly: Bool) {
        let files = DirectorySyncEngine.toTransferFiles(rows: compareRows, direction: syncDirection)
        if previewOnly {
            onStatusMessage?("Preview: \(files.count) file(s) would transfer")
            return
        }
        guard !files.isEmpty else {
            onStatusMessage?("Nothing to synchronize")
            return
        }
        switch syncDirection {
        case .mirrorLocalToRemote:
            transferCoordinator.enqueueSyncUpload(files: files)
        case .mirrorRemoteToLocal:
            transferCoordinator.enqueueSyncDownload(files: files)
        }
        showSyncSheet = false
        onStatusMessage?("Queued \(files.count) sync job(s)")
    }
}
