import SwiftUI

struct MountView: View {
    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void
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
    @State private var showAdvanced = false

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
        VStack(alignment: .leading, spacing: 0) {
            headerView
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    basicSection
                    optionsSection
                    if showAdvanced {
                        advancedSection
                    }
                }
                .padding(20)
            }
            
            Divider()
            footerView
        }
        .frame(width: 520, height: 540)
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
    }

    private var headerView: some View {
        HStack {
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            Text(editing != nil ? "Edit Connection" : "New Mount")
                .font(.system(size: 15, weight: .semibold))
            
            Spacer()
            
            Button {
                onDismiss()
            } label: {
                Text("Cancel")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Connection")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 6) {
                if knownHosts.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("No SSH host aliases found")
                            .font(.system(size: 12))
                    }
                    if let knownHostsDiagnostic {
                        Text(knownHostsDiagnostic)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Menu {
                        Button("Select a host...") {
                            hostAlias = ""
                        }
                        ForEach(knownHosts, id: \.self) { host in
                            Button(host) {
                                hostAlias = host
                            }
                        }
                    } label: {
                        HStack {
                            Text(hostAlias.isEmpty ? "Select a host..." : hostAlias)
                                .foregroundStyle(hostAlias.isEmpty ? .secondary : .primary)
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Remote Path")
                    .font(.system(size: 12, weight: .medium))
                TextField("e.g. ~/project or /var/www", text: $remotePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Mount Point")
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 0) {
                    Text("~/Volumes/")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 10)
                    TextField("folder name", text: $localPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Label (optional)")
                    .font(.system(size: 12, weight: .medium))
                TextField("Friendly name", text: $label)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $mountOnLaunch) {
                Label("Mount on app launch", systemImage: "power")
                    .font(.system(size: 13))
            }
            .toggleStyle(.switch)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Options")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Profile")
                        .font(.system(size: 13))
                    Spacer()
                    Picker("", selection: $profile) {
                        Text("Standard").tag(MountProfile.standard)
                        Text("Git-safe").tag(MountProfile.git)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                
                if profile == .git {
                    Text("Git profile enforces blocking I/O, single workers, and disabled caches for better compatibility.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            Button {
                withAnimation {
                    showAdvanced.toggle()
                }
            } label: {
                HStack {
                    Image(systemName: showAdvanced ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Advanced Options")
                        .font(.system(size: 13))
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                HStack {
                    Text("Read workers")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(readWorkers)", value: $readWorkers, in: 1...8)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("Write workers")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(writeWorkers)", value: $writeWorkers, in: 1...8)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("I/O Mode")
                        .font(.system(size: 12))
                    Spacer()
                    Picker("", selection: $ioMode) {
                        Text("Blocking").tag(MountIOMode.blocking)
                        Text("Nonblocking").tag(MountIOMode.nonblocking)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .disabled(profile == .git)
                }
            }

            Divider()

            Group {
                HStack {
                    Text("Health interval")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(healthInterval)s", value: $healthInterval, in: 1...300)
                }
                
                HStack {
                    Text("Health timeout")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(healthTimeout)s", value: $healthTimeout, in: 1...120)
                }
                
                HStack {
                    Text("Health failures")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(healthFailures)", value: $healthFailures, in: 1...12)
                }
            }

            Divider()

            Group {
                HStack {
                    Text("Attr cache")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(cacheAttrSeconds)s", value: $cacheAttrSeconds, in: 0...300)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("Dir cache")
                        .font(.system(size: 12))
                    Spacer()
                    Stepper("\(cacheDirSeconds)s", value: $cacheDirSeconds, in: 0...300)
                        .disabled(profile == .git)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var footerView: some View {
        VStack(spacing: 8) {
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(.red)
                }
            }
            
            HStack {
                Spacer()
                
                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .frame(width: 80)
                }
                .buttonStyle(.bordered)
                
                if editing != nil {
                    Button {
                        doSave()
                    } label: {
                        Text("Save")
                            .frame(width: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                } else {
                    Button {
                        doMount()
                    } label: {
                        Text("Mount")
                            .frame(width: 80)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(16)
    }

    private var resolvedLocalPath: String {
        localPath.isEmpty ? "" : "~/Volumes/\(localPath)"
    }

    private func hydrateFromEditingConfig() {
        if let config = editing {
            hostAlias = config.hostAlias
            remotePath = config.remotePath

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
            knownHostsDiagnostic = "Config exists but is not readable."
        } else {
            knownHostsDiagnostic = "No concrete Host aliases found."
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
