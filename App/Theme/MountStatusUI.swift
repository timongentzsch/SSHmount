import SwiftUI

extension MountStatus {
    var color: Color {
        switch self {
        case .connected: return SSHMountTheme.success
        case .connecting, .reconnecting: return SSHMountTheme.warning
        case .unreachable: return SSHMountTheme.warning
        case .disconnected: return .gray
        case .error: return SSHMountTheme.danger
        }
    }

    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise"
        case .unreachable: return "exclamationmark.triangle"
        case .disconnected: return "circle"
        case .error: return "xmark.circle"
        }
    }
}
