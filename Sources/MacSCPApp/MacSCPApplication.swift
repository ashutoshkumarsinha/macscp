// MacSCPApplication.swift
//
// WHAT THIS FILE DOES
// -------------------
// Custom NSApplication subclass for AppleScript command routing. NSScriptCommand handlers
// forward connect, disconnect, upload, and download to MacSCPScriptingController.
//

import AppKit

@objc(MacSCPApplication)
final class MacSCPApplication: NSApplication {
    @objc func connect(_ command: NSScriptCommand) {
        guard let name = command.directParameter as? String else {
            command.scriptErrorNumber = 1
            command.scriptErrorString = "Profile name required"
            return
        }
        Task { @MainActor in
            do {
                try await MacSCPScriptingController.connect(profileName: name)
            } catch {
                command.scriptErrorString = error.localizedDescription
                command.scriptErrorNumber = 2
            }
        }
    }

    @objc func disconnect(_ command: NSScriptCommand) {
        Task { @MainActor in
            await MacSCPScriptingController.disconnect()
        }
    }

    @objc func upload(_ command: NSScriptCommand) {
        guard let localPath = command.evaluatedArguments?["localPath"] as? String,
              let remotePath = command.evaluatedArguments?["remotePath"] as? String else {
            command.scriptErrorNumber = 1
            command.scriptErrorString = "local path and remote path required"
            return
        }
        Task { @MainActor in
            do {
                try await MacSCPScriptingController.upload(localPath: localPath, remotePath: remotePath)
            } catch {
                command.scriptErrorString = error.localizedDescription
                command.scriptErrorNumber = 2
            }
        }
    }

    @objc func download(_ command: NSScriptCommand) {
        guard let localPath = command.evaluatedArguments?["localPath"] as? String,
              let remotePath = command.evaluatedArguments?["remotePath"] as? String else {
            command.scriptErrorNumber = 1
            command.scriptErrorString = "local path and remote path required"
            return
        }
        Task { @MainActor in
            do {
                try await MacSCPScriptingController.download(remotePath: remotePath, localPath: localPath)
            } catch {
                command.scriptErrorString = error.localizedDescription
                command.scriptErrorNumber = 2
            }
        }
    }
}
