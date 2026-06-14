// CommanderView.swift
//
// WHAT THIS FILE DOES
// -------------------
// Dual-pane file browser with toolbar transfers and drag-and-drop. Binds to AppModel for
// local/remote listings, transfer queue status, and file operation actions.
//

import SwiftUI
import AppKit
import MacSCPCore

struct CommanderView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            commanderToolbar
            Divider()
            if appModel.featureSettings.uiLayoutMode == .explorer {
                explorerLayout
            } else {
                dualPaneLayout
            }
            if appModel.showTerminalPane {
                Divider()
                EmbeddedTerminalView(
                    host: appModel.draft.host,
                    port: Int(appModel.draft.port) ?? 22,
                    username: appModel.draft.username
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
        .sheet(item: Bindable(appModel).hostKeyPrompt) { request in
            HostKeyPromptView(
                request: request,
                onTrust: { appModel.respondHostKey(trusted: true) },
                onReject: { appModel.respondHostKey(trusted: false) }
            )
        }
        .sheet(item: Bindable(appModel).namePrompt) { prompt in
            NamePromptView(
                title: prompt.title,
                placeholder: prompt.placeholder,
                initialValue: prompt.initialValue,
                onConfirm: { value in Task { await appModel.confirmNamePrompt(value) } },
                onCancel: { appModel.namePrompt = nil }
            )
        }
        .sheet(item: Bindable(appModel).propertiesPrompt) { prompt in
            PropertiesSheetView(
                paneSide: prompt.paneSide,
                entryName: prompt.entryName,
                permissionsOctal: prompt.permissionsOctal,
                supportsChown: prompt.supportsChown,
                ownerUser: prompt.ownerUser,
                ownerGroup: prompt.ownerGroup,
                onSave: { octal, user, group in
                    Task { await appModel.saveProperties(octal: octal, ownerUser: user, ownerGroup: group) }
                },
                onCancel: { appModel.propertiesPrompt = nil }
            )
        }
        .sheet(isPresented: Bindable(appModel).showSyncSheet) {
            SyncCompareView()
        }
        .sheet(item: Bindable(appModel).internalEditor) { editor in
            InternalEditorView(
                fileName: editor.snapshot.fileName,
                text: Binding(
                    get: { appModel.internalEditor?.text ?? editor.text },
                    set: { appModel.internalEditor?.text = $0 }
                ),
                encoding: Binding(
                    get: { appModel.internalEditor?.encoding ?? editor.encoding },
                    set: { appModel.internalEditor?.encoding = $0 }
                ),
                lineEnding: Binding(
                    get: { appModel.internalEditor?.lineEnding ?? editor.lineEnding },
                    set: { appModel.internalEditor?.lineEnding = $0 }
                ),
                isSaving: editor.isSaving,
                errorMessage: editor.errorMessage,
                onSave: { Task { await appModel.saveInternalEditor() } },
                onSaveAnyway: { Task { await appModel.saveInternalEditor(conflictPolicy: .overwrite) } },
                onCancel: { appModel.cancelInternalEditor() }
            )
        }
        .sheet(isPresented: Bindable(appModel).showTransferHistory) {
            TransferHistoryView()
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button("History") {
                    appModel.showTransferHistory = true
                }
                .disabled(!appModel.featureSettings.transferHistoryEnabled)
                .help("View local transfer history")
            }
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

    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(appModel.workspacesForTabs) { tab in
                    Button(tab.title) {
                        appModel.selectTab(tab.id)
                    }
                    .buttonStyle(.bordered)
                    .tint(tab.id == appModel.selectedTabID ? .accentColor : .secondary)
                }
                Button("", systemImage: "plus") { appModel.newTab() }
                if appModel.workspacesForTabs.count > 1 {
                    Button("", systemImage: "xmark") {
                        Task { await appModel.closeSelectedTab() }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var dualPaneLayout: some View {
        HSplitView {
            localPane
            remotePane
        }
    }

    private var explorerLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Local files open in Finder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Reveal Local Folder") {
                    NSWorkspace.shared.open(appModel.localPath)
                }
                Button("Choose Local Folder") {
                    appModel.chooseLocalFolder()
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            remotePane
        }
    }

    private var localPane: some View {
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
            },
            onNewFolder: { appModel.promptNewFolder(pane: .local) },
            onRename: { appModel.promptRename(pane: .local, entryName: $0) },
            onDelete: { Task { await appModel.deleteSelected(pane: .local) } },
            onProperties: { appModel.promptProperties(pane: .local, entryName: $0) }
        )
    }

    private var remotePane: some View {
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
            },
            onNewFolder: { appModel.promptNewFolder(pane: .remote) },
            onRename: { appModel.promptRename(pane: .remote, entryName: $0) },
            onDelete: { Task { await appModel.deleteSelected(pane: .remote) } },
            onProperties: { appModel.promptProperties(pane: .remote, entryName: $0) },
            onQuickLook: { Task { await appModel.quickLookRemote() } },
            onEdit: { Task { await appModel.editRemoteSelection() } },
            onEditInternal: { Task { await appModel.editRemoteSelectionInternal() } }
        )
    }

    private var commanderToolbar: some View {
        HStack(spacing: 12) {
            Button("", systemImage: "chevron.left") {
                Task { await appModel.navigateBack() }
            }
            .disabled(!appModel.canNavigateBack)
            .help("Back")

            Button("", systemImage: "chevron.right") {
                Task { await appModel.navigateForward() }
            }
            .disabled(!appModel.canNavigateForward)
            .help("Forward")

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

            Divider().frame(height: 20)

            Button {
                Task { await appModel.uploadSelected() }
            } label: {
                Label("Upload", systemImage: "arrow.right.circle")
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])

            Button {
                Task { await appModel.downloadSelected() }
            } label: {
                Label("Download", systemImage: "arrow.left.circle")
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])

            Button {
                Task { await appModel.compareDirectories() }
            } label: {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .help("Compare and synchronize directories")

            Button {
                appModel.openTerminal()
            } label: {
                Label("Terminal", systemImage: "terminal")
            }

            Button {
                appModel.showTerminalPane.toggle()
            } label: {
                Label("Shell", systemImage: appModel.showTerminalPane ? "terminal.fill" : "terminal")
            }

            Button {
                var settings = appModel.featureSettings
                settings.uiLayoutMode = settings.uiLayoutMode == .commander ? .explorer : .commander
                appModel.updateFeatureSettings(settings)
            } label: {
                Label(
                    appModel.featureSettings.uiLayoutMode == .explorer ? "Explorer" : "Commander",
                    systemImage: appModel.featureSettings.uiLayoutMode == .explorer ? "list.bullet.rectangle" : "rectangle.split.2x1"
                )
            }

            Button {
                appModel.toggleLiveSync()
            } label: {
                Label(
                    "Live Sync",
                    systemImage: appModel.liveSyncEnabled ? "bolt.circle.fill" : "bolt.circle"
                )
            }
            .help("Keep remote directory up to date (FSEvents)")

            Spacer()
            selectionSummary

            Text(appModel.draft.transferProtocol.rawValue.uppercased())
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
            if let launch = AppMetricsService.launchMilliseconds() {
                Text("Launch \(launch) ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let connect = AppMetricsService.lastConnectMilliseconds() {
                Text("Connect \(connect) ms")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Image(systemName: "lock.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .help("Encrypted session")
            Text("\(appModel.remoteEntries.count) remote · queue \(appModel.transferQueue.jobs.count)")
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
    var onNewFolder: () -> Void = {}
    var onRename: (String) -> Void = { _ in }
    var onDelete: () -> Void = {}
    var onProperties: (String) -> Void = { _ in }
    var onQuickLook: () -> Void = {}
    var onEdit: () -> Void = {}
    var onEditInternal: () -> Void = {}

    @FocusState private var isFocused: Bool
    @State private var typeAhead = ""
    @State private var dropTargeted = false

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
                if !typeAhead.isEmpty {
                    Text("Find: \(typeAhead)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("", systemImage: "folder.badge.plus") { onNewFolder() }
                    .help("New folder")
                Button("", systemImage: "arrow.up.to.line") { onUp() }
                    .help("Up")
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("", systemImage: "arrow.clockwise") { onRefresh() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            List(filteredEntries, selection: $selection) { entry in
                row(for: entry)
                    .contextMenu {
                        Button("Rename") { onRename(entry.name) }
                        Button("Properties") { onProperties(entry.name) }
                        if paneSide == .remote && !entry.isDirectory {
                            Button("Quick Look") { onQuickLook() }
                            Button("Edit with Internal Editor") { onEditInternal() }
                            Button("Edit with External Editor") { onEdit() }
                        }
                        Divider()
                        Button("Delete", role: .destructive) { onDelete() }
                    }
            }
            .listStyle(.plain)
            .focusable()
            .focused($isFocused)
            .onKeyPress { press in
                handleKeyPress(press)
            }
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

    private var filteredEntries: [PaneEntry] {
        guard !typeAhead.isEmpty else { return entries }
        return entries.filter { $0.name.localizedCaseInsensitiveContains(typeAhead) }
    }

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.characters.count == 1, !press.modifiers.contains(.command) {
            typeAhead += press.characters
            if let match = entries.first(where: { $0.name.lowercased().hasPrefix(typeAhead.lowercased()) }) {
                selection = [match.name]
            }
            return .handled
        }
        if press.key == .escape {
            typeAhead = ""
            return .handled
        }
        if press.key == .return, let name = selection.first, let entry = entries.first(where: { $0.name == name }) {
            if entry.isDirectory { onOpen(entry) }
            else if paneSide == .remote { onQuickLook() }
            return .handled
        }
        if press.key == .downArrow, press.modifiers.contains(.command), let name = selection.first,
           let entry = entries.first(where: { $0.name == name }), entry.isDirectory {
            onOpen(entry)
            return .handled
        }
        if press.key == .space, paneSide == .remote {
            onQuickLook()
            return .handled
        }
        return .ignored
    }

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
            } else if paneSide == .remote {
                onQuickLook()
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
