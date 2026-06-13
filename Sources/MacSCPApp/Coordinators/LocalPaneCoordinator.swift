// LocalPaneCoordinator.swift — Local filesystem pane state and navigation.

import Foundation
import Observation

@MainActor
@Observable
final class LocalPaneCoordinator {
    var localPath: URL = FileManager.default.homeDirectoryForCurrentUser
    var localEntries: [LocalEntry] = []
    var selectedLocalNames = Set<String>()

    func refreshLocal() async {
        let directory = localPath
        // Directory listing can block on large folders; keep it off @MainActor.
        let entries = await Task.detached {
            LocalFileService.list(directory: directory)
        }.value
        localEntries = entries
    }

    func navigateUp() {
        localPath.deleteLastPathComponent()
        selectedLocalNames = []
        Task { await refreshLocal() }
    }

    func openDirectory(_ name: String) {
        localPath.appendPathComponent(name, isDirectory: true)
        selectedLocalNames = []
        Task { await refreshLocal() }
    }
}
