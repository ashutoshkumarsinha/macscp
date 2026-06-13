import Citadel
import Foundation
import MacSCPCore

enum TransferDestinationResolver {
    static func remotePathExists(sftp: Citadel.SFTPClient, path: String) async -> Bool {
        (try? await sftp.getAttributes(at: path)) != nil
    }

    static func resolveRemoteUploadPath(
        path: String,
        policy: OverwritePolicy,
        remoteExists: (String) async -> Bool
    ) async -> String? {
        let exists = await remoteExists(path)
        guard exists else { return path }

        switch policy {
        case .overwrite, .prompt:
            return path
        case .skip:
            return nil
        case .rename:
            for attempt in 1 ... 999 {
                let candidate = TransferPathPlanner.renamedRemotePath(path, attempt: attempt)
                if await !remoteExists(candidate) {
                    return candidate
                }
            }
            return path
        }
    }

    static func resolveLocalDownloadURL(
        _ url: URL,
        policy: OverwritePolicy
    ) throws -> URL? {
        let exists = FileManager.default.fileExists(atPath: url.path)
        guard exists else { return url }

        switch policy {
        case .overwrite, .prompt:
            return url
        case .skip:
            return nil
        case .rename:
            return TransferPathPlanner.nextAvailableLocalURL(preferred: url) { candidate in
                FileManager.default.fileExists(atPath: candidate.path)
            }
        }
    }
}

enum TransferContinuationFactory {
    static func shouldContinue(for cancellation: TransferCancellation?) -> (@Sendable () async -> Bool)? {
        guard let cancellation else { return nil }
        return {
            !cancellation.isCancelled && !Task.isCancelled
        }
    }
}
