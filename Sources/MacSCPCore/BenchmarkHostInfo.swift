// BenchmarkHostInfo.swift
//
// WHAT THIS FILE DOES
// -------------------
// Collects machine metadata when macscp-benchmark runs so JSON reports record host CPU, OS,
// and simulated network profile (MACSCP_BENCH_NETWORK). Compare reports only on similar hostInfo.
//

import Foundation

public struct BenchmarkHostInfo: Codable, Sendable {
    public var architecture: String
    public var processorCount: Int
    public var isAppleSilicon: Bool
    public var osVersion: String
    public var networkProfile: String

    public static func current() -> BenchmarkHostInfo {
        let network = ProcessInfo.processInfo.environment["MACSCP_BENCH_NETWORK"] ?? "loopback"
        return BenchmarkHostInfo(
            architecture: currentArchitecture(),
            processorCount: ProcessInfo.processInfo.activeProcessorCount,
            isAppleSilicon: AppleSiliconSupport.isAppleSilicon,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            networkProfile: network
        )
    }

    private static func currentArchitecture() -> String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
