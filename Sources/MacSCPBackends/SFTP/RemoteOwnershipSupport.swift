// RemoteOwnershipSupport.swift
//
// WHAT THIS FILE DOES
// -------------------
// Shared helpers for remote chown: shell command formatting and numeric uid/gid parsing.
//

import Foundation
import MacSCPCore

enum RemoteOwnershipSupport {
    static func parseUID(_ value: String) -> UInt32? {
        guard !value.isEmpty else { return nil }
        return UInt32(value)
    }

    static func chownCommand(user: String?, group: String?, path: String) -> String {
        let owner: String
        switch (user, group) {
        case let (user?, group?):
            owner = "\(user):\(group)"
        case let (user?, nil):
            owner = user
        case let (nil, group?):
            owner = ":\(group)"
        case (nil, nil):
            owner = ""
        }
        return "chown \(shellQuote(owner)) \(shellQuote(path))"
    }

    private static func shellQuote(_ value: String) -> String {
        if value.isEmpty { return "''" }
        if value.allSatisfy({ $0.isLetter || $0.isNumber || "-_./:@+".contains($0) }) {
            return value
        }
        return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}
