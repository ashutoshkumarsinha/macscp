// SFTPListingCache.swift
//
// WHAT THIS FILE DOES
// -------------------
// Remembers remote directory listings for a few seconds so refreshing the remote
// pane (or debounced refresh after uploads) does not hit the server every time.
//
// WHO USES IT
// -----------
// CitadelSFTPBackend and TraversioSFTPBackend in listDirectory(at:).
// Invalidated after uploads that may change directory contents.
//
// BEGINNER TIP
// ------------
// This is an `actor` — only one task uses the cache at a time, which is safe when
// multiple transfers finish and trigger pane refresh concurrently.

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
