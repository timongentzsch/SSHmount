import SwiftUI

struct MountView: View {
    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void
    /// If set, we're editing an existing saved config.
    var editing: MountConfig?

    @State private var hostAlias = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var label = ""
    @State private var mountOnLaunch = false

    @State private var profile: MountProfile = .standard
    @State private var readWorkers = 1
    @State private var writeWorkers = 1
    @State private var ioMode: MountIOMode = .blocking
    @State private var healthInterval = 5
    @State private var healthTimeout = 10
    @State private var healthFailures = 5
    @State private var busyThreshold = 32
    @State private var graceSeconds = 20
    @State private var queueTimeoutMs = 2_000
    @State private var cacheAttrSeconds = 5
    @State private var cacheDirSeconds = 5

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

    private var sshConfigPath: String {
        PathUtilities.realHomeDirectory + "/.ssh/config"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editing != nil ? "Edit Connection" : "New Mount")
                .font(.headline)

            VStack(alignment: .leading, spacing: 12) {
                hostPicker
                remotePathField
                mountPointField
                labelField
                optionsForm
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
        .frame(width: 520)
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(
                title: "Authentication Failed",
                message: "SSH key authentication failed for **\(hostAlias)**. Please enter your password:",
                actionLabel: "Connect",
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
            .frame(width: 400)
        }
        .onAppear {
            loadKnownHosts()
            hydrateFromEditingConfig()
        }
        .onChange(of: profile) { _, newValue in
            if newValue == .git {
                applyGitProfileOverrides()
            }
        }
    }

    private var hostPicker: some View {
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var remotePathField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Remote Path")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("e.g. ~/project or /var/www", text: $remotePath)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
        }
    }

    private var mountPointField: some View {
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
    }

    private var labelField: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Label")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Optional", text: $label)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var optionsForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connection Options")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Profile", selection: $profile) {
                Text("Standard").tag(MountProfile.standard)
                Text("Git-safe").tag(MountProfile.git)
            }
            .pickerStyle(.segmented)

            if profile == .git {
                Text("Git profile enforces blocking I/O, single workers, and disabled caches.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Stepper("Read workers: \(readWorkers)", value: $readWorkers, in: 1...8)
                    .disabled(profile == .git)
                Stepper("Write workers: \(writeWorkers)", value: $writeWorkers, in: 1...8)
                    .disabled(profile == .git)
            }
            Picker("I/O mode", selection: $ioMode) {
                Text("Blocking").tag(MountIOMode.blocking)
                Text("Nonblocking").tag(MountIOMode.nonblocking)
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
            .disabled(profile == .git)

            HStack {
                Stepper("Health interval: \(healthInterval)s", value: $healthInterval, in: 1...300)
                Stepper("Health timeout: \(healthTimeout)s", value: $healthTimeout, in: 1...120)
            }
            HStack {
                Stepper("Health failures: \(healthFailures)", value: $healthFailures, in: 1...12)
                Stepper("Busy threshold: \(busyThreshold)", value: $busyThreshold, in: 1...4096)
            }
            HStack {
                Stepper("Grace: \(graceSeconds)s", value: $graceSeconds, in: 0...300)
                Stepper("Queue timeout: \(queueTimeoutMs)ms", value: $queueTimeoutMs, in: 100...60_000, step: 100)
            }
            HStack {
                Stepper("Attr cache: \(cacheAttrSeconds)s", value: $cacheAttrSeconds, in: 0...300)
                    .disabled(profile == .git)
                Stepper("Dir cache: \(cacheDirSeconds)s", value: $cacheDirSeconds, in: 0...300)
                    .disabled(profile == .git)
            }
        }
    }

    /// Build the full local path from the folder name input.
    private var resolvedLocalPath: String {
        localPath.isEmpty ? "" : "~/Volumes/\(localPath)"
    }

    private func hydrateFromEditingConfig() {
        if let config = editing {
            hostAlias = config.hostAlias
            remotePath = config.remotePath

            // Strip ~/Volumes/ prefix to show just the folder name
            let home = PathUtilities.realHomeDirectory
            let prefix = home + "/Volumes/"
            if config.localPath.hasPrefix(prefix) {
                localPath = String(config.localPath.dropFirst(prefix.count))
            } else {
                localPath = config.localPath
            }

            label = config.label
            mountOnLaunch = config.mountOnLaunch

            let opts = config.options
            profile = opts.profile
            readWorkers = opts.readWorkers
            writeWorkers = opts.writeWorkers
            ioMode = opts.ioMode
            healthInterval = Int(opts.healthInterval.rounded())
            healthTimeout = Int(opts.healthTimeout.rounded())
            healthFailures = opts.healthFailures
            busyThreshold = opts.busyThreshold
            graceSeconds = Int(opts.graceSeconds.rounded())
            queueTimeoutMs = opts.queueTimeoutMs
            cacheAttrSeconds = Int(opts.cacheTimeout.rounded())
            cacheDirSeconds = Int(opts.dirCacheTimeout.rounded())
        }

        // Warn if the saved alias no longer exists, then fall back to the first known host.
        if !hostAlias.isEmpty && !knownHosts.contains(hostAlias) {
            errorMessage = "Saved host alias '\(hostAlias)' is no longer defined in ~/.ssh/config."
        }
        if !knownHosts.contains(hostAlias), let first = knownHosts.first {
            hostAlias = first
        }
    }

    private func applyGitProfileOverrides() {
        readWorkers = 1
        writeWorkers = 1
        ioMode = .blocking
        cacheAttrSeconds = 0
        cacheDirSeconds = 0
        if healthFailures < 7 { healthFailures = 7 }
        if busyThreshold < 64 { busyThreshold = 64 }
    }

    private func loadKnownHosts() {
        let hosts = SSHConfigParser().knownHosts()
        knownHosts = hosts

        guard hosts.isEmpty else {
            knownHostsDiagnostic = nil
            return
        }

        let configPath = sshConfigPath
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

    private func currentOptions() -> MountOptions {
        MountOptions(
            profile: profile,
            readWorkers: readWorkers,
            writeWorkers: writeWorkers,
            ioMode: ioMode,
            healthInterval: TimeInterval(healthInterval),
            healthTimeout: TimeInterval(healthTimeout),
            healthFailures: healthFailures,
            busyThreshold: busyThreshold,
            graceSeconds: TimeInterval(graceSeconds),
            queueTimeoutMs: queueTimeoutMs,
            cacheTimeout: TimeInterval(cacheAttrSeconds),
            dirCacheTimeout: TimeInterval(cacheDirSeconds),
            authPassword: nil
        )
    }

    /// Build a MountConfig from the current form state.
    /// Reuses the existing config's ID when editing.
    private func buildConfig() throws -> MountConfig {
        try validateInputs()
        return MountConfig(
            id: editing?.id ?? UUID(),
            label: label,
            hostAlias: hostAlias,
            remotePath: remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
            localPath: resolvedLocalPath,
            mountOnLaunch: mountOnLaunch,
            options: currentOptions()
        )
    }

    private func doMount() {
        do {
            let config = try buildConfig()
            manager.saveConfig(config)

            Task {
                let result = await manager.mountWithResult(config, sessionPassword: nil)
                await MainActor.run {
                    switch result {
                    case .success:
                        onDismiss()
                    case .authenticationFailed:
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
        do {
            let config = try buildConfig()
            manager.saveConfig(config)
            onDismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
