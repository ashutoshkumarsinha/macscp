// BackendError.swift — Errors thrown by SFTP backends and transfer logic.
// The UI can show error.localizedDescription to the user.

import Foundation

public enum BackendError: Error, Sendable, Equatable {
    case notConnected              // Operation called before connect()
    case notImplemented(String)    // Feature not built yet (e.g. SSH agent)
    case authenticationFailed(String)
    case hostKeyRejected(expected: String?, actual: String)
    case pathNotFound(String)
    case permissionDenied(String)
    case transferFailed(String)
    case cancelled                 // User cancelled or TransferCancellation fired
    case invalidConfiguration(String)
}
