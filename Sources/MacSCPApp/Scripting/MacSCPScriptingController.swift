// MacSCPScriptingController.swift — AppleScript command handlers (connect, disconnect, upload, download).

import AppKit
import Foundation
import MacSCPCore
import MacSCPBackends

@MainActor
enum MacSCPScriptingController {
    static weak var appModel: AppModel?

    static func connect(profileName: String) async throws {
        guard let appModel else { throw ScriptingError.appUnavailable }
        guard let profile = appModel.profiles.first(where: { $0.name == profileName }) else {
            throw ScriptingError.profileNotFound(profileName)
        }
        appModel.selectedProfileID = profile.id
        appModel.draft = SessionProfileDraft(from: profile)
        await appModel.connect()
    }

    static func disconnect() async {
        await appModel?.disconnect()
    }

    static func upload(localPath: String, remotePath: String) async throws {
        guard let appModel else { throw ScriptingError.appUnavailable }
        if appModel.isConnected, let backend = appModel.currentBackend {
            let localURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
            _ = try await backend.upload(
                localURL: localURL,
                remotePath: remotePath,
                options: TransferOptions(overwrite: .overwrite)
            )
            return
        }
        let profileName = appModel.activeSessionName.isEmpty ? appModel.draft.name : appModel.activeSessionName
        try await ShortcutsBridge.uploadFile(
            profileName: profileName,
            localPath: localPath,
            remotePath: remotePath
        )
    }

    static func download(remotePath: String, localPath: String) async throws {
        guard let appModel else { throw ScriptingError.appUnavailable }
        if appModel.isConnected, let backend = appModel.currentBackend {
            let localURL = URL(fileURLWithPath: NSString(string: localPath).expandingTildeInPath)
            let parent = localURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            _ = try await backend.download(
                remotePath: remotePath,
                localURL: localURL,
                options: TransferOptions()
            )
            return
        }
        let profileName = appModel.activeSessionName.isEmpty ? appModel.draft.name : appModel.activeSessionName
        try await ShortcutsBridge.downloadFile(
            profileName: profileName,
            remotePath: remotePath,
            localPath: localPath
        )
    }
}

enum ScriptingError: LocalizedError {
    case appUnavailable
    case profileNotFound(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .appUnavailable: return "MacSCP is not ready"
        case .profileNotFound(let name): return "Profile not found: \(name)"
        case .notConnected: return "Not connected"
        }
    }
}
