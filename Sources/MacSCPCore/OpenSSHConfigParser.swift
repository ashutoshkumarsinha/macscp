// OpenSSHConfigParser.swift
//
// WHAT THIS FILE DOES
// -------------------
// Parses ~/.ssh/config Host blocks and merges settings for a target host alias.
// SessionConfiguration.mergeOpenSSHConfig and TraversioSSHConfigurationBuilder use
// mergedSettings and resolveJumpChain for ProxyJump hops and identity files.
//
import Foundation

/// Parsed settings for one logical SSH target after merging matching `Host` blocks.
public struct OpenSSHHostSettings: Equatable, Sendable {
    public var hostName: String?
    public var port: Int?
    public var user: String?
    public var identityFile: String?
    public var proxyJump: [String]
    public var proxyCommand: String?

    public init(
        hostName: String? = nil,
        port: Int? = nil,
        user: String? = nil,
        identityFile: String? = nil,
        proxyJump: [String] = [],
        proxyCommand: String? = nil
    ) {
        self.hostName = hostName
        self.port = port
        self.user = user
        self.identityFile = identityFile
        self.proxyJump = proxyJump
        self.proxyCommand = proxyCommand
    }
}

/// One resolved hop in a ProxyJump chain.
public struct OpenSSHJumpEndpoint: Equatable, Sendable {
    public var host: String
    public var port: Int
    public var username: String?

    public init(host: String, port: Int = 22, username: String? = nil) {
        self.host = host
        self.port = port
        self.username = username
    }
}

/// A single `Host` section from an OpenSSH config file.
public struct OpenSSHHostBlock: Equatable, Sendable {
    public let patterns: [String]
    public let settings: [String: String]

    public init(patterns: [String], settings: [String: String]) {
        self.patterns = patterns
        self.settings = settings
    }
}

public enum OpenSSHConfigParser {
    public static func defaultConfigURL(homeDirectory: URL? = nil) -> URL {
        let home = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".ssh/config")
    }

    public static func load(from url: URL) throws -> [OpenSSHHostBlock] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return parse(contents: contents)
    }

    public static func parse(contents: String) -> [OpenSSHHostBlock] {
        var blocks: [OpenSSHHostBlock] = []
        var currentPatterns: [String] = []
        var currentSettings: [String: String] = [:]

        func flushBlock() {
            guard !currentPatterns.isEmpty else { return }
            blocks.append(OpenSSHHostBlock(patterns: currentPatterns, settings: currentSettings))
            currentPatterns = []
            currentSettings = [:]
        }

        for rawLine in contents.split(whereSeparator: \.isNewline) {
            var line = String(rawLine).trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            if let commentIndex = line.firstIndex(of: "#") {
                let before = line[..<commentIndex]
                if before.contains("\"") == false {
                    line = String(before).trimmingCharacters(in: .whitespaces)
                }
            }
            if line.isEmpty { continue }

            let parts = splitDirective(line)
            guard parts.count >= 2 else { continue }

            let key = parts[0].lowercased()
            let value = parts[1...].joined(separator: " ").trimmingCharacters(in: .whitespaces)

            if key == "host" {
                flushBlock()
                currentPatterns = value.split(whereSeparator: \.isWhitespace).map(String.init)
            } else if !currentPatterns.isEmpty {
                currentSettings[key] = unquote(value)
            }
        }

        flushBlock()
        return blocks
    }

    public static func mergedSettings(
        forHost host: String,
        port: Int?,
        blocks: [OpenSSHHostBlock]
    ) -> OpenSSHHostSettings? {
        var merged = OpenSSHHostSettings()
        var matched = false

        for block in blocks where hostMatches(host, port: port, patterns: block.patterns) {
            matched = true
            // OpenSSH uses first matching value per key across stanzas (see ssh_config(5)).
            apply(block.settings, to: &merged)
        }

        return matched ? merged : nil
    }

    public static func mergedSettings(
        forHost host: String,
        port: Int? = nil,
        configPath: URL? = nil,
        homeDirectory: URL? = nil
    ) -> OpenSSHHostSettings? {
        let path = configPath ?? defaultConfigURL(homeDirectory: homeDirectory)
        guard let blocks = try? load(from: path) else { return nil }
        return mergedSettings(forHost: host, port: port, blocks: blocks)
    }

    public static func resolveJumpChain(
        tokens: [String],
        defaultUsername: String,
        blocks: [OpenSSHHostBlock]
    ) -> [OpenSSHJumpEndpoint] {
        tokens.flatMap { token in
            let endpoints = parseJumpToken(token)
            return endpoints.map { endpoint in
                var resolved = endpoint
                if let settings = mergedSettings(forHost: endpoint.host, port: endpoint.port, blocks: blocks) {
                    if let hostName = settings.hostName, !hostName.isEmpty {
                        resolved.host = hostName
                    }
                    if let port = settings.port {
                        resolved.port = port
                    }
                    if resolved.username == nil, let user = settings.user, !user.isEmpty {
                        resolved.username = user
                    } else if resolved.username == nil {
                        resolved.username = defaultUsername
                    }
                } else if resolved.username == nil {
                    resolved.username = defaultUsername
                }
                return resolved
            }
        }
    }

    public static func resolveJumpChain(
        tokens: [String],
        defaultUsername: String,
        configPath: URL? = nil,
        homeDirectory: URL? = nil
    ) -> [OpenSSHJumpEndpoint] {
        let path = configPath ?? defaultConfigURL(homeDirectory: homeDirectory)
        let blocks = (try? load(from: path)) ?? []
        return resolveJumpChain(tokens: tokens, defaultUsername: defaultUsername, blocks: blocks)
    }

    // MARK: - Private

    private static func splitDirective(_ line: String) -> [String] {
        if let equalsIndex = line.firstIndex(of: "=") {
            let key = line[..<equalsIndex].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: equalsIndex)...].trimmingCharacters(in: .whitespaces)
            return [key, value]
        }

        let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let key = parts.first else { return [] }
        return [key, parts.dropFirst().joined(separator: " ")]
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2 else { return value }
        if (value.hasPrefix("\"") && value.hasSuffix("\""))
            || (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func apply(_ settings: [String: String], to merged: inout OpenSSHHostSettings) {
        if merged.hostName == nil, let hostName = settings["hostname"], !hostName.isEmpty {
            merged.hostName = hostName
        }
        if merged.port == nil, let portString = settings["port"], let port = Int(portString) {
            merged.port = port
        }
        if merged.user == nil, let user = settings["user"], !user.isEmpty {
            merged.user = user
        }
        if merged.identityFile == nil, let identity = settings["identityfile"], !identity.isEmpty {
            merged.identityFile = identity
        }
        if merged.proxyJump.isEmpty, let proxyJump = settings["proxyjump"], !proxyJump.isEmpty {
            merged.proxyJump = proxyJump
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        if merged.proxyCommand == nil, let proxyCommand = settings["proxycommand"], !proxyCommand.isEmpty {
            merged.proxyCommand = proxyCommand
        }
    }

    // MARK: - Host pattern matching

    private static func hostMatches(_ host: String, port: Int?, patterns: [String]) -> Bool {
        var matchedPositive = false
        for pattern in patterns {
            if pattern.hasPrefix("!") {
                // Negated pattern: if it matches, the whole Host line is rejected.
                let negated = String(pattern.dropFirst())
                if globMatch(negated, host) {
                    return false
                }
            } else if globMatch(pattern, host) {
                matchedPositive = true
            }
        }
        return matchedPositive
    }

    private static func globMatch(_ pattern: String, _ value: String) -> Bool {
        if pattern == "*" { return true }
        if pattern == value { return true }

        var patternIndex = pattern.startIndex
        var valueIndex = value.startIndex
        var starPattern: String.Index?
        var starValue: String.Index?

        while valueIndex < value.endIndex {
            if patternIndex < pattern.endIndex {
                let patternChar = pattern[patternIndex]
                if patternChar == "*" {
                    starPattern = pattern.index(after: patternIndex)
                    starValue = valueIndex
                    patternIndex = pattern.index(after: patternIndex)
                    continue
                }
                if patternChar == "?" || patternChar == value[valueIndex] {
                    patternIndex = pattern.index(after: patternIndex)
                    valueIndex = value.index(after: valueIndex)
                    continue
                }
            }

            if let starPattern {
                if let currentStarValue = starValue {
                    patternIndex = starPattern
                    valueIndex = value.index(after: currentStarValue)
                    starValue = valueIndex
                    continue
                }
            }
            return false
        }

        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            patternIndex = pattern.index(after: patternIndex)
        }
        return patternIndex == pattern.endIndex
    }

    private static func parseJumpToken(_ token: String) -> [OpenSSHJumpEndpoint] {
        // Accepts OpenSSH forms: [user@]host, host:port, user@host:port, user@[ipv6]:port
        let trimmed = token.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var username: String?
        var hostPort = trimmed

        if let atIndex = trimmed.lastIndex(of: "@") {
            username = String(trimmed[..<atIndex])
            hostPort = String(trimmed[trimmed.index(after: atIndex)...])
        }

        var host = hostPort
        var port = 22
        if hostPort.hasPrefix("[") {
            if let closing = hostPort.firstIndex(of: "]") {
                host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<closing])
                let remainder = hostPort[hostPort.index(after: closing)...]
                if remainder.hasPrefix(":"), let parsed = Int(remainder.dropFirst()) {
                    port = parsed
                }
            }
        } else if let colon = hostPort.lastIndex(of: ":"), colon != hostPort.startIndex {
            host = String(hostPort[..<colon])
            if let parsed = Int(hostPort[hostPort.index(after: colon)...]) {
                port = parsed
            }
        }

        return [OpenSSHJumpEndpoint(host: host, port: port, username: username)]
    }
}
