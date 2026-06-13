import Foundation

/// Tracks remote directories already created this session to avoid redundant SFTP mkdir round-trips.
final class CitadelDirectoryCache: @unchecked Sendable {
    private var ensured = Set<String>()
    private let lock = NSLock()

    func contains(_ path: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ensured.contains(path)
    }

    func insert(_ path: String) {
        lock.lock()
        defer { lock.unlock() }
        ensured.insert(path)
    }
}

enum CitadelUploadPlanner {
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
