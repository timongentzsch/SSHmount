import SwiftUI

extension MountStatus {
    var color: Color {
        switch self {
        case .connected: return .green
        case .connecting, .reconnecting: return .orange
        case .unreachable: return .yellow
        case .disconnected: return .gray
        case .error: return .red
        }
    }
    
    var systemImage: String {
        switch self {
        case .connected: return "checkmark.circle.fill"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .reconnecting: return "arrow.clockwise"
        case .unreachable: return "exclamationmark.triangle.fill"
        case .disconnected: return "circle"
        case .error: return "xmark.circle.fill"
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
    
    private var inactiveSavedConfigs: [MountConfig] {
        let activeConfigIDs = Set(manager.mounts.map(\.config.id))
        return manager.savedConfigs.filter { !activeConfigIDs.contains($0.id) }
    }
    
    private var filteredActiveMounts: [MountEntry] {
        guard !searchText.isEmpty else { return manager.mounts }
        return manager.mounts.filter { entry in
            entry.config.label.localizedCaseInsensitiveContains(searchText) ||
            entry.config.localPath.localizedCaseInsensitiveContains(searchText) ||
            entry.config.host.localizedCaseInsensitiveContains(searchText)
        }
    }
    
    private var filteredInactiveConfigs: [MountConfig] {
        guard !searchText.isEmpty else { return inactiveSavedConfigs }
        return inactiveSavedConfigs.filter { config in
            config.label.localizedCaseInsensitiveContains(searchText) ||
            config.localPath.localizedCaseInsensitiveContains(searchText) ||
            config.host.localizedCaseInsensitiveContains(searchText)
        }
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
        .animation(.viewTransition, value: showOnboarding)
        .animation(.viewTransition, value: showNewMount)
        .animation(.viewTransition, value: editingConfig?.id)
        .animation(.viewTransition, value: passwordPromptConfig?.id)
    }
    
    private var mountList: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchBar
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            
            Divider()
            
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    sectionActive
                    sectionDivider
                    sectionSaved
                }
            }
            .frame(maxHeight: 400)
            
            Divider()
            
            footerView
        }
    }
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            
            TextField("Filter connections", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
            
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
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
    
    @ViewBuilder
    private var sectionActive: some View {
        sectionHeader(
            title: "Active",
            icon: "bolt.fill",
            iconColor: .yellow,
            count: filteredActiveMounts.count,
            isExpanded: $activeSectionExpanded,
            trailing: {
                if !filteredActiveMounts.isEmpty {
                    Button {
                        Task { await manager.unmountAll() }
                    } label: {
                        Image(systemName: "eject.fill")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
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
                        subtitle: abbreviateHome(entry.config.localPath),
                        host: entry.config.host,
                        status: entry.status,
                        connectedSince: entry.connectedSince,
                        retryAttempt: entry.retryAttempt,
                        retryNextAt: entry.retryNextAt,
                        reconnectReason: entry.lastReconnectReason,
                        actions: {
                            connectionActions(for: entry)
                        }
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private var sectionSaved: some View {
        sectionHeader(
            title: "Saved",
            icon: "bookmark.fill",
            iconColor: .blue,
            count: filteredInactiveConfigs.count,
            isExpanded: $savedSectionExpanded,
            trailing: {
                Button {
                    withAnimation(.viewTransition) {
                        showNewMount = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Add new connection")
            }
        )
        
        if savedSectionExpanded {
            if filteredInactiveConfigs.isEmpty {
                emptyStateView(
                    message: searchText.isEmpty ? "No saved connections" : "No matches found",
                    icon: searchText.isEmpty ? "bookmark" : "magnifyingglass"
                )
            } else {
                ForEach(filteredInactiveConfigs) { config in
                    ConnectionRow(
                        label: config.label,
                        subtitle: abbreviateHome(config.localPath),
                        host: config.host,
                        status: .disconnected,
                        connectedSince: nil,
                        actions: {
                            savedConnectionActions(for: config)
                        }
                    )
                }
            }
        }
    }
    
    private var sectionDivider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
            .padding(.horizontal, 12)
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
                HStack(spacing: 6) {
                    Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 8)
                    
                    Image(systemName: icon)
                        .font(.system(size: 10))
                        .foregroundStyle(iconColor)
                    
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    
                    if count > 0 {
                        Text("\(count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(nsColor: .controlBackgroundColor))
                            .clipShape(Capsule())
                    }
                }
            }
            .buttonStyle(.plain)
            
            Spacer()
            
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
    
    private func emptyStateView(message: String, icon: String) -> some View {
        HStack {
            Spacer()
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 16)
            Spacer()
        }
    }
    
    @ViewBuilder
    private func connectionActions(for entry: MountEntry) -> some View {
        if entry.status == .connected {
            Button {
                openInFinder(path: entry.config.localPath)
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open in Finder")
            
            Button {
                openTerminal(at: entry.config.localPath)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open in Terminal")
            
            Button {
                Task { await manager.unmount(entry) }
            } label: {
                Image(systemName: "eject")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Unmount")
        }
    }
    
    @ViewBuilder
    private func savedConnectionActions(for config: MountConfig) -> some View {
        Button {
            Task {
                let result = await manager.mountWithResult(config)
                if case .authenticationFailed = result {
                    await MainActor.run {
                        withAnimation(.viewTransition) {
                            passwordPromptConfig = config
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "play.fill")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.green)
        .help("Mount")
        
        Button {
            withAnimation(.viewTransition) {
                editingConfig = config
            }
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Edit")
        
        Button {
            manager.deleteConfig(config)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Delete")
    }
    
    private var footerView: some View {
        HStack(spacing: 0) {
            Button {
                openSSHConfig()
            } label: {
                Label("SSH Config", systemImage: "doc.text")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            
            Spacer()
            
            if !manager.permissionStatus.allGood {
                Button {
                    showOnboarding = true
                } label: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("Setup issues")
            }
            
            Button {
                Task {
                    await manager.unmountAll()
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Shared Connection Row

struct ConnectionRow<Actions: View>: View {
    let label: String
    let subtitle: String?
    let host: String?
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
        HStack(spacing: 10) {
            Image(systemName: status.systemImage)
                .font(.system(size: 14))
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: shouldPulse)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                
                if showStatusText {
                    HStack(spacing: 4) {
                        Text(status.text)
                            .font(.system(size: 11))
                            .foregroundStyle(statusColor)
                        
                        if let subtitle {
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(.tertiary)
                            Text(subtitle)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    
                    if let connectedSince, status == .connected {
                        Text(connectedSince, style: .relative)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                } else if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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

/// Open ~/.ssh/config in the default editor, creating it if needed.
private func openSSHConfig() {
    let configPath = PathUtilities.realHomeDirectory + "/.ssh/config"
    let configDirectory = (configPath as NSString).deletingLastPathComponent
    let fileManager = FileManager.default
    let workspace = NSWorkspace.shared
    let fileURL = URL(fileURLWithPath: configPath)

    if !fileManager.fileExists(atPath: configDirectory) {
        try? fileManager.createDirectory(atPath: configDirectory, withIntermediateDirectories: true)
    }

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
