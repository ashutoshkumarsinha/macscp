// DeltaCapableTransferBackend.swift
//
// WHAT THIS FILE DOES
// -------------------
// Optional protocol for backends that support ranged SFTP read/write used by delta sync.
//

import Foundation

public protocol DeltaCapableTransferBackend: CapableTransferBackend {
    func readRemoteRange(remotePath: String, offset: Int64, length: Int) async throws -> Data
    func writeRemoteRange(remotePath: String, offset: Int64, data: Data, create: Bool) async throws
}

public extension TransferBackend {
    var asDeltaCapable: DeltaCapableTransferBackend? {
        self as? DeltaCapableTransferBackend
    }
}
