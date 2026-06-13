// TransferPerformanceTuning.swift
//
// WHAT THIS FILE DOES
// -------------------
// Reads transfer settings from config.toml and turns presets into concrete pool sizes, TCP buffer
// sizes, and chunk tuning. SessionCoordinator, MacSCPConfiguration, CitadelTCPConnector, and
// macscp-benchmark consume these values at connect and report time.
//

import Foundation

/// Describes the kind of network path to the server. Drives TCP tuning values.
public enum TransferNetworkProfile: String, Sendable, Equatable, Codable {
    case loopback  // Same machine (127.0.0.1 benchmarks)
    case lan       // Fast wired LAN
    case wifi      // Wireless — smaller buffers than LAN
    case wan       // High-latency internet — smaller buffers, Nagle may stay on
}

/// Helpers that detect Apple Silicon (arm64) and suggest pool sizes.
public enum AppleSiliconSupport {
    /// True when this binary runs on arm64 (M1/M2/M3/M4 Macs).
    public static var isAppleSilicon: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    /// How many parallel SFTP connections the app should prefer on Apple Silicon.
    /// Uses half the CPU cores, clamped between 2 and 4, so we use P-cores without
    /// opening too many SSH sessions.
    public static var recommendedPoolSize: Int {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        return min(max(2, cores / 2), 4)
    }
}

/// Maps config presets and benchmarks to numeric tuning values.
public enum TransferPerformanceTuning {
    /// Converts a user-facing preset from config.toml into a network profile for TCP tuning.
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

    /// SO_SNDBUF — how much data the OS may buffer before sending on the wire.
    public static func tcpSendBufferBytes(for profile: TransferNetworkProfile) -> Int {
        switch profile {
        case .loopback, .lan:
            return 2_097_152   // 2 MB
        case .wifi:
            return 1_048_576   // 1 MB
        case .wan:
            return 262_144     // 256 KB
        }
    }

    public static func tcpReceiveBufferBytes(for profile: TransferNetworkProfile) -> Int {
        tcpSendBufferBytes(for: profile)
    }

    /// TCP_NODELAY disables Nagle's algorithm (send small packets immediately).
    /// We turn it OFF on WAN where batching tiny packets can help high-latency links.
    public static func usesTCPNoDelay(for profile: TransferNetworkProfile) -> Bool {
        switch profile {
        case .loopback, .lan, .wifi:
            return true
        case .wan:
            return false
        }
    }

    /// How many SFTP connections PooledTransferBackend should open.
    /// apple_silicon preset on arm64 bumps this up to recommendedPoolSize.
    public static func effectivePoolSize(from settings: MacSCPTransferSettings) -> Int {
        if settings.preset == .appleSilicon, AppleSiliconSupport.isAppleSilicon {
            return max(settings.maxConcurrentTransfers, AppleSiliconSupport.recommendedPoolSize)
        }
        return max(1, settings.maxConcurrentTransfers)
    }

    /// When creating config.toml for the first time, arm64 Macs get apple_silicon preset.
    public static func suggestedPresetOnFirstLaunch() -> TransferPerformancePreset? {
        AppleSiliconSupport.isAppleSilicon ? .appleSilicon : nil
    }

    /// Used by macscp-benchmark when MACSCP_BENCH_NETWORK is set (e.g. loopback, wifi).
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
