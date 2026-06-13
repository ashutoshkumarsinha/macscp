import Foundation
import MacSCPCore
import MacSCPBackends

enum CLIActions {
    static func open(url: String, password: String?, agent: Bool, hostkey: String?, batch: Bool) async throws {
        try await CLISessionStore.shared.loadSettings()
        if batch {
            await HostKeyTrustGate.shared.setMode(.batchStrict)
        }
        let parsed: SFTPConnectionURL
        do {
            parsed = try SFTPConnectionURL.parse(url)
        } catch {
            throw CLIError.usage("Expected sftp://user@host/path URL")
        }
        var auth = parsed.authMethod
        if agent { auth = .agent }
        let config = CLISessionBuilder.configuration(
            host: parsed.host,
            port: parsed.port,
            username: parsed.username,
            password: password ?? parsed.password,
            keyPath: parsed.keyPath.map { NSString(string: $0).expandingTildeInPath },
            authMethod: auth,
            remotePath: parsed.path,
            hostKeyFingerprint: hostkey
        )
        do {
            try await CLISessionStore.shared.connect(config)
            print("Connected to \(parsed.host):\(parsed.port)")
        } catch let error as BackendError {
            throw CLIErrorMapper.map(error)
        }
    }

    static func close() async throws {
        try await CLISessionStore.shared.disconnect()
        print("Disconnected")
    }

    static func ls(path: String, json: Bool) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let entries = try await backend.listDirectory(at: path)
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(entries)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for entry in entries {
                let kind = entry.type == .directory ? "d" : "-"
                let size = entry.size.map(String.init) ?? "-"
                print("\(kind)\t\(size)\t\(entry.name)")
            }
        }
    }

    static func get(remote: String, local: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath, isDirectory: false)
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        _ = try await backend.download(remotePath: remote, localURL: localURL, options: TransferOptions())
        print("Downloaded \(remote) → \(localURL.path)")
    }

    static func put(local: String, remote: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath)
        _ = try await backend.upload(localURL: localURL, remotePath: remote, options: TransferOptions())
        print("Uploaded \(localURL.path) → \(remote)")
    }

    static func sync(local: String, remote: String, mirrorRemote: Bool, preview: Bool) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath, isDirectory: true)
        let rows = try await DirectorySyncEngine.compare(localRoot: localURL, remoteRoot: remote, backend: backend)
        let direction: SyncDirection = mirrorRemote ? .mirrorRemoteToLocal : .mirrorLocalToRemote
        let files = DirectorySyncEngine.toTransferFiles(rows: rows, direction: direction)
        if preview {
            print("Would transfer \(files.count) file(s)")
            return
        }
        for file in files {
            if direction == .mirrorLocalToRemote {
                _ = try await backend.upload(localURL: file.localURL, remotePath: file.remotePath, options: TransferOptions())
            } else {
                try DirectoryTransferPlanner.ensureLocalDirectories(for: [file])
                _ = try await backend.download(remotePath: file.remotePath, localURL: file.localURL, options: TransferOptions())
            }
        }
        print("Synchronized \(files.count) file(s)")
    }
}

enum CLIErrorMapper {
    static func map(_ error: BackendError) -> CLIError {
        switch error {
        case .authenticationFailed: return .authFailed
        case .hostKeyRejected: return .hostKeyRejected
        default: return .connectionFailed(error.localizedDescription)
        }
    }
}

enum MacSCPScriptRunner {
    static func run(_ text: String) async throws {
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard let verb = parts.first?.lowercased() else { continue }
            switch verb {
            case "open":
                guard parts.count >= 2 else { throw CLIError.usage("open requires URL") }
                try await CLIActions.open(url: parts[1], password: nil, agent: false, hostkey: nil, batch: false)
            case "close":
                try await CLIActions.close()
            case "ls":
                try await CLIActions.ls(path: parts.count > 1 ? parts[1] : "/", json: false)
            case "get":
                guard parts.count >= 3 else { throw CLIError.usage("get remote local") }
                try await CLIActions.get(remote: parts[1], local: parts[2])
            case "put":
                guard parts.count >= 3 else { throw CLIError.usage("put local remote") }
                try await CLIActions.put(local: parts[1], remote: parts[2])
            case "exit", "quit":
                return
            default:
                throw CLIError.usage("Unknown command: \(verb)")
            }
        }
    }
}
