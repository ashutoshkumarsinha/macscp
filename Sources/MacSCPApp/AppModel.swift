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

    var statusMessage = "Ready"
    private var paneRefreshTask: Task<Void, Never>?

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

    init() {
        wireCoordinators()

        if let settings = try? MacSCPConfiguration.loadSettings(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) {
            sessionCoordinator.applyTransferSettings(settings.transfer)
            transfers.applyTransferSettings(settings.transfer)
        }

        transfers.bind(backendProvider: self)
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

        sessionCoordinator.onConnected = { [weak self] in
            await self?.refreshRemote()
        }

        sessionCoordinator.onDisconnected = { [weak self] in
            // Fail queued jobs and clear remote pane when the SSH session ends.
            self?.transfers.handleDisconnect()
            self?.paneRefreshTask?.cancel()
            self?.paneRefreshTask = nil
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
        await sessionCoordinator.connect(using: profileCoordinator.draft)
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
            initialRemotePath: initialRemotePath
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
