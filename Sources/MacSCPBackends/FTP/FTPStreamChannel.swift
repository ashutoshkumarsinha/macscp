// FTPStreamChannel.swift — CFStream-based FTP control and passive data channels.

import Foundation
import MacSCPCore

final class FTPStreamChannel: @unchecked Sendable {
    private var inputStream: InputStream?
    private var controlOutput: OutputStream?

    func connect(host: String, port: Int, useTLS: Bool) async throws {
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(nil, host as CFString, UInt32(port), &readStream, &writeStream)
        guard let read = readStream?.takeRetainedValue(), let write = writeStream?.takeRetainedValue() else {
            throw BackendError.transferFailed("Could not create FTP streams")
        }

        inputStream = read
        controlOutput = write

        if useTLS {
            let settings: [String: Any] = [
                kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
                kCFStreamSSLValidatesCertificateChain as String: true,
            ]
            CFReadStreamSetProperty(read, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
            CFWriteStreamSetProperty(write, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
        }

        inputStream?.open()
        controlOutput?.open()
        try await waitUntilOpen(read: inputStream, write: controlOutput)
    }

    func upgradeToTLS() throws {
        guard let read = inputStream, let write = controlOutput else {
            throw BackendError.notConnected
        }
        let settings: [String: Any] = [
            kCFStreamSSLLevel as String: kCFStreamSocketSecurityLevelNegotiatedSSL,
            kCFStreamSSLValidatesCertificateChain as String: true,
        ]
        CFReadStreamSetProperty(read, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
        CFWriteStreamSetProperty(write, CFStreamPropertyKey(rawValue: kCFStreamPropertySSLSettings), settings as CFDictionary)
    }

    func readLine() async throws -> String {
        guard let input = inputStream else { throw BackendError.notConnected }
        var bytes: [UInt8] = []
        while true {
            var buffer = [UInt8](repeating: 0, count: 1)
            let read = input.read(&buffer, maxLength: 1)
            if read <= 0 {
                throw BackendError.transferFailed("FTP control connection closed")
            }
            if buffer[0] == 0x0A {
                break
            }
            if buffer[0] != 0x0D {
                bytes.append(buffer[0])
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func sendLine(_ line: String) async throws {
        guard let output = controlOutput else { throw BackendError.notConnected }
        let payload = (line + "\r\n").data(using: .utf8) ?? Data()
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var offset = 0
            while offset < payload.count {
                let written = output.write(base.advanced(by: offset), maxLength: payload.count - offset)
                if written <= 0 {
                    throw BackendError.transferFailed("FTP write failed")
                }
                offset += written
            }
        }
    }

    func sendCommand(_ command: String) async throws -> FTPResponse {
        try await sendLine(command)
        return try await FTPResponseParser.readResponse(from: self)
    }

    func openPassiveDataConnection(from response: FTPResponse, controlHost: String) async throws -> (InputStream, OutputStream) {
        guard let endpoint = parsePassiveEndpoint(response.message, controlHost: controlHost) else {
            throw BackendError.transferFailed("Could not parse passive endpoint")
        }
        var readStream: Unmanaged<CFReadStream>?
        var writeStream: Unmanaged<CFWriteStream>?
        CFStreamCreatePairWithSocketToHost(
            nil,
            endpoint.host as CFString,
            UInt32(endpoint.port),
            &readStream,
            &writeStream
        )
        guard let readCF = readStream?.takeRetainedValue(), let writeCF = writeStream?.takeRetainedValue() else {
            throw BackendError.transferFailed("Could not open data connection")
        }
        let read = readCF as InputStream
        let write = writeCF as OutputStream
        read.open()
        write.open()
        try await waitUntilOpen(read: read, write: write)
        return (read, write)
    }

    func close() {
        inputStream?.close()
        controlOutput?.close()
        inputStream = nil
        controlOutput = nil
    }

    private struct PassiveEndpoint {
        var host: String
        var port: Int
    }

    private func parsePassiveEndpoint(_ message: String, controlHost: String) -> PassiveEndpoint? {
        if let range = message.range(of: #"\(\|\|\|(\d+)\|\)"#, options: .regularExpression) {
            let digits = message[range].filter(\.isNumber)
            if let port = Int(digits) {
                return PassiveEndpoint(host: controlHost, port: port)
            }
        }

        if let range = message.range(of: #"\(([^)]+)\)"#, options: .regularExpression) {
            let inner = message[range].trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let numbers = inner.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard numbers.count >= 6 else { return nil }
            let host = numbers.prefix(4).map(String.init).joined(separator: ".")
            let port = numbers[4] * 256 + numbers[5]
            return PassiveEndpoint(host: host, port: port)
        }

        if let range = message.range(of: #"\|[^|]+\|([^|]+)\|(\d+)\|"#, options: .regularExpression) {
            let match = String(message[range])
            let parts = match.split(separator: "|").map(String.init)
            guard parts.count >= 4, let port = Int(parts[3]) else { return nil }
            return PassiveEndpoint(host: parts[2], port: port)
        }

        return nil
    }

    private func waitUntilOpen(read: InputStream?, write: OutputStream?) async throws {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let readStatus = read?.streamStatus ?? .closed
            let writeStatus = write?.streamStatus ?? .closed
            if readStatus == .open && writeStatus == .open {
                return
            }
            if readStatus == .error || writeStatus == .error {
                throw BackendError.transferFailed("FTP stream open failed")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw BackendError.transferFailed("FTP connection timed out")
    }
}

enum FTPDataTransfer {
    static func upload(
        localURL: URL,
        dataIn: InputStream,
        dataOut: OutputStream,
        options: TransferOptions,
        remotePath: String
    ) async throws -> Int64 {
        let data = try Data(contentsOf: localURL)
        var offset = 0
        let total = data.count
        let start = Date()

        while offset < total {
            try options.throwIfCancelled()
            let chunkSize = min(32 * 1024, total - offset)
            let written = data.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return 0 }
                return dataOut.write(base.advanced(by: offset), maxLength: chunkSize)
            }
            if written <= 0 {
                throw BackendError.transferFailed("FTP upload stalled")
            }
            offset += written
            reportProgress(
                direction: .upload,
                path: remotePath,
                totalBytes: Int64(total),
                transferredBytes: Int64(offset),
                start: start,
                options: options
            )
        }

        dataIn.close()
        dataOut.close()
        return Int64(total)
    }

    static func download(
        localURL: URL,
        dataIn: InputStream,
        dataOut: OutputStream,
        options: TransferOptions,
        remotePath: String
    ) async throws -> Int64 {
        let parent = localURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: localURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: localURL) else {
            throw BackendError.transferFailed("Could not create local file")
        }
        defer { try? handle.close() }

        var total: Int64 = 0
        let start = Date()
        var buffer = [UInt8](repeating: 0, count: 32 * 1024)

        while true {
            try options.throwIfCancelled()
            let read = dataIn.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            handle.write(Data(buffer.prefix(read)))
            total += Int64(read)
            reportProgress(
                direction: .download,
                path: remotePath,
                totalBytes: total,
                transferredBytes: total,
                start: start,
                options: options
            )
        }

        dataIn.close()
        dataOut.close()
        return total
    }

    private static func reportProgress(
        direction: TransferDirection,
        path: String,
        totalBytes: Int64,
        transferredBytes: Int64,
        start: Date,
        options: TransferOptions
    ) {
        guard let progress = options.progress else { return }
        let elapsed = Date().timeIntervalSince(start)
        progress(
            TransferProgress(
                transferID: UUID(),
                direction: direction,
                path: path,
                totalBytes: totalBytes,
                transferredBytes: transferredBytes,
                bytesPerSecond: elapsed > 0 ? Double(transferredBytes) / elapsed : nil
            )
        )
    }
}
