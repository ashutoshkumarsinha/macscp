// OverwritePromptView.swift
//
// WHAT THIS FILE DOES
// -------------------
// SwiftUI sheet for resolving overwrite conflicts before queued transfers run.
// AppModel shows this when TransferQueue collects a PendingTransferBatch.
//
import SwiftUI
import MacSCPUI

struct OverwritePromptView: View {
    let batch: PendingTransferBatch
    let onResolve: (OverwriteBatchAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("File Already Exists")
                .font(.title2.weight(.semibold))

            Text(promptMessage)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if !batch.conflictNames.isEmpty {
                GroupBox {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(batch.conflictNames, id: \.self) { name in
                                Label(name, systemImage: "doc")
                                    .font(.callout)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 120)
                }
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    onResolve(.cancel)
                }
                Spacer()
                Button("Skip Existing") {
                    onResolve(.skipExisting)
                }
                .keyboardShortcut(.defaultAction)
                Button("Rename All") {
                    onResolve(.renameAll)
                }
                Button("Overwrite All") {
                    onResolve(.overwriteAll)
                }
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private var promptMessage: String {
        let count = batch.conflictNames.count
        let noun = count == 1 ? "file already exists" : "\(count) files already exist"
        switch batch.kind {
        case .upload:
            return "The destination remote folder contains \(noun) with the same name(s). How should MacSCP proceed?"
        case .download:
            return "The destination local folder contains \(noun) with the same name(s). How should MacSCP proceed?"
        }
    }
}
