import SwiftUI

/// Shared password prompt view used for authentication fallback.
struct PasswordPromptView: View {
    let title: String
    let message: String
    let actionLabel: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SSHMountTheme.innerPadding) {
            Text(title)
                .font(.system(size: 18, weight: .semibold))

            Text(.init(message))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit {
                    if !password.isEmpty {
                        onSubmit(password)
                    }
                }

            HStack {
                Spacer()
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .keyboardShortcut(.cancelAction)

                Button(actionLabel) {
                    if !password.isEmpty {
                        onSubmit(password)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(SSHMountTheme.tint)
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding(SSHMountTheme.outerPadding)
        .onAppear {
            isFocused = true
        }
    }
}
