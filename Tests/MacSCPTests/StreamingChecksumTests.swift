import MacSCPCore
import XCTest

final class StreamingChecksumTests: XCTestCase {
    func testStreamingMatchesOneShotChecksum() {
        let data = Data(repeating: 0xAB, count: 4096)
        let streaming = StreamingSHA256()
        streaming.update(data)
        streaming.update(data)
        XCTAssertEqual(streaming.finalizeHex(), Checksum.sha256(of: data + data))
    }
}
