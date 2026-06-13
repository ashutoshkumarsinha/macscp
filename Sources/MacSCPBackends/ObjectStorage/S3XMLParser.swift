import Foundation
import MacSCPCore

enum S3XMLParser {
    static func parseListObjects(_ data: Data, layout: ObjectStorageLayout, prefix: String) -> [RemoteEntry] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        var entries: [RemoteEntry] = []
        let keyPattern = #"<Key>([^<]+)</Key>"#
        let sizePattern = #"<Size>([0-9]+)</Size>"#
        let keys = matches(text, pattern: keyPattern)
        let sizes = matches(text, pattern: sizePattern)

        for (index, key) in keys.enumerated() {
            if key.hasSuffix("/") {
                let name = (key as NSString).lastPathComponent
                if name.isEmpty { continue }
                entries.append(
                    RemoteEntry(
                        name: name,
                        path: layout.remotePath(for: String(key.dropLast())),
                        type: .directory,
                        size: nil
                    )
                )
            } else {
                let name = (key as NSString).lastPathComponent
                let size = index < sizes.count ? Int64(sizes[index]) : nil
                entries.append(
                    RemoteEntry(
                        name: name,
                        path: layout.remotePath(for: key),
                        type: .file,
                        size: size
                    )
                )
            }
        }

        if entries.isEmpty, !prefix.isEmpty {
            // CommonPrefixes fallback
            let prefixPattern = #"<Prefix>([^<]+)</Prefix>"#
            for match in matches(text, pattern: prefixPattern) where match != prefix && match.hasSuffix("/") {
                let name = (match.trimmingCharacters(in: CharacterSet(charactersIn: "/")) as NSString).lastPathComponent
                entries.append(
                    RemoteEntry(
                        name: name,
                        path: layout.remotePath(for: String(match.dropLast())),
                        type: .directory,
                        size: nil
                    )
                )
            }
        }

        return entries.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func matches(_ text: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let swiftRange = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[swiftRange])
        }
    }
}
