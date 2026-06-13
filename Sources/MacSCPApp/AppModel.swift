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
        guard backend != nil else { return }
        let files = localEntries.filter { selectedLocalNames.contains($0.name) && !$0.isDirectory }
        guard !files.isEmpty else {
            statusMessage = "Select local files to upload"
            return
        }

        for file in files {
            let localURL = localPath.appendingPathComponent(file.name)
            let remote = joinRemote(remotePath, file.name)
            transferQueue.enqueueUpload(
                localURL: localURL,
                remotePath: remote,
                totalBytes: file.size
            )
        }
        statusMessage = "Queued \(files.count) upload(s)"
        selectedLocalNames = []
    }

    func downloadSelected() {
        guard backend != nil else { return }
        let files = remoteEntries.filter { selectedRemoteNames.contains($0.name) && $0.type == .file }
        guard !files.isEmpty else {
            statusMessage = "Select remote files to download"
            return
        }

        for file in files {
            let localURL = localPath.appendingPathComponent(file.name)
            transferQueue.enqueueDownload(
                remotePath: file.path,
                localURL: localURL,
                totalBytes: file.size
            )
        }
        statusMessage = "Queued \(files.count) download(s)"
        selectedRemoteNames = []
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
