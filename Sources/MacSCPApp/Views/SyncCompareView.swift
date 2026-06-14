// SyncCompareView.swift
//
// WHAT THIS FILE DOES
// -------------------
// Sheet listing directory compare results and sync direction controls.
// SyncCoordinator populates compareRows; this view enqueues mirror or bidirectional sync.
//
import MacSCPCore
import SwiftUI

struct SyncCompareView: View {
    @Environment(AppModel.self) private var appModel
    @State private var previewOnly = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronize Directories")
                .font(.title3.weight(.semibold))

            Picker("Direction", selection: Bindable(appModel).syncDirection) {
                Text("Mirror local → remote").tag(SyncDirection.mirrorLocalToRemote)
                Text("Mirror remote → local").tag(SyncDirection.mirrorRemoteToLocal)
                Text("Bidirectional").tag(SyncDirection.bidirectional)
            }
            .pickerStyle(.radioGroup)

            if appModel.syncDirection == .bidirectional {
                Toggle("Delete extraneous files", isOn: Binding(
                    get: { appModel.sync.deleteExtraneous },
                    set: { appModel.sync.deleteExtraneous = $0 }
                ))
            }

            Toggle("Preview only (dry run)", isOn: $previewOnly)

            Table(appModel.syncCompareRows) {
                TableColumn("Path") { row in
                    Text(row.relativePath)
                }
                TableColumn("Status") { row in
                    Text(row.status.rawValue)
                        .foregroundStyle(color(for: row.status))
                }
                TableColumn("Local") { row in
                    Text(formatSize(row.localSize))
                }
                TableColumn("Remote") { row in
                    Text(formatSize(row.remoteSize))
                }
            }
            .frame(minHeight: 280)

            HStack {
                Spacer()
                Button("Cancel") {
                    appModel.sync.showSyncSheet = false
                }
                Button(previewOnly ? "Preview" : "Synchronize") {
                    appModel.runSync(previewOnly: previewOnly)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appModel.sync.isComparing)
            }
        }
        .padding(20)
        .frame(minWidth: 720, minHeight: 420)
    }

    private func color(for status: SyncEntryStatus) -> Color {
        switch status {
        case .same: .secondary
        case .newLocal, .newerLocal: .blue
        case .newRemote, .newerRemote: .green
        case .sizeMismatch: .orange
        }
    }

    private func formatSize(_ size: Int64?) -> String {
        guard let size else { return "—" }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

struct PropertiesSheetView: View {
    let paneSide: FilePaneSide
    let entryName: String
    let permissionsOctal: String
    let supportsChown: Bool
    let onSave: (String, String, String) -> Void
    let onCancel: () -> Void

    @State private var octal: String
    @State private var ownerUser: String
    @State private var ownerGroup: String

    init(
        paneSide: FilePaneSide,
        entryName: String,
        permissionsOctal: String,
        supportsChown: Bool,
        ownerUser: String = "",
        ownerGroup: String = "",
        onSave: @escaping (String, String, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.paneSide = paneSide
        self.entryName = entryName
        self.permissionsOctal = permissionsOctal
        self.supportsChown = supportsChown
        self.onSave = onSave
        self.onCancel = onCancel
        _octal = State(initialValue: permissionsOctal)
        _ownerUser = State(initialValue: ownerUser)
        _ownerGroup = State(initialValue: ownerGroup)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Properties — \(entryName)")
                .font(.headline)

            TextField("Permissions (octal)", text: $octal)
                .textFieldStyle(.roundedBorder)
            Text("Example: 644 for rw-r--r--")
                .font(.caption)
                .foregroundStyle(.secondary)

            if supportsChown {
                TextField("Owner (user or uid)", text: $ownerUser)
                    .textFieldStyle(.roundedBorder)
                TextField("Group (group or gid)", text: $ownerGroup)
                    .textFieldStyle(.roundedBorder)
                Text("Leave blank to keep unchanged. SSH backends only.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Save") { onSave(octal, ownerUser, ownerGroup) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

struct NamePromptView: View {
    let title: String
    let placeholder: String
    let initialValue: String
    let onConfirm: (String) -> Void
    let onCancel: () -> Void

    @State private var value: String

    init(
        title: String,
        placeholder: String,
        initialValue: String = "",
        onConfirm: @escaping (String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.title = title
        self.placeholder = placeholder
        self.initialValue = initialValue
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _value = State(initialValue: initialValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            TextField(placeholder, text: $value)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("OK") { onConfirm(value) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 320)
    }
}
