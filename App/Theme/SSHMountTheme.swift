import SwiftUI

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
