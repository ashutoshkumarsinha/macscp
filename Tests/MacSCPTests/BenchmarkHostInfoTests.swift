import MacSCPCore
import XCTest

final class BenchmarkHostInfoTests: XCTestCase {
    func testCurrentIncludesArchitectureAndCores() {
        let info = BenchmarkHostInfo.current()
        XCTAssertFalse(info.architecture.isEmpty)
        XCTAssertGreaterThan(info.processorCount, 0)
        XCTAssertEqual(info.isAppleSilicon, AppleSiliconSupport.isAppleSilicon)
        XCTAssertFalse(info.osVersion.isEmpty)
    }

    func testCurrentUsesLoopbackWhenEnvUnset() {
        let info = BenchmarkHostInfo.current()
        let env = ProcessInfo.processInfo.environment["MACSCP_BENCH_NETWORK"]
        if env == nil {
            XCTAssertEqual(info.networkProfile, "loopback")
        }
    }
}
