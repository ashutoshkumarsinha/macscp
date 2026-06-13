import Foundation
import MacSCPCore

enum TransferJobState: Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case failed(String)
    case cancelled
}

struct TransferJob: Identifiable, Equatable {
    let id: UUID
    let direction: TransferDirection
    let displayName: String
    let localURL: URL
    let remotePath: String
    var totalBytes: Int64?
    var transferredBytes: Int64
    var bytesPerSecond: Double?
    var state: TransferJobState
    let enqueuedAt: Date

    init(
        direction: TransferDirection,
        displayName: String,
        localURL: URL,
        remotePath: String,
        totalBytes: Int64? = nil
    ) {
        self.id = UUID()
        self.direction = direction
        self.displayName = displayName
        self.localURL = localURL
        self.remotePath = remotePath
        self.totalBytes = totalBytes
        self.transferredBytes = 0
        self.bytesPerSecond = nil
        self.state = .queued
        self.enqueuedAt = Date()
    }

    var progressFraction: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    var etaSeconds: TimeInterval? {
        guard let totalBytes, let speed = bytesPerSecond, speed > 0 else { return nil }
        let remaining = Double(totalBytes - transferredBytes)
        return remaining / speed
    }
}

@MainActor
@Observable
final class TransferQueue {
    private(set) var jobs: [TransferJob] = []
    var isPaused = false
    var maxConcurrentTransfers = 2

    private var processingTask: Task<Void, Never>?
    private weak var backendProvider: (any TransferBackendProvider)?

    var activeCount: Int {
        jobs.filter {
            switch $0.state {
            case .queued, .running, .paused: true
            default: false
            }
        }.count
    }

    var hasVisibleJobs: Bool {
        !jobs.isEmpty
    }

    func bind(backendProvider: any TransferBackendProvider) {
        self.backendProvider = backendProvider
    }

    func enqueueUpload(localURL: URL, remotePath: String, totalBytes: Int64?) {
        jobs.append(
            TransferJob(
                direction: .upload,
                displayName: localURL.lastPathComponent,
                localURL: localURL,
                remotePath: remotePath,
                totalBytes: totalBytes
            )
        )
        kickProcessor()
    }

    func enqueueDownload(remotePath: String, localURL: URL, totalBytes: Int64?) {
        jobs.append(
            TransferJob(
                direction: .download,
                displayName: (remotePath as NSString).lastPathComponent,
                localURL: localURL,
                remotePath: remotePath,
                totalBytes: totalBytes
            )
        )
        kickProcessor()
    }

    func pause() {
        isPaused = true
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .paused
        }
    }

    func resume() {
        isPaused = false
        for index in jobs.indices where jobs[index].state == .paused {
            jobs[index].state = .queued
        }
        kickProcessor()
    }

    func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].state {
        case .queued, .paused, .running:
            jobs[index].state = .cancelled
        default:
            break
        }
    }

    func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .completed, .cancelled, .failed:
                return true
            default:
                return false
            }
        }
    }

    private func kickProcessor() {
        guard processingTask == nil else { return }
        processingTask = Task { [weak self] in
            await self?.processLoop()
            await MainActor.run {
                guard let self else { return }
                self.processingTask = nil
                if self.jobs.contains(where: { $0.state == .queued }) {
                    self.kickProcessor()
                }
            }
        }
    }

    private func processLoop() async {
        while jobs.contains(where: { $0.state == .queued || $0.state == .running }) {
            if Task.isCancelled { return }

            if isPaused {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }

            guard let backendProvider, let backend = backendProvider.currentBackend else {
                return
            }

            let runningCount = jobs.filter { $0.state == .running }.count
            let availableSlots = maxConcurrentTransfers - runningCount
            if availableSlots <= 0 {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            let indicesToStart = jobs.indices.filter { jobs[$0].state == .queued }.prefix(availableSlots)
            if indicesToStart.isEmpty {
                if runningCount == 0 { return }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            for index in indicesToStart {
                jobs[index].state = .running
                let jobID = jobs[index].id
                Task { [weak self] in
                    await self?.runJob(jobID: jobID, backend: backend)
                }
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runJob(jobID: UUID, backend: TransferBackend) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        var options = TransferOptions(
            resume: true,
            overwrite: .overwrite,
            checksum: nil,
            maxConcurrentWrites: 8
        )

        options.progress = { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      let idx = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                if self.jobs[idx].state == .cancelled { return }
                self.jobs[idx].transferredBytes = progress.transferredBytes
                self.jobs[idx].totalBytes = progress.totalBytes
                self.jobs[idx].bytesPerSecond = progress.bytesPerSecond
            }
        }

        let direction = jobs[index].direction
        let localURL = jobs[index].localURL
        let remotePath = jobs[index].remotePath

        do {
            let result: TransferResult
            switch direction {
            case .upload:
                result = try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
            case .download:
                result = try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
            }

            guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if jobs[idx].state == .cancelled { return }
            jobs[idx].transferredBytes = result.bytesTransferred
            jobs[idx].state = .completed
            backendProvider?.transferDidComplete(jobID: jobID)
        } catch {
            guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if jobs[idx].state == .cancelled { return }
            jobs[idx].state = .failed(error.localizedDescription)
        }

        kickProcessor()
    }
}

@MainActor
protocol TransferBackendProvider: AnyObject {
    var currentBackend: TransferBackend? { get }
    func transferDidComplete(jobID: UUID)
}
