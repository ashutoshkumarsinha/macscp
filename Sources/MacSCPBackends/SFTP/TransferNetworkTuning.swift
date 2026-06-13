// TransferNetworkTuning.swift
//
// WHAT THIS FILE DOES
// -------------------
// Logs TCP tuning values to ~/.macscp/logs so you can confirm which preset was active at connect.
// Does not change sockets itself — CitadelTCPConnector applies the actual setOption calls.
//

import Foundation
import MacSCPCore

public enum TransferNetworkTuning {
    /// Log what we * intend* to apply from a config preset (before connect).
    public static func logIntendedSettings(preset: TransferPerformancePreset) {
        let profile = TransferPerformanceTuning.networkProfile(from: preset)
        logAppliedSettings(
            profile: profile,
            sendBuffer: TransferPerformanceTuning.tcpSendBufferBytes(for: profile),
            receiveBuffer: TransferPerformanceTuning.tcpReceiveBufferBytes(for: profile),
            tcpNoDelay: TransferPerformanceTuning.usesTCPNoDelay(for: profile)
        )
    }

    /// Log after socket options are set (or when documenting intended values).
    public static func logAppliedSettings(
        profile: TransferNetworkProfile,
        sendBuffer: Int,
        receiveBuffer: Int,
        tcpNoDelay: Bool
    ) {
        MacSCPLogger.shared.debug(
            """
            TCP tuning (\(profile.rawValue)): \
            sndbuf=\(sendBuffer) rcvbuf=\(receiveBuffer) tcp_nodelay=\(tcpNoDelay)
            """,
            category: .backend
        )
    }
}
