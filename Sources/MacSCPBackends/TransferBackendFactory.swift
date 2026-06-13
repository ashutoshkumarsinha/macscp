// TransferBackendFactory.swift — Protocol routing for SFTP, SCP, FTP, and FTPS backends.

import Foundation
import MacSCPCore

public enum TransferBackendFactory {
    /// Default factory entry point; uses Citadel unless caller specifies backend kind.
    public static func make(for transferProtocol: TransferProtocol) throws -> TransferBackend {
        try make(for: transferProtocol, backend: .citadel)
    }

    public static func make(
        for transferProtocol: TransferProtocol,
        backend: SFTPBackendKind,
        serialized: Bool = false
    ) throws -> TransferBackend {
        let raw: CapableTransferBackend
        switch transferProtocol {
        case .sftp:
            switch backend {
            case .citadel:
                raw = CitadelSFTPBackend()
            case .traversio:
                raw = TraversioSFTPBackend()
            }
        case .scp:
            raw = TraversioSCPBackend()
        case .ftp:
            raw = FTPTransferBackend(useFTPS: false)
        case .ftps:
            raw = FTPTransferBackend(useFTPS: true)
        case .webdav:
            raw = WebDAVTransferBackend()
        case .s3:
            raw = ObjectStorageTransferBackend.makeS3()
        case .gcs:
            raw = ObjectStorageTransferBackend.makeGCS()
        }

        if serialized {
            return SerializingTransferBackend(wrapping: raw)
        }
        return raw
    }
}
