// SFTPDirectoryCache.swift — Session-scoped cache of remote dirs already mkdir'd.

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
