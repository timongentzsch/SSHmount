import SwiftUI

@main
struct SSHMountApp: App {
    @StateObject private var mountManager = MountManager()

    var body: some Scene {
        MenuBarExtra {
            MountListView(manager: mountManager)
        } label: {
            Image(systemName: mountManager.aggregateStatus.iconName)
        }
        .menuBarExtraStyle(.window)
    }
}

// MARK: - Aggregate Connection Status

enum AggregateConnectionStatus {
    case noMounts
    case allConnected
    case degraded       // some unreachable or reconnecting
    case hasErrors
    case mixed          // connected + other states

    var iconName: String {
        switch self {
        case .noMounts:     "externaldrive.badge.minus"
        case .allConnected: "externaldrive.connected.to.line.below.fill"
        case .degraded:     "externaldrive.badge.exclamationmark"
        case .hasErrors:    "externaldrive.badge.xmark"
        case .mixed:        "externaldrive.connected.to.line.below"
        }
    }
}

// MARK: - Mount Manager

/// Manages all mount state and coordinates with the FSKit extension.
///
/// Two inputs:
/// 1. **Extension Darwin notifications** (`connected` / `reconnecting`)
///    → directly update mount health
/// 2. **Mount table poll** (30s) → kernel mount existence (add/remove entries)
///
/// The extension pings SSH every 1s and is the sole source of truth.
/// The app never probes the filesystem or monitors the network.
@MainActor
final class MountManager: ObservableObject {
    @Published var mounts: [MountEntry] = []
    @Published var savedConfigs: [MountConfig] = []
    @Published var permissionStatus = PermissionStatus()

    private var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var observingExtensionState = false

    var aggregateStatus: AggregateConnectionStatus {
        guard !mounts.isEmpty else { return .noMounts }

        let statuses = mounts.map(\.status)
        let hasError = statuses.contains { if case .error = $0 { return true }; return false }
        let allConnected = statuses.allSatisfy { $0 == .connected }
        let hasDegraded = statuses.contains { $0 == .unreachable || $0 == .reconnecting }

        if hasError { return .hasErrors }
        if allConnected { return .allConnected }
        if hasDegraded { return .degraded }
        return .mixed
    }

    private let configURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("SSHMount", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("mounts.json")
    }()

    init() {
        loadConfigs()
        startMountTablePolling()
        startSleepWakeHandling()
        startExtensionStateListeners()
        Task {
            await reconcileMountTable()
            await refreshPermissions()
            await autoMountOnLaunch()
        }
    }

    deinit {
        pollTask?.cancel()
        if let sleepObserver { NotificationCenter.default.removeObserver(sleepObserver) }
        if let wakeObserver { NotificationCenter.default.removeObserver(wakeObserver) }
        if observingExtensionState {
            CFNotificationCenterRemoveObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                Unmanaged.passUnretained(self).toOpaque(),
                nil,
                nil
            )
        }
    }

    // MARK: - Mount Operations

    enum MountResult {
        case success
        case authenticationFailed
        case otherError(String)
    }

    /// Mount with detailed result indicating auth failures vs other errors.
    func mountWithResult(_ config: MountConfig, sessionPassword: String? = nil) async -> MountResult {
        var resolvedConfig = config
        let entry = MountEntry(config: config, status: .connecting)
        withAnimation(.easeInOut(duration: 0.3)) {
            mounts.append(entry)
        }

        do {
            let mountPoint = try await ExtensionBridge.shared.requestMount(
                config.toRequest(sessionPassword: sessionPassword)
            )
            resolvedConfig.localPath = mountPoint
            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    mounts[idx].config = resolvedConfig
                    mounts[idx].status = .connected
                    mounts[idx].connectedSince = Date()
                }
            }
            return .success
        } catch {
            // Check if this is an authentication failure
            let errorMsg = error.localizedDescription.lowercased()
            let isAuthError = errorMsg.contains("authentication failed") ||
                              errorMsg.contains("auth failed") ||
                              errorMsg.contains("all authentication methods failed") ||
                              errorMsg.contains("permission denied")

            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    mounts[idx].status = .error(error.localizedDescription)
                }
            }

            return isAuthError ? .authenticationFailed : .otherError(error.localizedDescription)
        }
    }

    /// Legacy mount method that doesn't return detailed result.
    func mount(_ config: MountConfig, sessionPassword: String? = nil) async {
        _ = await mountWithResult(config, sessionPassword: sessionPassword)
    }

    func unmount(_ entry: MountEntry) async {
        do {
            try await ExtensionBridge.shared.requestUnmount(localPath: entry.config.localPath)
            withAnimation(.easeInOut(duration: 0.3)) {
                mounts.removeAll { $0.id == entry.id }
            }
        } catch {
            Log.app.error("Unmount error: \(error.localizedDescription)")
            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.easeInOut(duration: 0.3)) {
                    mounts[idx].status = .error("Unmount failed")
                }
            }
        }
    }

    func unmountAll() async {
        for entry in mounts {
            try? await ExtensionBridge.shared.requestUnmount(localPath: entry.config.localPath)
        }
        withAnimation(.easeInOut(duration: 0.3)) {
            mounts.removeAll()
        }
    }

    // MARK: - Extension State Listeners

    /// Listen for Darwin notifications from the extension.
    private func startExtensionStateListeners() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()

        // State notifications
        let stateNames: [CFString] = [
            "com.sshmount.state.connected" as CFString,
            "com.sshmount.state.reconnecting" as CFString,
        ]
        for name in stateNames {
            CFNotificationCenterAddObserver(
                center,
                observer,
                { (_, rawObserver, notificationName, _, _) in
                    guard let rawObserver, let notificationName else { return }
                    let manager = Unmanaged<MountManager>.fromOpaque(rawObserver).takeUnretainedValue()
                    let isConnected = (notificationName.rawValue as String) == "com.sshmount.state.connected"
                    Task { @MainActor in
                        let status: MountStatus = isConnected ? .connected : .reconnecting
                        Log.app.notice("Extension state: \(isConnected ? "connected" : "reconnecting", privacy: .public)")
                        manager.applyExtensionState(status)
                    }
                },
                name,
                nil,
                .deliverImmediately
            )
        }

        // Reconnect delay notifications (tells us when next attempt will fire)
        let delays: [Int] = [2, 4, 8, 16]
        for delay in delays {
            let name = "com.sshmount.reconnect.delay.\(delay)" as CFString
            CFNotificationCenterAddObserver(
                center,
                observer,
                { (_, rawObserver, notificationName, _, _) in
                    guard let rawObserver, let notificationName else { return }
                    let manager = Unmanaged<MountManager>.fromOpaque(rawObserver).takeUnretainedValue()
                    let nameStr = notificationName.rawValue as String
                    let delayStr = nameStr.replacingOccurrences(of: "com.sshmount.reconnect.delay.", with: "")
                    let delaySec = Double(delayStr) ?? 2
                    Task { @MainActor in
                        manager.applyRetryScheduled(delay: delaySec)
                    }
                },
                name,
                nil,
                .deliverImmediately
            )
        }

        observingExtensionState = true
    }

    /// Apply extension-reported state to all active mounts.
    private func applyExtensionState(_ status: MountStatus) {
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in mounts.indices where mounts[i].status.isActive {
                if status == .connected && mounts[i].status != .connected {
                    mounts[i].connectedSince = Date()
                    mounts[i].retryAttempt = 0
                    mounts[i].retryNextAt = nil
                } else if status != .connected {
                    mounts[i].connectedSince = nil
                }
                mounts[i].status = status
            }
        }
    }

    /// Extension scheduled a reconnect attempt in `delay` seconds.
    private func applyRetryScheduled(delay: Double) {
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in mounts.indices where mounts[i].status == .reconnecting {
                mounts[i].retryAttempt += 1
                mounts[i].retryNextAt = Date().addingTimeInterval(delay)
            }
        }
    }

    // MARK: - Sleep/Wake Handling

    private func startSleepWakeHandling() {
        let ws = NSWorkspace.shared.notificationCenter

        sleepObserver = ws.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.app.notice("System going to sleep, marking mounts unreachable")
                self?.markAllUnreachable()
            }
        }

        wakeObserver = ws.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                Log.app.notice("System woke, reconciling mount table")
                try? await Task.sleep(for: .seconds(2))
                await self?.reconcileMountTable()
            }
        }
    }

    private func markAllUnreachable() {
        withAnimation(.easeInOut(duration: 0.3)) {
            for i in mounts.indices where mounts[i].status == .connected || mounts[i].status == .reconnecting {
                mounts[i].status = .unreachable
                mounts[i].connectedSince = nil
            }
        }
    }

    // MARK: - Mount Table Polling

    private func startMountTablePolling() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { break }
                await self?.reconcileMountTable()
                await self?.refreshPermissions()
            }
        }
    }

    /// Reconcile tracked mounts with the kernel mount table.
    /// Only adds/removes entries — does not determine health.
    private func reconcileMountTable() async {
        let systemMounts = await ExtensionBridge.shared.activeMounts()
        let systemPaths = Set(systemMounts.map(\.localPath))

        // Remove entries whose kernel mount has disappeared.
        let disappeared = mounts.filter { !systemPaths.contains($0.config.localPath) && $0.status.isActive }
        if !disappeared.isEmpty {
            for entry in disappeared {
                Log.app.notice("Mount disappeared: \(entry.config.localPath, privacy: .public)")
            }
            withAnimation(.easeInOut(duration: 0.3)) {
                mounts.removeAll { !systemPaths.contains($0.config.localPath) && $0.status != .connecting }
            }
        }

        // Pick up externally-created mounts (e.g. from CLI).
        // Start as `.unreachable` — extension notification will promote.
        for mount in systemMounts {
            let alreadyTracked = mounts.contains { $0.config.localPath == mount.localPath }
            if !alreadyTracked {
                let matchedConfig = savedConfigs.first { config in
                    if config.localPath.isEmpty {
                        return config.hostAlias == (mount.remote.host ?? "")
                    }
                    let expanded = ExtensionBridge.expandTilde(config.localPath)
                    return expanded == mount.localPath
                }
                let config = matchedConfig.map { saved in
                    MountConfig(
                        id: saved.id,
                        label: saved.label,
                        hostAlias: saved.hostAlias,
                        remotePath: saved.remotePath,
                        localPath: mount.localPath,
                        mountOnLaunch: saved.mountOnLaunch,
                        mountOptions: saved.mountOptions
                    )
                } ?? MountConfig(
                    hostAlias: mount.remote.host ?? "unknown",
                    remotePath: mount.remote.path,
                    localPath: mount.localPath
                )
                withAnimation(.easeInOut(duration: 0.3)) {
                    mounts.append(MountEntry(config: config, status: .unreachable))
                }
                Log.app.debug("Picked up external mount: \(mount.localPath, privacy: .public)")
            }
        }
    }

    // MARK: - Auto-Mount on Launch

    private func autoMountOnLaunch() async {
        let autoConfigs = savedConfigs.filter(\.mountOnLaunch)
        for config in autoConfigs {
            Log.app.info("Auto-mounting: \(config.label, privacy: .public)")
            await mount(config)
        }
    }

    // MARK: - Config Persistence

    func saveConfig(_ config: MountConfig) {
        if let idx = savedConfigs.firstIndex(where: { $0.id == config.id }) {
            savedConfigs[idx] = config
        } else {
            savedConfigs.append(config)
        }
        persistConfigs()
    }

    func deleteConfig(_ config: MountConfig) {
        savedConfigs.removeAll { $0.id == config.id }
        persistConfigs()
    }

    private func loadConfigs() {
        guard let data = try? Data(contentsOf: configURL),
              let configs = try? JSONDecoder().decode([MountConfig].self, from: data) else { return }
        savedConfigs = configs
    }

    private func persistConfigs() {
        guard let data = try? JSONEncoder().encode(savedConfigs) else { return }
        try? data.write(to: configURL, options: .atomic)
    }

    // MARK: - Permission Checks

    func refreshPermissions() async {
        let installed = FileManager.default.fileExists(atPath: "/Applications/SSHMount.app")
        let extensionBundlePath = "/Applications/SSHMount.app/Contents/Extensions/SSHMountFS.appex"
        let extensionBundleExists = FileManager.default.fileExists(atPath: extensionBundlePath)

        var registered = false
        var enabled = false
        if let result = try? await ExtensionBridge.shared.runCommand(
            "/usr/bin/pluginkit", arguments: ["-m", "-i", "com.sshmount.app.fs"]
        ) {
            let pluginID = "com.sshmount.app.fs"
            let mergedOutput = result.stdout + "\n" + result.stderr
            let lines = mergedOutput
                .split(separator: "\n")
                .map { String($0) }

            registered = result.exitCode == 0 && lines.contains { $0.contains(pluginID) }
            enabled = lines.contains { line in
                line.contains(pluginID) && line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
            }

            if mergedOutput.contains("Connection invalid") {
                Log.app.notice("pluginkit connection invalid while checking extension status")
            }
        } else if extensionBundleExists {
            registered = true
            enabled = true
            Log.app.notice("Falling back to bundle-based extension status check")
        }

        let home: String
        if let pw = getpwuid(getuid()) {
            home = String(cString: pw.pointee.pw_dir)
        } else {
            home = FileManager.default.homeDirectoryForCurrentUser.path
        }
        let keyNames = ["id_ed25519", "id_rsa", "id_ecdsa"]
        let hasKeys = keyNames.contains { FileManager.default.fileExists(atPath: "\(home)/.ssh/\($0)") }

        permissionStatus = PermissionStatus(
            appInstalled: installed,
            extensionRegistered: registered,
            extensionEnabled: enabled,
            sshKeysFound: hasKeys
        )
    }
}

/// A live mount: config + runtime status.
struct MountEntry: Identifiable {
    let id = UUID()
    var config: MountConfig
    var status: MountStatus
    var connectedSince: Date?
    var retryAttempt: Int = 0
    var retryNextAt: Date?
}

/// Status of required permissions and setup.
struct PermissionStatus {
    var appInstalled = false
    var extensionRegistered = false
    var extensionEnabled = false
    var sshKeysFound = false

    var allGood: Bool { appInstalled && extensionRegistered && extensionEnabled && sshKeysFound }
}
