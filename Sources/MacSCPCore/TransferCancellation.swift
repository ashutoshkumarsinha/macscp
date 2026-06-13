// TransferCancellation.swift
//
// WHAT THIS FILE DOES
// -------------------
// Thread-safe cancellation token checked during long-running transfers.
// TransferOptions carries TransferCancellation; backends poll isCancelled and throwIfCancelled.
//
import Foundation

public final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    public func throwIfCancelled() throws {
        if isCancelled {
            throw BackendError.cancelled
        }
        try Task.checkCancellation()
    }
}

public enum TransferPathPlanner {
    public static func renamedLocalURL(_ url: URL, attempt: Int) -> URL {
        let directory = url.deletingLastPathComponent()
        let baseName = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let suffix = " (\(attempt))"
        let newName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
        return directory.appendingPathComponent(newName)
    }

    public static func renamedRemotePath(_ path: String, attempt: Int) -> String {
        let nsPath = path as NSString
        let directory = nsPath.deletingLastPathComponent
        let fileName = nsPath.lastPathComponent
        let stem = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        let suffix = " (\(attempt))"
        let newName = ext.isEmpty ? "\(stem)\(suffix)" : "\(stem)\(suffix).\(ext)"
        if directory.isEmpty || directory == "/" {
            return "/\(newName)"
        }
        return "\(directory)/\(newName)"
    }

    public static func nextAvailableLocalURL(
        preferred: URL,
        exists: (URL) -> Bool
    ) -> URL {
        guard exists(preferred) else { return preferred }
        for attempt in 1 ... 999 {
            let candidate = renamedLocalURL(preferred, attempt: attempt)
            if !exists(candidate) { return candidate }
        }
        return preferred
    }

    public static func nextAvailableRemotePath(
        preferred: String,
        exists: (String) -> Bool
    ) -> String {
        guard exists(preferred) else { return preferred }
        for attempt in 1 ... 999 {
            let candidate = renamedRemotePath(preferred, attempt: attempt)
            if !exists(candidate) { return candidate }
        }
        return preferred
    }
}
