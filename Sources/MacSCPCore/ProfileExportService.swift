import CryptoKit
import Foundation

public enum ProfileExportService {
    public static func exportEncryptedJSON(data: Data, password: String) throws -> Data {
        let key = deriveKey(from: password)
        let sealed = try AES.GCM.seal(data, using: key)
        guard let combined = sealed.combined else {
            throw ProfileExportError.encryptionFailed
        }
        var output = Data("MACSCP1".utf8)
        output.append(combined)
        return output
    }

    public static func importEncryptedJSON(_ data: Data, password: String) throws -> Data {
        guard data.count > 7, String(data: data.prefix(7), encoding: .utf8) == "MACSCP1" else {
            throw ProfileExportError.invalidFormat
        }
        let key = deriveKey(from: password)
        let box = try AES.GCM.SealedBox(combined: data.dropFirst(7))
        return try AES.GCM.open(box, using: key)
    }

    private static func deriveKey(from password: String) -> SymmetricKey {
        let hash = SHA256.hash(data: Data(password.utf8))
        return SymmetricKey(data: Data(hash))
    }
}

public enum ProfileExportError: Error, LocalizedError {
    case encryptionFailed
    case invalidFormat
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .encryptionFailed: return "Failed to encrypt profile export"
        case .invalidFormat: return "Invalid encrypted profile file"
        case .wrongPassword: return "Incorrect master password"
        }
    }
}
