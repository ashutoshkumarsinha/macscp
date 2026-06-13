// SFTPBackendSelector.swift
//
// WHAT THIS FILE DOES
// -------------------
// Decides whether to use Citadel or Traversio for this session, and logs why.
//
// RULES (in order)
// ----------------
// 1. SSH agent auth → Traversio (Citadel does not support agent well)
// 2. use_traversio_for_performance = true in config → Traversio (AGPL — user opt-in)
// 3. Otherwise → Citadel (default for key/password)
//
// BEGINNER TIP
// ------------
// SessionCoordinator calls select() before TransferBackendFactory.make(...).

import MacSCPCore

public enum SFTPBackendSelector {
    public static func select(
        authMethod: AuthMethod,
        settings: MacSCPTransferSettings
    ) -> SFTPBackendKind {
        if authMethod == .agent {
            return .traversio
        }
        if settings.useTraversioForPerformance {
            return .traversio
        }
        return .citadel
    }

    /// Writes a one-line reason to the log file so support/debugging is easier.
    public static func logSelection(_ kind: SFTPBackendKind, settings: MacSCPTransferSettings) {
        let reason: String
        switch kind {
        case .traversio where settings.useTraversioForPerformance:
            reason = "performance mode (Traversio)"
        case .traversio:
            reason = "SSH agent auth"
        case .citadel where settings.preset == .appleSilicon:
            reason = "Apple Silicon preset (Citadel)"
        default:
            reason = "default"
        }
        MacSCPLogger.shared.info("Selected SFTP backend: \(kind.rawValue) — \(reason)", category: .backend)
    }
}
