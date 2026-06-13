// SFTPAttributeMapping.swift — Shared SFTP file mode → EntryType mapping.

import Foundation

public enum SFTPAttributeMapping {
    public static func entryType(fromPermissions permissions: UInt32?) -> EntryType {
        guard let permissions else { return .file }
        let fileType = permissions & 0o170000
        if fileType == 0o040000 { return .directory }
        if fileType == 0o120000 { return .symlink }
        return .file
    }
}
