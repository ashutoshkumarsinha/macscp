// ShortcutsBridge.swift
//
// WHAT THIS FILE DOES
// -------------------
// Shared automation entry points for App Intents, URL handlers, and scripting. Connects via
// saved profile name and runs upload/download with a temporary TransferBackend session.
//

import Foundation
import MacSCPCore
import MacSCPBackends

enum ShortcutsBridge {
    static func connect(profileName: String) async throws {
        try await withConnectedBackend(profileName: profileName) { _ in }
    }

    static func uploadFile(profileName: String, localPath: String, remotePath: String) async throws {
        try await withConnectedBackend(profileName: profileName) { backend in
            let localURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
            _ = try await backend.upload(
                localURL: localURL,
                remotePath: remotePath,
                options: TransferOptions(overwrite: .overwrite)
            )
        }
    }

    static func downloadFile(profileName: String, remotePath: String, localPath: String) async throws {
        try await withConnectedBackend(profileName: profileName) { backend in
            let localURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
            let parent = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try await backend.download(
                remotePath: remotePath,
                localURL: localURL,
                options: TransferOptions()
            )
        }
    }

    static func syncDirectories(
        profileName: String,
        localPath: String,
        remotePath: String,
        mirrorRemote: Bool
    ) async throws {
        try await withConnectedBackend(profileName: profileName) { backend in
            let localURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath, isDirectory: true)
            let rows = try await DirectorySyncEngine.compare(
                localRoot: localURL,
                remoteRoot: remotePath,
                backend: backend
            )
            let direction: SyncDirection = mirrorRemote ? .mirrorRemoteToLocal : .mirrorLocalToRemote
            let files = DirectorySyncEngine.toTransferFiles(rows: rows, direction: direction)
            for file in files {
                if direction == .mirrorLocalToRemote {
                    _ = try await backend.upload(
                        localURL: file.localURL,
                        remotePath: file.remotePath,
                        options: TransferOptions(overwrite: .overwrite)
                    )
                } else {
                    try DirectoryTransferPlanner.ensureLocalDirectories(for: [file])
                    _ = try await backend.download(
                        remotePath: file.remotePath,
                        localURL: file.localURL,
                        options: TransferOptions()
                    )
                }
            }
        }
    }

    static func runScript(at path: String) async throws {
        let candidates = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/macscp").path,
            "/usr/local/bin/macscp",
        ]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ShortcutsBridgeError.scriptRunnerUnavailable
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["script", path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ShortcutsBridgeError.scriptFailed(Int(process.terminationStatus))
        }
    }

    static func openSessionURL(_ url: URL) async throws {
        if url.scheme?.lowercased() == "macscp" {
            guard url.host?.lowercased() == "open",
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  let sessionID = components.queryItems?.first(where: { $0.name == "session" })?.value,
                  let uuid = UUID(uuidString: sessionID) else {
                throw ShortcutsBridgeError.invalidURL
            }
            let profiles = try ProfileStore().load()
            guard let profile = profiles.first(where: { $0.id == uuid }) else {
                throw ShortcutsBridgeError.profileNotFound(sessionID)
            }
            try await connect(profileName: profile.name)
            return
        }

        let connection = try ConnectionURL.parse(url.absoluteString)
        try await withConnectedBackend(
            configuration: SessionConfigurationBuilder.make(
                transferProtocol: connection.transferProtocol,
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: connection.password,
                keyPath: connection.keyPath,
                authMethod: connection.authMethod,
                remotePath: connection.path,
                implicitTLS: connection.implicitTLS
            )
        ) { _ in }
    }

    private static func withConnectedBackend(
        profileName: String,
        operation: (TransferBackend) async throws -> Void
    ) async throws {
        let profiles = try ProfileStore().load()
        guard let profile = profiles.first(where: { $0.name == profileName }) else {
            throw ShortcutsBridgeError.profileNotFound(profileName)
        }
        try await withConnectedBackend(configuration: profile.sessionConfiguration, operation: operation)
    }

    private static func withConnectedBackend(
        configuration: SessionConfiguration,
        operation: (TransferBackend) async throws -> Void
    ) async throws {
        var config = configuration
        if let settings = try? MacSCPConfiguration.loadSettings(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) {
            config.networkProfile = TransferPerformanceTuning.networkProfile(from: settings.transfer.preset)
        }

        let backendKind = SFTPBackendSelector.select(
            authMethod: config.authMethod,
            settings: (try? MacSCPConfiguration.loadSettings(
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            ))?.transfer ?? MacSCPTransferSettings()
        )
        let backend = try TransferBackendFactory.make(
            for: config.protocol,
            backend: backendKind,
            serialized: true
        )
        try await backend.connect(configuration: config)
        defer { Task { try? await backend.disconnect() } }
        try await operation(backend)
    }
}

enum ShortcutsBridgeError: LocalizedError {
    case profileNotFound(String)
    case invalidURL
    case scriptRunnerUnavailable
    case scriptFailed(Int)

    var errorDescription: String? {
        switch self {
        case .profileNotFound(let name):
            return "Profile not found: \(name)"
        case .invalidURL:
            return "Invalid MacSCP URL"
        case .scriptRunnerUnavailable:
            return "macscp CLI not found"
        case .scriptFailed(let code):
            return "Script failed with exit code \(code)"
        }
    }
}
