// SFTPListingCacheTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// SFTPListingCache store, hit, expiry, and invalidation of remote directory listings.
//
import MacSCPCore
@testable import MacSCPBackends
import XCTest

final class SFTPListingCacheTests: XCTestCase {
    private func sampleEntries(path: String) -> [RemoteEntry] {
        [
            RemoteEntry(name: "a.txt", path: "\(path)/a.txt", type: .file, size: 1),
            RemoteEntry(name: "dir", path: "\(path)/dir", type: .directory, size: nil),
        ]
    }

    func testStoreAndHitCache() async {
        let cache = SFTPListingCache(ttl: 3.0)
        let entries = sampleEntries(path: "/remote")
        await cache.store(entries, for: "/remote")
        let cached = await cache.listing(for: "/remote")
        XCTAssertEqual(cached?.map(\.name), entries.map(\.name))
    }

    func testMissWhenPathNotCached() async {
        let cache = SFTPListingCache()
        let listing = await cache.listing(for: "/missing")
        XCTAssertNil(listing)
    }

    func testInvalidateRemovesEntry() async {
        let cache = SFTPListingCache()
        await cache.store(sampleEntries(path: "/x"), for: "/x")
        await cache.invalidate(path: "/x")
        let listing = await cache.listing(for: "/x")
        XCTAssertNil(listing)
    }

    func testInvalidateAllClearsCache() async {
        let cache = SFTPListingCache()
        await cache.store(sampleEntries(path: "/a"), for: "/a")
        await cache.store(sampleEntries(path: "/b"), for: "/b")
        await cache.invalidateAll()
        let listingA = await cache.listing(for: "/a")
        let listingB = await cache.listing(for: "/b")
        XCTAssertNil(listingA)
        XCTAssertNil(listingB)
    }

    func testEntryExpiresAfterTTL() async throws {
        let cache = SFTPListingCache(ttl: 0.05)
        await cache.store(sampleEntries(path: "/ttl"), for: "/ttl")
        let fresh = await cache.listing(for: "/ttl")
        XCTAssertNotNil(fresh)
        try await Task.sleep(for: .milliseconds(80))
        let expired = await cache.listing(for: "/ttl")
        XCTAssertNil(expired)
    }
}
