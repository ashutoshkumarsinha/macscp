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
