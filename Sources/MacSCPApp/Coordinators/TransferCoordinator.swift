// TransferCoordinator.swift — Upload/download orchestration, overwrite prompts, queue binding.
//
// Expands directory selections into flat file lists via DirectoryTransferPlanner,
// detects name conflicts, and enqueues jobs on TransferQueue.

import Foundation
import MacSCPCore
import MacSCPUI
import Observation

@MainActor
@Observable
final class TransferCoordinator {
    /// Non-nil while OverwritePromptView sheet is visible.
    var overwritePrompt: PendingTransferBatch?
    let transferQueue = TransferQueue()

    var onStatusMessage: ((String) -> Void)?
    /// AppModel uses this to debounce pane refresh after jobs finish.
    var onTransferComplete: ((UUID) -> Void)?

    func bind(backendProvider: TransferBackendProvider) {
        transferQueue.bind(backendProvider: backendProvider)
    }

    func applyTransferSettings(_ settings: MacSCPTransferSettings) {
        transferQueue.applyTransferSettings(settings)
    }

    func handleDisconnect() {
        transferQueue.handleDisconnect()
    }

    func uploadSelected(
        localPane: LocalPaneCoordinator,
        remotePath: String,
        remoteEntries: [RemoteEntry],
        isConnected: Bool
    ) async {
        let selected = localPane.localEntries.filter { localPane.selectedLocalNames.contains($0.name) }
        guard !selected.isEmpty else {
            onStatusMessage?("Select local files or folders to upload")
            return
        }

        var items: [PendingTransferItem] = []
        for entry in selected {
            if entry.isDirectory {
                let dirURL = localPane.localPath.appendingPathComponent(entry.name, isDirectory: true)
                do {
                    onStatusMessage?("Scanning \(entry.name)…")
                    let remoteBase = SFTPPathJoin.joinRemote(remotePath, entry.name)
                    // Walk local tree off the main thread so the UI stays responsive.
                    let files = try await Task.detached(priority: .userInitiated) {
                        try DirectoryTransferPlanner.expandLocalDirectory(at: dirURL, remoteBase: remoteBase)
                    }.value
                    items += files.map { file in
                        PendingTransferItem(
                            localURL: file.localURL,
                            remotePath: file.remotePath,
                            totalBytes: file.totalBytes,
                            hasConflict: remotePathConflict(named: (file.remotePath as NSString).lastPathComponent, in: remoteEntries)
                                || remoteEntries.contains { $0.path == file.remotePath }
                        )
                    }
                } catch {
                    onStatusMessage?("Failed to scan \(entry.name): \(error.localizedDescription)"
                    )
                    return
                }
            } else {
                items.append(
                    PendingTransferItem(
                        localURL: localPane.localPath.appendingPathComponent(entry.name),
                        remotePath: SFTPPathJoin.joinRemote(remotePath, entry.name),
                        totalBytes: entry.size,
                        hasConflict: remotePathConflict(named: entry.name, in: remoteEntries)
                    )
                )
            }
        }

        queueTransfers(kind: .upload, items: items, isConnected: isConnected)
        localPane.selectedLocalNames = []
    }

    func downloadSelected(
        localPane: LocalPaneCoordinator,
        remotePane: RemotePaneCoordinator,
        backend: TransferBackend?,
        isConnected: Bool
    ) async {
        let selected = remotePane.remoteEntries.filter { remotePane.selectedRemoteNames.contains($0.name) }
        guard !selected.isEmpty else {
            onStatusMessage?("Select remote files or folders to download")
            return
        }
        guard let backend else { return }

        var items: [PendingTransferItem] = []
        for entry in selected {
            switch entry.type {
            case .directory:
                do {
                    onStatusMessage?("Scanning remote \(entry.name)…")
                    let localBase = localPane.localPath.appendingPathComponent(entry.name, isDirectory: true)
                    let files = try await DirectoryTransferPlanner.expandRemoteDirectory(
                        backend: backend,
                        at: entry.path,
                        localBase: localBase
                    )
                    // Create destination folders before download jobs start writing files.
                    try DirectoryTransferPlanner.ensureLocalDirectories(for: files)
                    items += files.map { file in
                        PendingTransferItem(
                            localURL: file.localURL,
                            remotePath: file.remotePath,
                            totalBytes: file.totalBytes,
                            hasConflict: FileManager.default.fileExists(atPath: file.localURL.path)
                        )
                    }
                } catch {
                    onStatusMessage?("Failed to scan \(entry.name): \(error.localizedDescription)")
                    return
                }
            case .file:
                items.append(
                    PendingTransferItem(
                        localURL: localPane.localPath.appendingPathComponent(entry.name),
                        remotePath: entry.path,
                        totalBytes: entry.size,
                        hasConflict: FileManager.default.fileExists(
                            atPath: localPane.localPath.appendingPathComponent(entry.name).path
                        )
                    )
                )
            case .symlink:
                continue
            }
        }

        queueTransfers(kind: .download, items: items, isConnected: isConnected)
        remotePane.selectedRemoteNames = []
    }

    func uploadDropped(
        fileNames: [String],
        localPane: LocalPaneCoordinator,
        remotePath: String,
        remoteEntries: [RemoteEntry],
        isConnected: Bool
    ) async {
        localPane.selectedLocalNames = Set(fileNames)
        await uploadSelected(
            localPane: localPane,
            remotePath: remotePath,
            remoteEntries: remoteEntries,
            isConnected: isConnected
        )
    }

    func downloadDropped(
        fileNames: [String],
        localPane: LocalPaneCoordinator,
        remotePane: RemotePaneCoordinator,
        backend: TransferBackend?,
        isConnected: Bool
    ) async {
        remotePane.selectedRemoteNames = Set(fileNames)
        await downloadSelected(
            localPane: localPane,
            remotePane: remotePane,
            backend: backend,
            isConnected: isConnected
        )
    }

    func resolveOverwritePrompt(action: OverwriteBatchAction) {
        guard let batch = overwritePrompt else { return }
        overwritePrompt = nil

        switch action {
        case .cancel:
            onStatusMessage?("Transfer cancelled")
            MacSCPLogger.shared.info("Overwrite prompt cancelled", category: .transfer)
            return
        case .overwriteAll:
            MacSCPLogger.shared.info("Overwrite all (\(batch.items.count) files)", category: .transfer)
            enqueueBatch(batch, policy: .overwrite)
        case .skipExisting:
            MacSCPLogger.shared.info("Skip existing (\(batch.items.count) files)", category: .transfer)
            enqueueBatch(batch, policy: .skip)
        case .renameAll:
            MacSCPLogger.shared.info("Rename all (\(batch.items.count) files)", category: .transfer)
            enqueueBatch(batch, policy: .rename)
        }
    }

    func transferDidComplete(jobID: UUID) {
        onTransferComplete?(jobID)
        if let job = transferQueue.jobs.first(where: { $0.id == jobID }) {
            onStatusMessage?("\(job.displayName) transfer complete")
        }
    }

    private func queueTransfers(kind: PendingTransferBatch.Kind, items: [PendingTransferItem], isConnected: Bool) {
        guard isConnected, !items.isEmpty else { return }

        if items.contains(where: \.hasConflict) {
            overwritePrompt = PendingTransferBatch(kind: kind, items: items)
            onStatusMessage?("Confirm overwrite for \(overwritePrompt?.conflictNames.count ?? 0) file(s)")
            MacSCPLogger.shared.warning(
                "Overwrite prompt for \(overwritePrompt?.conflictNames.count ?? 0) file(s)",
                category: .transfer
            )
            return
        }

        enqueueBatch(PendingTransferBatch(kind: kind, items: items), policy: .overwrite)
    }

    private func enqueueBatch(_ batch: PendingTransferBatch, policy: OverwritePolicy) {
        switch batch.kind {
        case .upload:
            let uploadItems = batch.items.map { item in
                (
                    localURL: item.localURL,
                    remotePath: item.remotePath,
                    totalBytes: item.totalBytes,
                    overwritePolicy: item.hasConflict ? policy : OverwritePolicy.overwrite
                )
            }
            // Batch path uses backend.uploadBatch for better pipelining on multi-file uploads.
            if uploadItems.count > 1 {
                transferQueue.enqueueUploadBatch(items: uploadItems)
            } else if let item = uploadItems.first {
                transferQueue.enqueueUpload(
                    localURL: item.localURL,
                    remotePath: item.remotePath,
                    totalBytes: item.totalBytes,
                    overwritePolicy: item.overwritePolicy
                )
            }
        case .download:
            for item in batch.items {
                let effectivePolicy: OverwritePolicy = item.hasConflict ? policy : .overwrite
                transferQueue.enqueueDownload(
                    remotePath: item.remotePath,
                    localURL: item.localURL,
                    totalBytes: item.totalBytes,
                    overwritePolicy: effectivePolicy
                )
            }
        }

        onStatusMessage?("Queued \(batch.items.count) transfer(s)")
        MacSCPLogger.shared.info(
            "Queued \(batch.items.count) \(batch.kind == .upload ? "upload" : "download")(s)",
            category: .transfer
        )
    }

    private func remotePathConflict(named name: String, in remoteEntries: [RemoteEntry]) -> Bool {
        remoteEntries.contains { $0.name == name && ($0.type == .file || $0.type == .directory) }
    }
}
