// LocalPaneCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Local filesystem pane state and navigation. AppModel owns LocalPaneCoordinator and
// refreshes home-directory listings off the main actor for large folders.
//

import Foundation
import Observation

@MainActor
@Observable
final class LocalPaneCoordinator {
    var localPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var localEntries: [LocalEntry] = []
    var selectedLocalNames = Set<String>()
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []

    var canNavigateBack: Bool { !backStack.isEmpty }
    var canNavigateForward: Bool { !forwardStack.isEmpty }

    func refreshLocal() async {
        let directory = localPath
        // Directory listing can block on large folders; keep it off @MainActor.
        let entries = await Task.detached {
            LocalFileService.list(directory: directory)
        }.value
        localEntries = entries
    }

    func navigateUp() {
        pushHistory()
        localPath.deleteLastPathComponent()
        selectedLocalNames = []
        Task { await refreshLocal() }
    }

    func openDirectory(_ name: String) {
        pushHistory()
        localPath.appendPathComponent(name, isDirectory: true)
        selectedLocalNames = []
        Task { await refreshLocal() }
    }

    func navigateBack() -> Bool {
        guard let previous = backStack.popLast() else { return false }
        forwardStack.append(localPath)
        localPath = previous
        selectedLocalNames = []
        Task { await refreshLocal() }
        return true
    }

    func navigateForward() -> Bool {
        guard let next = forwardStack.popLast() else { return false }
        backStack.append(localPath)
        localPath = next
        selectedLocalNames = []
        Task { await refreshLocal() }
        return true
    }

    func restorePath(_ url: URL) {
        backStack.removeAll()
        forwardStack.removeAll()
        localPath = url
        selectedLocalNames = []
    }

    private func pushHistory() {
        backStack.append(localPath)
        forwardStack.removeAll()
    }
}
