// FilePaneListPolicy.swift
//
// WHAT THIS FILE DOES
// -------------------
// Threshold for switching file panes from List to LazyVStack virtualization.
//

import Foundation

public enum FilePaneListPolicy {
    public static let virtualizedEntryThreshold = 1000

    public static func usesVirtualizedList(entryCount: Int) -> Bool {
        entryCount >= virtualizedEntryThreshold
    }
}
