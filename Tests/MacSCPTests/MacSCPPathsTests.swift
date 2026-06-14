// MacSCPPathsTests.swift
//
// WHAT THIS FILE TESTS
// --------------------
// MACSCP_PROFILES and MACSCP_KNOWN_HOSTS environment overrides.
//

import MacSCPCore
import XCTest

final class MacSCPPathsTests: XCTestCase {
    private var savedProfiles: String?
    private var savedKnownHosts: String?

    override func setUp() {
        savedProfiles = ProcessInfo.processInfo.environment["MACSCP_PROFILES"]
        savedKnownHosts = ProcessInfo.processInfo.environment["MACSCP_KNOWN_HOSTS"]
    }

    override func tearDown() {
        setenv("MACSCP_PROFILES", savedProfiles ?? "", 1)
        setenv("MACSCP_KNOWN_HOSTS", savedKnownHosts ?? "", 1)
        if savedProfiles == nil { unsetenv("MACSCP_PROFILES") }
        if savedKnownHosts == nil { unsetenv("MACSCP_KNOWN_HOSTS") }
    }

    func testProfilesURLEnvOverride() {
        setenv("MACSCP_PROFILES", "/tmp/custom-profiles.json", 1)
        let url = MacSCPPaths.profilesURL(homeDirectory: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(url.path, "/tmp/custom-profiles.json")
    }

    func testKnownHostsURLEnvOverride() {
        setenv("MACSCP_KNOWN_HOSTS", "/tmp/custom-known.json", 1)
        let url = MacSCPPaths.knownHostsURL(homeDirectory: URL(fileURLWithPath: "/Users/test"))
        XCTAssertEqual(url.path, "/tmp/custom-known.json")
    }
}
