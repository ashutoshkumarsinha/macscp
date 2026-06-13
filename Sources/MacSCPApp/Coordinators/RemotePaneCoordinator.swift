// RemotePaneCoordinator.swift — Remote SFTP listing and path navigation.
//
// remotePath itself is owned by SessionCoordinator; this type mutates it via inout
// when navigating up or into a subdirectory.

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

    func navigateUp(remotePath: inout String) async -> String {
        remotePath = (remotePath as NSString).deletingLastPathComponent
        if remotePath.isEmpty { remotePath = "/" }
        selectedRemoteNames = []
        return remotePath
    }

    func openDirectory(_ name: String, remotePath: inout String) -> String {
        if remotePath.hasSuffix("/") {
            remotePath += name
        } else {
            remotePath += "/" + name
        }
        selectedRemoteNames = []
        return remotePath
    }
}
