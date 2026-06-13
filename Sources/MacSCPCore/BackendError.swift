// BackendError.swift
//
// WHAT THIS FILE DOES
// -------------------
// Errors thrown by SFTP backends and transfer logic. UI and CLI show error.localizedDescription
// for connect failures, host-key rejection, path errors, and cancelled transfers.
//

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
