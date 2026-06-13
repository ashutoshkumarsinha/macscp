// FileOperationsCoordinator.swift
//
// WHAT THIS FILE DOES
// -------------------
// Rename, mkdir, delete, and chmod on local and remote panes. AppModel and CommanderView
// call these helpers when the user edits files or directories in either pane.
//

import Foundation
import MacSCPCore
import MacSCPBackends

@MainActor
@Observable
final class FileOperationsCoordinator {
    var onStatusMessage: ((String) -> Void)?

    func createRemoteDirectory(
        name: String,
        backend: TransferBackend?,
        remotePath: String
    ) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let backend else { return false }
        let path = SFTPPathJoin.joinRemote(remotePath, trimmed)
        do {
            try await backend.createDirectory(at: path, recursive: false)
            onStatusMessage?("Created remote folder \(trimmed)")
            return true
        } catch {
            onStatusMessage?("Create folder failed: \(error.localizedDescription)")
            return false
        }
    }

    func createLocalDirectory(name: String, localPath: URL) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let url = localPath.appendingPathComponent(trimmed)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            onStatusMessage?("Created local folder \(trimmed)")
            return true
        } catch {
            onStatusMessage?("Create folder failed: \(error.localizedDescription)")
            return false
        }
    }

    func renameRemote(
        from name: String,
        to newName: String,
        backend: TransferBackend?,
        remotePath: String
    ) async -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let backend else { return false }
        let fromPath = SFTPPathJoin.joinRemote(remotePath, name)
        let toPath = SFTPPathJoin.joinRemote(remotePath, trimmed)
        do {
            try await backend.rename(from: fromPath, to: toPath)
            onStatusMessage?("Renamed remote item to \(trimmed)")
            return true
        } catch {
            onStatusMessage?("Rename failed: \(error.localizedDescription)")
            return false
        }
    }

    func renameLocal(from name: String, to newName: String, localPath: URL) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let fromURL = localPath.appendingPathComponent(name)
        let toURL = localPath.appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: fromURL, to: toURL)
            onStatusMessage?("Renamed local item to \(trimmed)")
            return true
        } catch {
            onStatusMessage?("Rename failed: \(error.localizedDescription)")
            return false
        }
    }

    func deleteRemote(
        names: [String],
        entries: [RemoteEntry],
        backend: TransferBackend?,
        remotePath: String
    ) async -> Bool {
        guard let backend else { return false }
        var ok = true
        for name in names {
            guard let entry = entries.first(where: { $0.name == name }) else { continue }
            do {
                switch entry.type {
                case .directory:
                    try await backend.removeDirectory(at: entry.path, recursive: true)
                case .file, .symlink:
                    try await backend.removeFile(at: entry.path)
                }
            } catch {
                ok = false
                onStatusMessage?("Delete failed for \(name): \(error.localizedDescription)")
            }
        }
        if ok { onStatusMessage?("Deleted \(names.count) remote item(s)") }
        return ok
    }

    func deleteLocal(names: [String], localPath: URL) -> Bool {
        var ok = true
        for name in names {
            let url = localPath.appendingPathComponent(name)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            } catch {
                ok = false
                onStatusMessage?("Delete failed for \(name): \(error.localizedDescription)")
            }
        }
        if ok { onStatusMessage?("Moved \(names.count) local item(s) to Trash") }
        return ok
    }

    func setRemotePermissions(
        _ permissions: FilePermissions,
        name: String,
        backend: TransferBackend?,
        remotePath: String
    ) async -> Bool {
        guard let backend else { return false }
        let path = SFTPPathJoin.joinRemote(remotePath, name)
        do {
            try await backend.setPermissions(permissions, at: path)
            onStatusMessage?("Updated permissions for \(name)")
            return true
        } catch {
            onStatusMessage?("chmod failed: \(error.localizedDescription)")
            return false
        }
    }
}
