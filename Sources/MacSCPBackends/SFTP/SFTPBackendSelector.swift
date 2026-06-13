// SFTPBackendSelector.swift — Backend choice for auth, presets, and performance mode.

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
