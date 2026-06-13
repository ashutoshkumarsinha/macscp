import Foundation
import MacSCPCore

enum AppMetricsService {
    private static let launchKey = "macscp.metrics.launchMs"
    private static let connectKey = "macscp.metrics.connectMs"

    static let processStart = Date()

    static func recordLaunchComplete() {
        let ms = Int(Date().timeIntervalSince(processStart) * 1000)
        UserDefaults.standard.set(ms, forKey: launchKey)
        MacSCPLogger.shared.info("Launch complete in \(ms) ms", category: .app)
    }

    static func recordConnect(durationMs: Int) {
        UserDefaults.standard.set(durationMs, forKey: connectKey)
        MacSCPLogger.shared.info("Connected in \(durationMs) ms", category: .app)
    }

    static func launchMilliseconds() -> Int? {
        let value = UserDefaults.standard.integer(forKey: launchKey)
        return value > 0 ? value : nil
    }

    static func lastConnectMilliseconds() -> Int? {
        let value = UserDefaults.standard.integer(forKey: connectKey)
        return value > 0 ? value : nil
    }
}
