import Foundation

public enum BackendError: Error, Sendable, Equatable {
    case notConnected
    case notImplemented(String)
    case authenticationFailed(String)
    case hostKeyRejected(expected: String?, actual: String)
    case pathNotFound(String)
    case permissionDenied(String)
    case transferFailed(String)
    case cancelled
    case invalidConfiguration(String)
}
