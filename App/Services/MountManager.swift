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

    var color: Color {
        switch self {
        case .noMounts:     .secondary
        case .allConnected: SSHMountTheme.success
        case .degraded:     SSHMountTheme.warning
        case .hasErrors:    SSHMountTheme.danger
        case .mixed:        .blue
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
    private struct MountTableSnapshot {
        let systemMounts: [ActiveMount]
        let systemPaths: Set<String>

        init(systemMounts: [ActiveMount]) {
            self.systemMounts = systemMounts
            self.systemPaths = Set(systemMounts.map(\.localPath))
        }
    }

    private static let connectedNotification = "com.sshmount.state.connected"
    private static let reconnectingNotification = "com.sshmount.state.reconnecting"
    private static let reconnectDelayNotificationPrefix = "com.sshmount.reconnect.delay."
    private static let reconnectReasonNotificationPrefix = "com.sshmount.reconnect.reason."
    private static let reconnectReasons = [
        "probe_timeout",
        "transport_error",
        "worker_exhausted",
        "manual_trigger",
    ]
    private static let reconnectDelaySteps = [2, 4, 8, 16]
    private static let healthyPollInterval: TimeInterval = 30
    private static let unhealthyPollInterval: TimeInterval = 5
    private static let permissionRefreshInterval: TimeInterval = 300

    @Published var mounts: [MountEntry] = []
    @Published var savedConfigs: [MountConfig] = []
    @Published var permissionStatus = PermissionStatus()

    private var pollTask: Task<Void, Never>?
    private nonisolated(unsafe) var sleepObserver: NSObjectProtocol?
    private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    private nonisolated(unsafe) var observingExtensionState = false

    var aggregateStatus: AggregateConnectionStatus {
        guard !mounts.isEmpty else { return .noMounts }

        var hasError = false
        var allConnected = true
        var hasDegraded = false
        for entry in mounts {
            let status = Self.aggregateStatusEquivalent(for: entry.status)
            switch status {
            case .error: hasError = true; allConnected = false
            case .unreachable, .reconnecting: hasDegraded = true; allConnected = false
            case .connected: break
            default: allConnected = false
            }
        }

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
                let now = Date()
                withAnimation(.mountTransition) {
                    mounts[idx].config = resolvedConfig
                    markConnected(&mounts[idx], connectedSince: now, overwriteTimestamp: true)
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
        guard let center = CFNotificationCenterGetDarwinNotifyCenter() else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()

        for name in [Self.connectedNotification, Self.reconnectingNotification] {
            addDarwinObserver(center: center, observer: observer, name: name as CFString)
        }

        for delay in Self.reconnectDelaySteps {
            let name = "\(Self.reconnectDelayNotificationPrefix)\(delay)"
            addDarwinObserver(center: center, observer: observer, name: name as CFString)
        }

        for reason in Self.reconnectReasons {
            let name = "\(Self.reconnectReasonNotificationPrefix)\(reason)"
            addDarwinObserver(center: center, observer: observer, name: name as CFString)
        }

        observingExtensionState = true
    }

    private func handleDarwinNotification(named notificationName: String) {
        switch notificationName {
        case Self.connectedNotification:
            Log.app.notice("Extension state: connected")
            applyExtensionState(.connected)
        case Self.reconnectingNotification:
            Log.app.notice("Extension state: reconnecting")
            applyExtensionState(.reconnecting)
        case let name where name.hasPrefix(Self.reconnectDelayNotificationPrefix):
            let value = name.replacingOccurrences(of: Self.reconnectDelayNotificationPrefix, with: "")
            applyRetryScheduled(delay: Double(value) ?? Double(Self.reconnectDelaySteps.first ?? 2))
        case let name where name.hasPrefix(Self.reconnectReasonNotificationPrefix):
            let raw = name.replacingOccurrences(of: Self.reconnectReasonNotificationPrefix, with: "")
            applyReconnectReason(raw)
        default:
            break
        }
    }

    private func addDarwinObserver(
        center: CFNotificationCenter,
        observer: UnsafeMutableRawPointer,
        name: CFString
    ) {
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, rawObserver, notificationName, _, _ in
                guard let rawObserver, let notificationName else { return }
                let manager = Unmanaged<MountManager>.fromOpaque(rawObserver).takeUnretainedValue()
                let notificationNameString = notificationName.rawValue as String
                Task { @MainActor in
                    manager.handleDarwinNotification(named: notificationNameString)
                }
            },
            name,
            nil,
            .deliverImmediately
        )
    }

    /// Apply extension-reported state to all tracked mounts.
    ///
    /// Applies to every mount except `.connecting` (in-progress mount requests).
    /// This ensures Darwin notifications can unstick any state, including `.error`.
    private func applyExtensionState(_ status: MountStatus) {
        let now = Date()
        updateMounts(matching: { $0.status != .connecting }) { entry in
            if status == .connected && entry.status != .connected {
                markConnected(&entry, connectedSince: now, overwriteTimestamp: true)
            } else {
                markStatus(status, for: &entry)
            }
        }
    }

    private func applyReconnectReason(_ raw: String) {
        let readable = raw
            .split(separator: "_")
            .map { $0.capitalized }
            .joined(separator: " ")
        updateMounts(
            matching: { $0.status == .reconnecting || $0.status == .unreachable },
            animation: .viewTransition
        ) { entry in
            entry.lastReconnectReason = readable
        }
    }

    /// Extension scheduled a reconnect attempt in `delay` seconds.
    private func applyRetryScheduled(delay: Double) {
        let nextRetryAt = Date().addingTimeInterval(delay)
        updateMounts(matching: { $0.status == .reconnecting }) { entry in
            entry.retryAttempt += 1
            entry.retryNextAt = nextRetryAt
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
        updateMounts(matching: { $0.status == .connected || $0.status == .reconnecting }) { entry in
            markStatus(.unreachable, for: &entry)
        }
    }

    // MARK: - Mount Table Polling

    /// True when any tracked mount is not in a healthy terminal state.
    private var hasUnhealthyMounts: Bool {
        mounts.contains { $0.status != .connected && $0.status != .connecting }
    }

    private var pollInterval: TimeInterval {
        hasUnhealthyMounts ? Self.unhealthyPollInterval : Self.healthyPollInterval
    }

    private func startMountTablePolling() {
        pollTask = Task { [weak self] in
            var elapsedSincePermissionCheck: TimeInterval = 0
            while !Task.isCancelled {
                let interval = self?.pollInterval ?? Self.healthyPollInterval
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { break }
                await self?.reconcileMountTable()
                elapsedSincePermissionCheck += interval
                if elapsedSincePermissionCheck >= Self.permissionRefreshInterval {
                    elapsedSincePermissionCheck = 0
                    await self?.refreshPermissions()
                }
            }
        }
    }

    /// Reconcile tracked mounts with the kernel mount table.
    ///
    /// Three passes:
    /// 1. **Remove** tracked mounts that no longer exist in the kernel (any state except `.connecting`).
    /// 2. **Heal** tracked mounts in stale state (error/unreachable/reconnecting) back to `.connected`
    ///    when the kernel mount table confirms they exist.
    /// 3. **Discover** externally-created mounts (e.g. from CLI).
    private func reconcileMountTable() async {
        let systemMounts = await ExtensionBridge.shared.activeMounts()
        let snapshot = MountTableSnapshot(systemMounts: systemMounts)

        removeTrackedMountsMissingFromKernel(using: snapshot)
        healTrackedMountsPresentInKernel(using: snapshot)
        discoverExternalMounts(using: snapshot)
    }

    private func removeTrackedMountsMissingFromKernel(using snapshot: MountTableSnapshot) {
        let missing = mounts.filter { $0.status != .connecting && !snapshot.systemPaths.contains($0.config.localPath) }
        guard !missing.isEmpty else { return }

        for entry in missing {
            Log.app.notice("Mount gone from kernel: \(entry.config.localPath, privacy: .public) (was \(entry.status.text, privacy: .public))")
        }

        withAnimation(.mountTransition) {
            mounts.removeAll { $0.status != .connecting && !snapshot.systemPaths.contains($0.config.localPath) }
        }
    }

    private func healTrackedMountsPresentInKernel(using snapshot: MountTableSnapshot) {
        let staleIndices = mounts.indices.filter {
            let status = mounts[$0].status
            return status != .connecting
                && status != .connected
                && snapshot.systemPaths.contains(mounts[$0].config.localPath)
        }
        guard !staleIndices.isEmpty else { return }

        let now = Date()
        withAnimation(.mountTransition) {
            for index in staleIndices {
                Log.app.notice("Healing \(self.mounts[index].status.text, privacy: .public) → connected: \(self.mounts[index].config.localPath, privacy: .public)")
                self.markConnected(&self.mounts[index], connectedSince: now, overwriteTimestamp: false)
            }
        }
    }

    private func discoverExternalMounts(using snapshot: MountTableSnapshot) {
        let newEntries = snapshot.systemMounts
            .filter { mount in !mounts.contains(where: { $0.config.localPath == mount.localPath }) }
            .map { mount in
                (
                    mount: mount,
                    entry: MountEntry(
                        config: makeTrackedConfig(for: mount),
                        status: .connected,
                        connectedSince: Date()
                    )
                )
            }
        guard !newEntries.isEmpty else { return }

        withAnimation(.mountTransition) {
            for newEntry in newEntries {
                mounts.append(newEntry.entry)
            }
        }

        for newEntry in newEntries {
            Log.app.notice("External mount picked up as connected: \(newEntry.mount.localPath, privacy: .public)")
        }
    }

    private func makeTrackedConfig(for mount: ActiveMount) -> MountConfig {
        guard let saved = matchingSavedConfig(for: mount) else {
            return MountConfig(
                hostAlias: mount.remote.host ?? "unknown",
                remotePath: mount.remote.path,
                localPath: mount.localPath
            )
        }

        return MountConfig(
            id: saved.id,
            label: saved.label,
            hostAlias: saved.hostAlias,
            remotePath: saved.remotePath,
            localPath: mount.localPath,
            mountOnLaunch: saved.mountOnLaunch,
            options: saved.options
        )
    }

    private func matchingSavedConfig(for mount: ActiveMount) -> MountConfig? {
        savedConfigs.first { config in
            if config.localPath.isEmpty {
                return config.hostAlias == (mount.remote.host ?? "")
            }
            return PathUtilities.expandTilde(config.localPath) == mount.localPath
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

    private func updateMounts(
        matching predicate: (MountEntry) -> Bool,
        animation: Animation = .mountTransition,
        _ update: (inout MountEntry) -> Void
    ) {
        let indices = mounts.indices.filter { predicate(mounts[$0]) }
        guard !indices.isEmpty else { return }

        withAnimation(animation) {
            for index in indices {
                update(&mounts[index])
            }
        }
    }

    private func resetReconnectMetadata(for entry: inout MountEntry) {
        entry.retryAttempt = 0
        entry.retryNextAt = nil
        entry.lastReconnectReason = nil
    }

    private func markConnected(_ entry: inout MountEntry, connectedSince: Date, overwriteTimestamp: Bool) {
        entry.status = .connected
        if overwriteTimestamp || entry.connectedSince == nil {
            entry.connectedSince = connectedSince
        }
        resetReconnectMetadata(for: &entry)
    }

    private func markStatus(_ status: MountStatus, for entry: inout MountEntry) {
        entry.status = status
        if status != .connected {
            entry.connectedSince = nil
        }
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
