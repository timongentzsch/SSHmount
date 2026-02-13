import SwiftUI

// MARK: - Shared Animation Constants

extension Animation {
    /// Standard transition for mount state changes (connect/disconnect/error).
    static let mountTransition = Animation.easeInOut(duration: 0.3)
    /// Quick transition for UI panel swaps (show/hide views).
    static let viewTransition = Animation.easeInOut(duration: 0.2)
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
/// The extension performs configurable SSH health checks and is the sole source of truth.
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

        let statuses = mounts.map { entry in
            Self.aggregateStatusEquivalent(for: entry.status)
        }
        let hasError = statuses.contains { if case .error = $0 { return true }; return false }
        let allConnected = statuses.allSatisfy { $0 == .connected }
        let hasDegraded = statuses.contains { $0 == .unreachable || $0 == .reconnecting }

        if hasError { return .hasErrors }
        if allConnected { return .allConnected }
        if hasDegraded { return .degraded }
        return .mixed
    }

    private static func aggregateStatusEquivalent(for status: MountStatus) -> MountStatus {
        guard case .error(let message) = status else { return status }
        let lower = message.lowercased()
        if lower.contains("unmount") || MountError.isBusyUnmountMessage(message) {
            return .connected
        }
        return status
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
        withAnimation(.mountTransition) {
            mounts.append(entry)
        }

        do {
            let mountPoint = try await ExtensionBridge.shared.requestMount(
                config.toRequest(sessionPassword: sessionPassword)
            )
            resolvedConfig.localPath = mountPoint
            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.mountTransition) {
                    mounts[idx].config = resolvedConfig
                    mounts[idx].status = .connected
                    mounts[idx].connectedSince = Date()
                }
            }
            return .success
        } catch {
            let isAuthError = Self.isAuthenticationError(error)

            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.mountTransition) {
                    mounts[idx].status = .error(error.localizedDescription)
                }
            }

            return isAuthError ? .authenticationFailed : .otherError(error.localizedDescription)
        }
    }

    func unmount(_ entry: MountEntry, force: Bool = false) async {
        do {
            try await ExtensionBridge.shared.requestUnmount(localPath: entry.config.localPath, force: force)
            withAnimation(.mountTransition) {
                mounts.removeAll { $0.id == entry.id }
            }
        } catch {
            Log.app.error("\(force ? "Force u" : "U")nmount error: \(error.localizedDescription)")
            if let idx = mounts.firstIndex(where: { $0.id == entry.id }) {
                withAnimation(.mountTransition) {
                    mounts[idx].status = .error(Self.userFacingUnmountError(error, force: force))
                }
            }
        }
    }

    func unmountAll(force: Bool = false) async {
        for entry in mounts {
            do {
                try await ExtensionBridge.shared.requestUnmount(localPath: entry.config.localPath, force: force)
            } catch {
                Log.app.error("\(force ? "Force u" : "U")nmount failed for \(entry.config.localPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }
        withAnimation(.mountTransition) {
            mounts.removeAll()
        }
    }

    // MARK: - Auth Error Detection

    /// Classify whether an error indicates authentication failure using typed error matching.
    private static func isAuthenticationError(_ error: Error) -> Bool {
        if let mountError = error as? MountError {
            if case .authFailed = mountError { return true }
        }
        // Fallback: string matching for errors from mount stderr
        let msg = error.localizedDescription.lowercased()
        return msg.contains("authentication failed") ||
               msg.contains("auth failed") ||
               msg.contains("all authentication methods failed") ||
               msg.contains("permission denied")
    }

    /// Map low-level unmount errors to concise user-facing text in the menu UI.
    private static func userFacingUnmountError(_ error: Error, force: Bool) -> String {
        let detail = error.localizedDescription
        if MountError.isBusyUnmountMessage(detail) {
            return force
                ? "Mount is still busy. Close Finder/Terminal/apps using it. If it remains stuck, restart FSKit daemons."
                : "Mount is busy. Close Finder/Terminal/apps using it, then retry or use Force unmount."
        }
        return force ? "Force unmount failed" : "Unmount failed"
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

        let reconnectReasons = [
            "probe_timeout",
            "transport_error",
            "worker_exhausted",
            "manual_trigger",
        ]
        for reason in reconnectReasons {
            let name = "com.sshmount.reconnect.reason.\(reason)" as CFString
            CFNotificationCenterAddObserver(
                center,
                observer,
                { (_, rawObserver, notificationName, _, _) in
                    guard let rawObserver, let notificationName else { return }
                    let manager = Unmanaged<MountManager>.fromOpaque(rawObserver).takeUnretainedValue()
                    let nameStr = notificationName.rawValue as String
                    let raw = nameStr.replacingOccurrences(of: "com.sshmount.reconnect.reason.", with: "")
                    Task { @MainActor in
                        manager.applyReconnectReason(raw)
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
        withAnimation(.mountTransition) {
            for i in mounts.indices where mounts[i].status.isActive {
                if status == .connected && mounts[i].status != .connected {
                    mounts[i].connectedSince = Date()
                    mounts[i].retryAttempt = 0
                    mounts[i].retryNextAt = nil
                    mounts[i].lastReconnectReason = nil
                } else if status != .connected {
                    mounts[i].connectedSince = nil
                }
                mounts[i].status = status
            }
        }
    }

    private func applyReconnectReason(_ raw: String) {
        let readable = raw
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
        withAnimation(.viewTransition) {
            for i in mounts.indices where mounts[i].status == .reconnecting || mounts[i].status == .unreachable {
                mounts[i].lastReconnectReason = readable
            }
        }
    }

    /// Extension scheduled a reconnect attempt in `delay` seconds.
    private func applyRetryScheduled(delay: Double) {
        withAnimation(.mountTransition) {
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
        withAnimation(.mountTransition) {
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
    /// Adds/removes entries and heals stale unreachable state when mount is present.
    private func reconcileMountTable() async {
        let systemMounts = await ExtensionBridge.shared.activeMounts()
        let systemPaths = Set(systemMounts.map(\.localPath))

        // Remove entries whose kernel mount has disappeared.
        let disappeared = mounts.filter { !systemPaths.contains($0.config.localPath) && $0.status.isActive }
        if !disappeared.isEmpty {
            for entry in disappeared {
                Log.app.notice("Mount disappeared: \(entry.config.localPath, privacy: .public)")
            }
            withAnimation(.mountTransition) {
                mounts.removeAll { !systemPaths.contains($0.config.localPath) && $0.status != .connecting }
            }
        }

        // Optimistically heal stale unreachable state when mount still exists.
        let promoteIndices = mounts.indices.filter {
            self.mounts[$0].status == .unreachable && systemPaths.contains(self.mounts[$0].config.localPath)
        }
        if !promoteIndices.isEmpty {
            for idx in promoteIndices {
                Log.app.notice("Promoting stale unreachable -> connected for \(self.mounts[idx].config.localPath, privacy: .public) (mount table present)")
            }
            withAnimation(.mountTransition) {
                for idx in promoteIndices {
                    self.mounts[idx].status = .connected
                    if self.mounts[idx].connectedSince == nil {
                        self.mounts[idx].connectedSince = Date()
                    }
                    self.mounts[idx].retryAttempt = 0
                    self.mounts[idx].retryNextAt = nil
                    self.mounts[idx].lastReconnectReason = nil
                }
            }
        }

        // Pick up externally-created mounts (e.g. from CLI).
        for mount in systemMounts {
            let alreadyTracked = mounts.contains { $0.config.localPath == mount.localPath }
            if !alreadyTracked {
                let matchedConfig = savedConfigs.first { config in
                    if config.localPath.isEmpty {
                        return config.hostAlias == (mount.remote.host ?? "")
                    }
                    let expanded = PathUtilities.expandTilde(config.localPath)
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
                        options: saved.options
                    )
                } ?? MountConfig(
                    hostAlias: mount.remote.host ?? "unknown",
                    remotePath: mount.remote.path,
                    localPath: mount.localPath
                )
                withAnimation(.mountTransition) {
                    mounts.append(MountEntry(config: config, status: .connected, connectedSince: Date()))
                }
                Log.app.notice("External mount picked up as connected: \(mount.localPath, privacy: .public)")
            }
        }
    }

    // MARK: - Auto-Mount on Launch

    private func autoMountOnLaunch() async {
        let autoConfigs = savedConfigs.filter(\.mountOnLaunch)
        for config in autoConfigs {
            Log.app.info("Auto-mounting: \(config.label, privacy: .public)")
            _ = await mountWithResult(config)
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
        guard let data = try? Data(contentsOf: configURL) else {
            Log.app.notice("No saved mount configs found")
            return
        }
        guard let configs = try? JSONDecoder().decode([MountConfig].self, from: data) else {
            Log.app.error("Failed to decode saved mount configs, resetting file")
            savedConfigs = []
            do {
                try Data("[]".utf8).write(to: configURL, options: .atomic)
            } catch {
                Log.app.error("Failed to reset invalid mount config file: \(error.localizedDescription, privacy: .public)")
            }
            return
        }
        savedConfigs = configs
    }

    private func persistConfigs() {
        guard let data = try? JSONEncoder().encode(savedConfigs) else {
            Log.app.error("Failed to encode mount configs")
            return
        }
        do {
            try data.write(to: configURL, options: .atomic)
        } catch {
            Log.app.error("Failed to save mount configs: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Permission Checks

    func refreshPermissions() async {
        let installed = FileManager.default.fileExists(atPath: "/Applications/SSHMount.app")
        let extensionBundlePath = "/Applications/SSHMount.app/Contents/Extensions/SSHMountFS.appex"
        let extensionBundleExists = FileManager.default.fileExists(atPath: extensionBundlePath)

        var registered = false
        var enabled = false
        if let result = try? await ExtensionBridge.shared.run(
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

        let home = PathUtilities.realHomeDirectory
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
    var lastReconnectReason: String?
}

/// Status of required permissions and setup.
struct PermissionStatus {
    var appInstalled = false
    var extensionRegistered = false
    var extensionEnabled = false
    var sshKeysFound = false

    var allGood: Bool { appInstalled && extensionRegistered && extensionEnabled && sshKeysFound }
}
