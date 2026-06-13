import Foundation
import MacSCPCore

struct PendingTransferItem: Identifiable, Equatable {
    let id = UUID()
    var localURL: URL
    var remotePath: String
    var totalBytes: Int64?
    var hasConflict: Bool
}

struct PendingTransferBatch: Identifiable, Equatable {
    enum Kind: Equatable {
        case upload
        case download
    }

    let id = UUID()
    var kind: Kind
    var items: [PendingTransferItem]

    var conflictNames: [String] {
        items.filter(\.hasConflict).map { item in
            switch kind {
            case .upload, .download:
                item.localURL.lastPathComponent
            }
        }
    }
}

enum OverwriteBatchAction {
    case cancel
    case overwriteAll
    case skipExisting
    case renameAll
}
