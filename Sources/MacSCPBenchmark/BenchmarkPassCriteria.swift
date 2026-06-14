// BenchmarkPassCriteria.swift
//
// WHAT THIS FILE DOES
// -------------------
// Pass/fail thresholds for performance benchmark scenarios (multiplex spike, ProxyCommand).
//

import Foundation

public enum BenchmarkPassCriteria {
    public static let multiplexImprovementThreshold = 0.30
    public static let proxyCommandMaxOverheadRatio = 2.0

    public static func multiplexImprovementRatio(separateSeconds: Double, multiplexSeconds: Double) -> Double {
        guard separateSeconds > 0 else { return 0 }
        return 1.0 - multiplexSeconds / separateSeconds
    }

    public static func multiplexMeetsTarget(
        separateSeconds: Double,
        multiplexSeconds: Double,
        supported: Bool
    ) -> Bool {
        supported
            && multiplexImprovementRatio(
                separateSeconds: separateSeconds,
                multiplexSeconds: multiplexSeconds
            ) >= multiplexImprovementThreshold
    }

    public static func proxyCommandOverheadRatio(directSeconds: Double, proxySeconds: Double) -> Double {
        directSeconds > 0 ? proxySeconds / directSeconds : proxySeconds
    }

    public static func proxyCommandMeetsTarget(directSeconds: Double, proxySeconds: Double) -> Bool {
        proxyCommandOverheadRatio(directSeconds: directSeconds, proxySeconds: proxySeconds)
            <= proxyCommandMaxOverheadRatio
    }
}
