// RsyncDelta.swift
//
// WHAT THIS FILE DOES
// -------------------
// rsync-style delta generation and application between a basis file and a target file.
// Used by DeltaSyncEngine for block-level sync instead of full file transfers.
//

import Foundation

public struct RsyncDeltaOperation: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case copy(sourceOffset: Int64, length: Int)
        case data(Data)
    }

    public var kind: Kind

    public init(kind: Kind) {
        self.kind = kind
    }
}

public struct RsyncDelta: Sendable, Equatable {
    public var operations: [RsyncDeltaOperation]
    public var basisSize: Int64
    public var targetSize: Int64
    public var literalBytes: Int64

    public init(
        operations: [RsyncDeltaOperation],
        basisSize: Int64,
        targetSize: Int64,
        literalBytes: Int64
    ) {
        self.operations = operations
        self.basisSize = basisSize
        self.targetSize = targetSize
        self.literalBytes = literalBytes
    }

    public var isEfficientComparedToFullTransfer: Bool {
        guard targetSize > 0 else { return true }
        return Double(literalBytes) / Double(targetSize) <= RsyncConstants.maxLiteralRatio
    }
}

public enum RsyncDeltaError: Error, CustomStringConvertible {
    case deltaInefficient(literalBytes: Int64, targetSize: Int64)
    case fileTooSmall(size: Int64)
    case invalidBasisRead(offset: Int64, length: Int)

    public var description: String {
        switch self {
        case let .deltaInefficient(literal, target):
            "Delta would transfer \(literal) of \(target) bytes; using full transfer"
        case let .fileTooSmall(size):
            "File too small for delta sync (\(size) bytes)"
        case let .invalidBasisRead(offset, length):
            "Invalid basis read at \(offset) length \(length)"
        }
    }
}

public enum RsyncDeltaGenerator {
    public static func generate(
        basisSize: Int64,
        readBasis: (Int64, Int) throws -> Data,
        targetURL: URL,
        blockSize: Int? = nil
    ) throws -> RsyncDelta {
        guard basisSize >= RsyncConstants.minimumFileSize else {
            throw RsyncDeltaError.fileTooSmall(size: basisSize)
        }

        let targetSize = try targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        guard targetSize >= RsyncConstants.minimumFileSize else {
            throw RsyncDeltaError.fileTooSmall(size: targetSize)
        }

        let block = blockSize ?? RsyncConstants.blockSize(for: max(basisSize, targetSize))
        var table = RsyncSignatureTable()
        var basisOffset: Int64 = 0
        while basisOffset < basisSize {
            let length = min(block, Int(basisSize - basisOffset))
            let chunk = try readBasis(basisOffset, length)
            guard chunk.count == length else {
                throw RsyncDeltaError.invalidBasisRead(offset: basisOffset, length: length)
            }
            table.insert(
                RsyncBlockSignature(
                    sourceOffset: basisOffset,
                    weak: RsyncWeakChecksum.checksum(block: chunk),
                    strong: RsyncStrongChecksum.md5(chunk)
                )
            )
            basisOffset += Int64(length)
        }

        return try generateFromTable(
            table: table,
            targetURL: targetURL,
            basisSize: basisSize,
            targetSize: targetSize
        )
    }

    public static func generateAsync(
        basisSize: Int64,
        readBasis: (Int64, Int) async throws -> Data,
        targetURL: URL,
        blockSize: Int? = nil
    ) async throws -> RsyncDelta {
        guard basisSize >= RsyncConstants.minimumFileSize else {
            throw RsyncDeltaError.fileTooSmall(size: basisSize)
        }

        let targetSize = try targetURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        guard targetSize >= RsyncConstants.minimumFileSize else {
            throw RsyncDeltaError.fileTooSmall(size: targetSize)
        }

        let block = blockSize ?? RsyncConstants.blockSize(for: max(basisSize, targetSize))
        var table = RsyncSignatureTable()
        var basisOffset: Int64 = 0
        while basisOffset < basisSize {
            let length = min(block, Int(basisSize - basisOffset))
            let chunk = try await readBasis(basisOffset, length)
            guard chunk.count == length else {
                throw RsyncDeltaError.invalidBasisRead(offset: basisOffset, length: length)
            }
            table.insert(
                RsyncBlockSignature(
                    sourceOffset: basisOffset,
                    weak: RsyncWeakChecksum.checksum(block: chunk),
                    strong: RsyncStrongChecksum.md5(chunk)
                )
            )
            basisOffset += Int64(length)
        }

        return try generateFromTable(
            table: table,
            targetURL: targetURL,
            basisSize: basisSize,
            targetSize: targetSize
        )
    }

    private static func generateFromTable(
        table: RsyncSignatureTable,
        targetURL: URL,
        basisSize: Int64,
        targetSize: Int64
    ) throws -> RsyncDelta {
        let block = RsyncConstants.blockSize(for: max(basisSize, targetSize))
        let reader = try RsyncFileReader(url: targetURL)
        var operations: [RsyncDeltaOperation] = []
        var literalBytes: Int64 = 0
        var targetOffset = 0
        var pendingLiteral = Data()

        func flushLiteral() {
            guard !pendingLiteral.isEmpty else { return }
            operations.append(RsyncDeltaOperation(kind: .data(pendingLiteral)))
            literalBytes += Int64(pendingLiteral.count)
            pendingLiteral.removeAll(keepingCapacity: true)
        }

        while targetOffset < reader.totalSize {
            let remaining = reader.totalSize - targetOffset
            let windowLength = min(block, remaining)
            guard windowLength > 0 else { break }

            let window = try reader.read(from: targetOffset, count: windowLength)
            if window.isEmpty { break }

            if window.count == block {
                let weak = RsyncWeakChecksum.checksum(block: window)
                let strong = RsyncStrongChecksum.md5(window)

                if let signature = table.match(weak: weak, strong: strong) {
                    var matchLength = block
                    var nextTarget = targetOffset + block
                    var nextBasis = signature.sourceOffset + Int64(block)

                    while nextTarget + block <= reader.totalSize {
                        let nextWindow = try reader.read(from: nextTarget, count: block)
                        if nextWindow.count < block { break }
                        let nextWeak = RsyncWeakChecksum.checksum(block: nextWindow)
                        let nextStrong = RsyncStrongChecksum.md5(nextWindow)
                        guard let nextSignature = table.match(weak: nextWeak, strong: nextStrong),
                              nextSignature.sourceOffset == nextBasis else {
                            break
                        }
                        matchLength += block
                        nextTarget += block
                        nextBasis += Int64(block)
                    }

                    flushLiteral()
                    operations.append(
                        RsyncDeltaOperation(
                            kind: .copy(sourceOffset: signature.sourceOffset, length: matchLength)
                        )
                    )
                    targetOffset += matchLength
                    continue
                }
            }

            if windowLength < block {
                pendingLiteral.append(window)
                targetOffset += window.count
                continue
            }

            pendingLiteral.append(window.prefix(1))
            targetOffset += 1

            if pendingLiteral.count >= block {
                flushLiteral()
            }
        }

        flushLiteral()

        let delta = RsyncDelta(
            operations: operations,
            basisSize: basisSize,
            targetSize: targetSize,
            literalBytes: literalBytes
        )
        guard delta.isEfficientComparedToFullTransfer else {
            throw RsyncDeltaError.deltaInefficient(literalBytes: literalBytes, targetSize: targetSize)
        }
        return delta
    }

    public static func generate(
        basisURL: URL,
        targetURL: URL,
        blockSize: Int? = nil
    ) throws -> RsyncDelta {
        let basisSize = try basisURL.resourceValues(forKeys: [.fileSizeKey]).fileSize.map { Int64($0) } ?? 0
        let reader = try RsyncFileReader(url: basisURL)
        return try generate(
            basisSize: basisSize,
            readBasis: { offset, length in
                try reader.read(from: Int(offset), count: length)
            },
            targetURL: targetURL,
            blockSize: blockSize
        )
    }
}

public enum RsyncDeltaApplier {
    public static func apply(
        basisURL: URL,
        delta: RsyncDelta,
        outputURL: URL
    ) throws -> Int64 {
        let basisReader = try RsyncFileReader(url: basisURL)
        return try apply(
            readBasis: { offset, length in
                try basisReader.read(from: Int(offset), count: length)
            },
            delta: delta,
            outputURL: outputURL
        )
    }

    public static func apply(
        readBasis: (Int64, Int) throws -> Data,
        delta: RsyncDelta,
        outputURL: URL
    ) throws -> Int64 {
        let parent = outputURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let handle = try FileHandle(forWritingTo: outputURL)
        defer { try? handle.close() }

        var outputOffset: Int64 = 0
        var networkBytes: Int64 = 0

        for operation in delta.operations {
            switch operation.kind {
            case let .copy(sourceOffset, length):
                let chunk = try readBasis(sourceOffset, length)
                guard chunk.count == length else {
                    throw RsyncDeltaError.invalidBasisRead(offset: sourceOffset, length: length)
                }
                try handle.seek(toOffset: UInt64(outputOffset))
                handle.write(chunk)
                outputOffset += Int64(length)
            case let .data(payload):
                try handle.seek(toOffset: UInt64(outputOffset))
                handle.write(payload)
                outputOffset += Int64(payload.count)
                networkBytes += Int64(payload.count)
            }
        }

        if outputOffset != delta.targetSize {
            try handle.truncate(atOffset: UInt64(outputOffset))
        }

        return networkBytes
    }
}

// Local file reader for delta generation/application (MacSCPCore cannot depend on MacSCPBackends).
final class RsyncFileReader: @unchecked Sendable {
    private let mapped: Data?
    private let handle: FileHandle?
    let totalSize: Int

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        totalSize = values.fileSize ?? 0
        if totalSize >= 256 * 1024 {
            mapped = try Data(contentsOf: url, options: [.mappedIfSafe])
            handle = nil
        } else {
            mapped = nil
            handle = try FileHandle(forReadingFrom: url)
        }
    }

    deinit {
        try? handle?.close()
    }

    func read(from offset: Int, count: Int) throws -> Data {
        guard offset < totalSize, count > 0 else { return Data() }
        let end = min(totalSize, offset + count)
        let sliceLength = end - offset
        if let mapped {
            return mapped.subdata(in: offset ..< end)
        }
        guard let handle else { return Data() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: sliceLength) ?? Data()
    }
}
