// TransferNotificationService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Optional Notification Center alert when the transfer queue finishes. AppModel requests
// authorization and notifies with failed/completed counts after the queue drains.
//

import Foundation
import UserNotifications

enum TransferNotificationService {
    static func requestAuthorizationIfNeeded() async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    static func notifyQueueComplete(failedCount: Int, completedCount: Int) async {
        let content = UNMutableNotificationContent()
        if failedCount > 0 {
            content.title = "MacSCP transfers finished with errors"
            content.body = "\(completedCount) completed, \(failedCount) failed."
        } else {
            content.title = "MacSCP transfers complete"
            content.body = "\(completedCount) file(s) transferred."
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "macscp.queue.complete.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}
