// SessionConnectionService.swift — Thin connect/disconnect wrapper around TransferBackend.

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
