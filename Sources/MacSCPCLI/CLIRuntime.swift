// CLIRuntime.swift
//
// WHAT THIS FILE DOES
// -------------------
// Global CLI runtime flags (batch, quiet, json, ini, timeout) shared across subcommands.
// MacSCPCLIMain applies parsed options here before delegating to CLIActions.
//
import Foundation
import MacSCPCore

enum CLIRuntime {
    nonisolated(unsafe) static var batchMode = false
    nonisolated(unsafe) static var quiet = false
    nonisolated(unsafe) static var jsonOutput = false
    nonisolated(unsafe) static var skipIni = false
    nonisolated(unsafe) static var configURL: URL?
    nonisolated(unsafe) static var connectionTimeout: Int?
    nonisolated(unsafe) static var hostKeyFingerprints: [String] = []
    nonisolated(unsafe) static var logLevel: MacSCPLogLevel?
    nonisolated(unsafe) static var logFile: URL?
    /// nil = follow config preset; true/false override pooling for SFTP.
    nonisolated(unsafe) static var poolOverride: Bool?
    nonisolated(unsafe) static var localWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    static let version = "0.3.0"

    static func reset() {
        batchMode = false
        quiet = false
        jsonOutput = false
        skipIni = false
        configURL = nil
        connectionTimeout = nil
        hostKeyFingerprints = []
        logLevel = nil
        logFile = nil
        poolOverride = nil
        localWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    }

    static func applyGlobalOptions(
        batch: Bool = false,
        quietFlag: Bool = false,
        json: Bool = false,
        ini: String? = nil,
        timeout: Int? = nil,
        hostkeys: [String] = [],
        loglevel: String? = nil,
        logfile: String? = nil,
        pool: Bool = false,
        noPool: Bool = false
    ) {
        if pool { poolOverride = true }
        if noPool { poolOverride = false }
        if batch { batchMode = true }
        if quietFlag { quiet = true }
        if json { jsonOutput = true }
        if ini?.lowercased() == "none" {
            skipIni = true
        } else if let ini, !ini.isEmpty {
            configURL = URL(fileURLWithPath: NSString(string: ini).expandingTildeInPath)
        }
        if let timeout { connectionTimeout = timeout }
        if !hostkeys.isEmpty { hostKeyFingerprints = hostkeys }
        if let loglevel {
            let normalized = loglevel.uppercased()
            if normalized == "WARN" {
                logLevel = .warning
            } else if let level = MacSCPLogLevel(rawValue: normalized) {
                logLevel = level
            }
        }
        if let logfile {
            logFile = URL(fileURLWithPath: NSString(string: logfile).expandingTildeInPath)
        }
    }

    static func printMessage(_ message: String) {
        guard !quiet, !jsonOutput else { return }
        print(message)
    }

    static func makeTransferOptions(
        resume: Bool? = nil,
        overwrite: OverwritePolicy = .overwrite,
        transferMode: TransferMode = .binary,
        checksum: ChecksumAlgorithm? = nil,
        verifyChecksum: Bool = false,
        settings: MacSCPTransferSettings,
        progress: ProgressHandler? = nil,
        useDeltaSync: Bool? = nil
    ) -> TransferOptions {
        TransferOptions(
            resume: resume ?? settings.resume,
            overwrite: overwrite,
            transferMode: transferMode,
            checksum: checksum,
            progress: progress,
            chunkSize: settings.chunkSize,
            maxConcurrentUploads: settings.maxConcurrentUploads,
            maxConcurrentWrites: settings.maxConcurrentWrites,
            maxConcurrentReads: settings.maxConcurrentReads,
            verifyChecksum: verifyChecksum || settings.verifyChecksums,
            useDeltaSync: useDeltaSync ?? settings.deltaSync
        )
    }

    static func makeTrackedTransferOptions(
        direction: TransferDirection,
        resume: Bool? = nil,
        overwrite: OverwritePolicy = .overwrite,
        transferMode: TransferMode = .binary,
        checksum: ChecksumAlgorithm? = nil,
        verifyChecksum: Bool = false,
        settings: MacSCPTransferSettings
    ) -> (options: TransferOptions, transferID: UUID) {
        let transferID = UUID()
        let progress = CLIJSONEventStream.makeProgressHandler(transferID: transferID)
        let options = makeTransferOptions(
            resume: resume,
            overwrite: overwrite,
            transferMode: transferMode,
            checksum: checksum,
            verifyChecksum: verifyChecksum,
            settings: settings,
            progress: progress
        )
        return (options, transferID)
    }

    static func bootstrapLogging() {
        if let logFile {
            MacSCPLogger.shared.bootstrapDedicatedLogFile(
                at: logFile,
                minimumLevel: logLevel ?? .info,
                mirrorStderr: !quiet
            )
            return
        }
        if skipIni {
            if let logLevel {
                MacSCPLogger.shared.bootstrapDedicatedLogFile(
                    at: FileManager.default.temporaryDirectory
                        .appendingPathComponent("macscp-cli.log"),
                    minimumLevel: logLevel,
                    mirrorStderr: !quiet
                )
            }
            return
        }
        _ = MacSCPLogger.shared.bootstrapCLI(minimumLevel: logLevel)
    }

    static func applyAdvanced(to session: inout SessionConfiguration) {
        if let timeout = connectionTimeout {
            session.advanced.connectionTimeoutSeconds = timeout
        }
        if let fingerprint = hostKeyFingerprints.last, session.advanced.hostKeyFingerprint == nil {
            session.advanced.hostKeyFingerprint = fingerprint
        }
    }
}
