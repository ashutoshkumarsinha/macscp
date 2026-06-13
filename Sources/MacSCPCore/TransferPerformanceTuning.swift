// TransferPerformanceTuning.swift — Apple Silicon presets and effective transfer limits.

import Foundation

public enum TransferNetworkProfile: String, Sendable, Equatable, Codable {
    case loopback
    case lan
    case wifi
    case wan
}

public enum AppleSiliconSupport {
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// Suggested SFTP connection pool size for parallel queue jobs on Apple Silicon.
    public static var recommendedPoolSize: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(max(2, cores / 2), 4)
    }
}

public enum TransferPerformanceTuning {
    public static func networkProfile(from preset: TransferPerformancePreset) -> TransferNetworkProfile {
        switch preset {
        case .default, .appleSilicon:
            return .lan
        case .lan:
            return .lan
        case .wan:
            return .wan
        }
    }

    public static func tcpSendBufferBytes(for profile: TransferNetworkProfile) -> Int {
        switch profile {
        case .loopback, .lan:
            return 2_097_152
        case .wifi:
            return 1_048_576
        case .wan:
            return 262_144
        }
    }

    public static func tcpReceiveBufferBytes(for profile: TransferNetworkProfile) -> Int {
        tcpSendBufferBytes(for: profile)
    }

    public static func usesTCPNoDelay(for profile: TransferNetworkProfile) -> Bool {
        switch profile {
        case .loopback, .lan, .wifi:
            return true
        case .wan:
            return false
        }
    }

    public static func effectivePoolSize(from settings: MacSCPTransferSettings) -> Int {
        if settings.preset == .appleSilicon, AppleSiliconSupport.isAppleSilicon {
            return max(settings.maxConcurrentTransfers, AppleSiliconSupport.recommendedPoolSize)
        }
        return max(1, settings.maxConcurrentTransfers)
    }

    public static func suggestedPresetOnFirstLaunch() -> TransferPerformancePreset? {
        AppleSiliconSupport.isAppleSilicon ? .appleSilicon : nil
    }

    public static func networkProfile(fromEnvironment value: String?) -> TransferNetworkProfile {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "wifi":
            return .wifi
        case "wan":
            return .wan
        case "lan":
            return .lan
        case "loopback", "":
            return .loopback
        default:
            return .loopback
        }
    }
}
