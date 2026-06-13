// MacSCPConfigurationTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// MacSCPConfiguration TOML parsing for logging, transfer presets, and settings round-trip.
//
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

    func testWanPresetAppliesSmallerChunksAndConcurrency() {
        let toml = """
        [transfer]
        preset = "wan"
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertEqual(settings.transfer.preset, .wan)
        XCTAssertEqual(settings.transfer.maxConcurrentTransfers, 1)
        XCTAssertEqual(settings.transfer.chunkSize, 262_144)
        XCTAssertEqual(settings.transfer.maxConcurrentUploads, 4)
    }

    func testDefaultConfigContentsReflectsPresetValues() {
        let apple = MacSCPConfiguration.defaultConfigContents(preset: .appleSilicon)
        XCTAssertTrue(apple.contains("preset = \"apple_silicon\""))
        XCTAssertTrue(apple.contains("chunk_size = 2097152"))

        let wan = MacSCPConfiguration.defaultConfigContents(preset: .wan)
        XCTAssertTrue(wan.contains("preset = \"wan\""))
        XCTAssertTrue(wan.contains("chunk_size = 262144"))
    }

    func testUseTraversioForPerformanceFlag() {
        let toml = """
        [transfer]
        use_traversio_for_performance = true
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertTrue(settings.transfer.useTraversioForPerformance)
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

    func testParseFeatureSettingsFromAppSection() {
        let toml = """
        [app]
        transfer_history = true
        notify_on_queue_complete = true
        icloud_profile_sync = false
        """
        let settings = MacSCPConfiguration.parseSettings(from: toml)
        XCTAssertTrue(settings.features.transferHistoryEnabled)
        XCTAssertTrue(settings.features.notifyOnQueueComplete)
        XCTAssertFalse(settings.features.iCloudProfileSyncEnabled)
    }

    func testSaveFeatureSettingsUpdatesAppSection() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-features-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        _ = try MacSCPConfiguration.loadSettings(homeDirectory: tempHome)
        let features = MacSCPFeatureSettings(
            transferHistoryEnabled: true,
            notifyOnQueueComplete: false,
            iCloudProfileSyncEnabled: true
        )
        try MacSCPConfiguration.saveFeatureSettings(features, homeDirectory: tempHome)
        let loaded = try MacSCPConfiguration.loadSettings(homeDirectory: tempHome)
        XCTAssertEqual(loaded.features, features)
    }
}
