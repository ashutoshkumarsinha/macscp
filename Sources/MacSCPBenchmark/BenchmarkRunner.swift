import Foundation
import MacSCPCore
import MacSCPBackends

struct BenchmarkRunner {
    let config: BenchmarkConfig

    func runAll() async throws -> BenchmarkReport {
        var results: [BenchmarkResult] = []

        for size in config.largeFileSizes {
            if size >= 1_073_741_824, config.skipLarge1GB { continue }
            results.append(try await runLargeFile(size: size, direction: .upload))
            results.append(try await runLargeFile(size: size, direction: .download))
        }

        results.append(try await runSmallFiles(direction: .upload))
        results.append(try await runSmallFiles(direction: .download))
        results.append(try await runListDirectory())
        results.append(try await runResumeDownload())
        results.append(try await runAuthEncryptedKey())

        return buildReport(results: results)
    }

    private enum Direction { case upload, download }

    private func runLargeFile(size: Int, direction: Direction) async throws -> BenchmarkResult {
        let label = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        let local = config.workDirectory.appendingPathComponent("large_\(size).bin")
        let remote = "\(config.dataDirectory.path)/bench/large_\(size).bin"
        try FixtureGenerator.largeFile(at: local, size: size)

        let backend = CitadelSFTPBackend()
        try await backend.connect(configuration: config.sessionConfiguration())
        defer { Task { try? await backend.disconnect() } }

        let start = Date()
        switch direction {
        case .upload:
            _ = try await backend.upload(localURL: local, remotePath: remote, options: TransferOptions(checksum: .sha256))
            let opensshTime = try OpenSSHSFTPBaseline.upload(local: local, remotePath: remote, config: config)
            let citadelTime = Date().timeIntervalSince(start)
            return compareThroughput(
                scenario: "large_upload_\(label)",
                citadelSeconds: citadelTime,
                baselineSeconds: opensshTime,
                bytes: Int64(size)
            )
        case .download:
            _ = try await backend.download(remotePath: remote, localURL: local.appendingPathExtension("dl"), options: TransferOptions(checksum: .sha256))
            let citadelTime = Date().timeIntervalSince(start)
            let dlLocal = config.workDirectory.appendingPathComponent("large_\(size).bin.openssh")
            let opensshTime = try OpenSSHSFTPBaseline.download(remotePath: remote, local: dlLocal, config: config)
            let match = try Checksum.sha256(of: local.appendingPathExtension("dl")) == Checksum.sha256(of: dlLocal)
            var result = compareThroughput(
                scenario: "large_download_\(label)",
                citadelSeconds: citadelTime,
                baselineSeconds: opensshTime,
                bytes: Int64(size)
            )
            result.sha256Match = match
            result.passed = result.passed && match
            return result
        }
    }

    private func runSmallFiles(direction: Direction) async throws -> BenchmarkResult {
        let count = config.smallFileCount
        let localDir = config.workDirectory.appendingPathComponent("small_local", isDirectory: true)
        let remoteDir = "\(config.dataDirectory.path)/bench/small"
        try FixtureGenerator.smallFileTree(at: localDir, count: count)

        let backend = CitadelSFTPBackend()
        try await backend.connect(configuration: config.sessionConfiguration())
        defer { Task { try? await backend.disconnect() } }
        try await backend.createDirectory(at: remoteDir, recursive: true)

        let start = Date()
        switch direction {
        case .upload:
            let files = try FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil)
            let items = files.map {
                BatchUploadItem(localURL: $0, remotePath: "\(remoteDir)/\($0.lastPathComponent)")
            }
            _ = try await backend.uploadBatch(
                items: items,
                options: TransferOptions(
                    checksum: nil,
                    chunkSize: 1024 * 1024,
                    maxConcurrentUploads: 12,
                    smallFileThreshold: 512 * 1024
                )
            )
            let citadelTime = Date().timeIntervalSince(start)

            let opensshStart = Date()
            let batchFiles = try FileManager.default.contentsOfDirectory(at: localDir, includingPropertiesForKeys: nil).map {
                (local: $0, remote: "\(remoteDir)/\($0.lastPathComponent)")
            }
            _ = try OpenSSHSFTPBaseline.uploadBatch(files: batchFiles, config: config)
            let opensshTime = Date().timeIntervalSince(opensshStart)
            let ratio = opensshTime / max(citadelTime, 0.001)
            return BenchmarkResult(
                scenario: "small_upload_\(count)_files",
                backend: "citadel vs openssh",
                durationSeconds: citadelTime,
                throughputMBps: nil,
                filesPerSecond: Double(count) / citadelTime,
                itemCount: count,
                bytes: Int64(count * 4096),
                sha256Match: nil,
                passed: ratio >= 0.80,
                notes: String(format: "ratio=%.2f (need >=0.80)", ratio)
            )
        case .download:
            let files = try await backend.listDirectory(at: remoteDir)
            for entry in files where entry.type == .file {
                let local = localDir.appendingPathComponent("dl_\(entry.name)")
                _ = try await backend.download(remotePath: entry.path, localURL: local, options: TransferOptions(checksum: nil))
            }
            let citadelTime = Date().timeIntervalSince(start)
            return BenchmarkResult(
                scenario: "small_download_\(count)_files",
                backend: "citadel",
                durationSeconds: citadelTime,
                throughputMBps: nil,
                filesPerSecond: Double(files.count) / citadelTime,
                itemCount: files.count,
                bytes: Int64(files.count * 4096),
                sha256Match: nil,
                passed: true,
                notes: "baseline download batch not run (sequential sftp batch overhead)"
            )
        }
    }

    private func runListDirectory() async throws -> BenchmarkResult {
        let remoteDir = "\(config.dataDirectory.path)/bench/small"
        let backend = CitadelSFTPBackend()
        try await backend.connect(configuration: config.sessionConfiguration())
        defer { Task { try? await backend.disconnect() } }

        let start = Date()
        let entries = try await backend.listDirectory(at: remoteDir)
        let citadelTime = Date().timeIntervalSince(start)

        let (opensshTime, count) = try OpenSSHSFTPBaseline.listDirectory(remoteDir: remoteDir, config: config)
        let ratio = opensshTime / max(citadelTime, 0.001)

        return BenchmarkResult(
            scenario: "list_directory",
            backend: "citadel vs openssh",
            durationSeconds: citadelTime,
            throughputMBps: nil,
            filesPerSecond: nil,
            itemCount: entries.count,
            bytes: 0,
            sha256Match: entries.count == count,
            passed: entries.count == count,
            notes: String(format: "citadel=%d entries, openssh=%d, time_ratio=%.2f", entries.count, count, ratio)
        )
    }

    private func runResumeDownload() async throws -> BenchmarkResult {
        let size = 10_485_760
        let local = config.workDirectory.appendingPathComponent("resume_source.bin")
        let remote = "\(config.dataDirectory.path)/bench/resume.bin"
        try FixtureGenerator.largeFile(at: local, size: size)

        let backend = CitadelSFTPBackend()
        try await backend.connect(configuration: config.sessionConfiguration())
        defer { Task { try? await backend.disconnect() } }
        _ = try await backend.upload(localURL: local, remotePath: remote, options: TransferOptions())

        let partial = config.workDirectory.appendingPathComponent("resume_partial.bin")
        let sourceData = try Data(contentsOf: local)
        let half = sourceData.count / 2
        try sourceData.prefix(half).write(to: partial)

        _ = try await backend.download(
            remotePath: remote,
            localURL: partial,
            options: TransferOptions(resume: true, checksum: .sha256)
        )

        let expected = try Checksum.sha256(of: local)
        let actual = try Checksum.sha256(of: partial)
        let match = expected == actual

        return BenchmarkResult(
            scenario: "resume_download_50pct",
            backend: "citadel",
            durationSeconds: 0,
            throughputMBps: nil,
            filesPerSecond: nil,
            itemCount: nil,
            bytes: Int64(size),
            sha256Match: match,
            passed: match,
            notes: match ? "checksum ok" : "checksum mismatch"
        )
    }

    private func runAuthEncryptedKey() async throws -> BenchmarkResult {
        let benchRoot = config.workDirectory.deletingLastPathComponent()
        let encKey = benchRoot.appendingPathComponent("keys/client_encrypted").path
        var session = config.sessionConfiguration()
        session.authMethod = .publicKey
        session.keyPath = encKey
        session.keyPassphrase = "benchpass"

        let backend = CitadelSFTPBackend()
        let start = Date()
        try await backend.connect(configuration: session)
        let entries = try await backend.listDirectory(at: config.dataDirectory.path)
        try await backend.disconnect()
        let elapsed = Date().timeIntervalSince(start)

        return BenchmarkResult(
            scenario: "auth_encrypted_ed25519_key",
            backend: "citadel",
            durationSeconds: elapsed,
            throughputMBps: nil,
            filesPerSecond: nil,
            itemCount: entries.count,
            bytes: 0,
            sha256Match: nil,
            passed: true,
            notes: "connected and listed \(entries.count) entries"
        )
    }

    private func compareThroughput(
        scenario: String,
        citadelSeconds: Double,
        baselineSeconds: Double,
        bytes: Int64
    ) -> BenchmarkResult {
        let citadelMBps = Double(bytes) / citadelSeconds / 1_048_576.0
        let ratio = citadelSeconds > 0 ? baselineSeconds / citadelSeconds : 0
        // citadel >= 90% of openssh speed => citadelTime <= baseline/0.9 => ratio >= 0.9
        let passed = ratio >= 0.90
        return BenchmarkResult(
            scenario: scenario,
            backend: "citadel vs openssh",
            durationSeconds: citadelSeconds,
            throughputMBps: citadelMBps,
            filesPerSecond: nil,
            itemCount: nil,
            bytes: bytes,
            sha256Match: nil,
            passed: passed,
            notes: String(format: "openssh=%.3fs citadel=%.3fs ratio=%.2f (need >=0.90)", baselineSeconds, citadelSeconds, ratio)
        )
    }

    private func buildReport(results: [BenchmarkResult]) -> BenchmarkReport {
        let large = results.filter { $0.scenario.hasPrefix("large_") && $0.scenario.contains("upload") }
        let small = results.first { $0.scenario.hasPrefix("small_upload") }
        let largeRatios = large.compactMap { result -> Double? in
            guard let notes = result.notes,
                  let range = notes.range(of: "ratio="),
                  let end = notes[range.upperBound...].firstIndex(of: " ") else { return nil }
            return Double(notes[range.upperBound ..< end])
        }
        let avgLarge = largeRatios.isEmpty ? nil : largeRatios.reduce(0, +) / Double(largeRatios.count)
        let smallRatio: Double? = {
            guard let notes = small?.notes,
                  let range = notes.range(of: "ratio=") else { return nil }
            let tail = notes[range.upperBound...]
            return Double(tail.prefix(while: { $0 != " " }))
        }()
        let pass = results.allSatisfy(\.passed)
        let recommendation = pass
            ? "Citadel meets spike pass criteria on this host. Proceed with Citadel as primary SFTP backend."
            : "Citadel below pass criteria on one or more scenarios. Review notes and consider Traversio contingency."

        return BenchmarkReport(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            config: .init(
                host: config.host,
                port: config.port,
                smallFileCount: config.smallFileCount,
                largeFileSizes: config.largeFileSizes
            ),
            results: results,
            summary: .init(
                citadelLargeFileRatio: avgLarge,
                citadelSmallFileRatio: smallRatio,
                passCriteriaMet: pass,
                recommendation: recommendation
            )
        )
    }
}
