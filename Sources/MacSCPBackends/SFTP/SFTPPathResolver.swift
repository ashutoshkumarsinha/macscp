// SFTPPathResolver.swift — Shared remote path normalization (Citadel + Traversio).

import Foundation

/// Normalizes and resolves SFTP paths against a session working directory.
struct SFTPPathResolver: Sendable {
    private(set) var workingDirectory: String

    init(workingDirectory: String = "/") {
        self.workingDirectory = Self.normalizeRemotePath(workingDirectory)
    }

    mutating func changeDirectory(to path: String) {
        workingDirectory = Self.normalizeRemotePath(path)
    }

    func resolve(_ path: String) -> String {
        if path.hasPrefix("/") {
            return Self.normalizeRemotePath(path)
        }
        return Self.normalizeRemotePath(Self.joinRemote(workingDirectory, path))
    }

    static func normalizeRemotePath(_ path: String) -> String {
        var components: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if part != "." {
                components.append(String(part))
            }
        }
        return "/" + components.joined(separator: "/")
    }

    static func joinRemote(_ base: String, _ name: String) -> String {
        if base == "/" { return "/\(name)" }
        if base.hasSuffix("/") { return base + name }
        return base + "/" + name
    }
}
