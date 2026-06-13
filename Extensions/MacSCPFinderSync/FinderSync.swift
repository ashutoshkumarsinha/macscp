import FinderSync

private enum SharedKeys {
    static let appGroupID = "group.com.macscp.app"
    static let activeProfileNameKey = "activeProfileName"
}

final class MacSCPFinderSync: FIFinderSync {
    override init() {
        super.init()
        if let defaults = UserDefaults(suiteName: SharedKeys.appGroupID),
           let folders = defaults.stringArray(forKey: "syncedFolders") {
            let urls = folders.compactMap { URL(string: $0) }
            if !urls.isEmpty {
                FIFinderSyncController.default().directoryURLs = Set(urls)
            }
        }
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems || menuKind == .contextualMenuForContainer else {
            return nil
        }
        let menu = NSMenu(title: "MacSCP")
        let profileName = UserDefaults(suiteName: SharedKeys.appGroupID)?
            .string(forKey: SharedKeys.activeProfileNameKey) ?? "session"
        let upload = NSMenuItem(
            title: "Upload to MacSCP (\(profileName))…",
            action: #selector(uploadSelection(_:)),
            keyEquivalent: ""
        )
        upload.target = self
        menu.addItem(upload)
        return menu
    }

    @objc private func uploadSelection(_ sender: NSMenuItem) {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.macscp.app") else {
            return
        }
        let items = FIFinderSyncController.default().selectedItemURLs() ?? []
        let paths = items.map(\.path).joined(separator: "\n")
        let encoded = paths.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        if let openURL = URL(string: "macscp://upload?paths=\(encoded)") {
            NSWorkspace.shared.open([openURL], withApplicationAt: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }
}
