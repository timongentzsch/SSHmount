import SwiftUI

struct OnboardingView: View {
    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Setup")
                .font(.headline)

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
                    .keyboardShortcut(.defaultAction)
                    .disabled(!manager.permissionStatus.allGood)
            }
        }
        .padding()
    }
}

struct OnboardingStep: View {
    let number: Int
    let title: String
    let description: String
    let ok: Bool
    var action: (String, () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "\(number).circle")
                .foregroundStyle(ok ? .green : .secondary)
                .font(.title3)

            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(.body, weight: .medium))
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let (label, handler) = action, !ok {
                    Button(label) { handler() }
                        .font(.caption)
                        .padding(.top, 2)
                }
            }
        }
    }
}
