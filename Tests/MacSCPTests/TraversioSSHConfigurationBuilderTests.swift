// TraversioSSHConfigurationBuilderTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// TraversioSSHConfigurationBuilder auth, host-key policy, HTTP proxy, and ProxyJump wiring.
//
@testable import MacSCPBackends
import MacSCPCore
import Traversio
import XCTest

final class TraversioSSHConfigurationBuilderTests: XCTestCase {
    func testPasswordAuthBuildsTargetConfiguration() async throws {
        let session = SessionConfiguration(
            host: "target.example.com",
            port: 2222,
            username: "deploy",
            password: "secret",
            authMethod: .password
        )

        let ssh = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)

        XCTAssertEqual(ssh.host, "target.example.com")
        XCTAssertEqual(ssh.port, 2222)
        XCTAssertEqual(ssh.username, "deploy")
        XCTAssertNil(ssh.connectionProxy)
        XCTAssertTrue(ssh.proxyJumpHosts.isEmpty)
    }

    func testHTTPProxyUsesDefaultPort8080() async throws {
        let session = SessionConfiguration(
            host: "target.example.com",
            username: "deploy",
            password: "secret",
            authMethod: .password,
            advanced: AdvancedSettings(proxyType: .http, proxyHost: "proxy.corp")
        )

        let ssh = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)

        guard case let .httpConnect(proxy)? = ssh.connectionProxy else {
            return XCTFail("Expected HTTP CONNECT proxy")
        }
        XCTAssertEqual(proxy.host, "proxy.corp")
        XCTAssertEqual(proxy.port, 8080)
        XCTAssertTrue(ssh.proxyJumpHosts.isEmpty)
    }

    func testSOCKS5ProxyUsesCustomPort() async throws {
        let session = SessionConfiguration(
            host: "target.example.com",
            username: "deploy",
            password: "secret",
            authMethod: .password,
            advanced: AdvancedSettings(proxyType: .socks5, proxyHost: "127.0.0.1", proxyPort: 9050)
        )

        let ssh = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)

        guard case let .socks5(proxy)? = ssh.connectionProxy else {
            return XCTFail("Expected SOCKS5 proxy")
        }
        XCTAssertEqual(proxy.host, "127.0.0.1")
        XCTAssertEqual(proxy.port, 9050)
    }

    func testProxyJumpBuildsHopChain() async throws {
        let session = SessionConfiguration(
            host: "target.internal",
            username: "deploy",
            password: "secret",
            authMethod: .password,
            advanced: AdvancedSettings(
                proxyType: .jump,
                proxyHost: "bastion.example.com,relay.example.com:2200"
            )
        )

        let ssh = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)

        XCTAssertNil(ssh.connectionProxy)
        XCTAssertEqual(ssh.proxyJumpHosts.count, 2)
        XCTAssertEqual(ssh.proxyJumpHosts[0].host, "bastion.example.com")
        XCTAssertEqual(ssh.proxyJumpHosts[0].port, 22)
        XCTAssertEqual(ssh.proxyJumpHosts[0].username, "deploy")
        XCTAssertEqual(ssh.proxyJumpHosts[1].host, "relay.example.com")
        XCTAssertEqual(ssh.proxyJumpHosts[1].port, 2200)
    }

    func testJumpTypeWithWhitespaceOnlyHostThrows() async {
        let session = SessionConfiguration(
            host: "target.internal",
            username: "deploy",
            password: "secret",
            authMethod: .password,
            advanced: AdvancedSettings(proxyType: .jump, proxyHost: "  ,  ")
        )

        do {
            _ = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)
            XCTFail("Expected invalid configuration")
        } catch let error as BackendError {
            guard case let .invalidConfiguration(message) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("ProxyJump"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testJumpTypeWithoutHostBuildsNoHops() async throws {
        let session = SessionConfiguration(
            host: "target.internal",
            username: "deploy",
            password: "secret",
            authMethod: .password,
            advanced: AdvancedSettings(proxyType: .jump, proxyHost: nil)
        )

        let ssh = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)
        XCTAssertTrue(ssh.proxyJumpHosts.isEmpty)
    }

    func testPasswordAuthRequiredWhenMissing() async {
        let session = SessionConfiguration(
            host: "target.example.com",
            username: "deploy",
            authMethod: .password
        )

        do {
            _ = try await TraversioSSHConfigurationBuilder.makeConfiguration(from: session)
            XCTFail("Expected authentication failure")
        } catch let error as BackendError {
            guard case .authenticationFailed = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
