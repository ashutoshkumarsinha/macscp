import SwiftUI
import MacSCPUI

struct TransferQueueView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var queue = appModel.transferQueue

        VStack(spacing: 0) {
            HStack {
                Label("Transfers", systemImage: "arrow.up.arrow.down")
                    .font(.caption.weight(.semibold))
                Spacer()
                if queue.activeCount > 0 {
                    Text("\(queue.activeCount) active")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if queue.isPaused {
                    Button("Resume") { queue.resume() }
                        .controlSize(.small)
                } else if queue.hasVisibleJobs {
                    Button("Pause") { queue.pause() }
                        .controlSize(.small)
                }
                Button("Clear Done") { queue.clearFinished() }
                    .controlSize(.small)
                    .disabled(!queue.jobs.contains {
                        switch $0.state {
                        case .completed, .cancelled, .failed, .skipped: true
                        default: false
                        }
                    })
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            if queue.jobs.isEmpty {
                Text("No transfers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            } else {
                List(queue.jobs) { job in
                    TransferJobRow(job: job) {
                        queue.cancel(jobID: job.id)
                    }
                }
                .listStyle(.plain)
                .frame(maxHeight: 140)
            }
        }
        .background(.bar)
    }
}

private struct TransferJobRow: View {
    let job: TransferJob
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: job.direction == .upload ? "arrow.up.circle" : "arrow.down.circle")
                    .foregroundStyle(job.direction == .upload ? .blue : .green)
                Text(job.displayName)
                    .lineLimit(1)
                Spacer()
                statusLabel
                if canCancel {
                    Button("", systemImage: "xmark.circle") { onCancel() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            if showsProgress {
                ProgressView(value: job.progressFraction)
                    .progressViewStyle(.linear)
                HStack {
                    Text(byteProgress)
                    Spacer()
                    if let speed = job.bytesPerSecond {
                        Text(formatSpeed(speed))
                    }
                    if let eta = job.etaSeconds {
                        Text("ETA \(formatETA(eta))")
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private var showsProgress: Bool {
        switch job.state {
        case .running, .paused, .completed:
            return job.totalBytes != nil
        default:
            return false
        }
    }

    private var canCancel: Bool {
        switch job.state {
        case .queued, .running, .paused:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch job.state {
        case .queued:
            Text("Queued").font(.caption).foregroundStyle(.secondary)
        case .running:
            Text("Running").font(.caption).foregroundStyle(.blue)
        case .paused:
            Text("Paused").font(.caption).foregroundStyle(.orange)
        case .completed:
            Text("Done").font(.caption).foregroundStyle(.green)
        case .skipped:
            Text("Skipped").font(.caption).foregroundStyle(.secondary)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case let .failed(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    private var byteProgress: String {
        let transferred = ByteCountFormatter.string(fromByteCount: job.transferredBytes, countStyle: .file)
        if let total = job.totalBytes {
            let totalStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(transferred) / \(totalStr)"
        }
        return transferred
    }

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file)
        return "\(formatted)/s"
    }

    private func formatETA(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(Int(seconds))s" }
        return "\(Int(seconds / 60))m \(Int(seconds) % 60)s"
    }
}
