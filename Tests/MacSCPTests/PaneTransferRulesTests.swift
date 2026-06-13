import MacSCPCore
import XCTest

final class PaneTransferRulesTests: XCTestCase {
    func testAcceptsLocalToRemoteDrop() {
        XCTAssertTrue(PaneTransferRules.acceptsDrop(from: .local, to: .remote))
    }

    func testAcceptsRemoteToLocalDrop() {
        XCTAssertTrue(PaneTransferRules.acceptsDrop(from: .remote, to: .local))
    }

    func testRejectsSamePaneDrop() {
        XCTAssertFalse(PaneTransferRules.acceptsDrop(from: .local, to: .local))
        XCTAssertFalse(PaneTransferRules.acceptsDrop(from: .remote, to: .remote))
    }

    func testDragPayloadRoundTripJSON() throws {
        let payload = PaneDragPayloadCodable(side: .local, fileNames: ["a.txt", "b.txt"])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(PaneDragPayloadCodable.self, from: data)
        XCTAssertEqual(decoded, payload)
    }
}

/// Mirrors app drag payload fields for serialization testing without SwiftUI.
private struct PaneDragPayloadCodable: Codable, Equatable {
    var side: PaneSide
    var fileNames: [String]
}
