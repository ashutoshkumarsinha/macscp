// HostKeyPromptView.swift
//
// WHAT THIS FILE DOES
// -------------------
// Modal prompt when an unknown SSH host key must be trusted or rejected.
// HostKeyTrustGate presents this view for interactive host-key verification.
//
import MacSCPCore
import SwiftUI

struct HostKeyPromptView: View {
    let request: HostKeyTrustRequest
    let onTrust: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(
                request.isKeyChange ? "Host Key Changed" : "Unknown Host Key",
                systemImage: request.isKeyChange ? "exclamationmark.triangle.fill" : "key.fill"
            )
            .font(.title3.weight(.semibold))
            .foregroundStyle(request.isKeyChange ? .orange : .primary)

            Text(message)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox("Server") {
                LabeledContent("Endpoint", value: request.endpoint)
                LabeledContent("SHA-256") {
                    Text(request.fingerprintSHA256)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                if let stored = request.storedFingerprint {
                    LabeledContent("Previously trusted") {
                        Text(stored)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reject", role: .cancel, action: onReject)
                Button(request.isKeyChange ? "Trust New Key" : "Trust and Connect", action: onTrust)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }

    private var message: String {
        if request.isKeyChange {
            return "The host key for this server has changed. This may indicate a security issue, or the server was reinstalled. Only continue if you expect this change."
        }
        return "MacSCP has not connected to this server before. Verify the fingerprint with your administrator, then trust the key to continue."
    }
}
