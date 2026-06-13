// SFTPBackendSelectorTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// SFTPBackendSelector chooses Citadel vs Traversio based on auth method and performance settings.
//
import MacSCPCore
import MacSCPBackends
import XCTest

final class SFTPBackendSelectorTests: XCTestCase {
    func testAgentAuthSelectsTraversio() {
        let settings = MacSCPTransferSettings()
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .agent, settings: settings),
            .traversio
        )
    }

    func testPerformanceModeSelectsTraversio() {
        var settings = MacSCPTransferSettings()
        settings.useTraversioForPerformance = true
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .publicKey, settings: settings),
            .traversio
        )
    }

    func testDefaultKeyAuthSelectsCitadel() {
        let settings = MacSCPTransferSettings()
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .publicKey, settings: settings),
            .citadel
        )
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .password, settings: settings),
            .citadel
        )
    }

    func testAgentOverridesPerformanceFlagStillTraversio() {
        var settings = MacSCPTransferSettings()
        settings.useTraversioForPerformance = false
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .agent, settings: settings),
            .traversio
        )
    }

    func testProxyJumpSelectsTraversio() {
        let settings = MacSCPTransferSettings()
        let advanced = AdvancedSettings(proxyType: .jump, proxyHost: "bastion")
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .publicKey, settings: settings, advanced: advanced),
            .traversio
        )
    }

    func testHTTPProxySelectsTraversio() {
        let settings = MacSCPTransferSettings()
        let advanced = AdvancedSettings(proxyType: .http, proxyHost: "proxy.corp", proxyPort: 8080)
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .password, settings: settings, advanced: advanced),
            .traversio
        )
    }

    func testSOCKS5ProxySelectsTraversio() {
        let settings = MacSCPTransferSettings()
        let advanced = AdvancedSettings(proxyType: .socks5, proxyHost: "127.0.0.1", proxyPort: 1080)
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .publicKey, settings: settings, advanced: advanced),
            .traversio
        )
    }

    func testProxyDoesNotSelectCitadelEvenWithAppleSiliconPreset() {
        var settings = MacSCPTransferSettings()
        settings.preset = .appleSilicon
        let advanced = AdvancedSettings(proxyType: .jump, proxyHost: "bastion")
        XCTAssertEqual(
            SFTPBackendSelector.select(authMethod: .publicKey, settings: settings, advanced: advanced),
            .traversio
        )
    }
}
