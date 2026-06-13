// TransferContinuationFactory.swift
//
// WHAT THIS FILE DOES
// -------------------
// Builds async shouldContinue closures that honor TransferCancellation and Task cancellation.
// Backends pass the factory result into chunked upload and download loops.
//
import Foundation

public enum TransferContinuationFactory {
    public static func shouldContinue(for cancellation: TransferCancellation?) -> (@Sendable () async -> Bool)? {
        guard let cancellation else { return nil }
        return {
            !cancellation.isCancelled && !Task.isCancelled
        }
    }
}
