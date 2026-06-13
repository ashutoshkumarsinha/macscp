import Foundation

public struct BatchUploadItem: Sendable, Equatable {
    public var localURL: URL
    public var remotePath: String

    public init(localURL: URL, remotePath: String) {
        self.localURL = localURL
        self.remotePath = remotePath
    }
}

public extension TransferBackend {
    func uploadBatch(
        items: [BatchUploadItem],
        options: TransferOptions
    ) async throws -> [TransferResult] {
        var results: [TransferResult] = []
        results.reserveCapacity(items.count)
        for item in items {
            let result = try await upload(
                localURL: item.localURL,
                remotePath: item.remotePath,
                options: options
            )
            results.append(result)
        }
        return results
    }
}

public enum SFTPBackendKind: String, Sendable, CaseIterable {
    case citadel
    case traversio
}
