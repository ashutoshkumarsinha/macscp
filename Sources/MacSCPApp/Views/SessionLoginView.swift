// SessionLoginView.swift — Profile sidebar and connection form (key / password / agent).

import SwiftUI
import MacSCPCore

struct SessionLoginView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var profileSearchText = ""

    private var filteredProfiles: [SessionProfile] {
        let query = profileSearchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appModel.profiles }
        return appModel.profiles.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.host.localizedCaseInsensitiveContains(query)
                || $0.username.localizedCaseInsensitiveContains(query)
        }
    }

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
                ForEach(filteredProfiles) { profile in
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
        .searchable(text: $profileSearchText, prompt: "Search Profiles")
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button("", systemImage: "plus") {
                    appModel.selectedProfileID = nil
                    appModel.draft = SessionProfileDraft()
                }
                Button("", systemImage: "minus") {
                    if let id = appModel.selectedProfileID {
                        appModel.deleteProfile(id: id)
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

            Picker("Authentication", selection: Bindable(appModel).draft.authMethod) {
                Text("SSH Key File").tag(AuthMethod.publicKey)
                Text("Password").tag(AuthMethod.password)
                Text("SSH Agent").tag(AuthMethod.agent)
            }

            if appModel.draft.authMethod == .publicKey {
                TextField("SSH Key", text: Bindable(appModel).draft.keyPath)
            } else if appModel.draft.authMethod == .password {
                SecureField("Password", text: Bindable(appModel).draft.password)
            } else if appModel.draft.authMethod == .agent {
                Text("Uses keys from SSH_AUTH_SOCK (ssh-agent).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Initial Remote Path", text: Bindable(appModel).draft.initialRemotePath)
            TextField("Host Key Fingerprint (optional SHA-256)", text: Bindable(appModel).draft.hostKeyFingerprint)
            TextField("Profile Name", text: Bindable(appModel).draft.name)

            Toggle("Require Touch ID to connect", isOn: Binding(
                get: { AppLockService.isEnabled },
                set: { AppLockService.setEnabled($0) }
            ))

            HStack {
                Button("Save") { appModel.saveDraftAsProfile() }
                Button("Cancel") { dismiss() }
                Spacer()
                Button(appModel.isConnecting ? "Connecting…" : "Login") {
                    Task { await appModel.connect() }
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(appModel.isConnecting || appModel.draft.host.isEmpty || !appModel.draft.validatePort())
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("New Connection")
    }
}
