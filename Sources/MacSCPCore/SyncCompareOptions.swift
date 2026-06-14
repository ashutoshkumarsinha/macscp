// SyncCompareOptions.swift
//
// WHAT THIS FILE DOES
// -------------------
// Options for DirectorySyncEngine.compare: file masks and comparison criteria.
// CLI sync and GUI SyncCoordinator pass these when comparing trees.
//
import Foundation

public enum SyncCompareCriteria: String, Sendable, Equatable {
    case time
    case size
    case checksum
}

/// WinSCP-style file mask: `include1; include2|exclude1; exclude2` (glob per segment).
public struct SyncFileMask: Sendable, Equatable {
    public var includes: [String]
    public var excludes: [String]

    public init(includes: [String] = ["*"], excludes: [String] = []) {
        self.includes = includes.isEmpty ? ["*"] : includes
        self.excludes = excludes
    }

    public static func parse(_ raw: String?) -> SyncFileMask {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else {
            return SyncFileMask()
        }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        let includes = splitMaskSegments(parts.first ?? "*")
        let excludes = parts.count > 1 ? splitMaskSegments(parts[1]) : []
        return SyncFileMask(includes: includes, excludes: excludes)
    }

    public func matches(relativePath: String) -> Bool {
        let fileName = (relativePath as NSString).lastPathComponent
        let included = includes.contains { globMatch($0, fileName) || globMatch($0, relativePath) }
        guard included else { return false }
        return !excludes.contains { globMatch($0, fileName) || globMatch($0, relativePath) }
    }

    private static func splitMaskSegments(_ segment: String) -> [String] {
        segment.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func globMatch(_ pattern: String, _ value: String) -> Bool {
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

            if let starPattern, let currentStarValue = starValue {
                patternIndex = starPattern
                valueIndex = value.index(after: currentStarValue)
                starValue = valueIndex
                continue
            }
            return false
        }

        while patternIndex < pattern.endIndex, pattern[patternIndex] == "*" {
            patternIndex = pattern.index(after: patternIndex)
        }
        return patternIndex == pattern.endIndex
    }
}

public struct SyncCompareOptions: Sendable, Equatable {
    public var criteria: SyncCompareCriteria
    public var fileMask: SyncFileMask

    public init(criteria: SyncCompareCriteria = .time, fileMask: SyncFileMask = SyncFileMask()) {
        self.criteria = criteria
        self.fileMask = fileMask
    }
}
