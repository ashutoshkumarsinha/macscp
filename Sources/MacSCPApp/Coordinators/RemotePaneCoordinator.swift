// RemotePaneCoordinator.swift — Remote SFTP listing and path navigation.

import Foundation
import MacSCPCore
import Observation

@MainActor
@Observable
final class RemotePaneCoordinator {
    var remoteEntries: [RemoteEntry] = []
    var selectedRemoteNames = Set<String>()

    var onStatusMessage: ((String) -> Void)?

    func refreshRemote(backend: TransferBackend?, at remotePath: String) async {
        guard let backend else { return }
        do {
            remoteEntries = try await backend.listDirectory(at: remotePath)
            onStatusMessage?("Remote listing updated")
        } catch {
            onStatusMessage?("Remote list failed: \(error.localizedDescription)")
            MacSCPLogger.shared.error(error, context: "Remote list failed at \(remotePath)", category: .backend)
        }
    }

    func navigateUp(from remotePath: String) -> String {
        selectedRemoteNames = []
        var path = (remotePath as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        return path
    }

    func openDirectory(_ name: String, from remotePath: String) -> String {
        selectedRemoteNames = []
        if remotePath.hasSuffix("/") {
            return remotePath + name
        }
        return remotePath + "/" + name
    }
}
