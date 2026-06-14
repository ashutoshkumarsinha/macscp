// MacSCPPaths.swift
//
// WHAT THIS FILE DOES
// -------------------
// Resolves config, profiles, and known-hosts paths with optional MACSCP_* env overrides.
//

import Foundation

public enum MacSCPPaths {
    public static func profilesURL(homeDirectory: URL? = nil) -> URL {
        if let override = ProcessInfo.processInfo.environment["MACSCP_PROFILES"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/MacSCP/profiles.json")
    }

    public static func knownHostsURL(homeDirectory: URL? = nil) -> URL {
        if let override = ProcessInfo.processInfo.environment["MACSCP_KNOWN_HOSTS"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
        }
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".macscp/known_hosts.json")
    }
}
