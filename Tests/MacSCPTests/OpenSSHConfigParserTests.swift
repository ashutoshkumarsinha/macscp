// OpenSSHConfigParserTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// OpenSSHConfigParser Host block parsing, merged settings, ProxyJump chains, and pattern matching.
//
import MacSCPCore
import XCTest

final class OpenSSHConfigParserTests: XCTestCase {
    private let sampleConfig = """
    Host jump
        HostName jump.example.com
        User jumpuser
        Port 2222

    Host production
        HostName prod.internal
        ProxyJump jump,bastion
        User deploy

    Host bastion
        HostName bastion.example.com

    Host *
        Port 22
    """

    func testParsesHostBlocks() {
        let blocks = OpenSSHConfigParser.parse(contents: sampleConfig)
        XCTAssertEqual(blocks.count, 4)
        XCTAssertEqual(blocks[0].patterns, ["jump"])
        XCTAssertEqual(blocks[0].settings["hostname"], "jump.example.com")
    }

    func testMergedSettingsExpandsAlias() {
        let blocks = OpenSSHConfigParser.parse(contents: sampleConfig)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "production", port: 22, blocks: blocks)
        XCTAssertEqual(settings?.hostName, "prod.internal")
        XCTAssertEqual(settings?.user, "deploy")
        XCTAssertEqual(settings?.proxyJump, ["jump", "bastion"])
    }

    func testWildcardHostBlock() {
        let blocks = OpenSSHConfigParser.parse(contents: sampleConfig)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "unknown.example.com", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.port, 22)
    }

    func testNegatedPatternRejectsHost() {
        let config = """
        Host !*.internal
            ProxyJump blocked

        Host *.internal
            ProxyJump allowed
        """
        let blocks = OpenSSHConfigParser.parse(contents: config)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "db.internal", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.proxyJump, ["allowed"])
    }

    func testResolveJumpChainUsesHostBlocks() {
        let blocks = OpenSSHConfigParser.parse(contents: sampleConfig)
        let chain = OpenSSHConfigParser.resolveJumpChain(
            tokens: ["jump", "bastion"],
            defaultUsername: "deploy",
            blocks: blocks
        )
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0].host, "jump.example.com")
        XCTAssertEqual(chain[0].port, 2222)
        XCTAssertEqual(chain[0].username, "jumpuser")
        XCTAssertEqual(chain[1].host, "bastion.example.com")
        XCTAssertEqual(chain[1].username, "deploy")
    }

    func testParseJumpTokenWithPort() {
        let blocks: [OpenSSHHostBlock] = []
        let chain = OpenSSHConfigParser.resolveJumpChain(
            tokens: ["admin@relay.example.com:2200"],
            defaultUsername: "deploy",
            blocks: blocks
        )
        XCTAssertEqual(chain.first?.host, "relay.example.com")
        XCTAssertEqual(chain.first?.port, 2200)
        XCTAssertEqual(chain.first?.username, "admin")
    }

    func testMergeOpenSSHConfigAppliesProxyJumpWhenProfileHasNoProxy() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try sampleConfig.write(to: configURL, atomically: true, encoding: .utf8)

        var session = SessionConfiguration(
            host: "production",
            port: 22,
            username: "local",
            authMethod: .publicKey,
            keyPath: "~/.ssh/id_ed25519"
        )
        session.mergeOpenSSHConfig(configPath: configURL)

        XCTAssertEqual(session.host, "prod.internal")
        XCTAssertEqual(session.username, "deploy")
        XCTAssertEqual(session.advanced.proxyType, .jump)
        XCTAssertEqual(session.advanced.proxyHost, "jump,bastion")
    }

    func testMergeOpenSSHConfigDoesNotOverrideExplicitProxy() {
        var session = SessionConfiguration(
            host: "production",
            port: 22,
            username: "deploy",
            authMethod: .publicKey,
            keyPath: "~/.ssh/id_ed25519",
            advanced: AdvancedSettings(proxyType: .jump, proxyHost: "manual.example.com")
        )
        session.mergeOpenSSHConfig(configPath: URL(fileURLWithPath: "/dev/null"))
        XCTAssertEqual(session.advanced.proxyHost, "manual.example.com")
    }

    func testRawSettingsApplyProxyJump() {
        var session = SessionConfiguration(host: "target", port: 22, username: "user")
        OpenSSHRawSettings.apply(["ProxyJump=jump1,jump2"], to: &session)
        XCTAssertEqual(session.advanced.proxyType, .jump)
        XCTAssertEqual(session.advanced.proxyHost, "jump1,jump2")
    }

    func testParsesKeyValueEqualsSyntax() {
        let config = """
        Host dev
            HostName=dev.local
            Port=2222
        """
        let blocks = OpenSSHConfigParser.parse(contents: config)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "dev", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.hostName, "dev.local")
        XCTAssertEqual(settings?.port, 2222)
    }

    func testParsesQuotedValues() {
        let config = """
        Host dev
            HostName "dev.local"
            IdentityFile '~/.ssh/id_ed25519'
        """
        let blocks = OpenSSHConfigParser.parse(contents: config)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "dev", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.hostName, "dev.local")
        XCTAssertEqual(settings?.identityFile, "~/.ssh/id_ed25519")
    }

    func testSkipsCommentLines() {
        let config = """
        # whole line comment
        Host dev
            HostName dev.local # inline ignored by naive split — value kept if quoted path not used
        """
        let blocks = OpenSSHConfigParser.parse(contents: config)
        XCTAssertEqual(blocks.count, 1)
    }

    func testLoadFromFileURL() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try sampleConfig.write(to: configURL, atomically: true, encoding: .utf8)

        let blocks = try OpenSSHConfigParser.load(from: configURL)
        XCTAssertEqual(blocks.count, 4)
    }

    func testDefaultConfigURLUsesHomeSSHDirectory() {
        let home = URL(fileURLWithPath: "/tmp/test-home")
        let url = OpenSSHConfigParser.defaultConfigURL(homeDirectory: home)
        XCTAssertEqual(url.path, "/tmp/test-home/.ssh/config")
    }

    func testFirstMatchWinsForSpecificHostBlock() {
        let blocks = OpenSSHConfigParser.parse(contents: sampleConfig)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "jump", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.port, 2222)
    }

    func testMergedSettingsReturnsNilWhenNoHostMatches() {
        let blocks = OpenSSHConfigParser.parse(contents: "Host only-dev\n    HostName dev.local\n")
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "prod", port: nil, blocks: blocks)
        XCTAssertNil(settings)
    }

    func testParseJumpTokenIPv6BracketForm() {
        let chain = OpenSSHConfigParser.resolveJumpChain(
            tokens: ["operator@[2001:db8::1]:2222"],
            defaultUsername: "deploy",
            blocks: []
        )
        XCTAssertEqual(chain.first?.host, "2001:db8::1")
        XCTAssertEqual(chain.first?.port, 2222)
        XCTAssertEqual(chain.first?.username, "operator")
    }

    func testMergeOpenSSHConfigAppliesIdentityFileWhenKeyPathMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try """
        Host staging
            HostName staging.example.com
            IdentityFile ~/.ssh/staging_key
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var session = SessionConfiguration(
            host: "staging",
            username: "deploy",
            authMethod: .publicKey
        )
        session.mergeOpenSSHConfig(configPath: configURL)

        XCTAssertEqual(session.host, "staging.example.com")
        XCTAssertEqual(session.keyPath, "~/.ssh/staging_key")
    }

    func testMergeOpenSSHConfigDoesNotOverrideExistingKeyPath() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try """
        Host staging
            IdentityFile ~/.ssh/from_config
        """.write(to: configURL, atomically: true, encoding: .utf8)

        var session = SessionConfiguration(
            host: "staging",
            username: "deploy",
            authMethod: .publicKey,
            keyPath: "~/.ssh/profile_key"
        )
        session.mergeOpenSSHConfig(configPath: configURL)

        XCTAssertEqual(session.keyPath, "~/.ssh/profile_key")
    }

    func testRawSettingsApplyHostNamePortUser() {
        var session = SessionConfiguration(host: "alias", port: 22, username: "old")
        OpenSSHRawSettings.apply(
            ["HostName=real.example.com", "Port=2222", "User=newuser"],
            to: &session
        )
        XCTAssertEqual(session.host, "real.example.com")
        XCTAssertEqual(session.port, 2222)
        XCTAssertEqual(session.username, "newuser")
    }

    func testRawSettingsIgnoresMalformedEntries() {
        var session = SessionConfiguration(host: "target", port: 22, username: "user")
        OpenSSHRawSettings.apply(["ProxyJump", "Port=not-a-number", "ProxyJump=hop"], to: &session)
        XCTAssertEqual(session.advanced.proxyHost, "hop")
        XCTAssertEqual(session.port, 22)
    }

    func testRequiresTraversioForProxyTypes() {
        var session = SessionConfiguration(host: "h", username: "u")
        XCTAssertFalse(session.requiresTraversioForProxy)

        session.advanced.proxyType = .jump
        XCTAssertTrue(session.requiresTraversioForProxy)

        session.advanced.proxyType = .http
        XCTAssertTrue(session.requiresTraversioForProxy)

        session.advanced.proxyType = .socks5
        XCTAssertTrue(session.requiresTraversioForProxy)

        session.advanced.proxyType = .none
        XCTAssertFalse(session.requiresTraversioForProxy)
    }

    func testCLIOpenPipelineAppliesRawSettingsBeforeOpenSSHMerge() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try sampleConfig.write(to: configURL, atomically: true, encoding: .utf8)

        var session = SessionConfiguration(
            host: "production",
            port: 22,
            username: "local",
            authMethod: .publicKey,
            keyPath: "~/.ssh/id_ed25519"
        )
        OpenSSHRawSettings.apply(["ProxyJump=cli-bastion"], to: &session)
        session.mergeOpenSSHConfig(configPath: configURL)

        XCTAssertEqual(session.host, "prod.internal")
        XCTAssertEqual(session.username, "deploy")
        XCTAssertEqual(session.advanced.proxyHost, "cli-bastion")
    }

    func testProxyCommandIsParsedButNotAppliedToSession() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config")
        try """
        Host via-command
            ProxyCommand ssh -W %h:%p bastion
        """.write(to: configURL, atomically: true, encoding: .utf8)

        let blocks = try OpenSSHConfigParser.load(from: configURL)
        let settings = OpenSSHConfigParser.mergedSettings(forHost: "via-command", port: nil, blocks: blocks)
        XCTAssertEqual(settings?.proxyCommand, "ssh -W %h:%p bastion")

        var session = SessionConfiguration(host: "via-command", username: "user")
        session.mergeOpenSSHConfig(configPath: configURL)
        XCTAssertEqual(session.advanced.proxyType, .none)
    }
}
