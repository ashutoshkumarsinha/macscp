import Foundation
import MacSCPCore
import MacSCPBackends
import Observation

@MainActor
@Observable
final class AppModel: TransferBackendProvider {
    var profiles: [SessionProfile] = []
    var selectedProfileID: UUID?
    var draft = SessionProfileDraft()
    var isConnected = false
    var isConnecting = false
    var showLogin = true
    var statusMessage = "Ready"
    var localPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var remotePath = "/"
    var localEntries: [LocalEntry] = []
    var remoteEntries: [RemoteEntry] = []
    var activeSessionName = ""
    var selectedLocalNames = Set<String>()
    var selectedRemoteNames = Set<String>()
    var overwritePrompt: PendingTransferBatch?
    let transferQueue = TransferQueue()

    private var backend: TransferBackend?
    private let profileStore = ProfileStore()
    private let connectionService = SessionConnectionService()

    var currentBackend: TransferBackend? { backend }

    init() {
        profiles = profileStore.load()
        if profiles.isEmpty {
            profiles = SessionProfile.sampleProfiles
        }
        selectedProfileID = profiles.first?.id
        syncDraftFromSelection()
        refreshLocal()
        transferQueue.bind(backendProvider: self)
    }

    func syncDraftFromSelection() {
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        draft = SessionProfileDraft(from: profile)
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        syncDraftFromSelection()
    }

    func saveDraftAsProfile() {
        let profile = draft.toProfile(existingID: selectedProfileID)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        selectedProfileID = profile.id
        profileStore.save(profiles)
        statusMessage = "Saved profile \"\(profile.name)\""
    }

    func connect() async {
        isConnecting = true
        statusMessage = "Connecting…"
        defer { isConnecting = false }

        do {
            let session = draft.toSessionConfiguration()
            let newBackend = try TransferBackendFactory.make(for: .sftp, backend: .citadel)
            try await connectionService.connect(backend: newBackend, configuration: session)
            backend = newBackend
            remotePath = session.initialRemotePath.isEmpty ? "/" : session.initialRemotePath
            activeSessionName = draft.name.isEmpty ? session.host : draft.name
            isConnected = true
            showLogin = false
            statusMessage = "Connected to \(session.host)"
            await refreshRemote()
        } catch {
            statusMessage = "Connection failed: \(error.localizedDescription)"
        }
    }

    func disconnect() async {
        if let backend {
            try? await connectionService.disconnect(backend: backend)
        }
        backend = nil
        isConnected = false
        remoteEntries = []
        selectedRemoteNames = []
        showLogin = true
        statusMessage = "Disconnected"
    }

    func refreshLocal() {
        localEntries = LocalFileService.list(directory: localPath)
    }

    func refreshRemote() async {
        guard let backend else { return }
        do {
            remoteEntries = try await backend.listDirectory(at: remotePath)
            statusMessage = "Remote listing updated"
        } catch {
            statusMessage = "Remote list failed: \(error.localizedDescription)"
        }
    }

    func navigateLocalUp() {
        localPath.deleteLastPathComponent()
        selectedLocalNames = []
        refreshLocal()
    }

    func navigateRemoteUp() async {
        remotePath = (remotePath as NSString).deletingLastPathComponent
        if remotePath.isEmpty { remotePath = "/" }
        selectedRemoteNames = []
        await refreshRemote()
    }

    func openLocalDirectory(_ name: String) {
        localPath.appendPathComponent(name, isDirectory: true)
        selectedLocalNames = []
        refreshLocal()
    }

    func openRemoteDirectory(_ name: String) async {
        if remotePath.hasSuffix("/") {
            remotePath += name
        } else {
            remotePath += "/" + name
        }
        selectedRemoteNames = []
        await refreshRemote()
    }

    func uploadSelected() {
        let files = localEntries.filter { selectedLocalNames.contains($0.name) && !$0.isDirectory }
        guard !files.isEmpty else {
            statusMessage = "Select local files to upload"
            return
        }
        let items = files.map { file in
            PendingTransferItem(
                localURL: localPath.appendingPathComponent(file.name),
                remotePath: joinRemote(remotePath, file.name),
                totalBytes: file.size,
                hasConflict: remoteFileExists(named: file.name)
            )
        }
        queueTransfers(kind: .upload, items: items)
        selectedLocalNames = []
    }

    func downloadSelected() {
        let files = remoteEntries.filter { selectedRemoteNames.contains($0.name) && $0.type == .file }
        guard !files.isEmpty else {
            statusMessage = "Select remote files to download"
            return
        }
        let items = files.map { file in
            PendingTransferItem(
                localURL: localPath.appendingPathComponent(file.name),
                remotePath: file.path,
                totalBytes: file.size,
                hasConflict: FileManager.default.fileExists(atPath: localPath.appendingPathComponent(file.name).path)
            )
        }
        queueTransfers(kind: .download, items: items)
        selectedRemoteNames = []
    }

    func uploadDropped(fileNames: [String]) {
        let files = localEntries.filter { fileNames.contains($0.name) && !$0.isDirectory }
        guard !files.isEmpty else { return }
        let items = files.map { file in
            PendingTransferItem(
                localURL: localPath.appendingPathComponent(file.name),
                remotePath: joinRemote(remotePath, file.name),
                totalBytes: file.size,
                hasConflict: remoteFileExists(named: file.name)
            )
        }
        queueTransfers(kind: .upload, items: items)
    }

    func downloadDropped(fileNames: [String]) {
        let files = remoteEntries.filter { fileNames.contains($0.name) && $0.type == .file }
        guard !files.isEmpty else { return }
        let items = files.map { file in
            PendingTransferItem(
                localURL: localPath.appendingPathComponent(file.name),
                remotePath: file.path,
                totalBytes: file.size,
                hasConflict: FileManager.default.fileExists(atPath: localPath.appendingPathComponent(file.name).path)
            )
        }
        queueTransfers(kind: .download, items: items)
    }

    func resolveOverwritePrompt(action: OverwriteBatchAction) {
        guard let batch = overwritePrompt else { return }
        overwritePrompt = nil

        switch action {
        case .cancel:
            statusMessage = "Transfer cancelled"
            return
        case .overwriteAll:
            enqueueBatch(batch, policy: .overwrite)
        case .skipExisting:
            enqueueBatch(batch, policy: .skip)
        case .renameAll:
            enqueueBatch(batch, policy: .rename)
        }
    }

    private func queueTransfers(kind: PendingTransferBatch.Kind, items: [PendingTransferItem]) {
        guard backend != nil, !items.isEmpty else { return }

        if items.contains(where: \.hasConflict) {
            overwritePrompt = PendingTransferBatch(kind: kind, items: items)
            statusMessage = "Confirm overwrite for \(overwritePrompt?.conflictNames.count ?? 0) file(s)"
            return
        }

        enqueueBatch(PendingTransferBatch(kind: kind, items: items), policy: .overwrite)
    }

    private func enqueueBatch(_ batch: PendingTransferBatch, policy: OverwritePolicy) {
        for item in batch.items {
            let effectivePolicy: OverwritePolicy = item.hasConflict ? policy : .overwrite

            switch batch.kind {
            case .upload:
                transferQueue.enqueueUpload(
                    localURL: item.localURL,
                    remotePath: item.remotePath,
                    totalBytes: item.totalBytes,
                    overwritePolicy: effectivePolicy
                )
            case .download:
                transferQueue.enqueueDownload(
                    remotePath: item.remotePath,
                    localURL: item.localURL,
                    totalBytes: item.totalBytes,
                    overwritePolicy: effectivePolicy
                )
            }
        }
        statusMessage = "Queued \(batch.items.count) transfer(s)"
    }

    private func remoteFileExists(named name: String) -> Bool {
        remoteEntries.contains { $0.name == name && $0.type == .file }
    }

    func transferDidComplete(jobID: UUID) {
        Task {
            await refreshRemote()
            refreshLocal()
        }
        if let job = transferQueue.jobs.first(where: { $0.id == jobID }) {
            statusMessage = "\(job.displayName) transfer complete"
        }
    }

    private func joinRemote(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}

struct SessionProfileDraft: Equatable {
    var name: String = ""
    var host: String = ""
    var port: String = "22"
    var username: String = ""
    var password: String = ""
    var keyPath: String = "~/.ssh/id_ed25519"
    var useKeyAuth: Bool = true
    var initialRemotePath: String = "/"

    init() {}

    init(from profile: SessionProfile) {
        name = profile.name
        host = profile.host
        port = String(profile.port)
        username = profile.username
        password = profile.password ?? ""
        keyPath = profile.keyPath ?? "~/.ssh/id_ed25519"
        useKeyAuth = profile.authMethod == .publicKey
        initialRemotePath = profile.initialRemotePath
    }

    func toProfile(existingID: UUID?) -> SessionProfile {
        SessionProfile(
            id: existingID ?? UUID(),
            name: name,
            host: host,
            port: Int(port) ?? 22,
            username: username,
            password: password.isEmpty ? nil : password,
            authMethod: useKeyAuth ? .publicKey : .password,
            keyPath: useKeyAuth ? keyPath : nil,
            initialRemotePath: initialRemotePath
        )
    }

    func toSessionConfiguration() -> SessionConfiguration {
        toProfile(existingID: nil).sessionConfiguration
    }
}

struct LocalEntry: Identifiable, Hashable {
    let id = UUID()
    var name: String
    var isDirectory: Bool
    var size: Int64?
    var modified: Date?
}

enum LocalFileService {
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
