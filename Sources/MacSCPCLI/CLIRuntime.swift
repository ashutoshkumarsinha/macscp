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
    nonisolated(unsafe) static var connectionTimeout: Int?
    nonisolated(unsafe) static var hostKeyFingerprints: [String] = []
    nonisolated(unsafe) static var logLevel: MacSCPLogLevel?
    nonisolated(unsafe) static var logFile: URL?
    nonisolated(unsafe) static var localWorkingDirectory = FileManager.default.homeDirectoryForCurrentUser.path
    static let version = "0.3.0"

    static func reset() {
        batchMode = false
        quiet = false
        jsonOutput = false
        skipIni = false
        connectionTimeout = nil
        hostKeyFingerprints = []
        logLevel = nil
        logFile = nil
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
        logfile: String? = nil
    ) {
        if batch { batchMode = true }
        if quietFlag { quiet = true }
        if json { jsonOutput = true }
        if ini?.lowercased() == "none" { skipIni = true }
        if let timeout { connectionTimeout = timeout }
        if !hostkeys.isEmpty { hostKeyFingerprints = hostkeys }
        if let loglevel, let level = MacSCPLogLevel(rawValue: loglevel.lowercased()) {
            logLevel = level
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
        progress: ProgressHandler? = nil
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
            verifyChecksum: verifyChecksum || settings.verifyChecksums
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

    static func applyAdvanced(to session: inout SessionConfiguration) {
        if let timeout = connectionTimeout {
            session.advanced.connectionTimeoutSeconds = timeout
        }
        if let fingerprint = hostKeyFingerprints.last, session.advanced.hostKeyFingerprint == nil {
            session.advanced.hostKeyFingerprint = fingerprint
        }
    }
}
