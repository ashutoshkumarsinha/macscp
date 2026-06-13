import Foundation

enum SFTPErrorHelpers {
    static func isAlreadyExists(_ error: Error) -> Bool {
        let message = String(describing: error).lowercased()
        return message.contains("already exists")
            || message.contains("file already")
            || message.contains("failure (4)")
            || message.contains("fx_failure")
    }
}
