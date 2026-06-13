// SessionConfiguration+OpenSSH.swift
//
// WHAT THIS FILE DOES
// -------------------
// Applies raw OpenSSH-style key=value overrides and merges ~/.ssh/config into SessionConfiguration.
// CLI --rawsettings and mergeOpenSSHConfig call OpenSSHRawSettings.apply and the extension.
//
import Foundation

public enum OpenSSHRawSettings {
    public static func apply(_ rawSettings: [String], to configuration: inout SessionConfiguration) {
        for entry in rawSettings {
            let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch key {
            case "proxyjump":
                configuration.advanced.proxyType = .jump
                configuration.advanced.proxyHost = value
            case "hostname":
                configuration.host = value
            case "port":
                if let port = Int(value) {
                    configuration.port = port
                }
            case "user":
                configuration.username = value
            default:
                break
            }
        }
    }
}

public extension SessionConfiguration {
    /// Fills host/port/user/key/proxy from `~/.ssh/config` when the profile host matches a Host alias.
    /// Profile proxy settings win over config; config never replaces an explicit profile key path.
    mutating func mergeOpenSSHConfig(
        configPath: URL? = nil,
        homeDirectory: URL? = nil
    ) {
        let path = configPath ?? OpenSSHConfigParser.defaultConfigURL(homeDirectory: homeDirectory)
        guard let settings = OpenSSHConfigParser.mergedSettings(
            forHost: host,
            port: port,
            configPath: path,
            homeDirectory: homeDirectory
        ) else {
            return
        }

        if let hostName = settings.hostName, !hostName.isEmpty {
            host = hostName
        }
        if let port = settings.port {
            self.port = port
        }
        if let user = settings.user, !user.isEmpty {
            username = user
        }
        if keyPath == nil, let identityFile = settings.identityFile, !identityFile.isEmpty {
            keyPath = identityFile
        }
        if advanced.proxyType == .none, !settings.proxyJump.isEmpty {
            advanced.proxyType = .jump
            advanced.proxyHost = settings.proxyJump.joined(separator: ",")
        }
    }

    var requiresTraversioForProxy: Bool {
        switch advanced.proxyType {
        case .none:
            false
        case .http, .socks5, .jump:
            true
        }
    }
}
