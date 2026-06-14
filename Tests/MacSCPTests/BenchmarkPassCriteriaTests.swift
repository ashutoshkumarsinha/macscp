// BenchmarkPassCriteriaTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// Multiplex spike and ProxyCommand benchmark pass thresholds.
//
import XCTest
import MacSCPBenchmark

final class BenchmarkPassCriteriaTests: XCTestCase {
    func testMultiplexImprovementRatio() {
        XCTAssertEqual(
            BenchmarkPassCriteria.multiplexImprovementRatio(separateSeconds: 0.10, multiplexSeconds: 0.07),
            0.3,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BenchmarkPassCriteria.multiplexImprovementRatio(separateSeconds: 0, multiplexSeconds: 0.05),
            0
        )
    }

    func testMultiplexMeetsTargetRequiresSupportAndThirtyPercentWin() {
        XCTAssertTrue(
            BenchmarkPassCriteria.multiplexMeetsTarget(
                separateSeconds: 0.10,
                multiplexSeconds: 0.06,
                supported: true
            )
        )
        XCTAssertFalse(
            BenchmarkPassCriteria.multiplexMeetsTarget(
                separateSeconds: 0.10,
                multiplexSeconds: 0.08,
                supported: true
            )
        )
        XCTAssertFalse(
            BenchmarkPassCriteria.multiplexMeetsTarget(
                separateSeconds: 0.10,
                multiplexSeconds: 0.05,
                supported: false
            )
        )
    }

    func testProxyCommandOverheadRatio() {
        XCTAssertEqual(
            BenchmarkPassCriteria.proxyCommandOverheadRatio(directSeconds: 0.05, proxySeconds: 0.10),
            2.0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            BenchmarkPassCriteria.proxyCommandOverheadRatio(directSeconds: 0, proxySeconds: 0.12),
            0.12,
            accuracy: 0.0001
        )
    }

    func testProxyCommandMeetsTargetWithinTwoTimesDirect() {
        XCTAssertTrue(
            BenchmarkPassCriteria.proxyCommandMeetsTarget(directSeconds: 0.05, proxySeconds: 0.09)
        )
        XCTAssertTrue(
            BenchmarkPassCriteria.proxyCommandMeetsTarget(directSeconds: 0.05, proxySeconds: 0.10)
        )
        XCTAssertFalse(
            BenchmarkPassCriteria.proxyCommandMeetsTarget(directSeconds: 0.05, proxySeconds: 0.11)
        )
    }
}
