// SFTPListingCache.swift — Short-TTL cache for remote directory listings.

import Foundation
import MacSCPCore

actor SFTPListingCache {
    private struct Entry {
        let entries: [RemoteEntry]
        let fetchedAt: Date
    }

    private var cache: [String: Entry] = [:]
    private let ttl: TimeInterval

    init(ttl: TimeInterval = 3.0) {
        self.ttl = ttl
    }

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

    func invalidate(path: String) {
        cache.removeValue(forKey: path)
    }

    func invalidateAll() {
        cache.removeAll()
    }
}
