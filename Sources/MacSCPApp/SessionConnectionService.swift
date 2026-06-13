// SessionConnectionService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Thin connect/disconnect wrapper around TransferBackend. SessionCoordinator calls connect
// then changeDirectory to the configured initial remote path after backend selection.
//

import Foundation
import MacSCPCore

@MainActor
struct SessionConnectionService {
    func connect(backend: TransferBackend, configuration: SessionConfiguration) async throws {
        try await backend.connect(configuration: configuration)
        try await backend.changeDirectory(to: configuration.initialRemotePath)
    }

    func disconnect(backend: TransferBackend) async throws {
        try await backend.disconnect()
    }
}
