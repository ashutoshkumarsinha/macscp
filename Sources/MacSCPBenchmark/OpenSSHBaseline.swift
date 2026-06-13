// OpenSSHBaseline.swift
//
// WHAT THIS FILE DOES
// -------------------
// Measures OpenSSH sftp/scp baseline upload and download speeds for comparison.
// BenchmarkRunner calls OpenSSHSFTPBaseline to record native client timings in reports.
//
import Foundation
import MacSCPCore

enum OpenSSHSFTPBaseline {
    static func upload(local: URL, remotePath: String, config: BenchmarkConfig) throws -> Double {
        let batch = config.workDirectory.appendingPathComponent("sftp-upload.txt")
        let remoteName = (remotePath as NSString).lastPathComponent
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        try runSSH(["mkdir", "-p", remoteDir], config: config)
        try "cd \(remoteDir)\nput \(shellQuote(local.path)) \(shellQuote(remoteName))\n".write(
            to: batch,
            atomically: true,
            encoding: .utf8
        )
        return try runSFTPBatch(batch, config: config)
    }

    static func download(remotePath: String, local: URL, config: BenchmarkConfig, resumeFrom: Int64 = 0) throws -> Double {
        let batch = config.workDirectory.appendingPathComponent("sftp-download.txt")
        let remoteName = (remotePath as NSString).lastPathComponent
        let remoteDir = (remotePath as NSString).deletingLastPathComponent
        if resumeFrom > 0 {
            if !FileManager.default.fileExists(atPath: local.path) {
                FileManager.default.createFile(atPath: local.path, contents: Data(count: Int(resumeFrom)))
            }
        } else if FileManager.default.fileExists(atPath: local.path) {
            try FileManager.default.removeItem(at: local)
        }
        try "cd \(remoteDir)\nget \(shellQuote(remoteName)) \(shellQuote(local.path))\n".write(
            to: batch,
            atomically: true,
            encoding: .utf8
        )
        return try runSFTPBatch(batch, config: config)
    }

    static func listDirectory(remoteDir: String, config: BenchmarkConfig) throws -> (Double, Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-p", String(config.port),
            "-i", config.keyPath ?? "",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(config.username)@\(config.host)",
            "ls -1 \(shellQuote(remoteDir)) | wc -l",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let start = Date()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendError.transferFailed("OpenSSH ls exited with \(process.terminationStatus)")
        }
        let elapsed = Date().timeIntervalSince(start)
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "0"
        let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        return (elapsed, count)
    }

    static func uploadBatch(files: [(local: URL, remote: String)], config: BenchmarkConfig) throws -> Double {
        let batch = config.workDirectory.appendingPathComponent("sftp-batch-upload.txt")
        var lines: [String] = []
        if let first = files.first {
            let remoteDir = (first.remote as NSString).deletingLastPathComponent
            try runSSH(["mkdir", "-p", remoteDir], config: config)
            lines.append("cd \(remoteDir)")
        }
        for file in files {
            let remoteName = (file.remote as NSString).lastPathComponent
            lines.append("put \(shellQuote(file.local.path)) \(shellQuote(remoteName))")
        }
        try lines.joined(separator: "\n").write(to: batch, atomically: true, encoding: .utf8)
        return try runSFTPBatch(batch, config: config)
    }

    private static func runSSH(_ command: [String], config: BenchmarkConfig) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-p", String(config.port),
            "-i", config.keyPath ?? "",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(config.username)@\(config.host)",
        ] + command
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendError.transferFailed("OpenSSH ssh exited with \(process.terminationStatus)")
        }
    }

    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runSFTPBatch(_ batch: URL, config: BenchmarkConfig) throws -> Double {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sftp")
        process.arguments = [
            "-B", "32768",
            "-b", batch.path,
            "-P", String(config.port),
            "-i", config.keyPath ?? "",
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "\(config.username)@\(config.host)",
        ]
        let start = Date()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BackendError.transferFailed("OpenSSH sftp exited with \(process.terminationStatus)")
        }
        return Date().timeIntervalSince(start)
    }
}

enum FixtureGenerator {
    static func largeFile(at url: URL, size: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        var seed: UInt8 = 0x5A
        let chunkSize = 1024 * 1024
        var remaining = size
        while remaining > 0 {
            let n = min(chunkSize, remaining)
            var buffer = [UInt8](repeating: 0, count: n)
            for i in 0 ..< n {
                buffer[i] = seed &+ UInt8(i % 251)
            }
            seed &+= 17
            try handle.write(contentsOf: buffer)
            remaining -= n
        }
    }

    static func smallFileTree(at directory: URL, count: Int) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for i in 0 ..< count {
            let file = directory.appendingPathComponent(String(format: "file_%05d.dat", i))
            let payload = Data((0 ..< 4096).map { UInt8(($0 + i) % 256) })
            try payload.write(to: file)
        }
    }
}
