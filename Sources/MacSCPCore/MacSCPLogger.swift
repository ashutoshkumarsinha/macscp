// MacSCPLogger.swift — File logging controlled by ~/.macscp/config.toml.

import Foundation

public enum MacSCPLogLevel: String, Sendable, Comparable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warning: 2
        case .error: 3
        }
    }

    public static func < (lhs: MacSCPLogLevel, rhs: MacSCPLogLevel) -> Bool {
        lhs.rank < rhs.rank
    }
}

public enum MacSCPLogCategory: String, Sendable {
    case app = "app"
    case session = "session"
    case transfer = "transfer"
    case backend = "backend"
}

/// Thread-safe file logger. Call `bootstrap()` once at app launch before logging.
public final class MacSCPLogger: @unchecked Sendable {
    public static let shared = MacSCPLogger()

    public private(set) var logDirectory: URL?
    public private(set) var isEnabled = true
    public var minimumLevel: MacSCPLogLevel = .debug
    public private(set) var retentionDays = 14
    public private(set) var mirrorStderr = false

    private var fileLoggingDisabled = false
    private var fileWriteWarningLogged = false

    private let lock = NSLock()
    private var fileHandle: FileHandle?
    private var currentLogDay: String?
    private let dateFormatter: DateFormatter
    private let dayFormatter: DateFormatter

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"

        dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
    }

    /// Test-only: close handles and allow bootstrap to a fresh directory.
    internal func resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        try? fileHandle?.close()
        fileHandle = nil
        logDirectory = nil
        currentLogDay = nil
        isEnabled = true
        minimumLevel = .debug
        retentionDays = 14
        mirrorStderr = false
        fileLoggingDisabled = false
        fileWriteWarningLogged = false
    }

    /// Loads ~/.macscp/config.toml, creates ~/.macscp/logs if logging is enabled.
    @discardableResult
    public func bootstrap(homeDirectory: URL? = nil) -> URL? {
        lock.lock()
        defer { lock.unlock() }

        if logDirectory != nil, fileHandle != nil {
            return logDirectory
        }

        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        let settings: MacSCPLoggingSettings
        do {
            settings = try MacSCPConfiguration.loadLoggingSettings(homeDirectory: home)
        } catch {
            fputs("MacSCP: failed to load config: \(error)\n", stderr)
            settings = MacSCPLoggingSettings()
        }

        applySettingsUnlocked(settings)

        guard isEnabled else {
            return nil
        }

        let directory = MacSCPConfiguration.macscpDirectory(homeDirectory: home)
            .appendingPathComponent("logs", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            fputs("MacSCP: failed to create log directory: \(error)\n", stderr)
            return nil
        }

        logDirectory = directory
        pruneOldLogs(in: directory, keepingDays: retentionDays)
        openLogFile(for: Date(), in: directory)

        let message = "Logging initialized at \(directory.path)"
        writeUnlocked(level: .info, category: .app, message: message)
        return directory
    }

    private func applySettingsUnlocked(_ settings: MacSCPLoggingSettings) {
        isEnabled = settings.enabled
        minimumLevel = settings.minimumLevel
        retentionDays = settings.retentionDays
        mirrorStderr = settings.mirrorStderr
    }

    public func log(
        _ message: String,
        level: MacSCPLogLevel = .info,
        category: MacSCPLogCategory = .app
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard isEnabled else { return }
        guard level >= minimumLevel else { return }
        rotateIfNeededUnlocked(for: Date())
        writeUnlocked(level: level, category: category, message: message)
    }

    public func debug(_ message: String, category: MacSCPLogCategory = .app) {
        log(message, level: .debug, category: category)
    }

    public func info(_ message: String, category: MacSCPLogCategory = .app) {
        log(message, level: .info, category: category)
    }

    public func warning(_ message: String, category: MacSCPLogCategory = .app) {
        log(message, level: .warning, category: category)
    }

    public func error(_ message: String, category: MacSCPLogCategory = .app) {
        log(message, level: .error, category: category)
    }

    public func error(_ error: Error, context: String, category: MacSCPLogCategory = .app) {
        log("\(context): \(error.localizedDescription)", level: .error, category: category)
    }

    // MARK: - Private

    private func rotateIfNeededUnlocked(for date: Date) {
        let day = dayFormatter.string(from: date)
        guard day != currentLogDay, let directory = logDirectory else { return }
        openLogFile(for: date, in: directory)
    }

    private func openLogFile(for date: Date, in directory: URL) {
        if let fileHandle {
            try? fileHandle.close()
            self.fileHandle = nil
        }

        let day = dayFormatter.string(from: date)
        currentLogDay = day
        let logURL = directory.appendingPathComponent("macscp-\(day).log")

        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        try? handle.seekToEnd()
        fileHandle = handle
    }

    private func writeUnlocked(
        level: MacSCPLogLevel,
        category: MacSCPLogCategory,
        message: String
    ) {
        let timestamp = dateFormatter.string(from: Date())
        let sanitized = message.replacingOccurrences(of: "\n", with: " ")
        let line = "\(timestamp) [\(level.rawValue)] [\(category.rawValue)] \(sanitized)\n"

        guard let data = line.data(using: .utf8) else { return }

        if fileHandle == nil, logDirectory != nil {
            rotateIfNeededUnlocked(for: Date())
        }

        if let fileHandle, !fileLoggingDisabled {
            do {
                try fileHandle.write(contentsOf: data)
            } catch {
                fileLoggingDisabled = true
                if !fileWriteWarningLogged {
                    fileWriteWarningLogged = true
                    fputs("MacSCP: log file write failed: \(error); continuing on stderr only\n", stderr)
                }
                fputs(line, stderr)
            }
        } else if fileLoggingDisabled {
            fputs(line, stderr)
        }

        #if DEBUG
        fputs(line, stderr)
        #else
        if mirrorStderr {
            fputs(line, stderr)
        }
        #endif
    }

    private func pruneOldLogs(in directory: URL, keepingDays: Int) {
        guard keepingDays > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                  at: directory,
                  includingPropertiesForKeys: [.contentModificationDateKey],
                  options: [.skipsHiddenFiles]
              ) else { return }

        let cutoff = Calendar.current.date(byAdding: .day, value: -keepingDays, to: Date()) ?? Date()

        for url in urls where url.pathExtension == "log" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date.distantPast
            if modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
