// FTPListingParser.swift
//
// WHAT THIS FILE DOES
// -------------------
// Parses MLSD and Unix LIST output into RemoteEntry rows. FTPTransferBackend uses this
// when listing directories over the FTP control and data channels.
//

import Foundation
import MacSCPCore

enum FTPListingParser {
    static func parse(_ text: String, basePath: String) -> [RemoteEntry] {
        let normalizedBase = SFTPPathJoin.normalizeRemote(basePath)
        var entries: [RemoteEntry] = []

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if let entry = parseMLSDLine(trimmed, basePath: normalizedBase) ?? parseUnixListLine(trimmed, basePath: normalizedBase) {
                if entry.name == "." || entry.name == ".." { continue }
                entries.append(entry)
            }
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func parseMLSDLine(_ line: String, basePath: String) -> RemoteEntry? {
        var facts: [String: String] = [:]
        var name = ""
        let parts = line.split(separator: ";", omittingEmptySubsequences: false).map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        for part in parts {
            if part.contains("=") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                if pair.count == 2 {
                    facts[pair[0].lowercased()] = pair[1]
                }
            } else if !part.isEmpty {
                name = part
            }
        }
        guard !name.isEmpty else { return nil }

        let type: EntryType
        switch facts["type"]?.lowercased() {
        case "dir", "cdir", "pdir":
            type = .directory
        case "file":
            type = .file
        default:
            type = .file
        }

        let size = facts["size"].flatMap { Int64($0) }
        let permissions = facts["perm"].flatMap { parseMLSDPermissions($0) }

        return RemoteEntry(
            name: name,
            path: SFTPPathJoin.joinRemote(basePath, name),
            type: type,
            size: type == .file ? size : nil,
            modified: nil,
            permissions: permissions
        )
    }

    private static func parseMLSDPermissions(_ perm: String) -> FilePermissions? {
        var value: UInt32 = 0
        if perm.contains("r") { value |= 0o400 }
        if perm.contains("w") { value |= 0o200 }
        if perm.contains("x") { value |= 0o100 }
        return value == 0 ? nil : FilePermissions(octal: value)
    }

    private static func parseUnixListLine(_ line: String, basePath: String) -> RemoteEntry? {
        SSHRemoteListingParser.parse(line + "\n", basePath: basePath).first
    }
}
