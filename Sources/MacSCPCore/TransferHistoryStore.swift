import Foundation

public struct TransferHistoryEntry: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var direction: TransferDirection
    public var localPath: String
    public var remotePath: String
    public var bytesTransferred: Int64
    public var sessionName: String
    public var success: Bool
    public var errorMessage: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        direction: TransferDirection,
        localPath: String,
        remotePath: String,
        bytesTransferred: Int64,
        sessionName: String,
        success: Bool,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.direction = direction
        self.localPath = localPath
        self.remotePath = remotePath
        self.bytesTransferred = bytesTransferred
        self.sessionName = sessionName
        self.success = success
        self.errorMessage = errorMessage
    }
}

public enum TransferHistoryStore {
    private static let fileName = "transfer-history.json"
    private static let maxEntries = 500

    public static func fileURL(homeDirectory: URL) -> URL {
        MacSCPConfiguration.macscpDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent(fileName)
    }

    public static func load(homeDirectory: URL) throws -> [TransferHistoryEntry] {
        let url = fileURL(homeDirectory: homeDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([TransferHistoryEntry].self, from: data)
    }

    public static func append(_ entry: TransferHistoryEntry, homeDirectory: URL) throws {
        var entries = (try? load(homeDirectory: homeDirectory)) ?? []
        entries.insert(entry, at: 0)
        if entries.count > maxEntries {
            entries = Array(entries.prefix(maxEntries))
        }
        let url = fileURL(homeDirectory: homeDirectory)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(entries)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
