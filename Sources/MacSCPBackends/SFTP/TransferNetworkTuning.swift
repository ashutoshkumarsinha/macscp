// TransferNetworkTuning.swift — TCP socket tuning for SFTP backends.

import Foundation
import MacSCPCore

public enum TransferNetworkTuning {
    public static func logIntendedSettings(preset: TransferPerformancePreset) {
        let profile = TransferPerformanceTuning.networkProfile(from: preset)
        logAppliedSettings(
            profile: profile,
            sendBuffer: TransferPerformanceTuning.tcpSendBufferBytes(for: profile),
            receiveBuffer: TransferPerformanceTuning.tcpReceiveBufferBytes(for: profile),
            tcpNoDelay: TransferPerformanceTuning.usesTCPNoDelay(for: profile)
        )
    }

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
