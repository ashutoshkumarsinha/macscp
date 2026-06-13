// SFTPBatchUploadExecutor.swift
//
// WHAT THIS FILE DOES
// -------------------
// Concurrent multi-file upload worker pool shared by CitadelSFTPBackend and TraversioSFTPBackend
// uploadBatch(). Limits concurrency from transfer settings while preserving per-item results.
//

import Foundation
import MacSCPCore

enum SFTPBatchUploadExecutor {
    static func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions,
        concurrency: Int,
        upload: @escaping @Sendable (BatchUploadItem, TransferOptions) async throws -> TransferResult
    ) async throws -> [TransferResult] {
        var results = [TransferResult?](repeating: nil, count: items.count)

        try await withThrowingTaskGroup(of: (Int, TransferResult).self) { group in
            var nextIndex = 0

            func scheduleNext() {
                guard nextIndex < items.count else { return }
                let index = nextIndex
                nextIndex += 1
                let item = items[index]
                var itemOptions = options
                // Checksum once at batch end would be expensive; skip per-file hashing in batch.
                itemOptions.checksum = nil
                group.addTask {
                    let result = try await upload(item, itemOptions)
                    return (index, result)
                }
            }

            for _ in 0 ..< min(max(1, concurrency), items.count) {
                scheduleNext()
            }

            for try await (index, result) in group {
                results[index] = result
                scheduleNext()
            }
        }

        return results.compactMap { $0 }
    }
}
