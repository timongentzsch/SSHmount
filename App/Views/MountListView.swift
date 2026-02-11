import SwiftUI

// MARK: - Color extension for MountStatus

extension MountStatus {
    var color: Color {
        switch self {
        case .connected: .green
        case .connecting, .reconnecting: .orange
        case .unreachable: .yellow
        case .disconnected: .gray
        case .error: .red
        }
    }
}

// MARK: - Main View

struct MountListView: View {
    @ObservedObject var manager: MountManager
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showNewMount = false
    @State private var editingConfig: MountConfig?
    @State private var passwordPromptConfig: MountConfig?

    /// Saved configs that are NOT currently mounted.
    private var inactiveSavedConfigs: [MountConfig] {
        let activeConfigIDs = Set(manager.mounts.map(\.config.id))
        return manager.savedConfigs.filter { !activeConfigIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !hasCompletedOnboarding || showOnboarding {
                OnboardingView(manager: manager, onDismiss: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        hasCompletedOnboarding = true
                        showOnboarding = false
                    }
                })
                .transition(.opacity)
            } else if let config = passwordPromptConfig {
                PasswordPromptView(
                    title: "Authentication Failed",
                    message: "SSH key authentication failed for **\(config.label)**. Please enter your password:",
                    actionLabel: "Mount",
                    onSubmit: { password in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            passwordPromptConfig = nil
                        }
                        Task {
                            let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
                            _ = await manager.mountWithResult(config, sessionPassword: trimmed.isEmpty ? nil : trimmed)
                        }
                    },
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            passwordPromptConfig = nil
                        }
                    }
                )
                .transition(.opacity)
            } else if showNewMount || editingConfig != nil {
                NewMountView(
                    manager: manager,
                    onDismiss: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showNewMount = false
                            editingConfig = nil
                        }
                    },
                    editing: editingConfig
                )
                .transition(.opacity)
            } else {
                mountList
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 8)
        .frame(width: 320)
        .animation(.easeInOut(duration: 0.2), value: showOnboarding)
        .animation(.easeInOut(duration: 0.2), value: showNewMount)
        .animation(.easeInOut(duration: 0.2), value: editingConfig?.id)
        .animation(.easeInOut(duration: 0.2), value: passwordPromptConfig?.id)
    }

    private var mountList: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Active header with eject-all
            HStack {
                Text("Active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await manager.unmountAll() }
                } label: {
                    Image(systemName: "eject")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("Unmount all")
                .disabled(manager.mounts.isEmpty)
            }
            .padding(.horizontal)

            if manager.mounts.isEmpty {
                Text("No active mounts")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.vertical, 2)
            } else {
                ForEach(manager.mounts) { entry in
                    ConnectionRow(
                        label: entry.config.label,
                        subtitle: abbreviateHome(entry.config.localPath),
                        status: entry.status,
                        connectedSince: entry.connectedSince,
                        retryAttempt: entry.retryAttempt,
                        retryNextAt: entry.retryNextAt,
                        reconnectReason: entry.lastReconnectReason,
                        actions: {
                            if entry.status == .connected {
                                Button {
                                    openInFinder(path: entry.config.localPath)
                                } label: {
                                    Image(systemName: "folder")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .help("Open in Finder")

                                Button {
                                    openTerminal(at: entry.config.localPath)
                                } label: {
                                    Image(systemName: "terminal")
                                        .font(.caption2)
                                }
                                .buttonStyle(.plain)
                                .help("Open in Terminal")
                            }

                            Button {
                                Task { await manager.unmount(entry) }
                            } label: {
                                Image(systemName: "eject")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Unmount")

                            Button {
                                Task { await manager.unmount(entry, force: true) }
                            } label: {
                                Image(systemName: "eject.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.orange)
                            }
                            .buttonStyle(.plain)
                            .help("Force unmount")
                        }
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            Divider()

            // Saved header with +
            HStack {
                Text("Saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showNewMount = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .help("New connection")
            }
            .padding(.horizontal)

            if inactiveSavedConfigs.isEmpty {
                Text("No saved connections")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal)
                    .padding(.vertical, 2)
            } else {
                ForEach(inactiveSavedConfigs) { config in
                    ConnectionRow(
                        label: config.label,
                        subtitle: abbreviateHome(config.localPath),
                        status: .disconnected,
                        connectedSince: nil,
                        actions: {
                            Button {
                                Task {
                                    let result = await manager.mountWithResult(config)
                                    if case .authenticationFailed = result {
                                        await MainActor.run {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                passwordPromptConfig = config
                                            }
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "play.fill")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Mount")

                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    editingConfig = config
                                }
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.caption2)
                            }
                            .buttonStyle(.plain)
                            .help("Edit connection")

                            Button {
                                manager.deleteConfig(config)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Remove saved connection")
                        }
                    )
                }
            }

            Divider()

            // Status — clickable to re-open onboarding when any check fails
            if !manager.permissionStatus.allGood {
                Button { showOnboarding = true } label: {
                    StatusSection(status: manager.permissionStatus)
                }
                .buttonStyle(.plain)
            } else {
                StatusSection(status: manager.permissionStatus)
            }
            Divider()

            Button("Quit") {
                Task {
                    await manager.unmountAll()
                    NSApplication.shared.terminate(nil)
                }
            }
            .padding(.horizontal)
        }
    }
}

// MARK: - Shared Connection Row

struct ConnectionRow<Actions: View>: View {
    let label: String
    let subtitle: String?
    let status: MountStatus
    var connectedSince: Date?
    var retryAttempt: Int = 0
    var retryNextAt: Date?
    var reconnectReason: String? = nil
    @ViewBuilder let actions: () -> Actions

    @State private var pulsing = false

    private var statusColor: Color { status.color }

    private var shouldPulse: Bool {
        status == .unreachable || status == .reconnecting || status == .connecting
    }

    private var showStatusText: Bool {
        status != .disconnected
    }

    var body: some View {
        HStack(spacing: 8) {
            // LED dot with glow
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(
                    color: statusColor.opacity(pulsing ? 0.3 : 0.6),
                    radius: pulsing ? 2 : 4
                )
                .opacity(pulsing ? 0.3 : 1.0)
                .animation(
                    shouldPulse
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : .default,
                    value: pulsing
                )
                .animation(.easeInOut(duration: 0.4), value: status)
                .onChange(of: shouldPulse) { _, newValue in
                    pulsing = newValue
                }
                .onAppear {
                    pulsing = shouldPulse
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)

                if showStatusText {
                    HStack(spacing: 0) {
                        if status == .reconnecting, retryAttempt > 0 {
                            retryStatusText
                        } else {
                            Text(status == .reconnecting
                                 ? "\(status.text)\(reconnectReason.map { " (\($0))" } ?? "")"
                                 : status.text)
                                .foregroundStyle(statusColor)

                            if let subtitle {
                                Text(" · ")
                                    .foregroundStyle(.tertiary)
                                Text(subtitle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .font(.caption)
                    .lineLimit(1)

                    if let connectedSince, status == .connected {
                        Text(connectedSince, style: .timer)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                } else if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            actions()
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    /// "Retry #N in Xs" with a live countdown.
    @ViewBuilder
    private var retryStatusText: some View {
        if let retryNextAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let remaining = max(0, Int(retryNextAt.timeIntervalSince(context.date)))
                if remaining > 0 {
                    Text("Retry #\(retryAttempt) in \(remaining)s\(reconnectReason.map { " (\($0))" } ?? "")")
                        .foregroundStyle(statusColor)
                        .monospacedDigit()
                } else {
                    Text("Retry #\(retryAttempt)...\(reconnectReason.map { " (\($0))" } ?? "")")
                        .foregroundStyle(statusColor)
                }
            }
        } else {
            Text("Reconnecting...\(reconnectReason.map { " (\($0))" } ?? "")")
                .foregroundStyle(statusColor)
        }
    }
}


// MARK: - Status Section

struct StatusSection: View {
    let status: PermissionStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Setup")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            StatusRow(label: "Installed in /Applications", ok: status.appInstalled)
            StatusRow(label: "Extension enabled", ok: status.extensionEnabled)
            StatusRow(label: "SSH keys found", ok: status.sshKeysFound)
        }
    }
}

struct StatusRow: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(ok ? .green : .red)
                .contentTransition(.symbolEffect(.replace))
                .animation(.easeInOut(duration: 0.3), value: ok)
            Text(label)
                .font(.caption)
        }
        .padding(.horizontal)
    }
}

// MARK: - Helpers

/// Open Terminal.app with a new window cd'd to the given directory.
/// Uses `do script` without AppleScript `activate` so existing Terminal windows
/// stay where they are, then brings only Terminal's front window forward via
/// NSRunningApplication.activate() (macOS 14+ doesn't raise all windows).
private func openTerminal(at path: String) {
    let script = """
        on run argv
            set targetPath to item 1 of argv
            tell application "Terminal"
                do script "cd " & quoted form of targetPath & "; clear"
            end tell
        end run
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script, path]
    try? process.run()

    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(500))
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal")
            .first?.activate()
    }
}

/// Open a single Finder window for the given path.
/// Uses NSWorkspace.selectFile which reuses an existing window if one is already
/// showing the same path, and only brings that window to front.
private func openInFinder(path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}

/// Replace the user's home directory prefix with ~
private func abbreviateHome(_ path: String) -> String {
    PathUtilities.abbreviateHome(path)
}
