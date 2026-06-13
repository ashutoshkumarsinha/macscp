// AppModel.swift — Thin facade over coordinators; SwiftUI binds here via @Observable.
//
// AppModel forwards state to views and implements TransferBackendProvider for the queue.
// Business logic lives in Coordinators/ (profile, session, panes, transfers).

import Foundation
import MacSCPCore
import MacSCPBackends
import MacSCPUI
import Observation

@MainActor
@Observable
final class AppModel: TransferBackendProvider {
    private let profileCoordinator = ProfileCoordinator()
    private let sessionCoordinator = SessionCoordinator()
    let localPane = LocalPaneCoordinator()
    let remotePane = RemotePaneCoordinator()
    let transfers = TransferCoordinator()
    let fileOps = FileOperationsCoordinator()
    let sync = SyncCoordinator()
    private let remoteEditor = RemoteEditorService()
    private let liveSync = LiveSyncCoordinator()

    var statusMessage = "Ready"
    var hostKeyPrompt: HostKeyTrustRequest?
    var namePrompt: NamePromptState?
    var propertiesPrompt: PropertiesPromptState?
    var liveSyncEnabled = false
    private var paneRefreshTask: Task<Void, Never>?
    private var hostKeyPollTask: Task<Void, Never>?

    var currentBackend: TransferBackend? { sessionCoordinator.backend }

    // MARK: - Forwarded state for views

    var profiles: [SessionProfile] {
        get { profileCoordinator.profiles }
        set { profileCoordinator.profiles = newValue }
    }

    var selectedProfileID: UUID? {
        get { profileCoordinator.selectedProfileID }
        set { profileCoordinator.selectedProfileID = newValue }
    }

    var draft: SessionProfileDraft {
        get { profileCoordinator.draft }
        set { profileCoordinator.draft = newValue }
    }

    var isConnected: Bool {
        get { sessionCoordinator.isConnected }
        set { sessionCoordinator.isConnected = newValue }
    }

    var isConnecting: Bool {
        get { sessionCoordinator.isConnecting }
        set { sessionCoordinator.isConnecting = newValue }
    }

    var showLogin: Bool {
        get { sessionCoordinator.showLogin }
        set { sessionCoordinator.showLogin = newValue }
    }

    var remotePath: String {
        get { sessionCoordinator.remotePath }
        set { sessionCoordinator.remotePath = newValue }
    }

    var activeSessionName: String {
        get { sessionCoordinator.activeSessionName }
        set { sessionCoordinator.activeSessionName = newValue }
    }

    var localPath: URL {
        get { localPane.localPath }
        set { localPane.localPath = newValue }
    }

    var localEntries: [LocalEntry] {
        get { localPane.localEntries }
        set { localPane.localEntries = newValue }
    }

    var remoteEntries: [RemoteEntry] {
        get { remotePane.remoteEntries }
        set { remotePane.remoteEntries = newValue }
    }

    var selectedLocalNames: Set<String> {
        get { localPane.selectedLocalNames }
        set { localPane.selectedLocalNames = newValue }
    }

    var selectedRemoteNames: Set<String> {
        get { remotePane.selectedRemoteNames }
        set { remotePane.selectedRemoteNames = newValue }
    }

    var overwritePrompt: PendingTransferBatch? {
        get { transfers.overwritePrompt }
        set { transfers.overwritePrompt = newValue }
    }

    var transferQueue: TransferQueue { transfers.transferQueue }

    var syncDirection: SyncDirection {
        get { sync.syncDirection }
        set { sync.syncDirection = newValue }
    }

    var syncCompareRows: [SyncCompareRow] {
        sync.compareRows
    }

    var showSyncSheet: Bool {
        get { sync.showSyncSheet }
        set { sync.showSyncSheet = newValue }
    }

    struct NamePromptState: Identifiable {
        var id = UUID()
        var title: String
        var placeholder: String
        var initialValue: String
        var paneSide: FilePaneSide
        var mode: NamePromptMode
    }

    enum NamePromptMode {
        case newFolder
        case rename(entryName: String)
    }

    struct PropertiesPromptState: Identifiable {
        var id = UUID()
        var paneSide: FilePaneSide
        var entryName: String
        var permissionsOctal: String
    }

    init() {
        wireCoordinators()

        if let settings = try? MacSCPConfiguration.loadSettings(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) {
            sessionCoordinator.applyTransferSettings(settings.transfer)
            transfers.applyTransferSettings(settings.transfer)
        }

        transfers.bind(backendProvider: self)
        Task { await HostKeyTrustGate.shared.setMode(.interactive) }
        Task { await refreshLocal() }
        MacSCPLogger.shared.info("MacSCP started (profiles: \(profiles.count))", category: .app)
    }

    private func wireCoordinators() {
        // Route coordinator status updates into the single status bar string.
        let setStatus: (String) -> Void = { [weak self] message in
            self?.statusMessage = message
        }

        profileCoordinator.onStatusMessage = setStatus
        sessionCoordinator.onStatusMessage = setStatus
        remotePane.onStatusMessage = setStatus
        transfers.onStatusMessage = setStatus
        fileOps.onStatusMessage = setStatus
        sync.onStatusMessage = setStatus

        sessionCoordinator.onConnected = { [weak self] in
            await self?.refreshRemote()
        }

        sessionCoordinator.onDisconnected = { [weak self] in
            self?.transfers.handleDisconnect()
            self?.liveSync.stop()
            self?.liveSyncEnabled = false
            self?.remoteEditor.stopAll()
            self?.paneRefreshTask?.cancel()
            self?.paneRefreshTask = nil
            self?.hostKeyPollTask?.cancel()
            self?.hostKeyPollTask = nil
            self?.remotePane.remoteEntries = []
            self?.remotePane.selectedRemoteNames = []
        }

        transfers.onTransferComplete = { [weak self] jobID in
            self?.schedulePaneRefresh(afterJobID: jobID)
        }
    }

    func syncDraftFromSelection() { profileCoordinator.syncDraftFromSelection() }
    func selectProfile(_ id: UUID) { profileCoordinator.selectProfile(id) }
    func deleteProfile(id: UUID) { profileCoordinator.deleteProfile(id: id) }
    func saveDraftAsProfile() { _ = profileCoordinator.saveDraftAsProfile() }

    func connect() async {
        guard await AppLockService.authenticate(reason: "Unlock MacSCP to connect") else {
            statusMessage = "Authentication required"
            return
        }
        startHostKeyPolling()
        await sessionCoordinator.connect(using: profileCoordinator.draft)
        stopHostKeyPolling()
    }

    func respondHostKey(trusted: Bool) {
        Task { await HostKeyTrustGate.shared.respond(trusted: trusted) }
        hostKeyPrompt = nil
    }

    private func startHostKeyPolling() {
        hostKeyPollTask?.cancel()
        hostKeyPollTask = Task {
            while !Task.isCancelled {
                if let request = await HostKeyTrustGate.shared.peekPendingRequest() {
                    hostKeyPrompt = request
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func stopHostKeyPolling() {
        hostKeyPollTask?.cancel()
        hostKeyPollTask = nil
        hostKeyPrompt = nil
    }

    func disconnect() async {
        await sessionCoordinator.disconnect()
    }

    func refreshLocal() async {
        await localPane.refreshLocal()
    }

    func refreshRemote() async {
        await remotePane.refreshRemote(backend: sessionCoordinator.backend, at: sessionCoordinator.remotePath)
    }

    func navigateLocalUp() { localPane.navigateUp() }

    func navigateRemoteUp() async {
        _ = await remotePane.navigateUp(remotePath: &sessionCoordinator.remotePath)
        await refreshRemote()
    }

    func openLocalDirectory(_ name: String) { localPane.openDirectory(name) }

    func openRemoteDirectory(_ name: String) async {
        _ = remotePane.openDirectory(name, remotePath: &sessionCoordinator.remotePath)
        await refreshRemote()
    }

    func uploadSelected() async {
        await transfers.uploadSelected(
            localPane: localPane,
            remotePath: sessionCoordinator.remotePath,
            remoteEntries: remotePane.remoteEntries,
            isConnected: sessionCoordinator.isConnected
        )
    }

    func downloadSelected() async {
        await transfers.downloadSelected(
            localPane: localPane,
            remotePane: remotePane,
            backend: sessionCoordinator.backend,
            isConnected: sessionCoordinator.isConnected
        )
    }

    func uploadDropped(fileNames: [String]) async {
        await transfers.uploadDropped(
            fileNames: fileNames,
            localPane: localPane,
            remotePath: sessionCoordinator.remotePath,
            remoteEntries: remotePane.remoteEntries,
            isConnected: sessionCoordinator.isConnected
        )
    }

    func downloadDropped(fileNames: [String]) async {
        await transfers.downloadDropped(
            fileNames: fileNames,
            localPane: localPane,
            remotePane: remotePane,
            backend: sessionCoordinator.backend,
            isConnected: sessionCoordinator.isConnected
        )
    }

    func resolveOverwritePrompt(action: OverwriteBatchAction) {
        transfers.resolveOverwritePrompt(action: action)
    }

    func transferDidComplete(jobID: UUID) {
        transfers.transferDidComplete(jobID: jobID)
    }

    func compareDirectories() async {
        await sync.compare(
            localPath: localPath,
            remotePath: remotePath,
            backend: sessionCoordinator.backend
        )
    }

    func runSync(previewOnly: Bool) {
        sync.enqueueSync(transferCoordinator: transfers, previewOnly: previewOnly)
    }

    func openTerminal() {
        let config = profileCoordinator.draft.toSessionConfiguration()
        TerminalHandoff.openSSHSession(configuration: config, remotePath: remotePath)
    }

    func toggleLiveSync() {
        if liveSyncEnabled {
            liveSync.stop()
            liveSyncEnabled = false
            statusMessage = "Live sync stopped"
        } else {
            liveSync.start(
                localRoot: localPath,
                remoteRoot: remotePath,
                transferCoordinator: transfers,
                onStatus: { [weak self] message in self?.statusMessage = message }
            )
            liveSyncEnabled = true
        }
    }

    func quickLookRemote() async {
        guard let name = remotePane.selectedRemoteNames.first,
              let entry = remotePane.remoteEntries.first(where: { $0.name == name }) else { return }
        await QuickLookPreviewService.previewRemoteFile(
            entry: entry,
            backend: sessionCoordinator.backend!,
            onStatus: { [weak self] message in self?.statusMessage = message }
        )
    }

    func editRemoteSelection() async {
        guard let name = remotePane.selectedRemoteNames.first,
              let entry = remotePane.remoteEntries.first(where: { $0.name == name }),
              let backend = sessionCoordinator.backend else { return }
        await remoteEditor.editRemoteFile(
            entry: entry,
            backend: backend,
            onStatus: { [weak self] message in self?.statusMessage = message }
        )
    }

    func promptNewFolder(pane: FilePaneSide) {
        namePrompt = NamePromptState(
            title: "New Folder",
            placeholder: "Folder name",
            initialValue: "",
            paneSide: pane,
            mode: .newFolder
        )
    }

    func promptRename(pane: FilePaneSide, entryName: String) {
        namePrompt = NamePromptState(
            title: "Rename",
            placeholder: "New name",
            initialValue: entryName,
            paneSide: pane,
            mode: .rename(entryName: entryName)
        )
    }

    func confirmNamePrompt(_ value: String) async {
        guard let prompt = namePrompt else { return }
        namePrompt = nil
        switch prompt.mode {
        case .newFolder:
            if prompt.paneSide == .local {
                if fileOps.createLocalDirectory(name: value, localPath: localPath) {
                    await refreshLocal()
                }
            } else {
                if await fileOps.createRemoteDirectory(
                    name: value,
                    backend: sessionCoordinator.backend,
                    remotePath: remotePath
                ) {
                    await refreshRemote()
                }
            }
        case let .rename(oldName):
            if prompt.paneSide == .local {
                if fileOps.renameLocal(from: oldName, to: value, localPath: localPath) {
                    await refreshLocal()
                }
            } else {
                if await fileOps.renameRemote(
                    from: oldName,
                    to: value,
                    backend: sessionCoordinator.backend,
                    remotePath: remotePath
                ) {
                    await refreshRemote()
                }
            }
        }
    }

    func promptProperties(pane: FilePaneSide, entryName: String) {
        let octal: String
        if pane == .remote,
           let entry = remotePane.remoteEntries.first(where: { $0.name == entryName }),
           let perm = entry.permissions {
            octal = String(format: "%o", perm.octal)
        } else {
            octal = "644"
        }
        propertiesPrompt = PropertiesPromptState(
            paneSide: pane,
            entryName: entryName,
            permissionsOctal: octal
        )
    }

    func saveProperties(octal: String) async {
        guard let prompt = propertiesPrompt else { return }
        propertiesPrompt = nil
        guard prompt.paneSide == .remote,
              let value = UInt32(octal, radix: 8) else { return }
        if await fileOps.setRemotePermissions(
            FilePermissions(octal: value),
            name: prompt.entryName,
            backend: sessionCoordinator.backend,
            remotePath: remotePath
        ) {
            await refreshRemote()
        }
    }

    func deleteSelected(pane: FilePaneSide) async {
        switch pane {
        case .local:
            if fileOps.deleteLocal(names: Array(localPane.selectedLocalNames), localPath: localPath) {
                await refreshLocal()
            }
        case .remote:
            if await fileOps.deleteRemote(
                names: Array(remotePane.selectedRemoteNames),
                entries: remotePane.remoteEntries,
                backend: sessionCoordinator.backend,
                remotePath: remotePath
            ) {
                await refreshRemote()
            }
        }
    }

    private func schedulePaneRefresh(afterJobID jobID: UUID) {
        // Debounce listing refresh so bursts of small files do not hammer listDirectory.
        paneRefreshTask?.cancel()
        paneRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            if transfers.transferQueue.activeCount > 0 { return }
            await refreshRemote()
            await refreshLocal()
        }

        if let job = transfers.transferQueue.jobs.first(where: { $0.id == jobID }) {
            statusMessage = "\(job.displayName) transfer complete"
        }
    }
}

struct SessionProfileDraft: Equatable {
    // Mutable login form; converted to SessionProfile on save/connect.
    var name: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var keyPath: String = "~/.ssh/id_ed25519"
    var authMethod: AuthMethod = .publicKey
    var initialRemotePath: String = "/"
    var hostKeyFingerprint: String = ""

    init() {}

    init(from profile: SessionProfile) {
        name = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        password = profile.password ?? ""
        keyPath = profile.keyPath ?? "~/.ssh/id_ed25519"
        authMethod = profile.authMethod
        initialRemotePath = profile.initialRemotePath
        hostKeyFingerprint = profile.hostKeyFingerprint ?? ""
    }

    func validatePort() -> Bool {
        guard let value = Int(port), (1 ... 65_535).contains(value) else { return false }
        return true
    }

    func toProfile(existingID: UUID?) -> SessionProfile {
        SessionProfile(
            id: existingID ?? UUID(),
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            password: authMethod == .password ? (password.isEmpty ? nil : password) : nil,
            authMethod: authMethod,
            keyPath: authMethod == .publicKey ? keyPath : nil,
            initialRemotePath: initialRemotePath,
            hostKeyFingerprint: hostKeyFingerprint.isEmpty ? nil : hostKeyFingerprint
        )
    }

    func toSessionConfiguration() -> SessionConfiguration {
        toProfile(existingID: nil).sessionConfiguration
    }
}

struct LocalEntry: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
}

enum LocalFileService {
    // Runs off the main thread from LocalPaneCoordinator.refreshLocal().
    static func list(directory: URL) -> [LocalEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return LocalEntry(
                name: url.lastPathComponent,
                isDirectory: values?.isDirectory ?? false,
                size: values?.fileSize.map { Int64($0) },
                modified: values?.contentModificationDate
            )
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}
