import Foundation

public enum EntryType: Sendable, Equatable {
    case file
    case directory
    case symlink
}

public struct FilePermissions: Sendable, Equatable {
    public var octal: UInt32

    public init(octal: UInt32) {
        self.octal = octal
    }
}

public struct RemoteEntry: Sendable, Equatable {
    public var name: String
    public var path: String
    public var type: EntryType
    public var size: Int64?
    public var modified: Date?
    public var permissions: FilePermissions?

    public init(
        name: String,
        path: String,
        type: EntryType,
        size: Int64? = nil,
        modified: Date? = nil,
        permissions: FilePermissions? = nil
    ) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
        self.modified = modified
        self.permissions = permissions
    }
}
