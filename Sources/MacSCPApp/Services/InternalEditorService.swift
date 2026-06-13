// InternalEditorService.swift
//
// WHAT THIS FILE DOES
// -------------------
// Downloads a remote text file for in-app editing and re-uploads on save. CommanderView
// opens InternalEditorView; TextFileEncoding handles decode/encode before backend upload.
//

import Foundation
import MacSCPCore

enum TextFileEncoding: String, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case latin1 = "Latin-1 (ISO-8859-1)"

    var id: String { rawValue }

    func decode(_ data: Data) -> String? {
        switch self {
        case .utf8:
            return String(data: data, encoding: .utf8)
        case .latin1:
            return String(data: data, encoding: .isoLatin1)
        }
    }

    func encode(_ text: String) -> Data? {
        switch self {
        case .utf8:
            return text.data(using: .utf8)
        case .latin1:
            return text.data(using: .isoLatin1)
        }
    }
}

enum TextLineEnding: String, CaseIterable, Identifiable {
    case lf = "LF (Unix)"
    case crlf = "CRLF (Windows)"

    var id: String { rawValue }

    static func detect(in text: String) -> TextLineEnding {
        text.contains("\r\n") ? .crlf : .lf
    }

    func normalize(_ text: String) -> String {
        let unified = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        switch self {
        case .lf:
            return unified
        case .crlf:
            return unified.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }
}

struct InternalEditorSnapshot: Equatable {
    var fileName: String
    var remotePath: String
    var text: String
    var encoding: TextFileEncoding
    var lineEnding: TextLineEnding
    var baselineSize: Int64?
    var baselineModified: Date?
}

enum InternalEditorError: LocalizedError {
    case notTextFile
    case decodeFailed
    case encodeFailed
    case remoteChanged

    var errorDescription: String? {
        switch self {
        case .notTextFile:
            return "Only text files can be edited in the internal editor."
        case .decodeFailed:
            return "Could not decode file with the selected encoding."
        case .encodeFailed:
            return "Could not encode file for upload."
        case .remoteChanged:
            return "The remote file changed while you were editing."
        }
    }
}

enum InternalEditorService {
    static func loadRemoteFile(
        entry: RemoteEntry,
        backend: TransferBackend
    ) async throws -> InternalEditorSnapshot {
        guard entry.type == .file else {
            throw InternalEditorError.notTextFile
        }

        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSCP/edit-internal", isDirectory: true)
        let sessionDir = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        let localURL = sessionDir.appendingPathComponent(entry.name)

        _ = try await backend.download(
            remotePath: entry.path,
            localURL: localURL,
            options: TransferOptions()
        )

        let data = try Data(contentsOf: localURL)
        try? FileManager.default.removeItem(at: sessionDir)

        let encoding = TextFileEncoding.utf8
        guard let text = encoding.decode(data) else {
            throw InternalEditorError.decodeFailed
        }

        return InternalEditorSnapshot(
            fileName: entry.name,
            remotePath: entry.path,
            text: text,
            encoding: encoding,
            lineEnding: TextLineEnding.detect(in: text),
            baselineSize: entry.size,
            baselineModified: entry.modified
        )
    }

    static func saveRemoteFile(
        snapshot: InternalEditorSnapshot,
        text: String,
        encoding: TextFileEncoding,
        lineEnding: TextLineEnding,
        backend: TransferBackend,
        conflictPolicy: InternalEditorConflictPolicy = .prompt
    ) async throws {
        if try await remoteChanged(snapshot: snapshot, backend: backend) {
            switch conflictPolicy {
            case .prompt:
                throw InternalEditorError.remoteChanged
            case .overwrite:
                break
            }
        }

        let normalized = lineEnding.normalize(text)
        guard let data = encoding.encode(normalized) else {
            throw InternalEditorError.encodeFailed
        }

        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacSCP/edit-internal", isDirectory: true)
        let sessionDir = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sessionDir) }

        let localURL = sessionDir.appendingPathComponent(snapshot.fileName)
        try data.write(to: localURL, options: .atomic)

        _ = try await backend.upload(
            localURL: localURL,
            remotePath: snapshot.remotePath,
            options: TransferOptions(overwrite: .overwrite)
        )
    }

    private static func remoteChanged(
        snapshot: InternalEditorSnapshot,
        backend: TransferBackend
    ) async throws -> Bool {
        let current = try await backend.stat(path: snapshot.remotePath)
        if let baselineSize = snapshot.baselineSize, let currentSize = current.size, baselineSize != currentSize {
            return true
        }
        if let baselineModified = snapshot.baselineModified,
           let currentModified = current.modified,
           abs(currentModified.timeIntervalSince(baselineModified)) > 1 {
            return true
        }
        return false
    }
}

enum InternalEditorConflictPolicy {
    case prompt
    case overwrite
}
