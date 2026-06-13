// AppLockService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Optional Touch ID / device authentication before revealing sessions. MacSCPApp checks
// isEnabled and authenticate() when the user opens a saved profile or commander UI.
//

import Foundation
import LocalAuthentication

enum AppLockService {
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "macscp.touchIDLock")
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "macscp.touchIDLock")
    }

    static func authenticate(reason: String = "Unlock MacSCP") async -> Bool {
        guard isEnabled else { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
                ? (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
                : true
        }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) ?? false
    }
}
