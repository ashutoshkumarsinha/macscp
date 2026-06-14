// TransferQueue.swift
//
// WHAT THIS FILE DOES
// -------------------
// Observable queue that schedules, runs, pauses, and tracks upload and download jobs.
// AppModel owns TransferQueue; TransferQueueView binds to its jobs and progress state.
//
import Foundation
import MacSCPCore
import MacSCPBackends

public enum TransferJobState: Equatable, Sendable {
    case queued
    case running
    case paused
    case completed
    case skipped
    case failed(String)
    case cancelled
}

public struct TransferJob: Identifiable, Equatable {
    public let id: UUID
    public let direction: TransferDirection
    public let displayName: String
    public let localURL: URL
    public let remotePath: String
    public var totalBytes: Int64?
    public var transferredBytes: Int64
    public var bytesPerSecond: Double?
    public var state: TransferJobState
    public var overwritePolicy: OverwritePolicy
    public let enqueuedAt: Date

    public init(
        direction: TransferDirection,
        displayName: String,
        localURL: URL,
        remotePath: String,
        totalBytes: Int64? = nil,
        overwritePolicy: OverwritePolicy = .overwrite
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
        self.overwritePolicy = overwritePolicy
        self.enqueuedAt = Date()
    }

    public var progressFraction: Double {
        guard let totalBytes, totalBytes > 0 else { return 0 }
        return min(1, Double(transferredBytes) / Double(totalBytes))
    }

    public var etaSeconds: TimeInterval? {
        guard let totalBytes, let speed = bytesPerSecond, speed > 0 else { return nil }
        let remaining = Double(totalBytes - transferredBytes)
        return remaining / speed
    }
}

@MainActor
@Observable
public final class TransferQueue {
    public private(set) var jobs: [TransferJob] = []
    public var isPaused = false
    public var maxConcurrentTransfers = 2

    private var processingTask: Task<Void, Never>?
    private var runningTasks: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: TransferCancellation] = [:]
    private var uploadBatchGroups: [[UUID]] = []
    private var progressLastReported: [UUID: Date] = [:]
    private weak var backendProvider: (any TransferBackendProvider)?

    private var transferSettings = MacSCPTransferSettings()
    private let progressMinInterval: TimeInterval = 0.1
    public var onQueueIdle: (([TransferJob]) -> Void)?

    public var activeCount: Int {
        jobs.filter {
            switch $0.state {
            case .queued, .running, .paused: true
            default: false
            }
        }.count
    }

    public var hasVisibleJobs: Bool {
        !jobs.isEmpty
    }

    public init() {}

    public func applyTransferSettings(_ settings: MacSCPTransferSettings) {
        transferSettings = settings
        maxConcurrentTransfers = settings.maxConcurrentTransfers
    }

    public func bind(backendProvider: any TransferBackendProvider) {
        self.backendProvider = backendProvider
    }

    public func enqueueUpload(
        localURL: URL,
        remotePath: String,
        totalBytes: Int64?,
        overwritePolicy: OverwritePolicy = .overwrite
    ) {
        jobs.append(
            TransferJob(
                direction: .upload,
                displayName: localURL.lastPathComponent,
                localURL: localURL,
                remotePath: remotePath,
                totalBytes: totalBytes,
                overwritePolicy: overwritePolicy
            )
        )
        kickProcessor()
        MacSCPLogger.shared.info(
            "Enqueued upload \(localURL.lastPathComponent) → \(remotePath)",
            category: .transfer
        )
    }

    public func enqueueUploadBatch(
        items: [(localURL: URL, remotePath: String, totalBytes: Int64?, overwritePolicy: OverwritePolicy)]
    ) {
        guard !items.isEmpty else { return }
        var batchJobIDs: [UUID] = []
        for item in items {
            let job = TransferJob(
                direction: .upload,
                displayName: item.localURL.lastPathComponent,
                localURL: item.localURL,
                remotePath: item.remotePath,
                totalBytes: item.totalBytes,
                overwritePolicy: item.overwritePolicy
            )
            jobs.append(job)
            batchJobIDs.append(job.id)
        }
        uploadBatchGroups.append(batchJobIDs)
        kickProcessor()
        MacSCPLogger.shared.info("Enqueued upload batch (\(items.count) files)", category: .transfer)
    }

    public func enqueueDownload(
        remotePath: String,
        localURL: URL,
        totalBytes: Int64?,
        overwritePolicy: OverwritePolicy = .overwrite
    ) {
        jobs.append(
            TransferJob(
                direction: .download,
                displayName: (remotePath as NSString).lastPathComponent,
                localURL: localURL,
                remotePath: remotePath,
                totalBytes: totalBytes,
                overwritePolicy: overwritePolicy
            )
        )
        kickProcessor()
        MacSCPLogger.shared.info(
            "Enqueued download \(remotePath) → \(localURL.path)",
            category: .transfer
        )
    }

    public func pause() {
        isPaused = true
        MacSCPLogger.shared.info("Transfer queue paused", category: .transfer)
        for (jobID, task) in runningTasks {
            cancellations[jobID]?.cancel()
            task.cancel()
        }
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .paused
        }
    }

    public func resume() {
        isPaused = false
        MacSCPLogger.shared.info("Transfer queue resumed", category: .transfer)
        for index in jobs.indices where jobs[index].state == .paused {
            jobs[index].state = .queued
        }
        kickProcessor()
    }

    public func cancel(jobID: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        switch jobs[index].state {
        case .queued, .paused, .running:
            jobs[index].state = .cancelled
            cancellations[jobID]?.cancel()
            runningTasks[jobID]?.cancel()
            runningTasks[jobID] = nil
            cancellations[jobID] = nil
            uploadBatchGroups.removeAll { $0.contains(jobID) }
            MacSCPLogger.shared.info("Cancelled transfer \(jobs[index].displayName)", category: .transfer)
        default:
            break
        }
    }

    public func handleDisconnect() {
        processingTask?.cancel()
        processingTask = nil
        for (jobID, task) in runningTasks {
            cancellations[jobID]?.cancel()
            task.cancel()
        }
        runningTasks.removeAll()
        cancellations.removeAll()
        uploadBatchGroups.removeAll()
        progressLastReported.removeAll()

        for index in jobs.indices {
            switch jobs[index].state {
            case .running, .paused:
                jobs[index].state = .cancelled
            case .queued:
                jobs[index].state = .failed("Disconnected")
            default:
                break
            }
        }
        MacSCPLogger.shared.info("Transfer queue cleared after disconnect", category: .transfer)
    }

    public func clearFinished() {
        jobs.removeAll { job in
            switch job.state {
            case .completed, .cancelled, .failed, .skipped:
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
                if self.backendProvider?.currentBackend != nil,
                   self.jobs.contains(where: { $0.state == .queued }) {
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

            if let batch = nextReadyUploadBatch() {
                startUploadBatch(jobIDs: batch, backend: backend)
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            let runningCount = jobs.filter { $0.state == .running }.count
            let availableSlots = maxConcurrentTransfers - runningCount
            if availableSlots <= 0 {
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            let indicesToStart = jobs.indices
                .filter { jobs[$0].state == .queued }
                .sorted { lhs, rhs in
                    let leftSize = jobs[lhs].totalBytes ?? Int64.max
                    let rightSize = jobs[rhs].totalBytes ?? Int64.max
                    if leftSize != rightSize { return leftSize < rightSize }
                    return jobs[lhs].enqueuedAt < jobs[rhs].enqueuedAt
                }
                .prefix(availableSlots)
            if indicesToStart.isEmpty {
                if runningCount == 0 {
                    notifyQueueIdleIfNeeded()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }

            for index in indicesToStart {
                jobs[index].state = .running
                let jobID = jobs[index].id
                startJob(jobID: jobID, backend: backend)
            }

            try? await Task.sleep(for: .milliseconds(100))
        }
        notifyQueueIdleIfNeeded()
    }

    private func notifyQueueIdleIfNeeded() {
        guard !jobs.isEmpty else { return }
        guard activeCount == 0 else { return }
        onQueueIdle?(jobs)
    }

    private func nextReadyUploadBatch() -> [UUID]? {
        guard let batch = uploadBatchGroups.first else { return nil }
        let allQueued = batch.allSatisfy { jobID in
            jobs.first(where: { $0.id == jobID })?.state == .queued
        }
        guard allQueued else { return nil }
        uploadBatchGroups.removeFirst()
        return batch
    }

    private func startUploadBatch(jobIDs: [UUID], backend: TransferBackend) {
        for jobID in jobIDs {
            guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
            jobs[index].state = .running
        }

        let cancellation = TransferCancellation()
        let batchKey = jobIDs.first ?? UUID()
        cancellations[batchKey] = cancellation

        runningTasks[batchKey] = Task { [weak self] in
            await self?.runUploadBatch(jobIDs: jobIDs, backend: backend, cancellation: cancellation)
            await MainActor.run {
                self?.runningTasks[batchKey] = nil
                self?.cancellations[batchKey] = nil
                self?.kickProcessor()
            }
        }
    }

    private func runUploadBatch(
        jobIDs: [UUID],
        backend: TransferBackend,
        cancellation: TransferCancellation
    ) async {
        let items: [BatchUploadItem] = jobIDs.compactMap { jobID in
            guard let job = jobs.first(where: { $0.id == jobID }) else { return nil }
            return BatchUploadItem(localURL: job.localURL, remotePath: job.remotePath)
        }

        let overwrite = jobs.first(where: { $0.id == jobIDs[0] })?.overwritePolicy ?? .overwrite
        var options = makeTransferOptions(cancellation: cancellation, overwrite: overwrite)
        options.maxConcurrentUploads = transferSettings.maxConcurrentUploads

        do {
            let results = try await backend.uploadBatch(items: items, options: options)
            for (index, jobID) in jobIDs.enumerated() {
                guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                if jobs[jobIndex].state == .cancelled { continue }
                let result = index < results.count ? results[index] : TransferResult(bytesTransferred: 0)
                jobs[jobIndex].transferredBytes = result.bytesTransferred
                if result.bytesTransferred == 0, jobs[jobIndex].overwritePolicy == .skip {
                    jobs[jobIndex].state = .skipped
                } else {
                    jobs[jobIndex].state = .completed
                    backendProvider?.transferDidComplete(jobID: jobID)
                }
            }
        } catch BackendError.cancelled {
            for jobID in jobIDs { markCancelled(jobID: jobID) }
        } catch is CancellationError {
            for jobID in jobIDs { markCancelled(jobID: jobID) }
        } catch {
            for jobID in jobIDs {
                guard let jobIndex = jobs.firstIndex(where: { $0.id == jobID }) else { continue }
                if jobs[jobIndex].state != .cancelled {
                    jobs[jobIndex].state = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func startJob(jobID: UUID, backend: TransferBackend) {
        let cancellation = TransferCancellation()
        cancellations[jobID] = cancellation

        runningTasks[jobID] = Task { [weak self] in
            await self?.runJob(jobID: jobID, backend: backend, cancellation: cancellation)
            await MainActor.run {
                self?.runningTasks[jobID] = nil
                self?.cancellations[jobID] = nil
                self?.progressLastReported[jobID] = nil
                self?.kickProcessor()
            }
        }
    }

    private func makeTransferOptions(
        cancellation: TransferCancellation,
        overwrite: OverwritePolicy
    ) -> TransferOptions {
        TransferOptions(
            resume: transferSettings.resume,
            overwrite: overwrite,
            checksum: transferSettings.verifyChecksums ? .sha256 : nil,
            chunkSize: transferSettings.chunkSize,
            maxConcurrentUploads: transferSettings.maxConcurrentUploads,
            maxConcurrentWrites: transferSettings.maxConcurrentWrites,
            maxConcurrentReads: transferSettings.maxConcurrentReads,
            cancellation: cancellation,
            verifyChecksum: transferSettings.verifyChecksums,
            useDeltaSync: transferSettings.deltaSync
        )
    }

    private func runJob(
        jobID: UUID,
        backend: TransferBackend,
        cancellation: TransferCancellation
    ) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }

        var options = makeTransferOptions(
            cancellation: cancellation,
            overwrite: jobs[index].overwritePolicy
        )

        options.progress = { [weak self] progress in
            Task { @MainActor in
                guard let self,
                      let idx = self.jobs.firstIndex(where: { $0.id == jobID }) else { return }
                if self.jobs[idx].state == .cancelled { return }

                let now = Date()
                if let last = self.progressLastReported[jobID],
                   now.timeIntervalSince(last) < self.progressMinInterval,
                   progress.transferredBytes != progress.totalBytes {
                    return
                }
                self.progressLastReported[jobID] = now

                self.jobs[idx].transferredBytes = progress.transferredBytes
                self.jobs[idx].totalBytes = progress.totalBytes
                self.jobs[idx].bytesPerSecond = progress.bytesPerSecond
            }
        }

        let direction = jobs[index].direction
        let localURL = jobs[index].localURL
        let remotePath = jobs[index].remotePath
        let displayName = jobs[index].displayName

        MacSCPLogger.shared.info(
            "Starting \(direction == .upload ? "upload" : "download") \(displayName)",
            category: .transfer
        )

        do {
            let result: TransferResult
            switch direction {
            case .upload:
                if options.useDeltaSync {
                    result = try await DeltaSyncEngine.syncUpload(
                        localURL: localURL,
                        remotePath: remotePath,
                        backend: backend,
                        options: options
                    )
                } else {
                    result = try await backend.upload(localURL: localURL, remotePath: remotePath, options: options)
                }
            case .download:
                if options.useDeltaSync {
                    result = try await DeltaSyncEngine.syncDownload(
                        remotePath: remotePath,
                        localURL: localURL,
                        backend: backend,
                        options: options
                    )
                } else {
                    result = try await backend.download(remotePath: remotePath, localURL: localURL, options: options)
                }
            }

            guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if jobs[idx].state == .cancelled { return }
            jobs[idx].transferredBytes = result.bytesTransferred
            if result.bytesTransferred == 0, jobs[idx].overwritePolicy == .skip {
                jobs[idx].state = .skipped
                MacSCPLogger.shared.info("Skipped \(displayName) (overwrite policy)", category: .transfer)
            } else {
                jobs[idx].state = .completed
                MacSCPLogger.shared.info(
                    "Completed \(displayName) (\(result.bytesTransferred) bytes)",
                    category: .transfer
                )
                backendProvider?.transferDidComplete(jobID: jobID)
            }
        } catch BackendError.cancelled {
            markCancelled(jobID: jobID)
            MacSCPLogger.shared.info("Cancelled \(displayName) mid-transfer", category: .transfer)
        } catch is CancellationError {
            markCancelled(jobID: jobID)
            MacSCPLogger.shared.info("Cancelled \(displayName) mid-transfer", category: .transfer)
        } catch {
            guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
            if jobs[idx].state == .cancelled {
                return
            }
            jobs[idx].state = .failed(error.localizedDescription)
            MacSCPLogger.shared.error(error, context: "Transfer failed for \(displayName)", category: .transfer)
        }
    }

    private func markCancelled(jobID: UUID) {
        guard let idx = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        if jobs[idx].state != .cancelled {
            jobs[idx].state = .cancelled
        }
    }
}

@MainActor
public protocol TransferBackendProvider: AnyObject {
    var currentBackend: TransferBackend? { get }
    func transferDidComplete(jobID: UUID)
}
