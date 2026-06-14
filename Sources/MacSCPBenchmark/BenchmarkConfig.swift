// BenchmarkConfig.swift
//
// WHAT THIS FILE DOES
// -------------------
// Command-line configuration for MacSCP benchmark runs against a remote host.
// Parsed by the benchmark CLI and passed to BenchmarkRunner and spike runners.
//
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

    public init(
        host: String,
        port: Int,
        username: String,
        password: String? = nil,
        keyPath: String? = nil,
        keyPassphrase: String? = nil,
        authMethod: AuthMethod,
        dataDirectory: URL,
        workDirectory: URL,
        smallFileCount: Int,
        largeFileSizes: [Int],
        skipLarge1GB: Bool
    ) {
        self.host = host
        self.port = port
        self.username = username
        self.password = password
        self.keyPath = keyPath
        self.keyPassphrase = keyPassphrase
        self.authMethod = authMethod
        self.dataDirectory = dataDirectory
        self.workDirectory = workDirectory
        self.smallFileCount = smallFileCount
        self.largeFileSizes = largeFileSizes
        self.skipLarge1GB = skipLarge1GB
    }

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
            initialRemotePath: dataDirectory.path,
            networkProfile: TransferPerformanceTuning.networkProfile(
                fromEnvironment: ProcessInfo.processInfo.environment["MACSCP_BENCH_NETWORK"]
            )
        )
    }

    /// Loopback ProxyCommand that forwards through `ssh -W` to measure relay overhead.
    public func proxyCommandSessionConfiguration() -> SessionConfiguration {
        var session = sessionConfiguration()
        let key = keyPath ?? ""
        session.advanced.proxyCommand = """
        ssh -p \(port) -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i "\(key)" -W %h:%p \(username)@127.0.0.1
        """
        return session
    }

    public func webDAVSessionConfiguration() -> SessionConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard env["MACSCP_BENCH_WEBDAV"] == "1" else { return nil }
        let webdavHost = env["MACSCP_BENCH_WEBDAV_HOST"] ?? "127.0.0.1"
        let webdavPort = Int(env["MACSCP_BENCH_WEBDAV_PORT"] ?? "8080") ?? 8080
        return SessionConfiguration(
            name: "webdav-benchmark",
            protocol: .webdav,
            host: webdavHost,
            port: webdavPort,
            username: env["MACSCP_BENCH_WEBDAV_USER"] ?? "bench",
            password: env["MACSCP_BENCH_WEBDAV_PASS"] ?? "bench",
            authMethod: .password,
            initialRemotePath: env["MACSCP_BENCH_WEBDAV_PATH"] ?? "/"
        )
    }

    public func s3SessionConfiguration() -> SessionConfiguration? {
        let env = ProcessInfo.processInfo.environment
        guard env["MACSCP_BENCH_S3"] == "1" else { return nil }
        let s3Host = env["MACSCP_BENCH_S3_HOST"] ?? "127.0.0.1"
        let s3Port = Int(env["MACSCP_BENCH_S3_PORT"] ?? "9000") ?? 9000
        let bucket = env["MACSCP_BENCH_S3_BUCKET"] ?? "macscp-bench"
        return SessionConfiguration(
            name: "s3-benchmark",
            protocol: .s3,
            host: s3Host,
            port: s3Port,
            username: env["MACSCP_BENCH_S3_ACCESS_KEY"] ?? "minioadmin",
            password: env["MACSCP_BENCH_S3_SECRET_KEY"] ?? "minioadmin",
            authMethod: .password,
            initialRemotePath: "/\(bucket)/",
            advanced: AdvancedSettings(cloudRegion: env["MACSCP_BENCH_S3_REGION"] ?? "us-east-1", cloudBucket: bucket)
        )
    }
}

public struct BenchmarkTimingBreakdown: Codable, Sendable {
    public var connectSeconds: Double
    public var transferSeconds: Double
    public var checksumSeconds: Double?
    public var disconnectSeconds: Double
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
    public var timingBreakdown: BenchmarkTimingBreakdown?
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
        public var hostInfo: BenchmarkHostInfo?
    }

    public struct ReportSummary: Codable, Sendable {
        public var citadelLargeFileRatio: Double?
        public var citadelSmallFileRatio: Double?
        public var passCriteriaMet: Bool
        public var recommendation: String
    }
}
