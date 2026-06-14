// TabPersistenceStore.swift
//
// WHAT THIS FILE DOES
// -------------------
// Saves and restores tab layout (titles and pane paths) across app relaunch.
// Does not auto-reconnect sessions — only restores browsing context per tab.
//
import Foundation
import MacSCPCore

struct SavedTabState: Codable, Equatable {
    var id: UUID
    var title: String
    var localPath: String
    var remotePath: String
}

enum TabPersistenceStore {
    private static let key = "macscp.tabs.state"

    static func load() -> (tabs: [SavedTabState], selectedID: UUID?)? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        struct Payload: Codable {
            var tabs: [SavedTabState]
            var selectedID: UUID?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data), !payload.tabs.isEmpty else {
            return nil
        }
        return (payload.tabs, payload.selectedID)
    }

    static func save(tabs: [SavedTabState], selectedID: UUID?) {
        struct Payload: Codable {
            var tabs: [SavedTabState]
            var selectedID: UUID?
        }
        let payload = Payload(tabs: tabs, selectedID: selectedID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}
