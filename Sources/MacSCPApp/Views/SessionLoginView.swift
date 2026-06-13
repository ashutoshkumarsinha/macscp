import SwiftUI

struct SessionLoginView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationSplitView {
            profileSidebar
        } detail: {
            profileDetail
        }
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        .frame(minWidth: 720, minHeight: 480)
    }

    private var profileSidebar: some View {
        List(selection: Binding(
            get: { appModel.selectedProfileID },
            set: { if let id = $0 { appModel.selectProfile(id) } }
        )) {
            Section("Saved Sessions") {
                ForEach(appModel.profiles) { profile in
                    Label {
                        Text(profile.name)
                    } icon: {
                        Image(systemName: profile.favorite ? "star.fill" : "folder")
                            .foregroundStyle(profile.favorite ? .yellow : .secondary)
                    }
                    .tag(profile.id)
                }
            }
        }
        .listStyle(.sidebar)
        .searchable(text: .constant(""), prompt: "Search Profiles")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("", systemImage: "plus") {
                    appModel.selectedProfileID = nil
                    appModel.draft = SessionProfileDraft()
                }
                Button("", systemImage: "minus") {
                    if let id = appModel.selectedProfileID {
                        appModel.profiles.removeAll { $0.id == id }
                        appModel.selectedProfileID = appModel.profiles.first?.id
                        appModel.syncDraftFromSelection()
                    }
                }
            }
        }
    }

    private var profileDetail: some View {
        Form {
            Picker("Protocol", selection: .constant("SFTP")) {
                Text("SFTP (SSH)").tag("SFTP")
            }

            TextField("Host Name", text: Bindable(appModel).draft.host)
            TextField("Port", text: Bindable(appModel).draft.port)
            TextField("Username", text: Bindable(appModel).draft.username)

            Toggle("Use SSH Key", isOn: Bindable(appModel).draft.useKeyAuth)

            if appModel.draft.useKeyAuth {
                TextField("SSH Key", text: Bindable(appModel).draft.keyPath)
            } else {
                SecureField("Password", text: Bindable(appModel).draft.password)
            }

            TextField("Initial Remote Path", text: Bindable(appModel).draft.initialRemotePath)
            TextField("Profile Name", text: Bindable(appModel).draft.name)

            HStack {
                Button("Save") { appModel.saveDraftAsProfile() }
                Button("Cancel") { dismiss() }
                Spacer()
                Button(appModel.isConnecting ? "Connecting…" : "Login") {
                    Task { await appModel.connect() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appModel.isConnecting || appModel.draft.host.isEmpty)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("New Connection")
    }
}
