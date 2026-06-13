import Foundation
import MacSCPCore

public struct PendingTransferItem: Identifiable, Equatable {
    public let id = UUID()
    public var localURL: URL
    public var remotePath: String
    public var totalBytes: Int64?
    public var hasConflict: Bool

    public init(localURL: URL, remotePath: String, totalBytes: Int64? = nil, hasConflict: Bool) {
        self.localURL = localURL
        self.remotePath = remotePath
        self.totalBytes = totalBytes
        self.hasConflict = hasConflict
    }
}

public struct PendingTransferBatch: Identifiable, Equatable {
    public enum Kind: Equatable {
        case upload
        case download
    }

    public let id = UUID()
    public var kind: Kind
    public var items: [PendingTransferItem]

    public init(kind: Kind, items: [PendingTransferItem]) {
        self.kind = kind
        self.items = items
    }

    public var conflictNames: [String] {
        TransferBatchPlanner.conflictNames(
            in: items.map {
                TransferConflictItem(displayName: $0.localURL.lastPathComponent, hasConflict: $0.hasConflict)
            }
        )
    }

    public var requiresPrompt: Bool {
        TransferBatchPlanner.requiresOverwritePrompt(
            items: items.map {
                TransferConflictItem(displayName: $0.localURL.lastPathComponent, hasConflict: $0.hasConflict)
            }
        )
    }
}

public enum OverwriteBatchAction {
    case cancel
    case overwriteAll
    case skipExisting
    case renameAll
}
