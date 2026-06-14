// CLIActions.swift
//
// WHAT THIS FILE DOES
// -------------------
// Implements macscp CLI verbs: open, close, ls, get, put, sync, navigation, file ops, and scripts.
// MacSCPCLIMain subcommands delegate here; actions use CLISessionStore for the live backend.
//
import Foundation
import MacSCPCore
import MacSCPBackends

enum CLIActions {
    static func open(
        url: String?,
        sessionName: String? = nil,
        password: String? = nil,
        privateKey: String? = nil,
        passphrase: String? = nil,
        agent: Bool = false,
        hostkey: String? = nil,
        batch: Bool = false,
        rawSettings: [String] = []
    ) async throws {
        if batch || CLIRuntime.batchMode {
            await HostKeyTrustGate.shared.setMode(.batchStrict)
        }
        try await CLISessionStore.shared.loadSettings()

        var config: SessionConfiguration
        if let sessionName {
            config = try CLIProfileResolver.resolve(
                nameOrID: sessionName,
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser
            )
            if let url, let parsed = try? ConnectionURL.parse(url) {
                config.initialRemotePath = parsed.path
            }
        } else {
            guard let url else { throw CLIError.usage("open requires URL or --session") }
            let parsed: ConnectionURL
            do {
                parsed = try ConnectionURL.parse(url)
            } catch {
                throw CLIError.usage("Expected sftp://, scp://, ftp://, or ftps:// URL")
            }
            var auth = parsed.authMethod
            if agent { auth = .agent }
            let keyPath = privateKey ?? parsed.keyPath
            config = CLISessionBuilder.configuration(
                transferProtocol: parsed.transferProtocol,
                host: parsed.host,
                port: parsed.port,
                username: parsed.username,
                password: password ?? parsed.password,
                keyPath: keyPath.map { NSString(string: $0).expandingTildeInPath },
                keyPassphrase: passphrase ?? ProcessInfo.processInfo.environment["MACSCP_PASSPHRASE"],
                authMethod: auth,
                remotePath: parsed.path,
                hostKeyFingerprint: hostkey ?? CLIRuntime.hostKeyFingerprints.last,
                implicitTLS: parsed.implicitTLS
            )
        }
        OpenSSHRawSettings.apply(rawSettings, to: &config)
        config.mergeOpenSSHConfig()
        do {
            try await CLISessionStore.shared.connect(config)
            CLIJSONEventStream.emitSessionConnected(config)
            CLIRuntime.printMessage("Connected to \(config.host):\(config.port)")
        } catch let error as BackendError {
            if CLIRuntime.jsonOutput {
                CLIJSONEventStream.emitTransferError(
                    transferID: nil,
                    direction: nil,
                    remotePath: nil,
                    localPath: nil,
                    message: error.localizedDescription
                )
            }
            throw CLIErrorMapper.map(error)
        }
    }

    static func close() async throws {
        try await CLISessionStore.shared.disconnect()
        CLIJSONEventStream.emitSessionDisconnected()
        CLIRuntime.printMessage("Disconnected")
    }

    static func ls(path: String, json: Bool) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        let entries = try await backend.listDirectory(at: resolved)
        let useJSON = json || CLIRuntime.jsonOutput
        if useJSON {
            struct LSPayload: Encodable {
                struct Entry: Encodable {
                    let name: String
                    let path: String
                    let type: String
                    let size: Int64?
                    let permissions: String?
                }
                let path: String
                let entries: [Entry]
            }
            let payload = LSPayload(
                path: resolved,
                entries: entries.map { entry in
                    LSPayload.Entry(
                        name: entry.name,
                        path: entry.path,
                        type: entry.type.rawValue,
                        size: entry.size,
                        permissions: entry.permissions.map { String(format: "%04o", $0.octal) }
                    )
                }
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(payload)
            print(String(decoding: data, as: UTF8.self))
        } else {
            for entry in entries {
                let kind = entry.type == .directory ? "d" : "-"
                let size = entry.size.map(String.init) ?? "-"
                print("\(kind)\t\(size)\t\(entry.name)")
            }
        }
    }

    static func get(
        remote: String,
        local: String,
        resume: Bool = false,
        overwrite: OverwritePolicy = .overwrite,
        transferMode: TransferMode = .binary,
        checksum: ChecksumAlgorithm? = nil
    ) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let settings = await CLISessionStore.shared.transferSettingsOrDefault()
        let resolvedRemote = await CLISessionStore.shared.resolveRemotePath(remote)
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath, isDirectory: false)
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try await downloadFile(
            backend: backend,
            remotePath: resolvedRemote,
            localURL: localURL,
            settings: settings,
            baseOptions: CLIRuntime.makeTransferOptions(
                resume: resume,
                overwrite: overwrite,
                transferMode: transferMode,
                checksum: checksum,
                verifyChecksum: checksum != nil,
                settings: settings
            )
        )
        CLIRuntime.printMessage("Downloaded \(resolvedRemote) → \(localURL.path)")
    }

    static func put(
        local: String,
        remote: String,
        resume: Bool = false,
        overwrite: OverwritePolicy = .overwrite,
        transferMode: TransferMode = .binary,
        checksum: ChecksumAlgorithm? = nil
    ) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let settings = await CLISessionStore.shared.transferSettingsOrDefault()
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath)
        let resolvedRemote = await CLISessionStore.shared.resolveRemotePath(remote)
        try await uploadFile(
            backend: backend,
            localURL: localURL,
            remotePath: resolvedRemote,
            settings: settings,
            baseOptions: CLIRuntime.makeTransferOptions(
                resume: resume,
                overwrite: overwrite,
                transferMode: transferMode,
                checksum: checksum,
                verifyChecksum: checksum != nil,
                settings: settings
            )
        )
        CLIRuntime.printMessage("Uploaded \(localURL.path) → \(resolvedRemote)")
    }

    static func sync(
        local: String,
        remote: String,
        mirrorRemote: Bool,
        mirrorLocal: Bool = false,
        bidirectional: Bool,
        preview: Bool,
        deleteExtraneous: Bool = false,
        fileMask: String? = nil,
        criteria: SyncCompareCriteria = .time
    ) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let settings = await CLISessionStore.shared.transferSettingsOrDefault()
        let localURL = URL(fileURLWithPath: NSString(string: local).expandingTildeInPath, isDirectory: true)
        let resolvedRemote = await CLISessionStore.shared.resolveRemotePath(remote)
        let compareOptions = SyncCompareOptions(
            criteria: criteria,
            fileMask: SyncFileMask.parse(fileMask)
        )
        let rows = try await DirectorySyncEngine.compare(
            localRoot: localURL,
            remoteRoot: resolvedRemote,
            backend: backend,
            options: compareOptions
        )
        let transferOptions = CLIRuntime.makeTransferOptions(settings: settings)

        if bidirectional {
            let plan = DirectorySyncEngine.bidirectionalPlan(rows: rows, deleteExtraneous: deleteExtraneous)
            if preview {
                if CLIRuntime.jsonOutput {
                    CLIJSONEventStream.emitSyncPreview(
                        uploads: plan.uploads.count,
                        downloads: plan.downloads.count,
                        remoteDeletes: plan.remoteDeletes.count,
                        localDeletes: plan.localDeletes.count
                    )
                } else {
                    CLIRuntime.printMessage(
                        "Would upload \(plan.uploads.count), download \(plan.downloads.count), " +
                        "delete \(plan.remoteDeletes.count + plan.localDeletes.count)"
                    )
                }
                return
            }
            CLIJSONEventStream.emitSyncStart(
                uploads: plan.uploads.count,
                downloads: plan.downloads.count,
                remoteDeletes: plan.remoteDeletes.count,
                localDeletes: plan.localDeletes.count,
                preview: false
            )
            for file in plan.uploads {
                try await uploadFile(
                    backend: backend,
                    localURL: file.localURL,
                    remotePath: file.remotePath,
                    settings: settings,
                    baseOptions: transferOptions
                )
            }
            for file in plan.downloads {
                try DirectoryTransferPlanner.ensureLocalDirectories(for: [file])
                try await downloadFile(
                    backend: backend,
                    remotePath: file.remotePath,
                    localURL: file.localURL,
                    settings: settings,
                    baseOptions: transferOptions
                )
            }
            if deleteExtraneous {
                for path in plan.remoteDeletes { try await backend.removeFile(at: path) }
                for url in plan.localDeletes { try FileManager.default.removeItem(at: url) }
            }
            CLIJSONEventStream.emitSyncComplete(
                filesTransferred: plan.uploads.count + plan.downloads.count,
                remoteDeletes: plan.remoteDeletes.count,
                localDeletes: plan.localDeletes.count
            )
            CLIRuntime.printMessage("Synchronized \(plan.uploads.count + plan.downloads.count) file(s)")
            return
        }

        let direction: SyncDirection
        if mirrorRemote {
            direction = .mirrorRemoteToLocal
        } else if mirrorLocal {
            direction = .mirrorLocalToRemote
        } else {
            direction = .mirrorLocalToRemote
        }
        let plan = DirectorySyncEngine.mirrorPlan(rows: rows, direction: direction, deleteExtraneous: deleteExtraneous)
        if preview {
            let uploads = direction == .mirrorLocalToRemote ? plan.transfers.count : 0
            let downloads = direction == .mirrorRemoteToLocal ? plan.transfers.count : 0
            if CLIRuntime.jsonOutput {
                CLIJSONEventStream.emitSyncPreview(
                    uploads: uploads,
                    downloads: downloads,
                    remoteDeletes: plan.remoteDeletes.count,
                    localDeletes: plan.localDeletes.count
                )
            } else {
                CLIRuntime.printMessage(
                    "Would transfer \(plan.transfers.count) file(s), delete \(plan.remoteDeletes.count + plan.localDeletes.count)"
                )
            }
            return
        }
        let uploads = direction == .mirrorLocalToRemote ? plan.transfers.count : 0
        let downloads = direction == .mirrorRemoteToLocal ? plan.transfers.count : 0
        CLIJSONEventStream.emitSyncStart(
            uploads: uploads,
            downloads: downloads,
            remoteDeletes: plan.remoteDeletes.count,
            localDeletes: plan.localDeletes.count,
            preview: false
        )
        for file in plan.transfers {
            switch direction {
            case .mirrorLocalToRemote:
                try await uploadFile(
                    backend: backend,
                    localURL: file.localURL,
                    remotePath: file.remotePath,
                    settings: settings,
                    baseOptions: transferOptions
                )
            case .mirrorRemoteToLocal:
                try DirectoryTransferPlanner.ensureLocalDirectories(for: [file])
                try await downloadFile(
                    backend: backend,
                    remotePath: file.remotePath,
                    localURL: file.localURL,
                    settings: settings,
                    baseOptions: transferOptions
                )
            case .bidirectional:
                break
            }
        }
        for path in plan.remoteDeletes { try await backend.removeFile(at: path) }
        for url in plan.localDeletes { try FileManager.default.removeItem(at: url) }
        CLIJSONEventStream.emitSyncComplete(
            filesTransferred: plan.transfers.count,
            remoteDeletes: plan.remoteDeletes.count,
            localDeletes: plan.localDeletes.count
        )
        CLIRuntime.printMessage("Synchronized \(plan.transfers.count) file(s)")
    }

    private static func downloadFile(
        backend: TransferBackend,
        remotePath: String,
        localURL: URL,
        settings: MacSCPTransferSettings,
        baseOptions: TransferOptions
    ) async throws {
        let (options, transferID) = CLIRuntime.makeTrackedTransferOptions(
            direction: .download,
            resume: baseOptions.resume,
            overwrite: baseOptions.overwrite,
            transferMode: baseOptions.transferMode,
            checksum: baseOptions.checksum,
            verifyChecksum: baseOptions.verifyChecksum,
            settings: settings
        )
        CLIJSONEventStream.emitTransferStart(
            transferID: transferID,
            direction: .download,
            remotePath: remotePath,
            localPath: localURL.path
        )
        do {
            let result = try await backend.download(
                remotePath: remotePath,
                localURL: localURL,
                options: options
            )
            CLIJSONEventStream.emitTransferComplete(
                transferID: transferID,
                direction: .download,
                remotePath: remotePath,
                localPath: localURL.path,
                result: result
            )
        } catch {
            CLIJSONEventStream.emitTransferError(
                transferID: transferID,
                direction: .download,
                remotePath: remotePath,
                localPath: localURL.path,
                message: error.localizedDescription
            )
            throw error
        }
    }

    private static func uploadFile(
        backend: TransferBackend,
        localURL: URL,
        remotePath: String,
        settings: MacSCPTransferSettings,
        baseOptions: TransferOptions
    ) async throws {
        let (options, transferID) = CLIRuntime.makeTrackedTransferOptions(
            direction: .upload,
            resume: baseOptions.resume,
            overwrite: baseOptions.overwrite,
            transferMode: baseOptions.transferMode,
            checksum: baseOptions.checksum,
            verifyChecksum: baseOptions.verifyChecksum,
            settings: settings
        )
        CLIJSONEventStream.emitTransferStart(
            transferID: transferID,
            direction: .upload,
            remotePath: remotePath,
            localPath: localURL.path
        )
        do {
            let result = try await backend.upload(
                localURL: localURL,
                remotePath: remotePath,
                options: options
            )
            CLIJSONEventStream.emitTransferComplete(
                transferID: transferID,
                direction: .upload,
                remotePath: remotePath,
                localPath: localURL.path,
                result: result
            )
        } catch {
            CLIJSONEventStream.emitTransferError(
                transferID: transferID,
                direction: .upload,
                remotePath: remotePath,
                localPath: localURL.path,
                message: error.localizedDescription
            )
            throw error
        }
    }

    static func cd(_ path: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        _ = try await backend.listDirectory(at: resolved)
        await CLISessionStore.shared.setRemotePath(resolved)
        CLIRuntime.printMessage(resolved)
    }

    static func lcd(_ path: String) async throws {
        let expanded = NSString(string: path).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError.usage("Not a directory: \(path)")
        }
        CLIRuntime.localWorkingDirectory = URL(fileURLWithPath: expanded).standardizedFileURL.path
        CLIRuntime.printMessage(CLIRuntime.localWorkingDirectory)
    }

    static func pwd() async throws {
        let path = await CLISessionStore.shared.currentRemotePath()
        CLIRuntime.printMessage(path)
    }

    static func lpwd() {
        CLIRuntime.printMessage(CLIRuntime.localWorkingDirectory)
    }

    static func rm(_ path: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        try await backend.removeFile(at: resolved)
        CLIRuntime.printMessage("Removed \(resolved)")
    }

    static func mkdir(_ path: String, recursive: Bool = false) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        try await backend.createDirectory(at: resolved, recursive: recursive)
        CLIRuntime.printMessage("Created \(resolved)")
    }

    static func mv(from source: String, to destination: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let fromPath = await CLISessionStore.shared.resolveRemotePath(source)
        let toPath = await CLISessionStore.shared.resolveRemotePath(destination)
        try await backend.rename(from: fromPath, to: toPath)
        CLIRuntime.printMessage("Renamed \(fromPath) → \(toPath)")
    }

    static func chmod(_ path: String, mode: String) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        guard let octal = UInt32(mode, radix: 8) else {
            throw CLIError.usage("Invalid octal mode: \(mode)")
        }
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        try await backend.setPermissions(FilePermissions(octal: octal), at: resolved)
        CLIRuntime.printMessage("Changed mode on \(resolved)")
    }

    static func chown(_ path: String, user: String?, group: String?) async throws {
        let backend = try await CLISessionStore.shared.backendOrThrow()
        let resolved = await CLISessionStore.shared.resolveRemotePath(path)
        try await backend.setOwnership(user: user, group: group, at: resolved)
        CLIRuntime.printMessage("Changed owner on \(resolved)")
    }

    static func call(_ args: [String]) async throws {
        guard let command = args.first else { throw CLIError.usage("call requires a command") }
        switch command {
        case "chmod":
            guard args.count >= 3 else { throw CLIError.usage("call chmod mode path") }
            try await chmod(args[2], mode: args[1])
        case "stat":
            guard args.count >= 2 else { throw CLIError.usage("call stat path") }
            let backend = try await CLISessionStore.shared.backendOrThrow()
            let resolved = await CLISessionStore.shared.resolveRemotePath(args[1])
            let entry = try await backend.stat(path: resolved)
            if CLIRuntime.jsonOutput {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(entry)
                print(String(decoding: data, as: UTF8.self))
            } else {
                CLIRuntime.printMessage("\(entry.path) \(entry.type.rawValue) \(entry.size ?? 0)")
            }
        case "chown":
            guard args.count >= 3 else { throw CLIError.usage("call chown owner[:group] path") }
            let ownerSpec = args[1]
            let path = args[2]
            let parts = ownerSpec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            let user = parts.first.map(String.init).flatMap { $0.isEmpty ? nil : $0 }
            let group: String?
            if parts.count > 1 {
                group = String(parts[1]).isEmpty ? nil : String(parts[1])
            } else {
                group = nil
            }
            try await chown(path, user: user, group: group)
        default:
            throw CLIError.usage("Unsupported call command: \(command)")
        }
    }

    static func runScript(at path: String) async throws {
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        try await MacSCPScriptRunner.run(text)
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
        var context = ScriptExecutionContext()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let parts = parseLine(trimmed)
            guard let verb = parts.first?.lowercased() else { continue }
            do {
                if try await execute(verb: verb, parts: parts, context: &context) {
                    return
                }
            } catch is ScriptExit {
                return
            } catch {
                if context.continueOnError {
                    context.failureCount += 1
                    fputs("Warning: \(error.localizedDescription)\n", stderr)
                    continue
                }
                throw error
            }
        }
        if context.failureCount > 0 {
            throw CLIError.partialSuccess("\(context.failureCount) command(s) failed")
        }
    }

    private static func parseLine(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                continue
            }
            if character.isWhitespace, !inQuotes {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    private static func execute(
        verb: String,
        parts: [String],
        context: inout ScriptExecutionContext
    ) async throws -> Bool {
        switch verb {
        case "option":
            guard parts.count >= 3 else { throw CLIError.usage("option name on|off") }
            let value = parts[2].lowercased() == "on"
            switch parts[1].lowercased() {
            case "continue": context.continueOnError = value
            case "failonnomatch": context.failOnNoMatch = value
            case "batch":
                CLIRuntime.batchMode = value
                if value { await HostKeyTrustGate.shared.setMode(.batchStrict) }
            case "confirm":
                context.confirmPrompts = value
            case "transfer":
                context.transferMode = parts[2].lowercased() == "ascii" ? .ascii : .binary
            default: throw CLIError.usage("Unknown option: \(parts[1])")
            }
            return false
        case "open":
            let switches = parseOpenSwitches(Array(parts.dropFirst()))
            try await CLIActions.open(
                url: switches.url,
                sessionName: switches.session,
                password: switches.password,
                privateKey: switches.privateKey,
                passphrase: switches.passphrase,
                agent: switches.agent,
                hostkey: switches.hostkey,
                batch: switches.batch || CLIRuntime.batchMode,
                rawSettings: switches.rawSettings
            )
        case "close":
            try await CLIActions.close()
        case "ls":
            try await CLIActions.ls(path: parts.count > 1 ? parts[1] : "/", json: CLIRuntime.jsonOutput)
        case "get":
            guard parts.count >= 3 else { throw CLIError.usage("get remote local") }
            try await CLIActions.get(
                remote: parts[1],
                local: parts[2],
                resume: context.resumeTransfers,
                transferMode: context.transferMode
            )
        case "put":
            guard parts.count >= 3 else { throw CLIError.usage("put local remote") }
            for local in try expandGlob(parts[1], failOnNoMatch: context.failOnNoMatch) {
                try await CLIActions.put(
                    local: local,
                    remote: parts[2],
                    resume: context.resumeTransfers,
                    transferMode: context.transferMode
                )
            }
        case "sync":
            guard parts.count >= 3 else { throw CLIError.usage("sync local remote") }
            var mirrorRemote = false
            var mirrorLocal = false
            var delete = false
            var preview = false
            var bidirectional = false
            var fileMask: String?
            var criteria = SyncCompareCriteria.time
            for flag in parts.dropFirst(2) {
                let lower = flag.lowercased()
                if lower == "-mirror" || lower == "-mirror-remote" { mirrorRemote = true }
                else if lower == "-mirror-local" { mirrorLocal = true }
                else if lower == "-delete" { delete = true }
                else if lower == "-preview" { preview = true }
                else if lower == "-bidirectional" { bidirectional = true }
                else if lower.hasPrefix("-filemask=") { fileMask = String(lower.dropFirst("-filemask=".count)) }
                else if lower.hasPrefix("-criteria=") {
                    criteria = SyncCompareCriteria(rawValue: String(lower.dropFirst("-criteria=".count))) ?? .time
                }
            }
            try await CLIActions.sync(
                local: parts[1],
                remote: parts[2],
                mirrorRemote: mirrorRemote,
                mirrorLocal: mirrorLocal,
                bidirectional: bidirectional,
                preview: preview,
                deleteExtraneous: delete,
                fileMask: fileMask,
                criteria: criteria
            )
        case "cd":
            guard parts.count >= 2 else { throw CLIError.usage("cd path") }
            try await CLIActions.cd(parts[1])
        case "lcd":
            guard parts.count >= 2 else { throw CLIError.usage("lcd path") }
            try await CLIActions.lcd(parts[1])
        case "pwd":
            try await CLIActions.pwd()
        case "lpwd":
            CLIActions.lpwd()
        case "rm":
            guard parts.count >= 2 else { throw CLIError.usage("rm path") }
            try await CLIActions.rm(parts[1])
        case "mkdir":
            guard parts.count >= 2 else { throw CLIError.usage("mkdir path") }
            try await CLIActions.mkdir(parts[1], recursive: parts.contains("-p"))
        case "mv":
            guard parts.count >= 3 else { throw CLIError.usage("mv source dest") }
            try await CLIActions.mv(from: parts[1], to: parts[2])
        case "chmod":
            guard parts.count >= 3 else { throw CLIError.usage("chmod mode path") }
            try await CLIActions.chmod(parts[2], mode: parts[1])
        case "call":
            try await CLIActions.call(Array(parts.dropFirst()))
        case "exit", "quit":
            throw ScriptExit()
        default:
            throw CLIError.usage("Unknown command: \(verb)")
        }
        return false
    }

    private struct OpenSwitches {
        var url: String?
        var session: String?
        var password: String?
        var privateKey: String?
        var passphrase: String?
        var agent = false
        var hostkey: String?
        var batch = false
        var rawSettings: [String] = []
    }

    private static func parseOpenSwitches(_ tokens: [String]) -> OpenSwitches {
        var result = OpenSwitches()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.hasPrefix("-") {
                let lower = token.lowercased()
                if lower == "-agent" { result.agent = true }
                else if lower == "-batch" { result.batch = true }
                else if lower.hasPrefix("-session=") {
                    result.session = String(token.dropFirst("-session=".count))
                } else if lower == "-session", index + 1 < tokens.count {
                    index += 1
                    result.session = tokens[index]
                } else if lower.hasPrefix("-password=") {
                    result.password = String(token.dropFirst("-password=".count))
                } else if lower.hasPrefix("-privatekey=") {
                    result.privateKey = String(token.dropFirst("-privatekey=".count))
                } else if lower.hasPrefix("-passphrase=") {
                    result.passphrase = String(token.dropFirst("-passphrase=".count))
                } else if lower.hasPrefix("-hostkey=") {
                    result.hostkey = String(token.dropFirst("-hostkey=".count))
                } else if lower.hasPrefix("-rawsettings=") {
                    result.rawSettings.append(String(token.dropFirst("-rawsettings=".count)))
                }
            } else if result.url == nil {
                result.url = token
            }
            index += 1
        }
        return result
    }

    private static func expandGlob(_ pattern: String, failOnNoMatch: Bool) throws -> [String] {
        if !pattern.contains("*") && !pattern.contains("?") {
            return [pattern]
        }
        let expanded = NSString(string: pattern).expandingTildeInPath
        let dir = (expanded as NSString).deletingLastPathComponent
        let name = (expanded as NSString).lastPathComponent
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let matched = entries.filter { $0.range(of: globToRegex(name), options: .regularExpression) != nil }
            .map { dir + "/" + $0 }
        if matched.isEmpty, failOnNoMatch {
            throw CLIError.transferFailed("No files matched \(pattern)")
        }
        return matched
    }

    private static func globToRegex(_ glob: String) -> String {
        "^" + NSRegularExpression.escapedPattern(for: glob)
            .replacingOccurrences(of: "\\*", with: ".*")
            .replacingOccurrences(of: "\\?", with: ".") + "$"
    }
}

private struct ScriptExecutionContext {
    var continueOnError = false
    var failOnNoMatch = false
    var confirmPrompts = false
    var resumeTransfers = false
    var transferMode: TransferMode = .binary
    var failureCount = 0
}

private struct ScriptExit: Error {}
