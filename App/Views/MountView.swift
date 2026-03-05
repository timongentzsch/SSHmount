import SwiftUI
import Observation

@Observable
final class MountFormModel {
    private static let defaults = MountOptions.defaultStandard

    var hostAlias = ""
    var remotePath = ""
    var localPath = ""
    var label = ""
    var mountOnLaunch = false

    var profile = defaults.profile
    var readWorkers = defaults.readWorkers
    var writeWorkers = defaults.writeWorkers
    var ioMode = defaults.ioMode
    var healthInterval = Int(defaults.healthInterval)
    var healthTimeout = Int(defaults.healthTimeout)
    var healthFailures = defaults.healthFailures
    var busyThreshold = defaults.busyThreshold
    var graceSeconds = Int(defaults.graceSeconds)
    var queueTimeoutMs = defaults.queueTimeoutMs
    var cacheAttrSeconds = Int(defaults.cacheTimeout)
    var cacheDirSeconds = Int(defaults.dirCacheTimeout)

    func hydrate(from config: MountConfig) {
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

    func applyGitProfileOverrides() {
        readWorkers = 0
        writeWorkers = 0
        ioMode = .blocking
        cacheAttrSeconds = 0
        cacheDirSeconds = 0
        if healthFailures < 7 { healthFailures = 7 }
        if busyThreshold < 64 { busyThreshold = 64 }
    }

    func currentOptions() -> MountOptions {
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

    var resolvedLocalPath: String {
        localPath.isEmpty ? "" : "~/Volumes/\(localPath)"
    }
}

struct MountView: View {
    var manager: MountManager
    var onDismiss: () -> Void
    var editing: MountConfig?

    @State private var form = MountFormModel()

    @State private var knownHosts: [String] = []
    @State private var knownHostsDiagnostic: String?
    @State private var errorMessage: String?
    @State private var showPasswordPrompt = false
    @State private var pendingMountConfig: MountConfig?
    @State private var showAdvanced = false

    private var hostAliasIsValid: Bool {
        knownHosts.contains(form.hostAlias)
    }

    private var canSubmit: Bool {
        hostAliasIsValid && !form.remotePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                message: "SSH key authentication failed for **\(form.hostAlias)**. Please enter your password:",
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
        .onChange(of: form.profile) { _, newProfile in
            if newProfile == .git {
                form.applyGitProfileOverrides()
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
                            form.hostAlias = ""
                        }
                        ForEach(knownHosts, id: \.self) { host in
                            Button(host) {
                                form.hostAlias = host
                            }
                        }
                    } label: {
                        HStack {
                            Text(form.hostAlias.isEmpty ? "Select a host..." : form.hostAlias)
                                .foregroundStyle(form.hostAlias.isEmpty ? .secondary : .primary)
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
                    TextField("e.g. ~/project or /var/www", text: $form.remotePath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, design: .monospaced))
                }

                formField(title: "Mount Point") {
                    HStack(spacing: 0) {
                        Text("~/Volumes/")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 2)
                        TextField("folder name", text: $form.localPath)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                    }
                }

                formField(title: "Label", detail: "Optional Finder-friendly name") {
                    TextField("Friendly name", text: $form.label)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
            }

            HStack(spacing: 10) {
                Label("Mount on app launch", systemImage: "power")
                    .font(.system(size: 13, weight: .medium))
                Spacer()
                Toggle("", isOn: $form.mountOnLaunch)
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

                    Picker("Profile", selection: $form.profile) {
                        ForEach(MountProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                }

                if let compatibilityDescription = form.profile.compatibilityDescription {
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
                    Stepper(form.profile == .git ? "Primary session" : "\(form.readWorkers)", value: $form.readWorkers, in: form.profile == .git ? 0...0 : form.profile.workerRange)
                        .disabled(form.profile == .git)
                }

                HStack {
                    Text("Write workers")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper(form.profile == .git ? "Primary session" : "\(form.writeWorkers)", value: $form.writeWorkers, in: form.profile == .git ? 0...0 : form.profile.workerRange)
                        .disabled(form.profile == .git)
                }

                HStack {
                    Text("I/O Mode")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Picker("", selection: $form.ioMode) {
                        Text("Blocking").tag(MountIOMode.blocking)
                        Text("Nonblocking").tag(MountIOMode.nonblocking)
                    }
                    .pickerStyle(.menu)
                    .frame(width: 120)
                    .disabled(form.profile == .git)
                }
            }

            Divider()

            Group {
                HStack {
                    Text("Health interval")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(form.healthInterval)s", value: $form.healthInterval, in: 1...300)
                }

                HStack {
                    Text("Health timeout")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(form.healthTimeout)s", value: $form.healthTimeout, in: 1...120)
                }

                HStack {
                    Text("Health failures")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(form.healthFailures)", value: $form.healthFailures, in: 1...12)
                }
            }

            Divider()

            Group {
                HStack {
                    Text("Attr cache")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(form.cacheAttrSeconds)s", value: $form.cacheAttrSeconds, in: 0...300)
                        .disabled(form.profile == .git)
                }

                HStack {
                    Text("Dir cache")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Stepper("\(form.cacheDirSeconds)s", value: $form.cacheDirSeconds, in: 0...300)
                        .disabled(form.profile == .git)
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

    private func hydrateFromEditingConfig() {
        if let config = editing {
            form.hydrate(from: config)
        }

        if !form.hostAlias.isEmpty && !knownHosts.contains(form.hostAlias) {
            errorMessage = "Saved host alias '\(form.hostAlias)' is no longer defined in ~/.ssh/config."
        }
        if !knownHosts.contains(form.hostAlias), let first = knownHosts.first {
            form.hostAlias = first
        }
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
            throw MountError.invalidFormat("Host alias '\(form.hostAlias)' is not defined in ~/.ssh/config")
        }

        let normalizedPath = form.remotePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedPath.isEmpty else {
            throw MountError.invalidFormat("Remote path is required")
        }
    }

    private func buildConfig() throws -> MountConfig {
        try validateInputs()
        return MountConfig(
            id: editing?.id ?? UUID(),
            label: form.label,
            hostAlias: form.hostAlias,
            remotePath: form.remotePath.trimmingCharacters(in: .whitespacesAndNewlines),
            localPath: form.resolvedLocalPath,
            mountOnLaunch: form.mountOnLaunch,
            options: form.currentOptions()
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
