import Foundation
@testable import MacSCPCore
import XCTest

final class MacSCPConfigurationTests: XCTestCase {
    func testParseLoggingSettingsDefaults() {
        let settings = MacSCPConfiguration.parseLoggingSettings(from: "")
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.minimumLevel, .debug)
        XCTAssertEqual(settings.retentionDays, 14)
        XCTAssertFalse(settings.mirrorStderr)
    }

    func testParseLoggingSettingsFromTOML() {
        let toml = """
        [logging]
        enabled = false
        level = "warn"
        retention_days = 7
        mirror_stderr = true
        """
        let settings = MacSCPConfiguration.parseLoggingSettings(from: toml)
        XCTAssertFalse(settings.enabled)
        XCTAssertEqual(settings.minimumLevel, .warning)
        XCTAssertEqual(settings.retentionDays, 7)
        XCTAssertTrue(settings.mirrorStderr)
    }

    func testLoadLoggingSettingsCreatesDefaultConfig() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-config-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let configURL = MacSCPConfiguration.configURL(homeDirectory: tempHome)
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path))

        let settings = try MacSCPConfiguration.loadLoggingSettings(homeDirectory: tempHome)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
        XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.minimumLevel, .debug)

        let contents = try String(contentsOf: configURL, encoding: .utf8)
        XCTAssertTrue(contents.contains("[logging]"))
        XCTAssertTrue(contents.contains("retention_days = 14"))
        #if arch(arm64)
        XCTAssertTrue(contents.contains("preset = \"apple_silicon\""))
        #else
        XCTAssertTrue(contents.contains("preset = \"default\""))
        #endif
    }

    func testFirstLaunchPresetOnAppleSilicon() throws {
        guard AppleSiliconSupport.isAppleSilicon else {
            throw XCTSkip("Apple Silicon only")
        }

        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-config-arm64-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let settings = try MacSCPConfiguration.loadSettings(homeDirectory: tempHome)
        XCTAssertEqual(settings.transfer.preset, .appleSilicon)
        XCTAssertEqual(settings.transfer.chunkSize, 2_097_152)
    }

    func testNetworkProfileFromEnvironment() {
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "wifi"), .wifi)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "WAN"), .wan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: nil), .loopback)
    }

    func testParseTransferSettingsFromTOML() {
        let toml = """
        [transfer]
        max_concurrent_transfers = 4
        max_concurrent_writes = 16
        resume = false
        verify_checksums = true
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertEqual(settings.transfer.maxConcurrentTransfers, 4)
        XCTAssertEqual(settings.transfer.maxConcurrentWrites, 16)
        XCTAssertFalse(settings.transfer.resume)
        XCTAssertTrue(settings.transfer.verifyChecksums)
    }

    func testLanPresetAppliesThroughputDefaults() {
        let toml = """
        [transfer]
        preset = "lan"
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertEqual(settings.transfer.preset, .lan)
        XCTAssertEqual(settings.transfer.maxConcurrentTransfers, 4)
        XCTAssertEqual(settings.transfer.maxConcurrentWrites, 32)
        XCTAssertEqual(settings.transfer.maxConcurrentUploads, 16)
        XCTAssertFalse(settings.transfer.verifyChecksums)
    }

    func testAppleSiliconPresetAppliesPoolAndChunkDefaults() {
        let toml = """
        [transfer]
        preset = "apple_silicon"
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertEqual(settings.transfer.preset, .appleSilicon)
        XCTAssertEqual(settings.transfer.maxConcurrentWrites, 32)
        XCTAssertEqual(settings.transfer.maxConcurrentUploads, 24)
        XCTAssertEqual(settings.transfer.chunkSize, 2_097_152)
    }

    func testEffectivePoolSizeUsesAppleSiliconRecommendation() {
        var settings = MacSCPTransferSettings(preset: .appleSilicon)
        settings.maxConcurrentTransfers = 1
        if AppleSiliconSupport.isAppleSilicon {
            XCTAssertGreaterThanOrEqual(
                TransferPerformanceTuning.effectivePoolSize(from: settings),
                2
            )
        }
    }

    func testExplicitTransferKeysOverridePreset() {
        let toml = """
        [transfer]
        preset = "lan"
        max_concurrent_writes = 10
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertEqual(settings.transfer.maxConcurrentWrites, 10)
    }
}
