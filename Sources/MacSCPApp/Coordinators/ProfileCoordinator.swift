// ProfileCoordinator.swift — Saved session profiles and login draft editing.
//
// Loads profiles.json, migrates legacy plaintext passwords to Keychain, and
// exposes SessionProfileDraft for SessionLoginView.

import Foundation
import MacSCPCore
import Observation

@MainActor
@Observable
final class ProfileCoordinator {
    var profiles: [SessionProfile] = []
    var selectedProfileID: UUID?
    var draft = SessionProfileDraft()

    private let profileStore = ProfileStore()

    /// Called by AppModel to update the status bar after save/delete/load errors.
    var onStatusMessage: ((String) -> Void)?

    init() {
        do {
            profiles = try profileStore.load()
        } catch {
            profiles = []
            onStatusMessage?("Failed to load profiles: \(error.localizedDescription)")
            MacSCPLogger.shared.error(error, context: "Profile load failed", category: .app)
        }

        if profiles.isEmpty {
            profiles = SessionProfile.sampleProfiles
        }
        selectedProfileID = profiles.first?.id
        syncDraftFromSelection()
    }

    func syncDraftFromSelection() {
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        draft = SessionProfileDraft(from: profile)
    }

    func selectProfile(_ id: UUID) {
        selectedProfileID = id
        syncDraftFromSelection()
    }

    func deleteProfile(id: UUID) {
        profileStore.deleteCredentials(profileID: id)
        profiles.removeAll { $0.id == id }
        selectedProfileID = profiles.first?.id
        syncDraftFromSelection()
        do {
            try profileStore.save(profiles)
            onStatusMessage?("Deleted profile")
            MacSCPLogger.shared.info("Deleted profile \(id)", category: .session)
        } catch {
            onStatusMessage?("Failed to save profiles: \(error.localizedDescription)")
            MacSCPLogger.shared.error(error, context: "Profile delete save failed", category: .session)
        }
    }

    func saveDraftAsProfile() -> Bool {
        guard draft.validatePort() else {
            onStatusMessage?("Invalid port (use 1–65535)")
            return false
        }

        let profile = draft.toProfile(existingID: selectedProfileID)
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        selectedProfileID = profile.id
        do {
            try profileStore.save(profiles)
            onStatusMessage?("Saved profile \"\(profile.name)\"")
            MacSCPLogger.shared.info("Saved profile \"\(profile.name)\" (\(profile.host))", category: .session)
            return true
        } catch {
            onStatusMessage?("Failed to save profile: \(error.localizedDescription)")
            MacSCPLogger.shared.error(error, context: "Profile save failed", category: .session)
            return false
        }
    }
}
