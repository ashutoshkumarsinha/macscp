// SyncIndexStore.swift
//
// WHAT THIS FILE DOES
// -------------------
// Persists last-known remote directory indexes between sync compares so unchanged trees
// can be diffed without a full remote walk.
//

import Foundation

public struct SyncRemoteIndexEntry: Sendable, Equatable, Codable {
    public var path: String
    public var size: Int64?
    public var modified: Date?

    public init(path: String, size: Int64?, modified: Date?) {
        self.path = path
        self.size = size
        self.modified = modified
    }
}

public actor SyncIndexStore {
    public static let shared = SyncIndexStore()

    private struct StoredIndex: Codable {
        var entries: [String: SyncRemoteIndexEntry]
        var fetchedAt: Date
    }

    private var memory: [String: StoredIndex] = [:]
    private let defaultTTL: TimeInterval = 300

    public func cachedEntries(forKey key: String, ttl: TimeInterval? = nil) -> [String: SyncRemoteIndexEntry]? {
        guard let stored = memory[key] else { return nil }
        let limit = ttl ?? defaultTTL
        if Date().timeIntervalSince(stored.fetchedAt) > limit {
            memory[key] = nil
            return nil
        }
        return stored.entries
    }

    public func store(_ entries: [String: SyncRemoteIndexEntry], forKey key: String) {
        memory[key] = StoredIndex(entries: entries, fetchedAt: Date())
    }

    public func invalidate(key: String) {
        memory.removeValue(forKey: key)
    }

    public static func cacheKey(remoteRoot: String, backendIdentifier: String) -> String {
        "\(backendIdentifier)|\(SFTPPathJoin.normalizeRemote(remoteRoot))"
    }
}
