// TransferPerformanceTuningTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TransferPerformanceTuning network profile mapping from presets and MACSCP_BENCH_NETWORK env.
//
import MacSCPCore
import XCTest

final class TransferPerformanceTuningTests: XCTestCase {
    func testNetworkProfileFromPreset() {
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(from: .default), .lan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(from: .lan), .lan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(from: .wan), .wan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(from: .appleSilicon), .lan)
    }

    func testNetworkProfileFromEnvironment() {
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "loopback"), .loopback)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "lan"), .lan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "wifi"), .wifi)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "wan"), .wan)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "  WIFI  "), .wifi)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: nil), .loopback)
        XCTAssertEqual(TransferPerformanceTuning.networkProfile(fromEnvironment: "unknown"), .loopback)
    }

    func testTcpBufferSizesVaryByProfile() {
        XCTAssertEqual(TransferPerformanceTuning.tcpSendBufferBytes(for: .lan), 2_097_152)
        XCTAssertEqual(TransferPerformanceTuning.tcpSendBufferBytes(for: .wifi), 1_048_576)
        XCTAssertEqual(TransferPerformanceTuning.tcpSendBufferBytes(for: .wan), 262_144)
        XCTAssertEqual(
            TransferPerformanceTuning.tcpReceiveBufferBytes(for: .wan),
            TransferPerformanceTuning.tcpSendBufferBytes(for: .wan)
        )
    }

    func testTcpNoDelayDisabledOnWanOnly() {
        XCTAssertTrue(TransferPerformanceTuning.usesTCPNoDelay(for: .loopback))
        XCTAssertTrue(TransferPerformanceTuning.usesTCPNoDelay(for: .lan))
        XCTAssertTrue(TransferPerformanceTuning.usesTCPNoDelay(for: .wifi))
        XCTAssertFalse(TransferPerformanceTuning.usesTCPNoDelay(for: .wan))
    }

    func testEffectivePoolSizeRespectsConfiguredMinimum() {
        let settings = MacSCPTransferSettings(maxConcurrentTransfers: 3)
        XCTAssertEqual(TransferPerformanceTuning.effectivePoolSize(from: settings), 3)
    }

    func testEffectivePoolSizeAppleSiliconOnArm64() {
        var settings = MacSCPTransferSettings(preset: .appleSilicon)
        settings.maxConcurrentTransfers = 1
        let poolSize = TransferPerformanceTuning.effectivePoolSize(from: settings)
        if AppleSiliconSupport.isAppleSilicon {
            XCTAssertGreaterThanOrEqual(poolSize, AppleSiliconSupport.recommendedPoolSize)
        } else {
            XCTAssertEqual(poolSize, 1)
        }
    }

    func testRecommendedPoolSizeIsClamped() {
        let pool = AppleSiliconSupport.recommendedPoolSize
        XCTAssertGreaterThanOrEqual(pool, 2)
        XCTAssertLessThanOrEqual(pool, 4)
    }

    func testSuggestedPresetOnFirstLaunchMatchesArchitecture() {
        let suggested = TransferPerformanceTuning.suggestedPresetOnFirstLaunch()
        if AppleSiliconSupport.isAppleSilicon {
            XCTAssertEqual(suggested, .appleSilicon)
        } else {
            XCTAssertNil(suggested)
        }
    }
}
