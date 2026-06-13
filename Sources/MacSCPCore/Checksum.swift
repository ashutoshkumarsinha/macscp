// Checksum.swift
//
// WHAT THIS FILE DOES
// -------------------
// SHA-256 helpers to verify file integrity after transfer. Streams file bytes on disk and
// returns a 64-char hex string; used when verify_checksums is enabled outside upload pipelines.
//

import Crypto
import Foundation

public enum Checksum {
    private static let streamBufferSize = 1_048_576

    /// Stream-hash a file on disk; returns 64-char hex string.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try handle.read(upToCount: streamBufferSize), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
