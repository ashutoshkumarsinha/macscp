import SwiftUI

@main
struct MacSCPApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appModel)
                .frame(minWidth: 960, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Connection") {
                    appModel.showLogin = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        Group {
            if appModel.isConnected {
                CommanderView()
            } else {
                SessionLoginView()
            }
        }
        .sheet(isPresented: Bindable(appModel).showLogin) {
            SessionLoginView()
        }
    }
}
