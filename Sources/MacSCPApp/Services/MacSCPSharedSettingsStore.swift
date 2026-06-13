import Foundation
import MacSCPCore

enum MacSCPSharedSettingsStore {
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: MacSCPSharedConstants.appGroupID)
    }

    static func setActiveProfileName(_ name: String) {
        defaults?.set(name, forKey: MacSCPSharedConstants.activeProfileNameKey)
    }

    static func activeProfileName() -> String? {
        defaults?.string(forKey: MacSCPSharedConstants.activeProfileNameKey)
    }

    static func setSyncedFolders(_ paths: [String]) {
        defaults?.set(paths, forKey: MacSCPSharedConstants.syncedFoldersKey)
    }

    static func syncedFolders() -> [String] {
        defaults?.stringArray(forKey: MacSCPSharedConstants.syncedFoldersKey) ?? []
    }
}
