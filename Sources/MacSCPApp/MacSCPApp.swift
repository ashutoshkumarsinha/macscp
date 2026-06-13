// MacSCPApp.swift
//
// WHAT THIS FILE DOES
// -------------------
// Application entry point and root navigation. Bootstraps MacSCPLogger, creates AppModel,
// registers MacSCPScriptingController, and hosts SessionLoginView or CommanderView.
//

import MacSCPCore
import SwiftUI

@main
struct MacSCPApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appModel: AppModel

    init() {
        MacSCPLogger.shared.bootstrap()
        let model = AppModel()
        MacSCPScriptingController.appModel = model
        _appModel = State(initialValue: model)
    }

    var body: some Scene {
        // WindowGroup creates a standard macOS document-style window.
        WindowGroup {
            RootView()
                // Inject appModel so any child view can read/update shared state.
                .environment(appModel)
                // Minimum window size so dual panes fit comfortably.
                .frame(minWidth: 960, minHeight: 560)
                .onOpenURL { url in
                    Task { await appModel.handleIncomingURL(url) }
                }
        }
        // Add items to the macOS menu bar (File menu, etc.).
        .commands {
            // Replace the default "New" menu item with our connection action.
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    appModel.showLogin = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("New Tab") {
                    appModel.newTab()
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
            CommandGroup(after: .windowList) {
                Button("Close Tab") {
                    Task { await appModel.closeSelectedTab() }
                }
                .keyboardShortcut("w", modifiers: [.command])
            }
        }
    }
}

// RootView decides which major screen to show based on connection state.
struct RootView: View {
    // Read appModel from the environment (injected above).
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isConnected {
                // Connected: show local + remote file panes.
                CommanderView()
            } else {
                // Not connected: show login / profile editor.
                SessionLoginView()
            }
        }
        // Modal sheet for "New Connection" from the menu.
        .sheet(isPresented: Bindable(appModel).showLogin) {
            SessionLoginView()
        }
    }
}
