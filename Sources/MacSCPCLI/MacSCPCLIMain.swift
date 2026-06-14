// MacSCPCLIMain.swift
//
// WHAT THIS FILE DOES
// -------------------
// @main ArgumentParser entry for the scriptable macscp command-line client.
// Defines global options and subcommands wired to CLIActions; supports script-as-first-arg.
//
import ArgumentParser
import Foundation
import MacSCPCore

@main
enum MacSCPCLIMain {
    static func main() async {
        CLIRuntime.reset()
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 1, args[0].hasSuffix(".macscp") || args[0].hasSuffix(".txt") {
            do {
                CLIRuntime.bootstrapLogging()
                try await CLIActions.runScript(at: args[0])
            } catch let error as CLIError {
                fputs("\(error)\n", stderr)
                exit(error.exitCode)
            } catch {
                fputs("\(error.localizedDescription)\n", stderr)
                exit(1)
            }
            return
        }

        do {
            var command = try MacSCPCLICommand.parseAsRoot()
            try await command.run()
        } catch let error as CLIError {
            fputs("\(error)\n", stderr)
            exit(error.exitCode)
        } catch let error as ValidationError {
            fputs("\(error)\n", stderr)
            exit(1)
        } catch {
            fputs("\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

struct MacSCPCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp",
        abstract: "Scriptable SFTP client for macOS.",
        subcommands: [
            Open.self, Close.self, Ls.self, Get.self, Put.self, Sync.self,
            Cd.self, Lcd.self, Pwd.self, Lpwd.self, Rm.self, Mkdir.self, Mv.self, Chmod.self,
            Call.self, Script.self, Version.self,
        ]
    )

    @OptionGroup var global: CLIGlobalOptions
}

struct CLIGlobalOptions: ParsableArguments {
    @Option(name: .customLong("session"), help: "Saved profile name or UUID.")
    var session: String?

    @Option(name: .long, help: "Config file path, or 'none' to skip ~/.macscp/config.toml.")
    var ini: String?

    @Flag(name: .long, help: "Batch mode (strict host keys, no prompts).")
    var batch = false

    @Flag(name: [.customShort("q"), .long], help: "Suppress non-error output.")
    var quiet = false

    @Flag(name: .long, help: "JSON output: objects for ls/stat/version; NDJSON events for transfers.")
    var json = false

    @Option(name: .long, help: "Connection timeout in seconds.")
    var timeout: Int?

    @Option(name: .long, parsing: .upToNextOption, help: "Expected host key fingerprint (repeatable).")
    var hostkey: [String] = []

    @Option(name: .long, help: "Log level: debug, info, warning, error.")
    var loglevel: String?

    @Option(name: .long, help: "Log file path.")
    var logfile: String?

    mutating func validate() throws {
        CLIRuntime.applyGlobalOptions(
            batch: batch,
            quietFlag: quiet,
            json: json,
            ini: ini,
            timeout: timeout,
            hostkeys: hostkey,
            loglevel: loglevel,
            logfile: logfile
        )
        CLIRuntime.bootstrapLogging()
    }
}

extension MacSCPCLICommand {
    struct Open: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open an SFTP session.")

        @OptionGroup var global: CLIGlobalOptions

        @Argument(help: "sftp://user@host[:port]/path")
        var url: String?

        @Option(name: .long, help: "Password authentication.")
        var password: String?

        @Option(name: .customLong("privatekey"), help: "Private key path.")
        var privateKey: String?

        @Option(name: .long, help: "Key passphrase.")
        var passphrase: String?

        @Flag(name: .long, help: "Use SSH agent.")
        var agent = false

        @Option(name: .customLong("rawsettings"), parsing: .upToNextOption, help: "OpenSSH-style settings (ProxyJump=host).")
        var rawSettings: [String] = []

        @Flag(name: .long, help: "FTP passive mode.")
        var passive = false

        @Flag(name: .long, help: "FTP active mode.")
        var active = false

        @Flag(name: .long, help: "FTPS implicit TLS (port 990).")
        var implicit = false

        @Flag(name: .long, help: "FTPS explicit TLS.")
        var explicit = false

        mutating func run() async throws {
            try await CLIActions.open(
                url: url,
                sessionName: global.session,
                password: password,
                privateKey: privateKey,
                passphrase: passphrase ?? ProcessInfo.processInfo.environment["MACSCP_PASSPHRASE"],
                agent: agent,
                hostkey: global.hostkey.last,
                batch: global.batch,
                rawSettings: rawSettings,
                ftpPassive: active ? false : (passive ? true : nil),
                ftpsImplicit: implicit ? true : (explicit ? false : nil)
            )
        }
    }

    struct Close: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Close the active session.")
        @OptionGroup var global: CLIGlobalOptions
        mutating func run() async throws { try await CLIActions.close() }
    }

    struct Ls: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List remote directory.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Remote path") var path: String = "/"
        mutating func run() async throws { try await CLIActions.ls(path: path, json: global.json) }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download remote file(s).")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Remote path(s) or glob") var remotes: [String]
        @Argument(help: "Local destination file or directory") var local: String
        @Flag(name: .long, help: "Resume partial transfer.") var resume = false
        @Flag(name: .long, help: "Skip existing files.") var skip = false
        @Option(name: .long, help: "Checksum: md5 or sha256.") var checksum: String?
        @Option(name: .long, help: "Transfer mode: binary or ascii.") var transfer: String?

        mutating func run() async throws {
            try await CLIActions.get(
                remotes: remotes,
                local: local,
                resume: resume,
                overwrite: skip ? .skip : .overwrite,
                transferMode: parseTransferMode(transfer),
                checksum: parseChecksum(checksum)
            )
        }
    }

    struct Put: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Upload local file.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Local path") var local: String
        @Argument(help: "Remote path") var remote: String
        @Flag(name: .long, help: "Resume partial transfer.") var resume = false
        @Flag(name: .long, help: "Skip existing files.") var skip = false
        @Option(name: .long, help: "Checksum: md5 or sha256.") var checksum: String?
        @Option(name: .long, help: "Transfer mode: binary or ascii.") var transfer: String?

        mutating func run() async throws {
            try await CLIActions.put(
                local: local,
                remote: remote,
                resume: resume,
                overwrite: skip ? .skip : .overwrite,
                transferMode: parseTransferMode(transfer),
                checksum: parseChecksum(checksum)
            )
        }
    }

    struct Sync: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "One-way directory sync.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Local directory") var local: String
        @Argument(help: "Remote directory") var remote: String
        @Flag(name: .long, help: "Mirror remote → local.") var mirrorRemote = false
        @Flag(name: .long, help: "Mirror local → remote (default).") var mirror = false
        @Flag(name: .long, help: "Two-way sync.") var bidirectional = false
        @Flag(name: .long, help: "Delete extraneous files on destination.") var delete = false
        @Flag(name: .long, help: "Preview only.") var preview = false
        @Option(name: .long, help: "WinSCP-style file mask.") var filemask: String?
        @Option(name: .long, help: "Compare criteria: time, size, checksum.") var criteria: String?

        mutating func run() async throws {
            try await CLIActions.sync(
                local: local,
                remote: remote,
                mirrorRemote: mirrorRemote,
                mirrorLocal: mirror || (!mirrorRemote && !bidirectional),
                bidirectional: bidirectional,
                preview: preview,
                deleteExtraneous: delete,
                fileMask: filemask,
                criteria: SyncCompareCriteria(rawValue: criteria ?? "time") ?? .time
            )
        }
    }

    struct Cd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change remote directory.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Remote path") var path: String
        mutating func run() async throws { try await CLIActions.cd(path) }
    }

    struct Lcd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change local directory.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Local path") var path: String
        mutating func run() async throws { try await CLIActions.lcd(path) }
    }

    struct Pwd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print remote working directory.")
        @OptionGroup var global: CLIGlobalOptions
        mutating func run() async throws { try await CLIActions.pwd() }
    }

    struct Lpwd: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print local working directory.")
        @OptionGroup var global: CLIGlobalOptions
        mutating func run() { CLIActions.lpwd() }
    }

    struct Rm: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove remote file.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Remote path") var path: String
        mutating func run() async throws { try await CLIActions.rm(path) }
    }

    struct Mkdir: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create remote directory.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Remote path") var path: String
        @Flag(name: .shortAndLong, help: "Create parent directories.") var recursive = false
        mutating func run() async throws { try await CLIActions.mkdir(path, recursive: recursive) }
    }

    struct Mv: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rename remote path.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Source path") var source: String
        @Argument(help: "Destination path") var destination: String
        mutating func run() async throws { try await CLIActions.mv(from: source, to: destination) }
    }

    struct Chmod: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change remote permissions.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Octal mode") var mode: String
        @Argument(help: "Remote path") var path: String
        mutating func run() async throws { try await CLIActions.chmod(path, mode: mode) }
    }

    struct Call: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run auxiliary command (stat, chmod).")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(parsing: .captureForPassthrough, help: "Command and arguments") var args: [String] = []
        mutating func run() async throws { try await CLIActions.call(args) }
    }

    struct Script: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a .macscp script file.")
        @OptionGroup var global: CLIGlobalOptions
        @Argument(help: "Path to script") var path: String
        mutating func run() async throws { try await CLIActions.runScript(at: path) }
    }

    struct Version: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print version.")
        @OptionGroup var global: CLIGlobalOptions
        mutating func run() {
            if global.json {
                print("{\"version\":\"\(CLIRuntime.version)\"}")
            } else {
                print("macscp \(CLIRuntime.version)")
            }
        }
    }
}

private func parseTransferMode(_ raw: String?) -> TransferMode {
    raw?.lowercased() == "ascii" ? .ascii : .binary
}

private func parseChecksum(_ raw: String?) -> ChecksumAlgorithm? {
    switch raw?.lowercased() {
    case "md5": return .md5
    case "sha256": return .sha256
    default: return nil
    }
}
