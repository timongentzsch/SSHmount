import SwiftUI

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
