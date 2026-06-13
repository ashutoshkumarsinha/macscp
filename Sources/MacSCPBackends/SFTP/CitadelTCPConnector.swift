// CitadelTCPConnector.swift
//
// WHAT THIS FILE DOES
// -------------------
// Opens Citadel SSH connections and applies TCP socket tuning (buffer sizes and
// TCP_NODELAY) based on the session's network profile (from config preset).
//
// WHY A SEPARATE FILE
// -------------------
// Citadel's public connect API does not expose bootstrap socket options. We connect
// normally, then adjust the underlying NIO channel before SFTP traffic starts.
//
// BEGINNER TIP
// ------------
// networkProfile travels on SessionConfiguration, set by SessionCoordinator from
// the user's preset in config.toml (lan / wan / apple_silicon).

@preconcurrency import Citadel
import Foundation
import MacSCPCore
import NIO

enum CitadelTCPConnector {
    /// Connect to SSH via Citadel, then tune the TCP socket for the active preset.
    static func connect(
        configuration: SessionConfiguration,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient {
        // Step 1: Standard Citadel SSH handshake (same as before performance work).
        let client = try await SSHClient.connect(
            host: configuration.host,
            port: configuration.port,
            authenticationMethod: authenticationMethod,
            hostKeyValidator: hostKeyValidator,
            reconnect: .never,
            connectTimeout: .seconds(
                Int64(max(1, configuration.advanced.connectionTimeoutSeconds))
            )
        )

        // Step 2: Apply preset-specific socket options on the live connection.
        let profile = configuration.networkProfile
        try await applySocketTuning(
            to: client,
            profile: profile,
            sendBuffer: TransferPerformanceTuning.tcpSendBufferBytes(for: profile),
            receiveBuffer: TransferPerformanceTuning.tcpReceiveBufferBytes(for: profile),
            tcpNoDelay: TransferPerformanceTuning.usesTCPNoDelay(for: profile)
        )
        return client
    }

    /// Sets SO_SNDBUF, SO_RCVBUF, and TCP_NODELAY on the NIO channel's event loop.
    private static func applySocketTuning(
        to client: SSHClient,
        profile: TransferNetworkProfile,
        sendBuffer: Int,
        receiveBuffer: Int,
        tcpNoDelay: Bool
    ) async throws {
        // Citadel does not expose its TCP channel publicly; reflection finds it.
        guard let channel = citadelChannel(from: client) else { return }

        // Socket options must be set on the channel's event loop (NIO requirement).
        try await channel.eventLoop.submit {
            guard let options = channel.syncOptions else { return }
            try options.setOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_SNDBUF),
                value: Int32(clamping: sendBuffer)
            )
            try options.setOption(
                ChannelOptions.socket(SocketOptionLevel(SOL_SOCKET), SO_RCVBUF),
                value: Int32(clamping: receiveBuffer)
            )
            try options.setOption(
                ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY),
                value: tcpNoDelay ? 1 : 0
            )
        }.get()

        TransferNetworkTuning.logAppliedSettings(
            profile: profile,
            sendBuffer: sendBuffer,
            receiveBuffer: receiveBuffer,
            tcpNoDelay: tcpNoDelay
        )
    }

    /// Walks SSHClient's internal session to get the NIO Channel (not public API).
    private static func citadelChannel(from client: SSHClient) -> Channel? {
        for child in Mirror(reflecting: client).children {
            guard child.label == "session" else { continue }
            for sessionChild in Mirror(reflecting: child.value).children {
                if sessionChild.label == "channel", let channel = sessionChild.value as? Channel {
                    return channel
                }
            }
        }
        return nil
    }
}
