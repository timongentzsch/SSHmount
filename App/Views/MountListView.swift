import SwiftUI

extension MountStatus {
    var color: Color {
        switch self {
        case .connected: return SSHMountTheme.success
        case .connecting, .reconnecting: return SSHMountTheme.warning
        case .unreachable: return SSHMountTheme.warning
        case .disconnected: return .gray
        case .error: return SSHMountTheme.danger
        }
    }
    
    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise"
        case .unreachable: return "exclamationmark.triangle"
        case .disconnected: return "circle"
        case .error: return "xmark.circle"
        }
    }
}

struct MountListView: View {
    @ObservedObject var manager: MountManager
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    @State private var showOnboarding = false
    @State private var showNewMount = false
    @State private var editingConfig: MountConfig?
    @State private var passwordPromptConfig: MountConfig?
    @State private var searchText = ""
    @State private var activeSectionExpanded = true
    @State private var savedSectionExpanded = true
    
    private var windowWidth: CGFloat {
        if showNewMount || editingConfig != nil {
            return 520
        }
        return 340
    }

    private func matchesSearch(_ config: MountConfig) -> Bool {
        config.label.localizedCaseInsensitiveContains(searchText) ||
        config.localPath.localizedCaseInsensitiveContains(searchText) ||
        config.hostAlias.localizedCaseInsensitiveContains(searchText)
    }

    private var filteredActiveMounts: [MountEntry] {
        guard !searchText.isEmpty else { return manager.mounts }
        return manager.mounts.filter { matchesSearch($0.config) }
    }

    private var filteredInactiveConfigs: [MountConfig] {
        let activeConfigIDs = Set(manager.mounts.map(\.config.id))
        let inactive = manager.savedConfigs.filter { !activeConfigIDs.contains($0.id) }
        guard !searchText.isEmpty else { return inactive }
        return inactive.filter { matchesSearch($0) }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !hasCompletedOnboarding || showOnboarding {
                OnboardingView(manager: manager, onDismiss: {
                    withAnimation(.viewTransition) {
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
                        withAnimation(.viewTransition) {
                            passwordPromptConfig = nil
                        }
                        Task {
                            let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
                            _ = await manager.mountWithResult(config, sessionPassword: trimmed.isEmpty ? nil : trimmed)
                        }
                    },
                    onCancel: {
                        withAnimation(.viewTransition) {
                            passwordPromptConfig = nil
                        }
                    }
                )
                .transition(.opacity)
            } else if showNewMount || editingConfig != nil {
                MountView(
                    manager: manager,
                    onDismiss: {
                        withAnimation(.viewTransition) {
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
        .frame(width: windowWidth)
        .sshMountCanvas()
        .animation(.viewTransition, value: showOnboarding)
        .animation(.viewTransition, value: showNewMount)
        .animation(.viewTransition, value: editingConfig?.id)
        .animation(.viewTransition, value: passwordPromptConfig?.id)
    }
    
    private var mountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
            searchBar

            ScrollView {
                VStack(alignment: .leading, spacing: SSHMountTheme.sectionSpacing) {
                    sectionActive
                    sectionSaved
                }
                .padding(.horizontal, SSHMountTheme.outerPadding)
                .padding(.vertical, SSHMountTheme.innerPadding)
            }
            .frame(maxHeight: 400)

            footerView
        }
    }

    private var headerView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("SSHMount")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(manager.mounts.count) active · \(manager.savedConfigs.count) saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !manager.permissionStatus.allGood {
                SSHMountBadge(title: "Setup")
            }
        }
        .padding(.horizontal, SSHMountTheme.outerPadding)
        .padding(.top, SSHMountTheme.outerPadding)
        .padding(.bottom, SSHMountTheme.innerPadding)
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            
            TextField("Filter connections", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
            
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, SSHMountTheme.innerPadding)
        .frame(minHeight: SSHMountTheme.controlHeight)
        .sshMountSurface()
        .padding(.horizontal, SSHMountTheme.outerPadding)
        .padding(.bottom, SSHMountTheme.innerPadding)
    }
    
    @ViewBuilder
    private var sectionActive: some View {
        VStack(alignment: .leading, spacing: SSHMountTheme.compactSpacing) {
            sectionHeader(
                title: "Active",
                icon: "bolt.fill",
                iconColor: .secondary,
                count: filteredActiveMounts.count,
                isExpanded: $activeSectionExpanded,
                trailing: {
                    if !filteredActiveMounts.isEmpty {
                        Button {
                            Task { await manager.unmountAll() }
                        } label: {
                            Image(systemName: "eject.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(SSHMountIconButtonStyle(layout: .square))
                        .help("Unmount all")
                    }
                }
            )
            if activeSectionExpanded {
                if filteredActiveMounts.isEmpty {
                    emptyStateView(message: "No active mounts", icon: "externaldrive.badge.minus")
                } else {
                    ForEach(filteredActiveMounts) { entry in
                        ConnectionRow(
                            label: entry.config.label,
                            subtitle: PathUtilities.abbreviateHome(entry.config.localPath),
                            host: entry.config.hostAlias,
                            status: entry.status,
                            connectedSince: entry.connectedSince,
                            actions: {
                                connectionActions(for: entry)
                            }
                        )
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var sectionSaved: some View {
        let configs = filteredInactiveConfigs
        VStack(alignment: .leading, spacing: SSHMountTheme.compactSpacing) {
            sectionHeader(
                title: "Saved",
                icon: "bookmark.fill",
                iconColor: .secondary,
                count: configs.count,
                isExpanded: $savedSectionExpanded,
                trailing: {
                    Button {
                        withAnimation(.viewTransition) {
                            showNewMount = true
                        }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(SSHMountIconButtonStyle(layout: .square))
                    .help("Add new connection")
                }
            )
            if savedSectionExpanded {
                if configs.isEmpty {
                    emptyStateView(
                        message: searchText.isEmpty ? "No saved connections" : "No matches found",
                        icon: searchText.isEmpty ? "bookmark" : "magnifyingglass"
                    )
                } else {
                    ForEach(configs) { config in
                        ConnectionRow(
                            label: config.label,
                            subtitle: nil,
                            host: config.hostAlias,
                            status: .disconnected,
                            connectedSince: nil,
                            compactLayout: true,
                            actions: {
                                savedConnectionActions(for: config)
                            }
                        )
                    }
                }
            }
        }
    }
    
    private func sectionHeader(
        title: String,
        icon: String,
        iconColor: Color,
        count: Int,
        isExpanded: Binding<Bool>,
        @ViewBuilder trailing: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    isExpanded.wrappedValue.toggle()
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 10)
                    
                    Image(systemName: icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(iconColor)
                    
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if count > 0 {
                        SSHMountBadge(title: "\(count)")
                    }
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            trailing()
        }
    }
    
    private func emptyStateView(message: String, icon: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: SSHMountTheme.compactSpacing) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .sshMountSurface(SSHMountTheme.surfaceSoft)
    }
    
    @ViewBuilder
    private func connectionActions(for entry: MountEntry) -> some View {
        if entry.status == .connected {
            Button {
                openInFinder(path: entry.config.localPath)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SSHMountIconButtonStyle(layout: .square))
            .help("Open in Finder")
            
            Button {
                openTerminal(at: entry.config.localPath)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SSHMountIconButtonStyle(layout: .square))
            .help("Open in Terminal")
            
            Button {
                Task { await manager.unmount(entry) }
            } label: {
                Image(systemName: "eject")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SSHMountIconButtonStyle(layout: .square))
            .help("Unmount")
        }
    }
    
    @ViewBuilder
    private func savedConnectionActions(for config: MountConfig) -> some View {
        Button {
            Task {
                let result = await manager.mountWithResult(config)
                if case .authenticationFailed = result {
                    withAnimation(.viewTransition) {
                        passwordPromptConfig = config
                    }
                }
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(SSHMountIconButtonStyle(layout: .square))
        .help("Mount")
        
        Button {
            withAnimation(.viewTransition) {
                editingConfig = config
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(SSHMountIconButtonStyle(layout: .square))
        .help("Edit")
        
        Button {
            manager.deleteConfig(config)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10, weight: .semibold))
        }
        .buttonStyle(SSHMountIconButtonStyle(layout: .square))
        .help("Delete")
    }
    
    private var footerView: some View {
        HStack(spacing: 10) {
            Button {
                openSSHConfig()
            } label: {
                Label("SSH Config", systemImage: "doc.text")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SSHMountIconButtonStyle())
            
            Spacer()
            
            if !manager.permissionStatus.allGood {
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(SSHMountIconButtonStyle(layout: .square))
                .help("Setup issues")
            }
            
            Button {
                Task {
                    await manager.unmountAll()
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(SSHMountIconButtonStyle())
        }
        .padding(.horizontal, SSHMountTheme.outerPadding)
        .padding(.vertical, SSHMountTheme.innerPadding)
    }
}

// MARK: - Shared Connection Row

struct ConnectionRow<Actions: View>: View {
    let label: String
    let subtitle: String?
    let host: String?
    let status: MountStatus
    var connectedSince: Date?
    var compactLayout = false
    @ViewBuilder let actions: () -> Actions

    private var shouldPulse: Bool {
        status == .unreachable || status == .reconnecting || status == .connecting
    }

    private var showStatusText: Bool {
        status != .disconnected
    }

    private var tooltipText: String {
        var parts: [String] = []
        if let host = host {
            parts.append(host)
        }
        if let subtitle = subtitle {
            parts.append(subtitle)
        }
        parts.append(status.text)
        return parts.joined(separator: " • ")
    }

    var body: some View {
        HStack(spacing: SSHMountTheme.innerPadding) {
            Image(systemName: status.systemImage)
                .font(.system(size: compactLayout ? 12 : 13, weight: .medium))
                .foregroundStyle(status.color)
                .symbolEffect(.pulse, isActive: shouldPulse)
                .frame(width: 16, height: 16)

            VStack(alignment: .leading, spacing: compactLayout ? 2 : 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(label)
                        .font(.system(size: compactLayout ? 12 : 13, weight: .semibold))
                        .lineLimit(1)

                    if showStatusText {
                        Text(status.text)
                            .font(.system(size: 10))
                            .foregroundStyle(status.color)
                    }
                }

                if let host {
                    Text(host)
                        .font(.system(size: compactLayout ? 11 : 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let subtitle, !compactLayout {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if let connectedSince, status == .connected {
                    Text("Connected \(connectedSince, style: .relative) ago")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: compactLayout ? SSHMountTheme.compactSpacing : SSHMountTheme.innerPadding)

            HStack(spacing: compactLayout ? 4 : 6) {
                actions()
            }
        }
        .padding(.horizontal, SSHMountTheme.innerPadding)
        .padding(.vertical, compactLayout ? 6 : 8)
        .sshMountSurface(SSHMountTheme.surfaceSoft)
        .contentShape(Rectangle())
        .help(tooltipText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(status.text)")
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
                activate
            end tell
        end run
        """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    process.arguments = ["-e", script, path]
    try? process.run()
}

/// Open a single Finder window for the given path.
/// Uses NSWorkspace.selectFile which reuses an existing window if one is already
/// showing the same path, and only brings that window to front.
private func openInFinder(path: String) {
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
}

/// Open ~/.ssh/config in the default editor, creating it if needed.
private func openSSHConfig() {
    let configPath = PathUtilities.realHomeDirectory + "/.ssh/config"
    let configDirectory = (configPath as NSString).deletingLastPathComponent
    let fileManager = FileManager.default
    let workspace = NSWorkspace.shared
    let fileURL = URL(fileURLWithPath: configPath)

    try? fileManager.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
    if !fileManager.fileExists(atPath: configPath) {
        try? "".write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    let preferredBundleIDs = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    for bundleID in preferredBundleIDs {
        if let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            workspace.open(
                [fileURL],
                withApplicationAt: appURL,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { _, _ in }
            )
            return
        }
    }

    workspace.open(fileURL)
}
