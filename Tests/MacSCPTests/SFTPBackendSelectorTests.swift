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
}
