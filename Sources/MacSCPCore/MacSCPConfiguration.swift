// MacSCPConfiguration.swift
//
// Loads and saves ~/.macscp/config.toml (logging + transfer settings).
// On first launch, creates the file — arm64 Macs get preset = "apple_silicon".
// See TransferPerformanceTuning.swift for how presets map to numbers.

import Foundation

public struct MacSCPLoggingSettings: Sendable, Equatable {
    public var enabled: Bool
    public var minimumLevel: MacSCPLogLevel
    public var retentionDays: Int
    public var mirrorStderr: Bool

    public init(
        enabled: Bool = true,
        minimumLevel: MacSCPLogLevel = .debug,
        retentionDays: Int = 14,
        mirrorStderr: Bool = false
    ) {
        self.enabled = enabled
        self.minimumLevel = minimumLevel
        self.retentionDays = retentionDays
        self.mirrorStderr = mirrorStderr
    }
}

public enum TransferPerformancePreset: String, Sendable, Equatable {
    case `default` = "default"
    case lan = "lan"
    case wan = "wan"
    case appleSilicon = "apple_silicon"
}

public struct MacSCPTransferSettings: Sendable, Equatable {
    public var maxConcurrentTransfers: Int
    public var maxConcurrentWrites: Int
    public var maxConcurrentReads: Int
    public var maxConcurrentUploads: Int
    public var chunkSize: Int
    public var resume: Bool
    public var verifyChecksums: Bool
    /// Applies tuned defaults for LAN or WAN; explicit keys in config.toml override preset values.
    public var preset: TransferPerformancePreset
    /// Use Traversio for key/password sessions when true (AGPL — see docs/user-guide.md).
    public var useTraversioForPerformance: Bool

    public init(
        maxConcurrentTransfers: Int = 2,
        maxConcurrentWrites: Int = 16,
        maxConcurrentReads: Int = 8,
        maxConcurrentUploads: Int = 12,
        chunkSize: Int = 1_048_576,
        resume: Bool = true,
        verifyChecksums: Bool = false,
        preset: TransferPerformancePreset = .default,
        useTraversioForPerformance: Bool = false
    ) {
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.maxConcurrentWrites = maxConcurrentWrites
        self.maxConcurrentReads = maxConcurrentReads
        self.maxConcurrentUploads = maxConcurrentUploads
        self.chunkSize = chunkSize
        self.resume = resume
        self.verifyChecksums = verifyChecksums
        self.preset = preset
        self.useTraversioForPerformance = useTraversioForPerformance
    }
}

public struct MacSCPAppSettings: Sendable, Equatable {
    public var logging: MacSCPLoggingSettings
    public var transfer: MacSCPTransferSettings

    public init(
        logging: MacSCPLoggingSettings = MacSCPLoggingSettings(),
        transfer: MacSCPTransferSettings = MacSCPTransferSettings()
    ) {
        self.logging = logging
        self.transfer = transfer
    }
}

public enum MacSCPConfiguration {
    public static let configFileName = "config.toml"

    public static let defaultConfigContents = defaultConfigContents(preset: .default)

    public static func defaultConfigContents(preset: TransferPerformancePreset) -> String {
        var transfer = MacSCPTransferSettings(preset: preset)
        applyPreset(preset, to: &transfer)

        return """
# MacSCP configuration
# See docs/user-guide.md §5.4 for details.

[logging]
enabled = true
level = "debug"
retention_days = 14
mirror_stderr = false

[transfer]
preset = "\(preset.rawValue)"
max_concurrent_transfers = \(transfer.maxConcurrentTransfers)
max_concurrent_writes = \(transfer.maxConcurrentWrites)
max_concurrent_reads = \(transfer.maxConcurrentReads)
max_concurrent_uploads = \(transfer.maxConcurrentUploads)
chunk_size = \(transfer.chunkSize)
resume = true
verify_checksums = false
use_traversio_for_performance = false

# Apple Silicon tuned preset (also available: lan, wan, apple_silicon):
# preset = "apple_silicon"
"""
    }

    public static func macscpDirectory(homeDirectory: URL) -> URL {
        homeDirectory.appendingPathComponent(".macscp", isDirectory: true)
    }

    public static func configURL(homeDirectory: URL) -> URL {
        macscpDirectory(homeDirectory: homeDirectory).appendingPathComponent(configFileName)
    }

    public static func loadSettings(homeDirectory: URL) throws -> MacSCPAppSettings {
        let directory = macscpDirectory(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let configURL = configURL(homeDirectory: homeDirectory)
        if !FileManager.default.fileExists(atPath: configURL.path) {
            // First launch: arm64 Macs get apple_silicon preset baked into new config.toml.
            let preset = TransferPerformanceTuning.suggestedPresetOnFirstLaunch() ?? .default
            let contents = defaultConfigContents(preset: preset)
            try contents.write(to: configURL, atomically: true, encoding: .utf8)
        }

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        return parseSettings(from: contents)
    }

    /// Ensures `~/.macscp/config.toml` exists and returns parsed logging settings.
    public static func loadLoggingSettings(homeDirectory: URL) throws -> MacSCPLoggingSettings {
        try loadSettings(homeDirectory: homeDirectory).logging
    }

    static func parseSettings(from contents: String) -> MacSCPAppSettings {
        var settings = MacSCPAppSettings()
        var section: String?

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }

            if line.hasPrefix("["), line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator].trimmingCharacters(in: .whitespaces))
            let value = String(line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces))

            switch section {
            case "logging":
                applyLoggingKey(key, value: value, to: &settings.logging)
            case "transfer":
                applyTransferKey(key, value: value, to: &settings.transfer)
            default:
                break
            }
        }

        if settings.logging.retentionDays < 0 {
            settings.logging.retentionDays = 0
        }

        return settings
    }

    static func applyPreset(_ preset: TransferPerformancePreset, to settings: inout MacSCPTransferSettings) {
        switch preset {
        case .default:
            break
        case .lan:
            settings.maxConcurrentTransfers = 4
            settings.maxConcurrentWrites = 32
            settings.maxConcurrentReads = 16
            settings.maxConcurrentUploads = 16
            settings.chunkSize = 1_048_576
            settings.verifyChecksums = false
        case .wan:
            settings.maxConcurrentTransfers = 1
            settings.maxConcurrentWrites = 8
            settings.maxConcurrentReads = 8
            settings.maxConcurrentUploads = 4
            settings.chunkSize = 262_144
            settings.verifyChecksums = false
        case .appleSilicon:
            // Tuned for M-series: bigger chunks, more concurrent uploads, connection pool.
            settings.maxConcurrentTransfers = AppleSiliconSupport.recommendedPoolSize
            settings.maxConcurrentWrites = 32
            settings.maxConcurrentReads = 16
            settings.maxConcurrentUploads = 24
            settings.chunkSize = 2_097_152
            settings.verifyChecksums = false
        }
    }

    static func parseLoggingSettings(from contents: String) -> MacSCPLoggingSettings {
        parseSettings(from: contents).logging
    }

    private static func applyLoggingKey(
        _ key: String,
        value: String,
        to settings: inout MacSCPLoggingSettings
    ) {
        switch key {
        case "enabled":
            settings.enabled = parseBool(value) ?? settings.enabled
        case "level":
            settings.minimumLevel = parseLogLevel(value) ?? settings.minimumLevel
        case "retention_days":
            settings.retentionDays = parseInt(value) ?? settings.retentionDays
        case "mirror_stderr":
            settings.mirrorStderr = parseBool(value) ?? settings.mirrorStderr
        default:
            break
        }
    }

    private static func applyTransferKey(
        _ key: String,
        value: String,
        to settings: inout MacSCPTransferSettings
    ) {
        switch key {
        case "max_concurrent_transfers":
            settings.maxConcurrentTransfers = max(1, parseInt(value) ?? settings.maxConcurrentTransfers)
        case "max_concurrent_writes":
            settings.maxConcurrentWrites = max(1, parseInt(value) ?? settings.maxConcurrentWrites)
        case "max_concurrent_reads":
            settings.maxConcurrentReads = max(1, parseInt(value) ?? settings.maxConcurrentReads)
        case "max_concurrent_uploads":
            settings.maxConcurrentUploads = max(1, parseInt(value) ?? settings.maxConcurrentUploads)
        case "chunk_size":
            settings.chunkSize = max(32_768, parseInt(value) ?? settings.chunkSize)
        case "resume":
            settings.resume = parseBool(value) ?? settings.resume
        case "verify_checksums":
            settings.verifyChecksums = parseBool(value) ?? settings.verifyChecksums
        case "preset":
            let parsed = TransferPerformancePreset(rawValue: unquote(value).lowercased()) ?? settings.preset
            settings.preset = parsed
            Self.applyPreset(parsed, to: &settings)
        case "use_traversio_for_performance":
            settings.useTraversioForPerformance = parseBool(value) ?? settings.useTraversioForPerformance
        default:
            break
        }
    }

    private static func parseBool(_ value: String) -> Bool? {
        let normalized = value.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "true", "yes", "1": return true
        case "false", "no", "0": return false
        default: return nil
        }
    }

    private static func parseInt(_ value: String) -> Int? {
        Int(value.trimmingCharacters(in: .whitespaces))
    }

    private static func parseLogLevel(_ value: String) -> MacSCPLogLevel? {
        let normalized = unquote(value).lowercased()
        switch normalized {
        case "debug": return .debug
        case "info": return .info
        case "warn", "warning": return .warning
        case "error": return .error
        default: return nil
        }
    }

    private static func unquote(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\""))
              || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
