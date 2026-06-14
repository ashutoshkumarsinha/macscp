// RemotePaneCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Remote SFTP listing and path navigation. AppModel refreshes remoteEntries via the
// connected TransferBackend when the user browses the remote pane. Shows cached entries
// immediately while a background refresh runs (stale-while-revalidate).
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
    private var refreshTask: Task<Void, Never>?
    private var lastListedPath: String?

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    var onStatusMessage: ((String) -> Void)?

    func refreshRemote(backend: TransferBackend?, at remotePath: String, force: Bool = false) async {
        guard let backend else { return }

        if !force, lastListedPath == remotePath, !remoteEntries.isEmpty {
            refreshTask?.cancel()
            refreshTask = Task { [weak self] in
                await self?.fetchListing(backend: backend, at: remotePath, staleWhileRevalidate: true)
            }
            return
        }

        refreshTask?.cancel()
        await fetchListing(backend: backend, at: remotePath, staleWhileRevalidate: false)
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
        lastListedPath = nil
    }

    private func pushHistory(current: String) {
        backStack.append(current)
        forwardStack.removeAll()
    }

    private func fetchListing(backend: TransferBackend, at remotePath: String, staleWhileRevalidate: Bool) async {
        do {
            let entries = try await backend.listDirectory(at: remotePath)
            guard !Task.isCancelled else { return }
            remoteEntries = entries
            lastListedPath = remotePath
            if staleWhileRevalidate {
                onStatusMessage?("Remote listing refreshed")
            } else {
                onStatusMessage?("Remote listing updated")
            }
        } catch {
            guard !Task.isCancelled else { return }
            if !staleWhileRevalidate || remoteEntries.isEmpty {
                onStatusMessage?("Remote list failed: \(error.localizedDescription)")
            }
            MacSCPLogger.shared.error(error, context: "Remote list failed at \(remotePath)", category: .backend)
        }
    }
}
