// RemoteEditorService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Downloads a remote file, opens it in an external editor, and re-uploads on save. CommanderView
// uses DispatchSource file watchers to detect when the edited local copy changes.
//

import AppKit
import Foundation
import MacSCPCore

@MainActor
final class RemoteEditorService {
    private var watchers: [UUID: DispatchSourceFileSystemObject] = [:]
    private var contexts: [UUID: EditContext] = [:]
    private var onStatusHandler: ((String) -> Void)?

    private struct EditContext {
        var localURL: URL
        var remotePath: String
        var backend: TransferBackend
    }

    func editRemoteFile(
        entry: RemoteEntry,
        backend: TransferBackend,
        onStatus: @escaping (String) -> Void
    ) async {
        guard entry.type == .file else { return }
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSCP/edit", isDirectory: true)
        let sessionDir = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
            let localURL = sessionDir.appendingPathComponent(entry.name)
            _ = try await backend.download(remotePath: entry.path, localURL: localURL, options: TransferOptions())
            let id = UUID()
            contexts[id] = EditContext(localURL: localURL, remotePath: entry.path, backend: backend)
            onStatusHandler = onStatus
            watchFile(id: id)
            NSWorkspace.shared.open(localURL)
            onStatus("Editing \(entry.name) — saves will upload automatically")
        } catch {
            onStatus("Edit failed: \(error.localizedDescription)")
        }
    }

    func stopAll() {
        for (_, source) in watchers {
            source.cancel()
        }
        watchers.removeAll()
        contexts.removeAll()
        onStatusHandler = nil
    }

    private func watchFile(id: UUID) {
        guard let context = contexts[id] else { return }
        let fd = open(context.localURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                await self?.uploadIfChanged(id: id)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchers[id] = source
    }

    private func uploadIfChanged(id: UUID) async {
        guard let context = contexts[id] else { return }
        do {
            _ = try await context.backend.upload(
                localURL: context.localURL,
                remotePath: context.remotePath,
                options: TransferOptions(overwrite: .overwrite)
            )
            onStatusHandler?("Uploaded changes to \(context.remotePath)")
        } catch {
            onStatusHandler?("Re-upload failed: \(error.localizedDescription)")
        }
    }
}
