// ProxyCommandRelay.swift
//
// WHAT THIS FILE DOES
// -------------------
// Runs OpenSSH ProxyCommand subprocesses and bridges them to a local TCP listener so Citadel
// and Traversio (TCP-only SSH clients) can connect through stdio-based proxy commands.
//

import Foundation
import MacSCPCore
import os

public enum ProxyCommandTemplate {
    /// Expands OpenSSH ProxyCommand tokens (%h, %p, %r, %n) for the target session.
    public static func expand(_ template: String, configuration: SessionConfiguration) -> String {
        template
            .replacingOccurrences(of: "%h", with: configuration.host)
            .replacingOccurrences(of: "%n", with: configuration.host)
            .replacingOccurrences(of: "%p", with: String(configuration.port))
            .replacingOccurrences(of: "%r", with: configuration.username)
    }
}

enum SSHConnectRouting {
    struct Endpoint: Sendable {
        var host: String
        var port: Int
        var relay: ProxyCommandRelay?
    }

    static func prepare(from configuration: SessionConfiguration) throws -> Endpoint {
        guard let command = configuration.advanced.proxyCommand?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !command.isEmpty
        else {
            return Endpoint(host: configuration.host, port: configuration.port, relay: nil)
        }

        let expanded = ProxyCommandTemplate.expand(command, configuration: configuration)
        let relay = try ProxyCommandRelay.start(commandLine: expanded)
        return Endpoint(host: "127.0.0.1", port: relay.localPort, relay: relay)
    }
}

final class ProxyCommandRelay: @unchecked Sendable {
    let localPort: Int

    private let listenSocket: Int32
    private let commandLine: String
    private var acceptTask: Task<Void, Never>?
    private let stopped = OSAllocatedUnfairLock(initialState: false)

    private init(listenSocket: Int32, localPort: Int, commandLine: String) {
        self.listenSocket = listenSocket
        self.localPort = localPort
        self.commandLine = commandLine
    }

    static func start(commandLine: String) throws -> ProxyCommandRelay {
        let listenSocket = socket(AF_INET, SOCK_STREAM, 0)
        guard listenSocket >= 0 else {
            throw BackendError.transferFailed("ProxyCommand relay socket failed")
        }

        var reuse: Int32 = 1
        setsockopt(listenSocket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout.size(ofValue: reuse)))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(listenSocket, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(listenSocket)
            throw BackendError.transferFailed("ProxyCommand relay bind failed")
        }

        guard listen(listenSocket, SOMAXCONN) == 0 else {
            close(listenSocket)
            throw BackendError.transferFailed("ProxyCommand relay listen failed")
        }

        var boundAddress = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(listenSocket, sockaddrPointer, &boundLength)
            }
        }
        guard nameResult == 0 else {
            close(listenSocket)
            throw BackendError.transferFailed("ProxyCommand relay port lookup failed")
        }

        let relay = ProxyCommandRelay(
            listenSocket: listenSocket,
            localPort: Int(UInt16(bigEndian: boundAddress.sin_port)),
            commandLine: commandLine
        )
        relay.startAcceptLoop()
        return relay
    }

    func stop() {
        stopped.withLock { $0 = true }
        acceptTask?.cancel()
        shutdown(listenSocket, SHUT_RDWR)
        close(listenSocket)
    }

    private func startAcceptLoop() {
        acceptTask = Task.detached { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let isStopped = stopped.withLock { $0 }
                if isStopped { break }

                var clientAddress = sockaddr_in()
                var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientSocket = withUnsafeMutablePointer(to: &clientAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                        accept(self.listenSocket, sockaddrPointer, &clientLength)
                    }
                }
                guard clientSocket >= 0 else { break }
                self.bridge(clientSocket: clientSocket, commandLine: self.commandLine)
            }
        }
    }

    private func bridge(clientSocket: Int32, commandLine: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", commandLine]

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            close(clientSocket)
            return
        }

        let stdinWrite = stdinPipe.fileHandleForWriting
        let stdoutRead = stdoutPipe.fileHandleForReading

        Task.detached {
            Self.pump(from: clientSocket, to: stdinWrite)
            try? stdinWrite.close()
            if process.isRunning {
                process.terminate()
            }
        }

        Task.detached {
            Self.pump(from: stdoutRead.fileDescriptor, to: clientSocket)
            close(clientSocket)
            if process.isRunning {
                process.terminate()
            }
        }
    }

    private static func pump(from input: Int32, to output: FileHandle) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count <= 0 { break }
            output.write(Data(buffer[0 ..< count]))
        }
    }

    private static func pump(from input: Int32, to output: Int32) {
        var buffer = [UInt8](repeating: 0, count: 32_768)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count <= 0 { break }
            var remaining = count
            var offset = 0
            while remaining > 0 {
                let written = buffer.withUnsafeBytes { rawBuffer in
                    write(output, rawBuffer.baseAddress!.advanced(by: offset), remaining)
                }
                if written <= 0 { return }
                remaining -= written
                offset += written
            }
        }
    }
}
