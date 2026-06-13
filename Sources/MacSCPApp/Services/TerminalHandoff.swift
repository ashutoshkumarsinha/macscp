// TerminalHandoff.swift — Open Terminal.app or iTerm2 with an SSH session.

import AppKit
import Foundation
import MacSCPCore

enum TerminalHandoff {
    enum TerminalApp: String {
        case terminal = "Terminal"
        case iTerm = "iTerm"
    }

    static var preferredApp: TerminalApp {
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil {
            return .iTerm
        }
        return .terminal
    }

    static func openSSHSession(configuration: SessionConfiguration, remotePath: String) {
        var parts = ["ssh", "-p", String(configuration.port)]
        if configuration.authMethod == .publicKey, let key = configuration.keyPath {
            let expanded = NSString(string: key).expandingTildeInPath
            parts += ["-i", expanded]
        }
        parts += ["\(configuration.username)@\(configuration.host)", "-t", "cd \(shellQuote(remotePath)) && exec $SHELL"]
        let command = parts.joined(separator: " ")

        switch preferredApp {
        case .terminal:
            let script = """
            tell application "Terminal"
                activate
                do script "\(escapeAppleScript(command))"
            end tell
            """
            runAppleScript(script)
        case .iTerm:
            let script = """
            tell application "iTerm"
                activate
                create window with default profile
                tell current session of current window
                    write text "\(escapeAppleScript(command))"
                end tell
            end tell
            """
            runAppleScript(script)
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func escapeAppleScript(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func runAppleScript(_ source: String) {
        var error: NSDictionary?
        if let script = NSAppleScript(source: source) {
            script.executeAndReturnError(&error)
        }
    }
}
