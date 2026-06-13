// SFTPErrorHelpers.swift
//
// WHAT THIS FILE DOES
// -------------------
// Classifies SFTP errors from Citadel and Traversio into common conditions.
// Backends call isAlreadyExists when mkdir fails because a path already exists.
//
import Foundation

enum SFTPErrorHelpers {
    /// Returns true when an SFTP mkdir failed because the path already exists.
    /// OpenSSH often returns SSH_FX_FAILURE (4) instead of a dedicated code; Traversio
    /// surfaces that as "status 4: Failure" while Citadel uses "failure (4)".
    static func isAlreadyExists(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("already exists")
            || message.contains("file already")
            || message.contains("failure (4)")
            || message.contains("status 4:")
            || message.contains("ssh_fx_failure")
            || message.contains("fx_failure")
    }
}
