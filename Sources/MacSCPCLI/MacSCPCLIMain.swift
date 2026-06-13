// MacSCPCLIMain.swift
//
// WHAT THIS FILE DOES
// -------------------
// @main ArgumentParser entry for the scriptable macscp command-line client.
// Defines Open, Close, Ls, Get, Put, Sync, and Script subcommands wired to CLIActions.
//
import ArgumentParser
import Foundation

@main
struct MacSCPCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp",
        abstract: "Scriptable SFTP client for macOS.",
        subcommands: [Open.self, Close.self, Ls.self, Get.self, Put.self, Sync.self, Script.self]
    )
}

extension MacSCPCLICommand {
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open an SFTP session.")

        @Argument(help: "sftp://user@host[:port]/path")
        var url: String

        @Option(name: .long, help: "Password authentication.")
        var password: String?

        @Flag(name: .long, help: "Use SSH agent.")
        var agent = false

        @Option(name: .long, help: "Host key fingerprint.")
        var hostkey: String?

        @Flag(name: .long, help: "Batch mode (strict host keys).")
        var batch = false

        @Option(name: .customLong("rawsettings"), parsing: .upToNextOption, help: "OpenSSH-style settings (ProxyJump=host).")
        var rawSettings: [String] = []

        mutating func run() async throws {
            try await CLIActions.open(
                url: url,
                password: password,
                agent: agent,
                hostkey: hostkey,
                batch: batch,
                rawSettings: rawSettings
            )
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close the active session.")
        mutating func run() async throws {
            try await CLIActions.close()
        }
    }

    struct Ls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List remote directory.")

        @Argument(help: "Remote path")
        var path: String = "/"

        @Flag(name: .long, help: "JSON output.")
        var json = false

        mutating func run() async throws {
            try await CLIActions.ls(path: path, json: json)
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download remote file.")

        @Argument(help: "Remote path")
        var remote: String

        @Argument(help: "Local destination")
        var local: String

        mutating func run() async throws {
            try await CLIActions.get(remote: remote, local: local)
        }
    }

    struct Put: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Upload local file.")

        @Argument(help: "Local path")
        var local: String

        @Argument(help: "Remote path")
        var remote: String

        mutating func run() async throws {
            try await CLIActions.put(local: local, remote: remote)
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One-way directory sync.")

        @Argument(help: "Local directory")
        var local: String

        @Argument(help: "Remote directory")
        var remote: String

        @Flag(name: .long, help: "Mirror remote → local instead of local → remote.")
        var mirrorRemote = false

        @Flag(name: .long, help: "Two-way sync (upload newer local + download newer remote).")
        var bidirectional = false

        @Flag(name: .long, help: "Preview only.")
        var preview = false

        mutating func run() async throws {
            try await CLIActions.sync(
                local: local,
                remote: remote,
                mirrorRemote: mirrorRemote,
                bidirectional: bidirectional,
                preview: preview
            )
        }
    }

    struct Script: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a .macscp script file.")

        @Argument(help: "Path to script")
        var path: String

        mutating func run() async throws {
            let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            try await MacSCPScriptRunner.run(text)
        }
    }
}
