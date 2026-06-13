// LocalFileReader.swift — mmap-backed sequential reads with read-ahead hints (Apple Silicon friendly).

import Foundation

/// Sequential local file reader; uses mmap for files ≥ 256 KB.
final class LocalFileSequentialReader: @unchecked Sendable {
    private let mapped: Data?
    private let handle: FileHandle?
    private let length: Int

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        length = values.fileSize ?? 0
        if length >= 256 * 1024 {
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
