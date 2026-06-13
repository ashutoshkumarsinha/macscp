// MacSCPConfiguration.swift — ~/.macscp/config.toml (created on first bootstrap).

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

public struct MacSCPTransferSettings: Sendable, Equatable {
    public var maxConcurrentTransfers: Int
    public var maxConcurrentWrites: Int
    public var maxConcurrentReads: Int
    public var maxConcurrentUploads: Int
    public var chunkSize: Int
    public var resume: Bool

    public init(
        maxConcurrentTransfers: Int = 2,
        maxConcurrentWrites: Int = 8,
        maxConcurrentReads: Int = 8,
        maxConcurrentUploads: Int = 8,
        chunkSize: Int = 1_048_576,
        resume: Bool = true
    ) {
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.maxConcurrentWrites = maxConcurrentWrites
        self.maxConcurrentReads = maxConcurrentReads
        self.maxConcurrentUploads = maxConcurrentUploads
        self.chunkSize = chunkSize
        self.resume = resume
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

    public static let defaultConfigContents = """
# MacSCP configuration
# See docs/user-guide.md §5.4 for details.

[logging]
enabled = true
level = "debug"
retention_days = 14
mirror_stderr = false

[transfer]
max_concurrent_transfers = 2
max_concurrent_writes = 8
max_concurrent_reads = 8
max_concurrent_uploads = 8
chunk_size = 1048576
resume = true
"""

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
            try defaultConfigContents.write(to: configURL, atomically: true, encoding: .utf8)
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
