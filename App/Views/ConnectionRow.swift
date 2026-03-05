import SwiftUI

struct ConnectionRow<Actions: View>: View {
    let label: String
    let subtitle: String?
    let host: String?
    let status: MountStatus
    var connectedSince: Date?
    var compactLayout = false
    @ViewBuilder let actions: () -> Actions

    private var shouldPulse: Bool {
        status == .unreachable || status == .reconnecting || status == .connecting
    }

    private var showStatusText: Bool {
        status != .disconnected
    }

    private var tooltipText: String {
        var parts: [String] = []
        if let host = host {
            parts.append(host)
        }
        if let subtitle = subtitle {
            parts.append(subtitle)
        }
        parts.append(status.text)
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: SSHMountTheme.innerPadding) {
            Image(systemName: status.systemImage)
                .font(.system(size: compactLayout ? 12 : 13, weight: .medium))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, isActive: shouldPulse)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: compactLayout ? 2 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.system(size: compactLayout ? 12 : 13, weight: .semibold))
                        .lineLimit(1)

                    if showStatusText {
                        Text(status.text)
                            .font(.system(size: 10))
                            .foregroundStyle(status.color)
                    }
                }

                if let host {
                    Text(host)
                        .font(.system(size: compactLayout ? 11 : 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let subtitle, !compactLayout {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let connectedSince, status == .connected {
                    Text("Connected \(connectedSince, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: compactLayout ? SSHMountTheme.compactSpacing : SSHMountTheme.innerPadding)

            HStack(spacing: compactLayout ? 4 : 6) {
                actions()
            }
        }
        .padding(.horizontal, SSHMountTheme.innerPadding)
        .padding(.vertical, compactLayout ? 6 : 8)
        .sshMountSurface(SSHMountTheme.surfaceSoft)
        .contentShape(Rectangle())
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(status.text)")
    }
}
