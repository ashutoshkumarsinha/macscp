// DirectoryTransferPlannerTests.swift — Tests for recursive directory expansion and path join.

import Foundation
import MacSCPCore
import Testing

@Test
func expandLocalDirectoryListsNestedFiles() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macscp-dir-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sub = root.appendingPathComponent("sub", isDirectory: true)
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    let file = sub.appendingPathComponent("hello.txt")
    try Data("hello".utf8).write(to: file)

    let files = try DirectoryTransferPlanner.expandLocalDirectory(at: root, remoteBase: "/upload")
    #expect(files.count == 1)
    #expect(files[0].remotePath == "/upload/sub/hello.txt")
    #expect(files[0].localURL.lastPathComponent == "hello.txt")
}

@Test
func sftpPathJoinNormalizesAndJoins() {
    #expect(SFTPPathJoin.normalizeRemote("/a//b/../c") == "/a/c")
    #expect(SFTPPathJoin.joinRemote("/base", "file.txt") == "/base/file.txt")
    #expect(SFTPPathJoin.joinRemote("/", "file.txt") == "/file.txt")
}

@Test
func ensureLocalDirectoriesCreatesParents() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("macscp-mkdir-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let nested = root.appendingPathComponent("a/b/c/file.bin")
    let files = [
        DirectoryTransferFile(localURL: nested, remotePath: "/remote/a/b/c/file.bin"),
    ]
    try DirectoryTransferPlanner.ensureLocalDirectories(for: files)
    #expect(FileManager.default.fileExists(atPath: nested.deletingLastPathComponent().path))
}
