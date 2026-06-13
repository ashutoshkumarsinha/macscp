// MacSCPLoggerTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// MacSCPLogger bootstrap, log directory creation, rotation, and level filtering.
//
import Foundation
@testable import MacSCPCore
import XCTest

final class MacSCPLoggerTests: XCTestCase {
    private var tempHome: URL!

    override func setUpWithError() throws {
        MacSCPLogger.shared.resetForTesting()
        tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-log-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempHome)
    }

    func testBootstrapCreatesLogDirectory() throws {
        let logger = MacSCPLogger.shared
        let directory = logger.bootstrap(homeDirectory: tempHome)

        XCTAssertNotNil(directory)
        let expected = tempHome.appendingPathComponent(".macscp/logs", isDirectory: true)
        XCTAssertEqual(directory, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path))
    }

    func testLogWritesToDailyFile() throws {
        let logger = MacSCPLogger.shared
        let directory = try XCTUnwrap(logger.bootstrap(homeDirectory: tempHome))

        logger.info("test message", category: .app)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: Date())
        let logFile = directory.appendingPathComponent("macscp-\(day).log")

        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path))
        let contents = try String(contentsOf: logFile, encoding: .utf8)
        XCTAssertTrue(contents.contains("[INFO] [app] test message"))
        XCTAssertTrue(contents.contains("Logging initialized"))
    }

    func testMinimumLevelFiltersDebug() throws {
        let logger = MacSCPLogger.shared
        _ = logger.bootstrap(homeDirectory: tempHome)
        logger.minimumLevel = .warning

        logger.debug("hidden debug", category: .app)
        logger.warning("visible warning", category: .app)

        let directory = tempHome.appendingPathComponent(".macscp/logs", isDirectory: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        let logFile = directory.appendingPathComponent("macscp-\(formatter.string(from: Date())).log")
        let contents = try String(contentsOf: logFile, encoding: .utf8)

        XCTAssertFalse(contents.contains("hidden debug"))
        XCTAssertTrue(contents.contains("visible warning"))
    }

    func testBootstrapCreatesDefaultConfig() throws {
        let logger = MacSCPLogger.shared
        _ = logger.bootstrap(homeDirectory: tempHome)

        let configURL = MacSCPConfiguration.configURL(homeDirectory: tempHome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testDisabledLoggingSkipsLogDirectory() throws {
        let configURL = MacSCPConfiguration.configURL(homeDirectory: tempHome)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [logging]
        enabled = false
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let logger = MacSCPLogger.shared
        let directory = logger.bootstrap(homeDirectory: tempHome)

        XCTAssertNil(directory)
        XCTAssertFalse(logger.isEnabled)
        let logsDir = tempHome.appendingPathComponent(".macscp/logs", isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: logsDir.path))

        logger.info("should not appear", category: .app)
    }

    func testConfigMinimumLevelAppliedOnBootstrap() throws {
        let configURL = MacSCPConfiguration.configURL(homeDirectory: tempHome)
        try FileManager.default.createDirectory(
            at: configURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try """
        [logging]
        enabled = true
        level = "error"
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let logger = MacSCPLogger.shared
        _ = logger.bootstrap(homeDirectory: tempHome)
        XCTAssertEqual(logger.minimumLevel, .error)
    }
}
