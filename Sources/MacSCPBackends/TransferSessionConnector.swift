// TransferSessionConnector.swift
//
// WHAT THIS FILE DOES
// -------------------
// Shared connect path for CLI, Shortcuts, and automation: picks Citadel vs Traversio,
// optional PooledTransferBackend, or a single serialized backend.
//

import Foundation
import MacSCPCore

public enum TransferSessionConnector {
    /// Opens a backend for the session. When `usePool` is nil, pooling follows transfer settings.
    public static func connect(
        configuration: SessionConfiguration,
        transferSettings: MacSCPTransferSettings,
        usePool: Bool? = nil
    ) async throws -> TransferBackend {
        switch configuration.protocol {
        case .sftp:
            let backendKind = SFTPBackendSelector.select(
                authMethod: configuration.authMethod,
                settings: transferSettings,
                advanced: configuration.advanced
            )
            let poolSize = TransferPerformanceTuning.effectivePoolSize(from: transferSettings)
            let shouldPool = usePool ?? (poolSize > 1)
            if shouldPool, poolSize > 1 {
                let pool = PooledTransferBackend(poolSize: poolSize, backendKind: backendKind)
                try await pool.connect(configuration: configuration)
                return pool
            }
            let single = try TransferBackendFactory.make(
                for: .sftp,
                backend: backendKind,
                serialized: true
            )
            try await single.connect(configuration: configuration)
            return single
        case .scp, .ftp, .ftps, .webdav, .s3, .gcs:
            let single = try TransferBackendFactory.make(for: configuration.protocol, backend: .citadel, serialized: true)
            try await single.connect(configuration: configuration)
            return single
        }
    }
}
