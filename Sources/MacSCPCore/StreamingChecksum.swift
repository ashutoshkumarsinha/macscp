// StreamingChecksum.swift — Incremental SHA-256 while streaming file bytes (CryptoKit).

import Crypto
import Foundation

/// Incremental SHA-256 hasher for overlapping with transfer I/O.
public final class StreamingSHA256: @unchecked Sendable {
    private var hasher = SHA256()

    public init() {}

    public func update(_ data: Data) {
        guard !data.isEmpty else { return }
        hasher.update(data: data)
    }

    public func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
