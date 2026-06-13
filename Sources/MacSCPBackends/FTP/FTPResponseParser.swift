// FTPResponseParser.swift — Parse multi-line FTP control responses.

import Foundation
import MacSCPCore

struct FTPResponse: Equatable, Sendable {
    var code: Int
    var message: String
}

enum FTPResponseParser {
    static func readResponse(from channel: FTPStreamChannel) async throws -> FTPResponse {
        var lines: [String] = []
        while true {
            let line = try await channel.readLine()
            lines.append(line)
            guard line.count >= 4, let code = Int(line.prefix(3)) else { continue }
            let separator = line.dropFirst(3).first
            if separator == " " {
                let message = lines.map { String($0.dropFirst(4)) }.joined(separator: "\n")
                return FTPResponse(code: code, message: message)
            }
            if separator == "-" {
                continue
            }
        }
    }

    static func expect(_ response: FTPResponse, codes: [Int]) throws {
        guard codes.contains(response.code) else {
            throw BackendError.transferFailed("FTP \(response.code): \(response.message)")
        }
    }
}
