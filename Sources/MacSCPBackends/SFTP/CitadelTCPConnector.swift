// CitadelTCPConnector.swift — TCP socket tuning for Citadel SSH connections.

@preconcurrency import Citadel
import Foundation
import MacSCPCore
import NIO

enum CitadelTCPConnector {
    static func connect(
        configuration: SessionConfiguration,
        authenticationMethod: SSHAuthenticationMethod,
        hostKeyValidator: SSHHostKeyValidator
    ) async throws -> SSHClient {
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

    private static func applySocketTuning(
        to client: SSHClient,
        profile: TransferNetworkProfile,
        sendBuffer: Int,
        receiveBuffer: Int,
        tcpNoDelay: Bool
    ) async throws {
        guard let channel = citadelChannel(from: client) else { return }

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
