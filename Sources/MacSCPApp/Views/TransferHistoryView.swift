// TransferHistoryView.swift — Optional local transfer log browser.

import SwiftUI
import MacSCPCore

struct TransferHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [TransferHistoryEntry] = []
    @State private var errorMessage: String?

    private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transfer History")
                    .font(.title2)
                Spacer()
                Button("Refresh") { reload() }
                Button("Done") { dismiss() }
            }
            if let errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
            if entries.isEmpty {
                ContentUnavailableView(
                    "No transfers recorded",
                    systemImage: "clock.arrow.circlepath",
                    description: Text("Enable transfer history in session settings or config.toml.")
                )
            } else {
                Table(entries) {
                    TableColumn("When") { entry in
                        Text(entry.timestamp.formatted(date: .abbreviated, time: .standard))
                    }
                    TableColumn("Session") { entry in
                        Text(entry.sessionName)
                    }
                    TableColumn("Direction") { entry in
                        Text(entry.direction.rawValue.capitalized)
                    }
                    TableColumn("Local") { entry in
                        Text(entry.localPath).lineLimit(1)
                    }
                    TableColumn("Remote") { entry in
                        Text(entry.remotePath).lineLimit(1)
                    }
                    TableColumn("Bytes") { entry in
                        Text(ByteCountFormatter.string(fromByteCount: entry.bytesTransferred, countStyle: .file))
                    }
                }
            }
        }
        .padding()
        .frame(minWidth: 720, minHeight: 420)
        .onAppear { reload() }
    }

    private func reload() {
        do {
            entries = try TransferHistoryStore.load(homeDirectory: homeDirectory)
                .sorted { $0.timestamp > $1.timestamp }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
