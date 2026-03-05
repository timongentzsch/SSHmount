import Foundation

/// Runtime state of a mount.
enum MountStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case unreachable
    case error(String)

    var text: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .reconnecting: "Reconnecting..."
        case .unreachable: "Unreachable"
        case .error(let msg): "Error: \(msg)"
        }
    }
}
