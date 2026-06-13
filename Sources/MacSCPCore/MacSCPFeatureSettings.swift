// MacSCPFeatureSettings.swift
//
// WHAT THIS FILE DOES
// -------------------
// User-facing feature toggles: history, notifications, iCloud sync, and UI layout mode.
// MacSCPConfiguration loads and persists these alongside transfer settings.
//
import Foundation

public struct MacSCPFeatureSettings: Sendable, Equatable {
    public var transferHistoryEnabled: Bool
    public var notifyOnQueueComplete: Bool
    public var iCloudProfileSyncEnabled: Bool
    public var uiLayoutMode: UILayoutMode

    public init(
        transferHistoryEnabled: Bool = false,
        notifyOnQueueComplete: Bool = false,
        iCloudProfileSyncEnabled: Bool = false,
        uiLayoutMode: UILayoutMode = .commander
    ) {
        self.transferHistoryEnabled = transferHistoryEnabled
        self.notifyOnQueueComplete = notifyOnQueueComplete
        self.iCloudProfileSyncEnabled = iCloudProfileSyncEnabled
        self.uiLayoutMode = uiLayoutMode
    }
}

public enum MacSCPSharedConstants {
    public static let appGroupID = "group.com.macscp.app"
    public static let syncedFoldersKey = "syncedFolders"
    public static let activeProfileNameKey = "activeProfileName"
    public static let iCloudContainerID = "iCloud.com.macscp.app"
}
