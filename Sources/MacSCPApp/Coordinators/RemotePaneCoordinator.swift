// RemotePaneCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Remote SFTP listing and path navigation. AppModel refreshes remoteEntries via the
// connected TransferBackend when the user browses the remote pane.
//

import Foundation
import MacSCPCore
import Observation

@MainActor
@Observable
final class RemotePaneCoordinator {
    var remoteEntries: [RemoteEntry] = []
    var selectedRemoteNames = Set<String>()
    private var backStack: [String] = []
    private var forwardStack: [String] = []

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

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
        pushHistory(current: remotePath)
        selectedRemoteNames = []
        var path = (remotePath as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        return path
    }

    func openDirectory(_ name: String, from remotePath: String) -> String {
        pushHistory(current: remotePath)
        selectedRemoteNames = []
        if remotePath.hasSuffix("/") {
            return remotePath + name
        }
        return remotePath + "/" + name
    }

    func navigateBack(from remotePath: String) -> String? {
        guard let previous = backStack.popLast() else { return nil }
        forwardStack.append(remotePath)
        selectedRemoteNames = []
        return previous
    }

    func navigateForward(from remotePath: String) -> String? {
        guard let next = forwardStack.popLast() else { return nil }
        backStack.append(remotePath)
        selectedRemoteNames = []
        return next
    }

    func restorePath(_ path: String) {
        backStack.removeAll()
        forwardStack.removeAll()
        selectedRemoteNames = []
    }

    private func pushHistory(current: String) {
        backStack.append(current)
        forwardStack.removeAll()
    }
}
