// InternalEditorView.swift — In-app text editor for remote files (download → edit → upload).

import SwiftUI

struct InternalEditorView: View {
    let fileName: String
    @Binding var text: String
    @Binding var encoding: TextFileEncoding
    @Binding var lineEnding: TextLineEnding
    var isSaving: Bool
    var errorMessage: String?
    let onSave: () -> Void
    let onSaveAnyway: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("Encoding", selection: $encoding) {
                    ForEach(TextFileEncoding.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(maxWidth: 220)

                Picker("Line Endings", selection: $lineEnding) {
                    ForEach(TextLineEnding.allCases) { option in
                        Text(option.rawValue).tag(option)
                    }
                }
                .frame(maxWidth: 220)

                Spacer()

                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)

                if errorMessage != nil {
                    Button("Save Anyway") { onSaveAnyway() }
                        .disabled(isSaving)
                }

                Button(isSaving ? "Saving…" : "Save") { onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
            }
            .padding()

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
            }

            Divider()

            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .padding(8)
        }
        .frame(minWidth: 720, minHeight: 520)
        .navigationTitle(fileName)
    }
}
