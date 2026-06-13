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

    func testEmptyUpdatesAreIgnored() {
        let streaming = StreamingSHA256()
        streaming.update(Data())
        streaming.update(Data([0x01]))
        streaming.update(Data())
        XCTAssertEqual(streaming.finalizeHex(), Checksum.sha256(of: Data([0x01])))
    }

    func testIncrementalChunksMatchSingleRead() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-stream-checksum-\(UUID().uuidString).bin")
        let payload = Data((0 ..< 8192).map { UInt8($0 % 251) })
        try payload.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let streaming = StreamingSHA256()
        streaming.update(payload.prefix(3000))
        streaming.update(payload.dropFirst(3000))

        XCTAssertEqual(streaming.finalizeHex(), try Checksum.sha256(of: url))
    }
}
