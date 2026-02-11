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
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text(.init(message))
                .font(.caption)
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
                .keyboardShortcut(.cancelAction)

                Button(actionLabel) {
                    if !password.isEmpty {
                        onSubmit(password)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding()
        .onAppear {
            isFocused = true
        }
    }
}
