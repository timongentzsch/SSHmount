import SwiftUI

@main
struct SSHMountApp: App {
    @StateObject private var mountManager = MountManager()

    var body: some Scene {
        MenuBarExtra {
            MountListView(manager: mountManager)
        } label: {
            MenuBarIcon(count: mountManager.mounts.count, status: mountManager.aggregateStatus)
        }
        .menuBarExtraStyle(.window)
    }
}

enum SSHMountTheme {
    static let outerPadding: CGFloat = 14
    static let innerPadding: CGFloat = 10
    static let compactSpacing: CGFloat = 6
    static let sectionSpacing: CGFloat = 12
    static let controlCornerRadius: CGFloat = 8
    static let panelCornerRadius: CGFloat = 12
    static let controlHeight: CGFloat = 34
    static let iconButtonSize: CGFloat = 28

    static let tint = Color.accentColor
    static let success = Color.green
    static let warning = Color.orange
    static let danger = Color.red
    static let surface = Color.white.opacity(0.08)
    static let surfaceSoft = Color.white.opacity(0.06)
    static let stroke = Color.white.opacity(0.12)
    static let buttonBackground = Color(nsColor: .controlBackgroundColor)
}

struct SSHMountBadge: View {
    let title: String
    var tint: Color = .secondary

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(SSHMountTheme.buttonBackground, in: Capsule())
    }
}

struct SSHMountSectionTitle: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct SSHMountIconButtonStyle: ButtonStyle {
    enum Layout {
        case padded
        case square
    }

    var tint: Color = .secondary
    var layout: Layout = .padded

    func makeBody(configuration: Configuration) -> some View {
        styledLabel(configuration.label)
            .foregroundStyle(tint)
            .background(
                SSHMountTheme.buttonBackground.opacity(configuration.isPressed ? 1 : 0.7),
                in: RoundedRectangle(
                    cornerRadius: SSHMountTheme.controlCornerRadius,
                    style: .continuous
                )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }

    @ViewBuilder
    private func styledLabel(_ label: Configuration.Label) -> some View {
        switch layout {
        case .padded:
            label
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        case .square:
            label
                .frame(
                    width: SSHMountTheme.iconButtonSize,
                    height: SSHMountTheme.iconButtonSize
                )
        }
    }
}

private struct SSHMountCanvasModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .containerBackground(.regularMaterial, for: .window)
    }
}

private struct SSHMountSurfaceModifier: ViewModifier {
    let fill: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(fill, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(SSHMountTheme.stroke, lineWidth: 1)
            )
    }
}

extension View {
    func sshMountCanvas() -> some View {
        modifier(SSHMountCanvasModifier())
    }

    func sshMountSurface(
        _ fill: Color = SSHMountTheme.surface,
        cornerRadius: CGFloat = SSHMountTheme.controlCornerRadius
    ) -> some View {
        modifier(SSHMountSurfaceModifier(fill: fill, cornerRadius: cornerRadius))
    }
}

struct MenuBarIcon: View {
    let count: Int
    let status: AggregateConnectionStatus

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: status.iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(status.color)

            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3.5)
                    .padding(.vertical, 1)
                    .background(status.color, in: Capsule())
                    .offset(x: 5, y: -5)
            }
        }
    }
}
