// TransferHistoryRecorder.swift — Persists completed transfers when enabled in config.

import Foundation
import MacSCPCore
import MacSCPUI

enum TransferHistoryRecorder {
    static func record(job: TransferJob, sessionName: String, homeDirectory: URL) {
        let success: Bool
        let errorMessage: String?
        switch job.state {
        case .completed, .skipped:
            success = true
            errorMessage = nil
        case .failed(let message):
            success = false
            errorMessage = message
        default:
            return
        }

        let entry = TransferHistoryEntry(
            direction: job.direction,
            localPath: job.localURL.path,
            remotePath: job.remotePath,
            bytesTransferred: job.transferredBytes,
            sessionName: sessionName,
            success: success,
            errorMessage: errorMessage
        )
        try? TransferHistoryStore.append(entry, homeDirectory: homeDirectory)
    }
}
