// QuickLookPreviewService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Previews local or downloaded remote files with macOS Quick Look.
// File pane actions invoke preview for a URL without leaving the transfer UI.
//
import AppKit
import Foundation
import MacSCPCore
import Quartz

@MainActor
enum QuickLookPreviewService {
    private static var retainedDataSource: PreviewDataSource?

    private final class PreviewItem: NSObject, QLPreviewItem {
        let url: URL
        init(url: URL) { self.url = url }
        var previewItemURL: URL? { url }
    }

    private final class PreviewDataSource: NSObject, QLPreviewPanelDataSource {
        let item: PreviewItem
        init(item: PreviewItem) { self.item = item }
        func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { 1 }
        func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
            item
        }
    }

    static func previewRemoteFile(
        entry: RemoteEntry,
        backend: TransferBackend,
        onStatus: (String) -> Void
    ) async {
        guard entry.type == .file else { return }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macscp-ql-\(UUID().uuidString)-\(entry.name)")
        do {
            _ = try await backend.download(remotePath: entry.path, localURL: temp, options: TransferOptions())
            guard let panel = QLPreviewPanel.shared() else { return }
            let dataSource = PreviewDataSource(item: PreviewItem(url: temp))
            retainedDataSource = dataSource
            panel.dataSource = dataSource
            panel.makeKeyAndOrderFront(nil)
            onStatus("Previewing \(entry.name)")
        } catch {
            onStatus("Quick Look failed: \(error.localizedDescription)")
        }
    }
}
