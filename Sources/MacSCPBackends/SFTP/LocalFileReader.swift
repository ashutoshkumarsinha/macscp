// LocalFileReader.swift
//
// WHAT THIS FILE DOES
// -------------------
// Reads local file bytes sequentially for Citadel uploads. Large files use memory-
// mapping (mmap) so the kernel maps file pages directly instead of copying into RAM.
//
// WHO USES IT
// -----------
// CitadelPipelinedWriter and CitadelSFTPBackend sequential upload path.
//
// BEGINNER TIP
// ------------
// Files under 256 KB use a normal FileHandle — mmap overhead is not worth it for
// tiny files. F_RDADVISE tells macOS we read sequentially (better read-ahead).

import Foundation

/// Reads a local file from start to end, one chunk at a time.
final class LocalFileSequentialReader: @unchecked Sendable {
    private let mapped: Data?
    private let handle: FileHandle?
    private let length: Int

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        length = values.fileSize ?? 0
        if length >= 256 * 1024 {
            // mmap: Data points at file on disk; subdata is cheap.
            mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
            handle = nil
        } else {
            mapped = nil
            let fileHandle = try FileHandle(forReadingFrom: url)
            Self.applySequentialReadHint(to: fileHandle)
            handle = fileHandle
        }
    }

    deinit {
        try? handle?.close()
    }

    var totalSize: Int { length }

    func read(from offset: Int, count: Int) throws -> Data {
        guard offset < length, count > 0 else { return Data() }
        let end = min(length, offset + count)
        let sliceLength = end - offset

        if let mapped {
            return mapped.subdata(in: offset ..< end)
        }
        guard let handle else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: sliceLength) ?? Data()
    }

    private static func applySequentialReadHint(to handle: FileHandle) {
        #if os(macOS)
        _ = fcntl(handle.fileDescriptor, F_RDADVISE, 1)
        #endif
    }
}

#if os(macOS)
private let F_RDADVISE: Int32 = 42
#endif
