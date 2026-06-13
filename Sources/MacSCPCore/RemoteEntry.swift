// RemoteEntry.swift
//
// WHAT THIS FILE DOES
// -------------------
// One row in a remote directory listing (like ls -l output). EntryType and FilePermissions
// model remote files for pane views and every backend listDirectory implementation.
//

import Foundation

public enum EntryType: String, Sendable, Equatable, Codable {
    case file
    case directory
    case symlink
}

// Unix permission bits (e.g. 0o644) for remote files.
public struct FilePermissions: Sendable, Equatable, Codable {
    public var octal: UInt32

    public init(octal: UInt32) {
        self.octal = octal
    }
}

// Describes one file or folder on the remote server.
public struct RemoteEntry: Sendable, Equatable, Codable {
    public var name: String
    public var path: String          // Full remote path
    public var type: EntryType
    public var size: Int64?          // nil for some directories
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
