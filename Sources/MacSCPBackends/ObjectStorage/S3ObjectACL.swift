// S3ObjectACL.swift
//
// WHAT THIS FILE DOES
// -------------------
// Maps Unix permission bits to S3 canned ACLs for PutObjectAcl requests.
//

import MacSCPCore

public enum S3ObjectACL {
    public static func canned(for permissions: FilePermissions) -> String {
        let mode = permissions.octal
        let worldRead = (mode & 0o004) != 0
        let worldWrite = (mode & 0o002) != 0
        let groupRead = (mode & 0o040) != 0
        if worldWrite { return "public-read-write" }
        if worldRead { return "public-read" }
        if groupRead { return "authenticated-read" }
        return "private"
    }
}
