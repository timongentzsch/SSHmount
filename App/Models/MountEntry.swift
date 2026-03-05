import SwiftUI

// MARK: - Shared Animation Constants

extension Animation {
    /// Standard transition for mount state changes (connect/disconnect/error).
    static let mountTransition = Animation.easeInOut(duration: 0.3)
    /// Quick transition for UI panel swaps (show/hide views).
    static let viewTransition = Animation.easeInOut(duration: 0.2)
}

// MARK: - Aggregate Connection Status

enum AggregateConnectionStatus {
    case noMounts
    case allConnected
    case degraded       // some unreachable or reconnecting
    case hasErrors
    case mixed          // connected + other states

    var iconName: String {
        switch self {
        case .noMounts:     "externaldrive.badge.minus"
        case .allConnected: "externaldrive.connected.to.line.below.fill"
        case .degraded:     "externaldrive.badge.exclamationmark"
        case .hasErrors:    "externaldrive.badge.xmark"
        case .mixed:        "externaldrive.connected.to.line.below"
        }
    }

    var color: Color {
        switch self {
        case .noMounts:     .secondary
        case .allConnected: SSHMountTheme.success
        case .degraded:     SSHMountTheme.warning
        case .hasErrors:    SSHMountTheme.danger
        case .mixed:        .blue
        }
    }
}

// MARK: - Mount Entry

/// A live mount: config + runtime status.
struct MountEntry: Identifiable {
    let id = UUID()
    var config: MountConfig
    var status: MountStatus
    var connectedSince: Date?
    var retryAttempt: Int = 0
    var retryNextAt: Date?
    var lastReconnectReason: String?
}

// MARK: - Permission Status

/// Status of required permissions and setup.
struct PermissionStatus {
    var appInstalled = false
    var extensionRegistered = false
    var extensionEnabled = false
    var sshKeysFound = false

    var allGood: Bool { appInstalled && extensionRegistered && extensionEnabled && sshKeysFound }
}
