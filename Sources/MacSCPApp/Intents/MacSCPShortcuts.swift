// MacSCPShortcuts.swift
//
// WHAT THIS FILE DOES
// -------------------
// Shortcuts and App Intents actions for automation (connect, upload, download). Each intent
// delegates to ShortcutsBridge for shared entry points with URL handlers and scripting.
//

import AppIntents
import Foundation

struct ConnectToSessionIntent: AppIntent {
    static var title: LocalizedStringResource { "Connect to Session" }
    static var description: IntentDescription { IntentDescription("Connect MacSCP to a saved session profile.") }

    @Parameter(title: "Profile Name")
    var profileName: String

    func perform() async throws -> some IntentResult {
        try await ShortcutsBridge.connect(profileName: profileName)
        return .result()
    }
}

struct UploadFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Upload File" }
    static var description: IntentDescription { IntentDescription("Upload a local file to a saved session.") }

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Local Path")
    var localPath: String

    @Parameter(title: "Remote Path")
    var remotePath: String

    func perform() async throws -> some IntentResult {
        try await ShortcutsBridge.uploadFile(
            profileName: profileName,
            localPath: localPath,
            remotePath: remotePath
        )
        return .result()
    }
}

struct DownloadFileIntent: AppIntent {
    static var title: LocalizedStringResource { "Download File" }
    static var description: IntentDescription { IntentDescription("Download a remote file using a saved session.") }

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Remote Path")
    var remotePath: String

    @Parameter(title: "Local Path")
    var localPath: String

    func perform() async throws -> some IntentResult {
        try await ShortcutsBridge.downloadFile(
            profileName: profileName,
            remotePath: remotePath,
            localPath: localPath
        )
        return .result()
    }
}

struct SyncDirectoriesIntent: AppIntent {
    static var title: LocalizedStringResource { "Sync Directories" }
    static var description: IntentDescription { IntentDescription("One-way sync between local and remote directories.") }

    @Parameter(title: "Profile Name")
    var profileName: String

    @Parameter(title: "Local Path")
    var localPath: String

    @Parameter(title: "Remote Path")
    var remotePath: String

    @Parameter(title: "Mirror Remote to Local", default: false)
    var mirrorRemote: Bool

    func perform() async throws -> some IntentResult {
        try await ShortcutsBridge.syncDirectories(
            profileName: profileName,
            localPath: localPath,
            remotePath: remotePath,
            mirrorRemote: mirrorRemote
        )
        return .result()
    }
}

struct RunScriptIntent: AppIntent {
    static var title: LocalizedStringResource { "Run MacSCP Script" }
    static var description: IntentDescription { IntentDescription("Run a .macscp script file.") }

    @Parameter(title: "Script Path")
    var scriptPath: String

    func perform() async throws -> some IntentResult {
        try await ShortcutsBridge.runScript(at: scriptPath)
        return .result()
    }
}

struct MacSCPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectToSessionIntent(),
            phrases: [
                "Connect to session in \(.applicationName)",
                "Open session in \(.applicationName)",
            ],
            shortTitle: "Connect Session",
            systemImageName: "link"
        )
        AppShortcut(
            intent: UploadFileIntent(),
            phrases: [
                "Upload file with \(.applicationName)",
            ],
            shortTitle: "Upload File",
            systemImageName: "arrow.up.doc"
        )
        AppShortcut(
            intent: DownloadFileIntent(),
            phrases: [
                "Download file with \(.applicationName)",
            ],
            shortTitle: "Download File",
            systemImageName: "arrow.down.doc"
        )
        AppShortcut(
            intent: SyncDirectoriesIntent(),
            phrases: [
                "Sync directories with \(.applicationName)",
            ],
            shortTitle: "Sync Directories",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: RunScriptIntent(),
            phrases: [
                "Run script in \(.applicationName)",
            ],
            shortTitle: "Run Script",
            systemImageName: "terminal"
        )
    }
}
