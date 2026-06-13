import SwiftUI

struct EmbeddedTerminalView: View {
    let host: String
    let port: Int
    let username: String
    @State private var output = ""
    @State private var command = ""
    @State private var isRunning = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Integrated SSH")
                .font(.headline)
            ScrollView {
                Text(output.isEmpty ? "Run a command against the active session." : output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            HStack {
                TextField("Command", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { runCommand() }
                Button(isRunning ? "Running…" : "Run") { runCommand() }
                    .disabled(isRunning || command.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
        .frame(minHeight: 160)
    }

    private func runCommand() {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isRunning = true
        output += "\n$ \(trimmed)\n"
        Task {
            defer { isRunning = false }
            do {
                let result = try await runSSH(trimmed)
                output += result + "\n"
            } catch {
                output += "Error: \(error.localizedDescription)\n"
            }
        }
    }

    private func runSSH(_ remoteCommand: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = [
                "-p", String(port),
                "-o", "BatchMode=yes",
                "-o", "StrictHostKeyChecking=accept-new",
                "\(username)@\(host)",
                remoteCommand,
            ]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? ""
                if process.terminationStatus == 0 {
                    continuation.resume(returning: text)
                } else {
                    continuation.resume(throwing: TerminalRunError.nonZeroExit(text))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }
}

enum TerminalRunError: LocalizedError {
    case nonZeroExit(String)

    var errorDescription: String? {
        switch self {
        case .nonZeroExit(let text): return text.isEmpty ? "SSH command failed" : text
        }
    }
}
