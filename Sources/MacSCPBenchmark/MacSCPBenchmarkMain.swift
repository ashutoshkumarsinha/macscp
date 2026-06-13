import ArgumentParser
import Foundation

@main
struct MacSCPBenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "macscp-benchmark",
        abstract: "Run MacSCP SFTP backend spike benchmarks (spec §5).",
        subcommands: [UploadSpike.self]
    )

    @Flag(name: .long, help: "Use full file sizes (1 MB, 100 MB, 1 GB) and 10k small files.")
    var full: Bool = false

    @Option(name: .long, help: "Write JSON report to path.")
    var output: String?

    mutating func run() async throws {
        if full {
            setenv("MACSCP_BENCH_FULL", "1", 1)
        }

        let config = try BenchmarkConfig.fromEnvironment()
        print("MacSCP SFTP Benchmark")
        print("  Host: \(config.host):\(config.port)")
        print("  User: \(config.username)")
        print("  Small files: \(config.smallFileCount)")
        print("  Large sizes: \(config.largeFileSizes.map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }.joined(separator: ", "))")
        print()

        let runner = BenchmarkRunner(config: config)
        let report = try await runner.runAll()

        for result in report.results {
            let status = result.passed ? "PASS" : "FAIL"
            var line = "[\(status)] \(result.scenario): \(String(format: "%.3f", result.durationSeconds))s"
            if let mbps = result.throughputMBps {
                line += String(format: " (%.1f MB/s)", mbps)
            }
            if let notes = result.notes {
                line += " — \(notes)"
            }
            print(line)
        }

        print()
        print("Summary: passCriteriaMet=\(report.summary.passCriteriaMet)")
        if let large = report.summary.citadelLargeFileRatio {
            print(String(format: "  Avg large-file ratio vs OpenSSH: %.2f (target >= 0.90)", large))
        }
        if let small = report.summary.citadelSmallFileRatio {
            print(String(format: "  Small-file ratio vs OpenSSH: %.2f (target >= 0.80)", small))
        }
        print("  \(report.summary.recommendation)")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)

        let outPath = output ?? ".benchmark/benchmark-results/report.json"
        let outURL = URL(fileURLWithPath: outPath, isDirectory: false)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outURL)
        print()
        print("Report written to \(outURL.path)")
    }
}

struct UploadSpike: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "upload-spike",
        abstract: "Compare Citadel vs Traversio vs OpenSSH on upload scenarios only."
    )

    @Option(name: .long, help: "Write JSON report to path.")
    var output: String?

    mutating func run() async throws {
        let config = try BenchmarkConfig.fromEnvironment()
        print("MacSCP Upload Spike (Citadel vs Traversio vs OpenSSH)")
        print("  Host: \(config.host):\(config.port)")
        print()

        let report = try await UploadSpikeRunner(config: config).run()
        for result in report.results {
            var line = "[\(result.backend)] \(result.scenario): \(String(format: "%.3f", result.durationSeconds))s"
            if let mbps = result.throughputMBps {
                line += String(format: " (%.1f MB/s)", mbps)
            }
            if let notes = result.notes {
                line += " — \(notes)"
            }
            print(line)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        let outPath = output ?? ".benchmark/benchmark-results/upload-spike.json"
        let outURL = URL(fileURLWithPath: outPath)
        try FileManager.default.createDirectory(at: outURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: outURL)
        print()
        print("Report written to \(outURL.path)")
    }
}
