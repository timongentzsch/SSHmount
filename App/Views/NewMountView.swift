import SwiftUI

struct NewMountView: View {
    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void
    /// If set, we're editing an existing saved config.
    var editing: MountConfig?

    @State private var hostAlias = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var label = ""
    @State private var mountOnLaunch = false
    @State private var mountOptions = ""
    @State private var knownHosts: [String] = []
    @State private var knownHostsDiagnostic: String?
    @State private var errorMessage: String?
    @State private var showPasswordPrompt = false
    @State private var pendingMountConfig: MountConfig?

    private var hostAliasIsValid: Bool {
        knownHosts.contains(hostAlias)
    }

    private var canSubmit: Bool {
        hostAliasIsValid && !remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing != nil ? "Edit Connection" : "New Mount")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Host")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if knownHosts.isEmpty {
                        Text("No SSH host aliases found in ~/.ssh/config")
                            .font(.caption)
                            .foregroundStyle(.red)
                        if let knownHostsDiagnostic {
                            Text(knownHostsDiagnostic)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Picker("Host", selection: $hostAlias) {
                            ForEach(knownHosts, id: \.self) { host in
                                Text(host).tag(host)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Remote Path")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. ~/project or /var/www", text: $remotePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mount Point")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("~/Volumes/")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                        TextField("folder name (auto)", text: $localPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Label")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("Optional", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mount Options")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("e.g. rdonly,nosuid,follow_symlinks=no", text: $mountOptions)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                Toggle("Mount on launch", isOn: $mountOnLaunch)
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                if editing != nil {
                    Button("Save") { doSave() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                } else {
                    Button("Mount") { doMount() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSubmit)
                }
            }
        }
        .padding()
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(
                hostAlias: hostAlias,
                onSubmit: { password in
                    showPasswordPrompt = false
                    if let config = pendingMountConfig {
                        Task {
                            let result = await manager.mountWithResult(config, sessionPassword: password)
                            await MainActor.run {
                                switch result {
                                case .success:
                                    onDismiss()
                                case .authenticationFailed:
                                    errorMessage = "Authentication failed even with password"
                                case .otherError(let message):
                                    errorMessage = message
                                }
                            }
                        }
                    }
                },
                onCancel: {
                    showPasswordPrompt = false
                    pendingMountConfig = nil
                }
            )
        }
        .onAppear {
            loadKnownHosts()

            if let config = editing {
                hostAlias = config.hostAlias
                remotePath = config.remotePath

                // Strip ~/Volumes/ prefix to show just the folder name
                let home = SSHConfigParser.realHomeDirectory
                let prefix = home + "/Volumes/"
                if config.localPath.hasPrefix(prefix) {
                    localPath = String(config.localPath.dropFirst(prefix.count))
                } else {
                    localPath = config.localPath
                }

                label = config.label
                mountOnLaunch = config.mountOnLaunch
                mountOptions = config.mountOptions
            }

            if !hostAlias.isEmpty && !knownHosts.contains(hostAlias) {
                errorMessage = "Saved host alias '\(hostAlias)' is no longer defined in ~/.ssh/config."
            }

            if !knownHosts.contains(hostAlias), let first = knownHosts.first {
                hostAlias = first
            }

            if hostAlias.isEmpty, let first = knownHosts.first {
                hostAlias = first
            }
        }
    }

    /// Build the full local path from the folder name input.
    private var resolvedLocalPath: String {
        localPath.isEmpty ? "" : "~/Volumes/\(localPath)"
    }

    private func loadKnownHosts() {
        let hosts = SSHConfigParser().knownHosts()
        knownHosts = hosts

        guard hosts.isEmpty else {
            knownHostsDiagnostic = nil
            return
        }

        let configPath = SSHConfigParser.realHomeDirectory + "/.ssh/config"
        if !FileManager.default.fileExists(atPath: configPath) {
            knownHostsDiagnostic = "Config file not found at \(configPath)."
        } else if !FileManager.default.isReadableFile(atPath: configPath) {
            knownHostsDiagnostic = "Config exists but is not readable at \(configPath)."
        } else {
            knownHostsDiagnostic = "Config is readable, but contains no concrete Host aliases."
        }
    }

    private func validateInputs() throws {
        guard hostAliasIsValid else {
            throw MountError.invalidFormat("Host alias '\(hostAlias)' is not defined in ~/.ssh/config")
        }

        let normalizedPath = remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw MountError.invalidFormat("Remote path is required")
        }
    }

    private func doMount() {
        do {
            try validateInputs()
            let config = MountConfig(
                label: label,
                hostAlias: hostAlias,
                remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
                localPath: resolvedLocalPath,
                mountOnLaunch: mountOnLaunch,
                mountOptions: mountOptions
            )
            manager.saveConfig(config)

            // Try mount without password first (key-based auth)
            Task {
                let result = await manager.mountWithResult(config, sessionPassword: nil)

                // Handle result on main thread
                await MainActor.run {
                    switch result {
                    case .success:
                        onDismiss()
                    case .authenticationFailed:
                        // Authentication failed - show password prompt
                        pendingMountConfig = config
                        showPasswordPrompt = true
                    case .otherError(let message):
                        errorMessage = message
                    }
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func doSave() {
        guard let existing = editing else { return }

        do {
            try validateInputs()
            let config = MountConfig(
                id: existing.id,
                label: label,
                hostAlias: hostAlias,
                remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
                localPath: resolvedLocalPath,
                mountOnLaunch: mountOnLaunch,
                mountOptions: mountOptions
            )
            manager.saveConfig(config)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Password Prompt Sheet

struct PasswordPromptView: View {
    let hostAlias: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    @State private var password = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Authentication Failed")
                .font(.headline)

            Text("SSH key authentication failed for **\(hostAlias)**. Please enter your password:")
                .font(.body)
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

                Button("Connect") {
                    if !password.isEmpty {
                        onSubmit(password)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password.isEmpty)
            }
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            isFocused = true
        }
    }
}
