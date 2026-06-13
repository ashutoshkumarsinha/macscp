// BenchmarkHostInfo.swift
//
// WHAT THIS FILE DOES
// -------------------
// Collects machine metadata when macscp-benchmark runs so JSON reports record
// whether results came from Apple Silicon, how many cores, and which network
// profile was simulated (MACSCP_BENCH_NETWORK env var).
//
// BEGINNER TIP
// ------------
// Compare reports over time only on similar hostInfo — loopback on an M2 Mac
// is not comparable to wifi on an Intel Mac without context.

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
