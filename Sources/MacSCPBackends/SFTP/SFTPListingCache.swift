// SFTPListingCache.swift
//
// WHAT THIS FILE DOES
// -------------------
// Short-lived in-memory cache of remote directory listings so pane refresh does not hit the
// server every time. CitadelSFTPBackend and TraversioSFTPBackend use it in listDirectory(at:)
// and invalidate after uploads that may change contents.
//

import Foundation
import MacSCPCore

/// Short-lived in-memory cache: remote path → list of RemoteEntry.
actor SFTPListingCache {
    private struct Entry {
        let entries: [RemoteEntry]
        let fetchedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval

    /// Default TTL is 3 seconds — long enough to debounce UI refresh, short enough
    /// that new files on the server show up quickly.
    init(ttl: TimeInterval = 3.0) {
        self.ttl = ttl
    }

    /// Returns cached entries if still fresh; nil means caller should list from SFTP.
    func listing(for path: String) -> [RemoteEntry]? {
        guard let entry = cache[path] else { return nil }
        if Date().timeIntervalSince(entry.fetchedAt) > ttl {
            cache[path] = nil
            return nil
        }
        return entry.entries
    }

    func store(_ entries: [RemoteEntry], for path: String) {
        cache[path] = Entry(entries: entries, fetchedAt: Date())
    }

    /// Drop one path after upload/rename so the next listDirectory fetches fresh data.
    func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
