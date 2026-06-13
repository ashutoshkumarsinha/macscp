import Foundation

public enum TransferContinuationFactory {
    public static func shouldContinue(for cancellation: TransferCancellation?) -> (@Sendable () async -> Bool)? {
        guard let cancellation else { return nil }
        return {
            !cancellation.isCancelled && !Task.isCancelled
        }
    }
}
