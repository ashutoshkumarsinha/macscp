// CommanderView.swift — Dual-pane file browser, toolbar transfers, drag-and-drop.

import SwiftUI
import MacSCPCore

struct CommanderView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            commanderToolbar
            Divider()
            HSplitView {
                FilePaneView(
                    paneSide: .local,
                    title: "LOCAL",
                    subtitle: appModel.localPath.path,
                    entries: appModel.localEntries.map { .local($0) },
                    selection: Bindable(appModel).selectedLocalNames,
                    onRefresh: { Task { await appModel.refreshLocal() } },
                    onUp: { appModel.navigateLocalUp() },
                    onOpen: { entry in
                        if case let .local(local) = entry, local.isDirectory {
                            appModel.openLocalDirectory(local.name)
                        }
                    },
                    onDropFromOpposite: { payload in
                        Task { await appModel.downloadDropped(fileNames: payload.fileNames) }
                    }
                )
                FilePaneView(
                    paneSide: .remote,
                    title: "REMOTE",
                    subtitle: "\(appModel.draft.host):\(appModel.remotePath)",
                    entries: appModel.remoteEntries.map { .remote($0) },
                    selection: Bindable(appModel).selectedRemoteNames,
                    onRefresh: { Task { await appModel.refreshRemote() } },
                    onUp: { Task { await appModel.navigateRemoteUp() } },
                    onOpen: { entry in
                        if case let .remote(remote) = entry, remote.type == .directory {
                            Task { await appModel.openRemoteDirectory(remote.name) }
                        }
                    },
                    onDropFromOpposite: { payload in
                        Task { await appModel.uploadDropped(fileNames: payload.fileNames) }
                    }
                )
            }
            Divider()
            TransferQueueView()
            Divider()
            statusBar
        }
        .navigationTitle(appModel.activeSessionName)
        .sheet(item: Bindable(appModel).overwritePrompt) { batch in
            OverwritePromptView(batch: batch) { action in
                appModel.resolveOverwritePrompt(action: action)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                if appModel.transferQueue.activeCount > 0 {
                    Text("Queue: \(appModel.transferQueue.activeCount)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ToolbarItem(placement: .automatic) {
                Button("Disconnect") {
                    Task { await appModel.disconnect() }
                }
            }
        }
    }

    private var commanderToolbar: some View {
        HStack(spacing: 12) {
            Button("", systemImage: "arrow.up") {
                appModel.navigateLocalUp()
                Task { await appModel.navigateRemoteUp() }
            }
            .help("Up (both panes)")

            Button("", systemImage: "arrow.clockwise") {
                Task {
                    await appModel.refreshLocal()
                    await appModel.refreshRemote()
                }
            }
            .help("Refresh")

            Divider()
                .frame(height: 20)

            Button {
                Task { await appModel.uploadSelected() }
            } label: {
                Label("Upload", systemImage: "arrow.right.circle")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            .help("Upload selected local files to remote")

            Button {
                Task { await appModel.downloadSelected() }
            } label: {
                Label("Download", systemImage: "arrow.left.circle")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("Download selected remote files to local")

            Spacer()

            selectionSummary

            Text("SFTP")
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectionSummary: some View {
        HStack(spacing: 16) {
            if !appModel.selectedLocalNames.isEmpty {
                Text("\(appModel.selectedLocalNames.count) local selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !appModel.selectedRemoteNames.isEmpty {
                Text("\(appModel.selectedRemoteNames.count) remote selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusBar: some View {
        HStack {
            Text(appModel.statusMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(appModel.remoteEntries.count) remote items")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

enum PaneEntry: Identifiable {
    case local(LocalEntry)
    case remote(RemoteEntry)

    var id: String {
        switch self {
        case let .local(entry): "local-\(entry.name)"
        case let .remote(entry): "remote-\(entry.path)"
        }
    }

    var name: String {
        switch self {
        case let .local(entry): entry.name
        case let .remote(entry): entry.name
        }
    }

    var isDirectory: Bool {
        switch self {
        case let .local(entry): entry.isDirectory
        case let .remote(entry): entry.type == .directory
        }
    }

    var size: Int64? {
        switch self {
        case let .local(entry): entry.size
        case let .remote(entry): entry.size
        }
    }

    var modified: Date? {
        switch self {
        case let .local(entry): entry.modified
        case let .remote(entry): entry.modified
        }
    }
}

struct FilePaneView: View {
    let paneSide: FilePaneSide
    let title: String
    let subtitle: String
    let entries: [PaneEntry]
    @Binding var selection: Set<String>
    let onRefresh: () -> Void
    let onUp: () -> Void
    let onOpen: (PaneEntry) -> Void
    let onDropFromOpposite: (PaneDragPayload) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(subtitle)
                        .font(.caption2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("", systemImage: "arrow.up.to.line") { onUp() }
                Button("", systemImage: "arrow.clockwise") { onRefresh() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(entries, selection: $selection) { entry in
                row(for: entry)
            }
            .listStyle(.plain)
        }
        .dropDestination(for: PaneDragPayload.self) { payloads, _ in
            guard let payload = payloads.first, paneSide.acceptsDrop(from: payload.side) else {
                return false
            }
            onDropFromOpposite(payload)
            return true
        } isTargeted: { isTargeted in
            dropTargeted = isTargeted
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(.blue, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
    }

    @State private var dropTargeted = false

    @ViewBuilder
    private func row(for entry: PaneEntry) -> some View {
        let content = HStack {
            Image(systemName: entry.isDirectory ? "folder.fill" : "doc")
                .foregroundStyle(entry.isDirectory ? .blue : .secondary)
            Text(entry.name)
            Spacer()
            Text(formatSize(entry.size, isDirectory: entry.isDirectory))
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .tag(entry.name)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                onOpen(entry)
            }
        }

        if let payload = dragPayload(for: entry) {
            content.draggable(payload) {
                Label(entry.name, systemImage: entry.isDirectory ? "folder" : "doc")
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        } else {
            content
        }
    }

    private func dragPayload(for entry: PaneEntry) -> PaneDragPayload? {
        // Directories are draggable; TransferCoordinator expands them before enqueue.
        let names: [String]
        if selection.contains(entry.name) {
            names = entries.filter { selection.contains($0.name) }.map(\.name)
        } else {
            names = [entry.name]
        }
        guard !names.isEmpty else { return nil }
        return PaneDragPayload(side: paneSide.dragSide, fileNames: names)
    }

    private func formatSize(_ size: Int64?, isDirectory: Bool) -> String {
        guard let size, !isDirectory else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}
