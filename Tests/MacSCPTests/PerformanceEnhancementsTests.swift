import Foundation
import Testing
@testable import MacSCPCore

@Test func syncIndexStoreCachesAndExpires() async {
    let store = SyncIndexStore.shared
    let key = "test-backend|/data"
    await store.invalidate(key: key)

    let entry = SyncRemoteIndexEntry(path: "/data/file.txt", size: 10, modified: Date())
    await store.store(["file.txt": entry], forKey: key)

    let cached = await store.cachedEntries(forKey: key, ttl: 60)
    #expect(cached?["file.txt"]?.size == 10)

    await store.invalidate(key: key)
    let afterInvalidate = await store.cachedEntries(forKey: key)
    #expect(afterInvalidate == nil)
}

@Test func effectivePoolSizeUsesIntelFallback() {
    var settings = MacSCPTransferSettings()
    settings.preset = .appleSilicon
    settings.maxConcurrentTransfers = 1
    let poolSize = TransferPerformanceTuning.effectivePoolSize(from: settings)
    #if arch(arm64)
    #expect(poolSize >= 2)
    #else
    #expect(poolSize >= 2)
    #endif
}
