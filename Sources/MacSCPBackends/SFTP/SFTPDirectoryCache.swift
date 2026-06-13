// SFTPDirectoryCache.swift
//
// WHAT THIS FILE DOES
// -------------------
// Session-scoped cache of remote directories already mkdir'd to skip redundant SFTP round-trips.
// CitadelSFTPBackend and TraversioSFTPBackend check the cache before creating parent paths.
//

import Foundation

/// Tracks remote directories already created this session to avoid redundant SFTP mkdir round-trips.
final class SFTPDirectoryCache: @unchecked Sendable {
    private var ensured = Set<String>()
    private let lock = NSLock()

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ensured.contains(path)
    }

    func insert(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        ensured.insert(path)
    }
}
