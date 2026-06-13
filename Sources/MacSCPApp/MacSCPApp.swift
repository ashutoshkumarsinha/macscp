// MacSCPApp.swift — Application entry point and root navigation.

import MacSCPCore
import SwiftUI

@main
struct MacSCPApp: App {
    @State private var appModel: AppModel

    init() {
        MacSCPLogger.shared.bootstrap()
        _appModel = State(initialValue: AppModel())
    }

    var body: some Scene {
        // WindowGroup creates a standard macOS document-style window.
        WindowGroup {
            RootView()
                // Inject appModel so any child view can read/update shared state.
                .environment(appModel)
                // Minimum window size so dual panes fit comfortably.
                .frame(minWidth: 960, minHeight: 560)
        }
        // Add items to the macOS menu bar (File menu, etc.).
        .commands {
            // Replace the default "New" menu item with our connection action.
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    // Show the login sheet even if already connected.
                    appModel.showLogin = true
                }
                // Keyboard shortcut: Shift+Command+N
                .keyboardShortcut("n", modifiers: [.command, .shift])
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
