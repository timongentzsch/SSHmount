import SwiftUI

struct MountView: View {
    private static let defaultOptions = MountOptions.defaultStandard

    @ObservedObject var manager: MountManager
    var onDismiss: () -> Void
    var editing: MountConfig?

    @State private var hostAlias = ""
    @State private var remotePath = ""
    @State private var localPath = ""
    @State private var label = ""
    @State private var mountOnLaunch = false

    @State private var profile = Self.defaultOptions.profile
    @State private var readWorkers = Self.defaultOptions.readWorkers
    @State private var writeWorkers = Self.defaultOptions.writeWorkers
    @State private var ioMode = Self.defaultOptions.ioMode
    @State private var healthInterval = Int(Self.defaultOptions.healthInterval)
    @State private var healthTimeout = Int(Self.defaultOptions.healthTimeout)
    @State private var healthFailures = Self.defaultOptions.healthFailures
    @State private var busyThreshold = Self.defaultOptions.busyThreshold
    @State private var graceSeconds = Int(Self.defaultOptions.graceSeconds)
    @State private var queueTimeoutMs = Self.defaultOptions.queueTimeoutMs
    @State private var cacheAttrSeconds = Int(Self.defaultOptions.cacheTimeout)
    @State private var cacheDirSeconds = Int(Self.defaultOptions.dirCacheTimeout)

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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    basicSection
                    optionsSection
                    if showAdvanced {
                        advancedSection
                    }
                }
                .padding(.horizontal, SSHMountTheme.outerPadding)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)

            footerView
        }
        .frame(width: 500, height: 500)
        .background(.clear)
        .sheet(isPresented: $showPasswordPrompt) {
            PasswordPromptView(
                title: "Authentication Failed",
                message: "SSH key authentication failed for **\(hostAlias)**. Please enter your password:",
                actionLabel: "Connect",
                onSubmit: { password in
                    showPasswordPrompt = false
                    if let config = pendingMountConfig {
                        Task {
                            let result = await manager.mountWithPassword(password, config: config)
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
        .onChange(of: profile) { _, newProfile in
            if newProfile == .git {
                applyGitProfileOverrides()
            }
        }
    }

    private var headerView: some View {
        HStack {
            Text(editing != nil ? "Edit Connection" : "New Mount")
                .font(.system(size: 15, weight: .semibold))

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
            }
            .buttonStyle(SSHMountIconButtonStyle(layout: .square))
        }
        .padding(.horizontal, SSHMountTheme.outerPadding)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var basicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SSHMountSectionTitle(title: "Connection")

            VStack(alignment: .leading, spacing: 8) {
                if knownHosts.isEmpty {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(SSHMountTheme.warning)
                        Text("No SSH host aliases found")
                            .font(.system(size: 12, weight: .semibold))
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
                                .font(.system(size: 13, design: .monospaced))
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, SSHMountTheme.innerPadding)
                        .frame(minHeight: SSHMountTheme.controlHeight)
                        .sshMountSurface()
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                formField(title: "Remote Path") {
                    TextField("e.g. ~/project or /var/www", text: $remotePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }

                formField(title: "Mount Point") {
                    HStack(spacing: 0) {
                        Text("~/Volumes/")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        TextField("folder name", text: $localPath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                formField(title: "Label", detail: "Optional Finder-friendly name") {
                    TextField("Friendly name", text: $label)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
            }

            HStack(spacing: 10) {
                Label("Mount on app launch", systemImage: "power")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: $mountOnLaunch)
                    .labelsHidden()
            }
            .toggleStyle(.switch)
        }
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SSHMountSectionTitle(title: "Options")

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: SSHMountTheme.compactSpacing) {
                    Text("Profile")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)

                    Picker("Profile", selection: $profile) {
                        ForEach(MountProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }

                if let compatibilityDescription = profile.compatibilityDescription {
                    Text(compatibilityDescription)
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
        VStack(alignment: .leading, spacing: 10) {
            SSHMountSectionTitle(title: "Advanced")

            Group {
                HStack {
                    Text("Read workers")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper(profile == .git ? "Primary session" : "\(readWorkers)", value: $readWorkers, in: profile == .git ? 0...0 : profile.workerRange)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("Write workers")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper(profile == .git ? "Primary session" : "\(writeWorkers)", value: $writeWorkers, in: profile == .git ? 0...0 : profile.workerRange)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("I/O Mode")
                        .font(.system(size: 12, weight: .medium))
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
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(healthInterval)s", value: $healthInterval, in: 1...300)
                }
                
                HStack {
                    Text("Health timeout")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(healthTimeout)s", value: $healthTimeout, in: 1...120)
                }
                
                HStack {
                    Text("Health failures")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(healthFailures)", value: $healthFailures, in: 1...12)
                }
            }

            Divider()

            Group {
                HStack {
                    Text("Attr cache")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(cacheAttrSeconds)s", value: $cacheAttrSeconds, in: 0...300)
                        .disabled(profile == .git)
                }
                
                HStack {
                    Text("Dir cache")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(cacheDirSeconds)s", value: $cacheDirSeconds, in: 0...300)
                        .disabled(profile == .git)
                }
            }
        }
        .padding(SSHMountTheme.outerPadding)
        .sshMountSurface(SSHMountTheme.surfaceSoft)
    }

    private var footerView: some View {
        VStack(spacing: 6) {
            if let error = errorMessage {
                HStack {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(SSHMountTheme.danger)
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(SSHMountTheme.danger)
                }
            }
            
            HStack {
                Spacer()
                
                Button {
                    onDismiss()
                } label: {
                    Text("Cancel")
                        .frame(width: 76)
                }
                .buttonStyle(.bordered)

                if editing != nil {
                    Button {
                        doSave()
                    } label: {
                        Text("Save")
                            .frame(width: 76)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SSHMountTheme.tint)
                    .disabled(!canSubmit)
                } else {
                    Button {
                        doMount()
                    } label: {
                        Text("Mount")
                            .frame(width: 76)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(SSHMountTheme.tint)
                    .disabled(!canSubmit)
                }
            }
        }
        .padding(.horizontal, SSHMountTheme.outerPadding)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private func formField<Content: View>(
        title: String,
        detail: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            content()
                .padding(.horizontal, SSHMountTheme.innerPadding)
                .frame(minHeight: SSHMountTheme.controlHeight)
                .sshMountSurface()
        }
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

            if opts.profile == .git {
                applyGitProfileOverrides()
            }
        }

        if !hostAlias.isEmpty && !knownHosts.contains(hostAlias) {
            errorMessage = "Saved host alias '\(hostAlias)' is no longer defined in ~/.ssh/config."
        }
        if !knownHosts.contains(hostAlias), let first = knownHosts.first {
            hostAlias = first
        }
    }

    private func applyGitProfileOverrides() {
        readWorkers = 0
        writeWorkers = 0
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
