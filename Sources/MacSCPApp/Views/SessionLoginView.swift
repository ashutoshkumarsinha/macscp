// SessionLoginView.swift
//
// WHAT THIS FILE DOES
// -------------------
// Profile sidebar and connection form (key, password, or SSH agent). AppModel draft state
// drives connect; users pick or edit SessionProfile entries before CommanderView opens.
//

import SwiftUI
import AppKit
import MacSCPCore

struct SessionLoginView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(\.dismiss) private var dismiss
    @State private var profileSearchText = ""
    @State private var masterPassword = ""
    @State private var exportError: String?

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

    private var usesSSHAuth: Bool {
        TransferProtocolDefaults.supportsSSHAuth(appModel.draft.transferProtocol)
    }

    private var profileDetail: some View {
        Form {
            Picker("Protocol", selection: Bindable(appModel).draft.transferProtocol) {
                Text("SFTP (SSH)").tag(TransferProtocol.sftp)
                Text("SCP (SSH)").tag(TransferProtocol.scp)
                Text("FTP").tag(TransferProtocol.ftp)
                Text("FTPS").tag(TransferProtocol.ftps)
                Text("WebDAV").tag(TransferProtocol.webdav)
                Text("Amazon S3").tag(TransferProtocol.s3)
                Text("Google Cloud Storage").tag(TransferProtocol.gcs)
            }
            .onChange(of: appModel.draft.transferProtocol) { _, newValue in
                appModel.draft.port = String(TransferProtocolDefaults.defaultPort(for: newValue))
                if !TransferProtocolDefaults.supportsSSHAuth(newValue) {
                    appModel.draft.authMethod = .password
                }
            }

            TextField("Host Name", text: Bindable(appModel).draft.host)
            TextField("Port", text: Bindable(appModel).draft.port)
            TextField("Username", text: Bindable(appModel).draft.username)

            if usesSSHAuth {
                Picker("Authentication", selection: Bindable(appModel).draft.authMethod) {
                    Text("SSH Key File").tag(AuthMethod.publicKey)
                    Text("Password").tag(AuthMethod.password)
                    Text("SSH Agent").tag(AuthMethod.agent)
                }

                if appModel.draft.authMethod == .publicKey {
                    TextField("SSH Key", text: Bindable(appModel).draft.keyPath)
                    SecureField("Key Passphrase (optional)", text: Bindable(appModel).draft.keyPassphrase)
                } else if appModel.draft.authMethod == .password {
                    SecureField("Password", text: Bindable(appModel).draft.password)
                } else if appModel.draft.authMethod == .agent {
                    Text("Uses keys from SSH_AUTH_SOCK (ssh-agent).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                TextField("Host Key Fingerprint (optional SHA-256)", text: Bindable(appModel).draft.hostKeyFingerprint)
            } else {
                SecureField(appModel.draft.transferProtocol == .webdav ? "Password" : "Secret Key", text: Bindable(appModel).draft.password)
            }

            if TransferProtocolDefaults.usesCloudCredentials(appModel.draft.transferProtocol)
                && appModel.draft.transferProtocol != .webdav {
                TextField("Bucket (optional if path is /bucket/prefix)", text: Bindable(appModel).draft.cloudBucket)
                TextField("Region (e.g. us-east-1, auto for GCS)", text: Bindable(appModel).draft.cloudRegion)
            }

            TextField(
                appModel.draft.transferProtocol == .s3 || appModel.draft.transferProtocol == .gcs
                    ? "Path (/bucket/prefix)"
                    : "Initial Remote Path",
                text: Bindable(appModel).draft.initialRemotePath
            )
            TextField("Profile Name", text: Bindable(appModel).draft.name)

            Section("Proxy") {
                Picker("Type", selection: Bindable(appModel).draft.proxyType) {
                    Text("None").tag(ProxyType.none)
                    Text("HTTP").tag(ProxyType.http)
                    Text("SOCKS5").tag(ProxyType.socks5)
                    Text("SSH Jump Host").tag(ProxyType.jump)
                }
                if appModel.draft.proxyType != .none {
                    TextField("Proxy Host", text: Bindable(appModel).draft.proxyHost)
                    TextField("Port (optional)", text: Bindable(appModel).draft.proxyPort)
                }
            }

            Section("Security") {
                SecureField("Master password", text: $masterPassword)
                Button("Set Master Password") {
                    try? MasterPasswordService.setMasterPassword(masterPassword)
                    masterPassword = ""
                }
                Button("Export Encrypted Profiles…") {
                    exportProfiles()
                }
                if let exportError {
                    Text(exportError).font(.caption).foregroundStyle(.red)
                }
            }

            Toggle("Require Touch ID to connect", isOn: Binding(
                get: { AppLockService.isEnabled },
                set: { AppLockService.setEnabled($0) }
            ))

            Section("Optional Features") {
                Toggle("Save transfer history locally", isOn: Binding(
                    get: { appModel.featureSettings.transferHistoryEnabled },
                    set: {
                        var settings = appModel.featureSettings
                        settings.transferHistoryEnabled = $0
                        appModel.updateFeatureSettings(settings)
                    }
                ))
                Toggle("Notify when transfer queue completes", isOn: Binding(
                    get: { appModel.featureSettings.notifyOnQueueComplete },
                    set: {
                        var settings = appModel.featureSettings
                        settings.notifyOnQueueComplete = $0
                        appModel.updateFeatureSettings(settings)
                    }
                ))
                Toggle("Sync saved profiles via iCloud (encrypted)", isOn: Binding(
                    get: { appModel.featureSettings.iCloudProfileSyncEnabled },
                    set: {
                        var settings = appModel.featureSettings
                        settings.iCloudProfileSyncEnabled = $0
                        appModel.updateFeatureSettings(settings)
                    }
                ))
            }

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

    private func exportProfiles() {
        exportError = nil
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "macscp-profiles.enc"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try appModel.exportEncryptedProfiles(to: url, password: masterPassword)
        } catch {
            exportError = error.localizedDescription
        }
    }
}
