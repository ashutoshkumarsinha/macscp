import Foundation
import Testing
@testable import MacSCPCore

@Test func rsyncDeltaUpdatesChangedRegion() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macscp-rsync-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let basisURL = directory.appendingPathComponent("basis.bin")
    let targetURL = directory.appendingPathComponent("target.bin")
    let outputURL = directory.appendingPathComponent("output.bin")

    var basis = Data(repeating: 0x61, count: 80_000)
    var target = basis
    target.replaceSubrange(20_000 ..< 20_512, with: Data(repeating: 0x42, count: 512))
    try basis.write(to: basisURL)
    try target.write(to: targetURL)

    let delta = try RsyncDeltaGenerator.generate(basisURL: basisURL, targetURL: targetURL)
    #expect(delta.literalBytes > 0)
    #expect(delta.literalBytes < delta.targetSize)

    let transferred = try RsyncDeltaApplier.apply(basisURL: basisURL, delta: delta, outputURL: outputURL)
    #expect(transferred == delta.literalBytes)

    let applied = try Data(contentsOf: outputURL)
    #expect(applied == target)
}

@Test func rsyncDeltaRejectsSmallFiles() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("macscp-rsync-small-\(UUID().uuidString)", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let basisURL = directory.appendingPathComponent("small.bin")
        let targetURL = directory.appendingPathComponent("small2.bin")
        try Data(repeating: 1, count: 1024).write(to: basisURL)
        try Data(repeating: 2, count: 1024).write(to: targetURL)

        #expect(throws: RsyncDeltaError.self) {
            _ = try RsyncDeltaGenerator.generate(basisURL: basisURL, targetURL: targetURL)
        }
    } catch {
        Issue.record("Setup failed: \(error)")
    }
}
