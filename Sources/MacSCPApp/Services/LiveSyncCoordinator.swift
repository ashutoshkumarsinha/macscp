// LiveSyncCoordinator.swift — FSEvents watch on local folder → debounced upload queue.

import CoreServices
import Foundation
import MacSCPCore

@MainActor
final class LiveSyncCoordinator {
    private var stream: FSEventStreamRef?
    private var debounceTask: Task<Void, Never>?
    private var localRoot: URL?
    private var remoteRoot: String = "/"
    private weak var transferCoordinator: TransferCoordinator?

    func start(
        localRoot: URL,
        remoteRoot: String,
        transferCoordinator: TransferCoordinator,
        onStatus: (String) -> Void
    ) {
        stop()
        self.localRoot = localRoot
        self.remoteRoot = remoteRoot
        self.transferCoordinator = transferCoordinator

        let path = localRoot.path as CFString
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        stream = FSEventStreamCreate(
            nil,
            { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let coordinator = Unmanaged<LiveSyncCoordinator>.fromOpaque(info).takeUnretainedValue()
                Task { @MainActor in
                    coordinator.scheduleUpload(paths: eventPaths, count: numEvents)
                }
            },
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5,
            UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes)
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
            onStatus("Live sync watching \(localRoot.path)")
        }
    }

    func stop() {
        debounceTask?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        localRoot = nil
        transferCoordinator = nil
    }

    private func scheduleUpload(paths: UnsafeMutableRawPointer, count: Int) {
        debounceTask?.cancel()
        debounceTask = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let localRoot, let transferCoordinator else { return }
            do {
                let files = try DirectoryTransferPlanner.expandLocalDirectory(at: localRoot, remoteBase: remoteRoot)
                transferCoordinator.enqueueSyncUpload(files: files)
            } catch {
                // Ignore scan errors during live sync bursts.
            }
        }
    }
}
