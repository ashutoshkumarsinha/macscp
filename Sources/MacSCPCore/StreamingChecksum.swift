// StreamingChecksum.swift
//
// WHAT THIS FILE DOES
// -------------------
// Computes SHA-256 while file bytes stream during upload instead of reading the file twice.
// CitadelSFTPBackend and CitadelPipelinedWriter call update/finalizeHex when verify_checksums is on.
//

import Crypto
import Foundation

/// Incremental SHA-256 hasher safe to use from transfer I/O loops.
public final class StreamingSHA256: @unchecked Sendable {
    private var hasher = SHA256()

    public init() {}

    /// Feed the next chunk of file data into the hash.
    public func update(_ data: Data) {
        guard !data.isEmpty else { return }
        hasher.update(data: data)
    }

    /// Returns lowercase hex digest (same format as Checksum.sha256).
    public func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
