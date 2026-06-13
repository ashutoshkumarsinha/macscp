import Foundation
import MacSCPCore

public struct BenchmarkConfig: Sendable {
    public var host: String
    public var port: Int
    public var username: String
    public var password: String?
    public var keyPath: String?
    public var keyPassphrase: String?
    public var authMethod: AuthMethod
    public var dataDirectory: URL
    public var workDirectory: URL
    public var smallFileCount: Int
    public var largeFileSizes: [Int]
    public var skipLarge1GB: Bool

    public static func fromEnvironment() throws -> BenchmarkConfig {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let benchRoot = root.appendingPathComponent(".benchmark", isDirectory: true)
        let dataDir = benchRoot.appendingPathComponent("data", isDirectory: true)
        let workDir = benchRoot.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        let port = Int(ProcessInfo.processInfo.environment["MACSCP_BENCH_PORT"] ?? "2222") ?? 2222
        let full = ProcessInfo.processInfo.environment["MACSCP_BENCH_FULL"] == "1"

        return BenchmarkConfig(
            host: ProcessInfo.processInfo.environment["MACSCP_BENCH_HOST"] ?? "127.0.0.1",
            port: port,
            username: ProcessInfo.processInfo.environment["MACSCP_BENCH_USER"] ?? NSUserName(),
            password: nil,
            keyPath: ProcessInfo.processInfo.environment["MACSCP_BENCH_KEY"]
                ?? benchRoot.appendingPathComponent("keys/client_key").path,
            keyPassphrase: nil,
            authMethod: .publicKey,
            dataDirectory: dataDir,
            workDirectory: workDir,
            smallFileCount: full ? 10_000 : 1_000,
            largeFileSizes: full ? [1_048_576, 104_857_600, 1_073_741_824] : [1_048_576, 10_485_760],
            skipLarge1GB: !full
        )
    }

    public func sessionConfiguration() -> SessionConfiguration {
        SessionConfiguration(
            name: "benchmark",
            protocol: .sftp,
            host: host,
            port: port,
            username: username,
            password: password,
            authMethod: authMethod,
            keyPath: keyPath,
            keyPassphrase: keyPassphrase,
            initialRemotePath: dataDirectory.path
        )
    }
}

public struct BenchmarkResult: Codable, Sendable {
    public var scenario: String
    public var backend: String
    public var durationSeconds: Double
    public var throughputMBps: Double?
    public var filesPerSecond: Double?
    public var itemCount: Int?
    public var bytes: Int64
    public var sha256Match: Bool?
    public var passed: Bool
    public var notes: String?
}

public struct BenchmarkReport: Codable, Sendable {
    public var timestamp: String
    public var config: ReportConfig
    public var results: [BenchmarkResult]
    public var summary: ReportSummary

    public struct ReportConfig: Codable, Sendable {
        public var host: String
        public var port: Int
        public var smallFileCount: Int
        public var largeFileSizes: [Int]
    }

    public struct ReportSummary: Codable, Sendable {
        public var citadelLargeFileRatio: Double?
        public var citadelSmallFileRatio: Double?
        public var passCriteriaMet: Bool
        public var recommendation: String
    }
}
