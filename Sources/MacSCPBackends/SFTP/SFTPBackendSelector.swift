// SFTPBackendSelector.swift
//
// WHAT THIS FILE DOES
// -------------------
// Decides Citadel vs Traversio for a session and logs why. Agent auth or proxy → Traversio;
// use_traversio_for_performance opt-in → Traversio; otherwise Citadel. SessionCoordinator calls
// select() before TransferBackendFactory.make(...).
//

import MacSCPCore

public enum SFTPBackendSelector {
    public static func select(
        authMethod: AuthMethod,
        settings: MacSCPTransferSettings,
        advanced: AdvancedSettings = AdvancedSettings()
    ) -> SFTPBackendKind {
        if authMethod == .agent || advanced.proxyType != .none {
            return .traversio
        }
        if settings.useTraversioForPerformance {
            return .traversio
        }
        return .citadel
    }

    /// Writes a one-line reason to the log file so support/debugging is easier.
    public static func logSelection(
        _ kind: SFTPBackendKind,
        settings: MacSCPTransferSettings,
        advanced: AdvancedSettings = AdvancedSettings()
    ) {
        let reason: String
        switch kind {
        case .traversio where settings.useTraversioForPerformance:
            reason = "performance mode (Traversio)"
            MacSCPLogger.shared.warning(
                "Traversio AGPL backend enabled for key/password session (use_traversio_for_performance). See NOTICE and docs/traversio-licensing.md.",
                category: .backend
            )
        case .traversio where advanced.proxyType != .none:
            reason = "proxy (\(advanced.proxyType.rawValue))"
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
