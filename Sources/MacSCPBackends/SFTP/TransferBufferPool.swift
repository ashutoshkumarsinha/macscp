// TransferBufferPool.swift
//
// WHAT THIS FILE DOES
// -------------------
// Reuses NIO ByteBuffer objects between upload chunks to reduce allocator pressure during large
// transfers. CitadelSFTPBackend sequential upload and CitadelPipelinedWriter borrow and recycle buffers.
//

import Foundation
import NIO

enum TransferBufferPool {
    private final class Storage: @unchecked Sendable {
        private var available: [ByteBuffer] = []
        private let maxPooled = 8
        private let lock = NSLock()

        func borrow(capacity: Int) -> ByteBuffer {
            lock.lock()
            defer { lock.unlock() }
            if let index = available.firstIndex(where: { $0.capacity >= capacity }) {
                var buffer = available.remove(at: index)
                buffer.clear()
                return buffer
            }
            return ByteBufferAllocator().buffer(capacity: capacity)
        }

        func recycle(_ buffer: ByteBuffer) {
            lock.lock()
            defer { lock.unlock() }
            guard available.count < maxPooled else { return }
            var copy = buffer
            copy.clear()
            available.append(copy)
        }
    }

    private static let storage = Storage()

    static func borrow(capacity: Int) -> ByteBuffer {
        storage.borrow(capacity: capacity)
    }

    static func recycle(_ buffer: ByteBuffer) {
        storage.recycle(buffer)
    }
}
