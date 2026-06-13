import Foundation

public enum OverwritePolicy: Sendable {
    case prompt
    case overwrite
    case skip
    case rename
}

public enum TransferMode: Sendable {
    case binary
    case ascii
}

public enum ChecksumAlgorithm: Sendable {
    case md5
    case sha256
}

public struct TransferProgress: Sendable {
    public var transferID: UUID
    public var direction: TransferDirection
    public var path: String
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    public var bytesPerSecond: Double?

    public init(
        transferID: UUID,
        direction: TransferDirection,
        path: String,
        totalBytes: Int64? = nil,
        transferredBytes: Int64,
        bytesPerSecond: Double? = nil
    ) {
        self.transferID = transferID
        self.direction = direction
        self.path = path
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
    }
}

public enum TransferDirection: Sendable {
    case upload
    case download
}

public typealias ProgressHandler = @Sendable (TransferProgress) -> Void

public struct TransferOptions: Sendable {
    public var resume: Bool
    public var overwrite: OverwritePolicy
    public var transferMode: TransferMode
    public var checksum: ChecksumAlgorithm?
    public var progress: ProgressHandler?
    public var chunkSize: Int
    /// Concurrent uploads when using `uploadBatch` (small files benefit most).
    public var maxConcurrentUploads: Int
    /// Files at or below this size use a single-write fast path.
    public var smallFileThreshold: Int
    /// In-flight SFTP WRITE requests per open file handle (Citadel pipelined upload).
    public var maxConcurrentWrites: Int
    /// In-flight SFTP READ requests per open file handle (Traversio pipelined download).
    public var maxConcurrentReads: Int
    /// When set, backends poll this during transfers for mid-flight cancel.
    public var cancellation: TransferCancellation?
    /// When false, skip checksum computation even if `checksum` is set (faster transfers).
    public var verifyChecksum: Bool

    public init(
        resume: Bool = false,
        overwrite: OverwritePolicy = .overwrite,
        transferMode: TransferMode = .binary,
        checksum: ChecksumAlgorithm? = nil,
        progress: ProgressHandler? = nil,
        chunkSize: Int = 1024 * 1024,
        maxConcurrentUploads: Int = 12,
        smallFileThreshold: Int = 256 * 1024,
        maxConcurrentWrites: Int = 16,
        maxConcurrentReads: Int = 8,
        cancellation: TransferCancellation? = nil,
        verifyChecksum: Bool = false
    ) {
        self.resume = resume
        self.overwrite = overwrite
        self.transferMode = transferMode
        self.checksum = checksum
        self.progress = progress
        self.chunkSize = chunkSize
        self.maxConcurrentUploads = maxConcurrentUploads
        self.smallFileThreshold = smallFileThreshold
        self.maxConcurrentWrites = maxConcurrentWrites
        self.maxConcurrentReads = maxConcurrentReads
        self.cancellation = cancellation
        self.verifyChecksum = verifyChecksum
    }

    public func throwIfCancelled() throws {
        try cancellation?.throwIfCancelled()
    }
}

public struct TransferResult: Sendable, Equatable {
    public var bytesTransferred: Int64
    public var checksum: String?
    public var resumedFrom: Int64?

    public init(bytesTransferred: Int64, checksum: String? = nil, resumedFrom: Int64? = nil) {
        self.bytesTransferred = bytesTransferred
        self.checksum = checksum
        self.resumedFrom = resumedFrom
    }
}
