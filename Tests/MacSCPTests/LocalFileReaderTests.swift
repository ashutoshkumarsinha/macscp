@testable import MacSCPBackends
import XCTest

final class LocalFileReaderTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-reader-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    func testReadsSmallFileViaFileHandle() throws {
        let url = tempDirectory.appendingPathComponent("small.bin")
        let payload = Data(repeating: 0xCD, count: 1024)
        try payload.write(to: url)

        let reader = try LocalFileSequentialReader(url: url)
        XCTAssertEqual(reader.totalSize, 1024)
        XCTAssertEqual(try reader.read(from: 0, count: 512), payload.prefix(512))
        XCTAssertEqual(try reader.read(from: 512, count: 512), payload.suffix(512))
    }

    func testReadsLargeFileViaMappedPath() throws {
        let url = tempDirectory.appendingPathComponent("large.bin")
        let size = 300 * 1024
        let payload = Data(repeating: 0xAB, count: size)
        try payload.write(to: url)

        let reader = try LocalFileSequentialReader(url: url)
        XCTAssertEqual(reader.totalSize, size)
        let chunk = try reader.read(from: 256 * 1024, count: 4096)
        XCTAssertEqual(chunk, payload.subdata(in: (256 * 1024) ..< (256 * 1024 + 4096)))
    }

    func testReadPastEndReturnsEmpty() throws {
        let url = tempDirectory.appendingPathComponent("tiny.bin")
        try Data([1, 2, 3]).write(to: url)
        let reader = try LocalFileSequentialReader(url: url)
        XCTAssertTrue(try reader.read(from: 10, count: 5).isEmpty)
        XCTAssertTrue(try reader.read(from: 0, count: 0).isEmpty)
    }
}
