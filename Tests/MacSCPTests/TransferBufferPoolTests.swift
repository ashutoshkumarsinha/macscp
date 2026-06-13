// TransferBufferPoolTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TransferBufferPool borrow and recycle of NIO ByteBuffer instances for transfer I/O.
//
@testable import MacSCPBackends
import NIO
import XCTest

final class TransferBufferPoolTests: XCTestCase {
    func testBorrowProvidesWritableBuffer() {
        var buffer = TransferBufferPool.borrow(capacity: 4096)
        buffer.writeBytes([0x01, 0x02, 0x03])
        XCTAssertEqual(buffer.readableBytes, 3)
    }

    func testRecycleAllowsReuse() {
        var first = TransferBufferPool.borrow(capacity: 8192)
        first.writeBytes(Array(repeating: UInt8(0xFF), count: 100))
        TransferBufferPool.recycle(first)

        let second = TransferBufferPool.borrow(capacity: 8192)
        XCTAssertGreaterThanOrEqual(second.capacity, 8192)
        XCTAssertEqual(second.readableBytes, 0)
    }
}
