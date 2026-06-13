// HostKeyTrustGate.swift — Interactive host-key trust for GUI and strict batch CLI mode.

import Foundation

public struct HostKeyTrustRequest: Sendable, Equatable, Identifiable {
    public var id: UUID
    public var endpoint: String
    public var fingerprintSHA256: String
    /// True when a stored fingerprint differs from what the server presented.
    public var isKeyChange: Bool
    public var storedFingerprint: String?

    public init(
        id: UUID = UUID(),
        endpoint: String,
        fingerprintSHA256: String,
        isKeyChange: Bool,
        storedFingerprint: String? = nil
    ) {
        self.id = id
        self.endpoint = endpoint
        self.fingerprintSHA256 = fingerprintSHA256
        self.isKeyChange = isKeyChange
        self.storedFingerprint = storedFingerprint
    }
}

public actor HostKeyTrustGate {
    public static let shared = HostKeyTrustGate()

    public enum Mode: Sendable {
        /// Auto-trust unknown keys (benchmarks, tests).
        case silentTOFU
        /// Prompt via HostKeyTrustGate.pendingRequest + respond(trusted:).
        case interactive
        /// Reject unknown/changed keys unless pinned fingerprint matches.
        case batchStrict
    }

    private var mode: Mode = .silentTOFU
    private var pendingRequest: HostKeyTrustRequest?
    private var waiter: CheckedContinuation<Bool, Never>?

    public init() {}

    public func setMode(_ mode: Mode) {
        self.mode = mode
    }

    public func currentMode() -> Mode { mode }

    public func peekPendingRequest() -> HostKeyTrustRequest? {
        pendingRequest
    }

    public func respond(trusted: Bool) {
        waiter?.resume(returning: trusted)
        waiter = nil
        pendingRequest = nil
    }

    /// Returns whether the fingerprint should be saved to the trust store.
    public func approveTrust(for request: HostKeyTrustRequest) async -> Bool {
        switch mode {
        case .silentTOFU:
            return true
        case .batchStrict:
            return false
        case .interactive:
            pendingRequest = request
            defer {
                pendingRequest = nil
            }
            return await withCheckedContinuation { continuation in
                waiter = continuation
            }
        }
    }

    /// Runs async gate logic from synchronous SSH host-key callbacks.
    public nonisolated static func runBlocking<T: Sendable>(
        _ operation: @Sendable @escaping () async -> T
    ) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = BlockingResultBox<T>()
        Task {
            box.value = await operation()
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }
}

private final class BlockingResultBox<T>: @unchecked Sendable {
    var value: T?
}

private final class UncheckedSendableBox<T>: @unchecked Sendable {
    var value: T?
    init() {}
}
