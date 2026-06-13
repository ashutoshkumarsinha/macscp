import Foundation

enum SecurityScopedBookmarkStore {
    private static let defaultsKey = "macscp.localPaneBookmark"

    static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    static func resolveBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }

    static func startAccessing(url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    static func stopAccessing(url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
}
