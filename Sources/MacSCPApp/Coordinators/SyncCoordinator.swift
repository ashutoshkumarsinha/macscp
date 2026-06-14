// SyncCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Compares local and remote directories and enqueues sync transfers.
// SyncCoordinator drives SyncCompareView and calls DirectorySyncEngine plus TransferCoordinator.
//
import Foundation
import MacSCPCore

@MainActor
@Observable
final class SyncCoordinator {
    var compareRows: [SyncCompareRow] = []
    var isComparing = false
    var syncDirection: SyncDirection = .mirrorLocalToRemote
    var deleteExtraneous = false
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

    func enqueueSync(
        transferCoordinator: TransferCoordinator,
        fileOps: FileOperationsCoordinator,
        backend: TransferBackend?,
        previewOnly: Bool
    ) {
        if syncDirection == .bidirectional {
            let plan = DirectorySyncEngine.bidirectionalPlan(rows: compareRows, deleteExtraneous: deleteExtraneous)
            if previewOnly {
                onStatusMessage?(
                    "Preview: \(plan.uploads.count) upload(s), \(plan.downloads.count) download(s), " +
                    "\(plan.remoteDeletes.count + plan.localDeletes.count) delete(s)"
                )
                return
            }
            transferCoordinator.enqueueSyncUpload(files: plan.uploads)
            transferCoordinator.enqueueSyncDownload(files: plan.downloads)
            if deleteExtraneous, let backend {
                Task {
                    for path in plan.remoteDeletes {
                        try? await backend.removeFile(at: path)
                    }
                    for url in plan.localDeletes {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
            showSyncSheet = false
            onStatusMessage?("Queued bidirectional sync")
            return
        }

        let files = DirectorySyncEngine.toTransferFiles(rows: compareRows, direction: syncDirection)
        if previewOnly {
            onStatusMessage?("Preview: \(files.count) file(s) would transfer")
            return
        }
        let plan = DirectorySyncEngine.mirrorPlan(
            rows: compareRows,
            direction: syncDirection,
            deleteExtraneous: deleteExtraneous
        )
        guard !plan.transfers.isEmpty || !plan.remoteDeletes.isEmpty || !plan.localDeletes.isEmpty else {
            onStatusMessage?("Nothing to synchronize")
            return
        }
        switch syncDirection {
        case .mirrorLocalToRemote:
            transferCoordinator.enqueueSyncUpload(files: plan.transfers)
            if deleteExtraneous, let backend {
                Task {
                    for path in plan.remoteDeletes {
                        try? await backend.removeFile(at: path)
                    }
                }
            }
        case .mirrorRemoteToLocal:
            transferCoordinator.enqueueSyncDownload(files: plan.transfers)
            if deleteExtraneous {
                Task {
                    for url in plan.localDeletes {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        case .bidirectional:
            break
        }
        showSyncSheet = false
        onStatusMessage?("Queued \(plan.transfers.count) sync job(s)")
    }
}
