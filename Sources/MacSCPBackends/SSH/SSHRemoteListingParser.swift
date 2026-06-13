// SSHRemoteListingParser.swift
//
// WHAT THIS FILE DOES
// -------------------
// Parses `ls -la` output into RemoteEntry rows for SCP remote directory listings.
// TraversioSCPBackend runs remote ls and feeds output through this parser.
//

import Foundation
import MacSCPCore

enum SSHRemoteListingParser {
    static func parse(_ output: String, basePath: String) -> [RemoteEntry] {
        let normalizedBase = SFTPPathJoin.normalizeRemote(basePath)
        var entries: [RemoteEntry] = []

        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("total ") { continue }

            guard let entry = parseLine(String(trimmed), basePath: normalizedBase) else { continue }
            if entry.name == "." || entry.name == ".." { continue }
            entries.append(entry)
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parseLine(_ line: String, basePath: String) -> RemoteEntry? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 9 else { return nil }

        let permissions = parts[0]
        guard permissions.first == "d" || permissions.first == "-" || permissions.first == "l" else {
            return nil
        }

        let size = Int64(parts[4])
        let name = parts.dropFirst(8).joined(separator: " ")
        if name.isEmpty { return nil }

        let type: EntryType
        if permissions.first == "d" {
            type = .directory
        } else if permissions.first == "l" {
            type = .symlink
        } else {
            type = .file
        }

        let path = SFTPPathJoin.joinRemote(basePath, name)
        let octal = parsePermissions(permissions)

        return RemoteEntry(
            name: name,
            path: path,
            type: type,
            size: type == .file ? size : nil,
            modified: nil,
            permissions: octal.map { FilePermissions(octal: $0) }
        )
    }

    private static func parsePermissions(_ text: String) -> UInt32? {
        guard text.count >= 10 else { return nil }
        var value: UInt32 = 0
        let mapping: [Character: (UInt32, UInt32, UInt32)] = [
            "r": (0o400, 0o040, 0o004),
            "w": (0o200, 0o020, 0o002),
            "x": (0o100, 0o010, 0o001),
        ]

        let chars = Array(text)
        for index in 1 ..< 10 {
            let char = chars[index]
            if char == "-" { continue }
            let tripleIndex = (index - 1) / 3
            guard let bits = mapping[char] else { continue }
            switch tripleIndex {
            case 0: value |= bits.0
            case 1: value |= bits.1
            default: value |= bits.2
            }
        }
        return value
    }
}
