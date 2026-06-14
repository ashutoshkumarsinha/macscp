// BenchmarkConfigTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// BenchmarkConfig session builders for ProxyCommand, WebDAV, and S3 fixtures.
//
import MacSCPCore
import MacSCPBackends
import MacSCPBenchmark
import XCTest

final class BenchmarkConfigTests: XCTestCase {
    private var savedWebDAV: String?
    private var savedWebDAVPort: String?
    private var savedWebDAVUser: String?
    private var savedWebDAVPass: String?
    private var savedWebDAVPath: String?
    private var savedS3: String?
    private var savedS3Port: String?
    private var savedS3Bucket: String?
    private var savedS3AccessKey: String?
    private var savedS3SecretKey: String?
    private var savedS3Region: String?

    override func setUp() {
        super.setUp()
        let env = ProcessInfo.processInfo.environment
        savedWebDAV = env["MACSCP_BENCH_WEBDAV"]
        savedWebDAVPort = env["MACSCP_BENCH_WEBDAV_PORT"]
        savedWebDAVUser = env["MACSCP_BENCH_WEBDAV_USER"]
        savedWebDAVPass = env["MACSCP_BENCH_WEBDAV_PASS"]
        savedWebDAVPath = env["MACSCP_BENCH_WEBDAV_PATH"]
        savedS3 = env["MACSCP_BENCH_S3"]
        savedS3Port = env["MACSCP_BENCH_S3_PORT"]
        savedS3Bucket = env["MACSCP_BENCH_S3_BUCKET"]
        savedS3AccessKey = env["MACSCP_BENCH_S3_ACCESS_KEY"]
        savedS3SecretKey = env["MACSCP_BENCH_S3_SECRET_KEY"]
        savedS3Region = env["MACSCP_BENCH_S3_REGION"]
    }

    override func tearDown() {
        restore("MACSCP_BENCH_WEBDAV", savedWebDAV)
        restore("MACSCP_BENCH_WEBDAV_PORT", savedWebDAVPort)
        restore("MACSCP_BENCH_WEBDAV_USER", savedWebDAVUser)
        restore("MACSCP_BENCH_WEBDAV_PASS", savedWebDAVPass)
        restore("MACSCP_BENCH_WEBDAV_PATH", savedWebDAVPath)
        restore("MACSCP_BENCH_S3", savedS3)
        restore("MACSCP_BENCH_S3_PORT", savedS3Port)
        restore("MACSCP_BENCH_S3_BUCKET", savedS3Bucket)
        restore("MACSCP_BENCH_S3_ACCESS_KEY", savedS3AccessKey)
        restore("MACSCP_BENCH_S3_SECRET_KEY", savedS3SecretKey)
        restore("MACSCP_BENCH_S3_REGION", savedS3Region)
        super.tearDown()
    }

    func testProxyCommandSessionIncludesBenchPortAndKey() throws {
        let config = sampleConfig(port: 2222, keyPath: "/tmp/bench-key")
        let session = config.proxyCommandSessionConfiguration()

        XCTAssertEqual(session.host, "127.0.0.1")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "benchuser")
        let proxy = try XCTUnwrap(session.advanced.proxyCommand)
        XCTAssertTrue(proxy.contains("-p 2222"))
        XCTAssertTrue(proxy.contains("-i \"/tmp/bench-key\""))
        XCTAssertTrue(proxy.contains("-W %h:%p"))
        XCTAssertTrue(proxy.contains("benchuser@127.0.0.1"))
    }

    func testProxyCommandTemplateExpandsBenchHostAndPort() throws {
        let config = sampleConfig(port: 2222, keyPath: "/tmp/bench-key")
        let session = config.proxyCommandSessionConfiguration()
        let template = try XCTUnwrap(session.advanced.proxyCommand)
        let expanded = ProxyCommandTemplate.expand(template, configuration: session)
        XCTAssertTrue(expanded.contains("-W 127.0.0.1:2222"))
    }

    func testWebDAVSessionConfigurationNilWhenDisabled() {
        unsetenv("MACSCP_BENCH_WEBDAV")
        let config = sampleConfig()
        XCTAssertNil(config.webDAVSessionConfiguration())
    }

    func testWebDAVSessionConfigurationReadsEnvironment() throws {
        setenv("MACSCP_BENCH_WEBDAV", "1", 1)
        setenv("MACSCP_BENCH_WEBDAV_PORT", "9090", 1)
        setenv("MACSCP_BENCH_WEBDAV_USER", "davuser", 1)
        setenv("MACSCP_BENCH_WEBDAV_PASS", "davpass", 1)
        setenv("MACSCP_BENCH_WEBDAV_PATH", "/upload/", 1)

        let session = try XCTUnwrap(sampleConfig().webDAVSessionConfiguration())
        XCTAssertEqual(session.protocol, .webdav)
        XCTAssertEqual(session.host, "127.0.0.1")
        XCTAssertEqual(session.port, 9090)
        XCTAssertEqual(session.username, "davuser")
        XCTAssertEqual(session.password, "davpass")
        XCTAssertEqual(session.initialRemotePath, "/upload/")
    }

    func testS3SessionConfigurationNilWhenDisabled() {
        unsetenv("MACSCP_BENCH_S3")
        let config = sampleConfig()
        XCTAssertNil(config.s3SessionConfiguration())
    }

    func testS3SessionConfigurationReadsEnvironment() throws {
        setenv("MACSCP_BENCH_S3", "1", 1)
        setenv("MACSCP_BENCH_S3_PORT", "9001", 1)
        setenv("MACSCP_BENCH_S3_BUCKET", "test-bucket", 1)
        setenv("MACSCP_BENCH_S3_ACCESS_KEY", "access", 1)
        setenv("MACSCP_BENCH_S3_SECRET_KEY", "secret", 1)
        setenv("MACSCP_BENCH_S3_REGION", "eu-west-1", 1)

        let session = try XCTUnwrap(sampleConfig().s3SessionConfiguration())
        XCTAssertEqual(session.protocol, .s3)
        XCTAssertEqual(session.host, "127.0.0.1")
        XCTAssertEqual(session.port, 9001)
        XCTAssertEqual(session.username, "access")
        XCTAssertEqual(session.password, "secret")
        XCTAssertEqual(session.initialRemotePath, "/test-bucket/")
        XCTAssertEqual(session.advanced.cloudBucket, "test-bucket")
        XCTAssertEqual(session.advanced.cloudRegion, "eu-west-1")
    }

    private func sampleConfig(port: Int = 2222, keyPath: String = "/tmp/key") -> BenchmarkConfig {
        BenchmarkConfig(
            host: "127.0.0.1",
            port: port,
            username: "benchuser",
            password: nil,
            keyPath: keyPath,
            keyPassphrase: nil,
            authMethod: .publicKey,
            dataDirectory: URL(fileURLWithPath: "/tmp/bench-data"),
            workDirectory: URL(fileURLWithPath: "/tmp/bench-work"),
            smallFileCount: 100,
            largeFileSizes: [1024],
            skipLarge1GB: true
        )
    }

    private func restore(_ key: String, _ value: String?) {
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
    }
}
