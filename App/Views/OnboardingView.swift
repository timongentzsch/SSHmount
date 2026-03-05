import SwiftUI

struct OnboardingView: View {
    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: SSHMountTheme.sectionSpacing) {
            Text("Setup")
                .font(.system(size: 18, weight: .semibold))

            Text("Install the app, enable the filesystem extension, and make sure SSH keys are available.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            OnboardingStep(
                number: 1,
                title: "Install in /Applications",
                description: "Drag SSHMount.app into /Applications so macOS can discover the filesystem extension.",
                ok: manager.permissionStatus.appInstalled
            )

            OnboardingStep(
                number: 2,
                title: "Enable filesystem extension",
                description: "Open System Settings → General → Login Items & Extensions → File System Extensions, then enable SSHMount.",
                ok: manager.permissionStatus.extensionEnabled,
                action: ("Open System Settings", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!)
                })
            )

            OnboardingStep(
                number: 3,
                title: "SSH keys",
                description: "Place your SSH keys (id_ed25519, id_rsa, or id_ecdsa) in ~/.ssh/. SSHMount reads your ~/.ssh/config for host aliases.",
                ok: manager.permissionStatus.sshKeysFound
            )

            HStack {
                Spacer()
                Button("Get Started") { onDismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(SSHMountTheme.tint)
                    .keyboardShortcut(.defaultAction)
                .disabled(!manager.permissionStatus.allGood)
            }
        }
        .padding(SSHMountTheme.outerPadding)
    }
}

struct OnboardingStep: View {
    let number: Int
    let title: String
    let description: String
    let ok: Bool
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: SSHMountTheme.innerPadding) {
            Image(systemName: ok ? "checkmark.circle" : "\(number).circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: SSHMountTheme.compactSpacing) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Text(description)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                if let (label, handler) = action, !ok {
                    Button(label) { handler() }
                        .font(.system(size: 11, weight: .semibold))
                        .buttonStyle(.bordered)
                        .tint(SSHMountTheme.tint)
                        .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
