import Foundation

public enum PaneSide: String, Codable, Sendable {
    case local
    case remote
}

public enum PaneTransferRules {
    /// Returns true when a drag from `source` pane may be dropped on `destination` pane.
    public static func acceptsDrop(from source: PaneSide, to destination: PaneSide) -> Bool {
        switch (destination, source) {
        case (.remote, .local), (.local, .remote):
            return true
        default:
            return false
        }
    }
}

public enum TransferBatchPlanner {
    public static func requiresOverwritePrompt(items: [TransferConflictItem]) -> Bool {
        items.contains(where: \.hasConflict)
    }

    public static func conflictNames(in items: [TransferConflictItem]) -> [String] {
        items.filter(\.hasConflict).map(\.displayName)
    }
}

public struct TransferConflictItem: Equatable, Sendable {
    public var displayName: String
    public var hasConflict: Bool

    public init(displayName: String, hasConflict: Bool) {
        self.displayName = displayName
        self.hasConflict = hasConflict
    }
}
