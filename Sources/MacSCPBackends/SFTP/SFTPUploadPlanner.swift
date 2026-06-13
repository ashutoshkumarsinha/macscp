// SFTPUploadPlanner.swift
//
// WHAT THIS FILE DOES
// -------------------
// Shared upload prep helpers (parent path, local file size). CitadelSFTPBackend and TraversioSFTPBackend
// ensure parent directories exist and size files before starting uploads.
//

import Foundation

enum SFTPUploadPlanner {
    /// Returns the remote parent directory that must exist before upload, if any.
    static func parentDirectory(of remotePath: String) -> String? {
        let parent = (remotePath as NSString).deletingLastPathComponent
        guard !parent.isEmpty, parent != "/" else { return nil }
        return parent
    }

    static func localFileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue ?? 0
    }
}
