// RsyncChecksum.swift
//
// WHAT THIS FILE DOES
// -------------------
// rsync-style weak (rolling Adler-32) and strong (MD5) block checksums for delta sync.
//

import Crypto
import Foundation

public enum RsyncConstants {
    public static let minimumFileSize: Int64 = 65_536
    public static let maxLiteralRatio: Double = 0.90

    public static func blockSize(for fileSize: Int64) -> Int {
        guard fileSize > 0 else { return 512 }
        let estimated = Int(sqrt(Double(fileSize)))
        return max(512, min(8192, estimated))
    }
}

public enum RsyncWeakChecksum {
    public static func checksum(block: Data) -> UInt32 {
        var a: UInt32 = 1
        var b: UInt32 = 0
        for byte in block {
            a = (a + UInt32(byte)) & 0xFFFF
            b = (b + a) & 0xFFFF
        }
        return a | (b << 16)
    }

    public static func roll(previous: UInt32, remove: UInt8, add: UInt8, blockSize: Int) -> UInt32 {
        var a = previous & 0xFFFF
        var b = previous >> 16
        a = (a - UInt32(remove) + UInt32(add)) & 0xFFFF
        b = (b - UInt32(blockSize) * UInt32(remove) + a) & 0xFFFF
        return a | (b << 16)
    }
}

public enum RsyncStrongChecksum {
    public static func md5(_ block: Data) -> Data {
        Data(Insecure.MD5.hash(data: block))
    }
}

public struct RsyncBlockSignature: Sendable, Equatable {
    public var sourceOffset: Int64
    public var weak: UInt32
    public var strong: Data
}

public struct RsyncSignatureTable: Sendable {
    private var buckets: [UInt32: [RsyncBlockSignature]] = [:]

    public mutating func insert(_ signature: RsyncBlockSignature) {
        buckets[signature.weak, default: []].append(signature)
    }

    public func match(weak: UInt32, strong: Data) -> RsyncBlockSignature? {
        guard let candidates = buckets[weak] else { return nil }
        return candidates.first { $0.strong == strong }
    }
}
