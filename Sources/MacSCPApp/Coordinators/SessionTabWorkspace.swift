// SessionTabWorkspace.swift
//
// WHAT THIS FILE DOES
// -------------------
// Per-tab workspace bundling session, local, and remote pane coordinators.
// SessionTabWorkspace is the unit AppModel keeps for each open connection tab.
//
import Foundation
import MacSCPCore
import Observation

@MainActor
@Observable
final class SessionTabWorkspace: Identifiable {
    let id = UUID()
    var title: String = "Session"
    let sessionCoordinator = SessionCoordinator()
    let localPane = LocalPaneCoordinator()
    let remotePane = RemotePaneCoordinator()
}
