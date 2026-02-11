import Foundation

enum MountProfile: String, Codable, CaseIterable, Sendable {
    case standard
    case git
}

enum MountIOMode: String, Codable, CaseIterable, Sendable {
    case blocking
    case nonblocking
}

/// Canonical mount/runtime options used across App, CLI, and Extension.
/// Legacy option names are intentionally unsupported.
struct MountOptions: Codable, Sendable, Equatable {
    let profile: MountProfile
    let readWorkers: Int
    let writeWorkers: Int
    let ioMode: MountIOMode
    let healthInterval: TimeInterval
    let healthTimeout: TimeInterval
    let healthFailures: Int
    let busyThreshold: Int
    let graceSeconds: TimeInterval
    let queueTimeoutMs: Int
    let cacheTimeout: TimeInterval
    let dirCacheTimeout: TimeInterval
    /// Session-only password auth fallback. Never persisted by UI.
    let authPassword: String?

    // MARK: - Defaults

    static let defaultStandard = MountOptions(
        profile: .standard,
        readWorkers: 1,
        writeWorkers: 1,
        ioMode: .blocking,
        healthInterval: 5,
        healthTimeout: 10,
        healthFailures: 5,
        busyThreshold: 32,
        graceSeconds: 20,
        queueTimeoutMs: 2_000,
        cacheTimeout: 5,
        dirCacheTimeout: 5,
        authPassword: nil
    )

    init(
        profile: MountProfile = .standard,
        readWorkers: Int = 1,
        writeWorkers: Int = 1,
        ioMode: MountIOMode = .blocking,
        healthInterval: TimeInterval = 5,
        healthTimeout: TimeInterval = 10,
        healthFailures: Int = 5,
        busyThreshold: Int = 32,
        graceSeconds: TimeInterval = 20,
        queueTimeoutMs: Int = 2_000,
        cacheTimeout: TimeInterval = 5,
        dirCacheTimeout: TimeInterval = 5,
        authPassword: String? = nil
    ) {
        let normalized = MountOptions.normalize(
            profile: profile,
            readWorkers: readWorkers,
            writeWorkers: writeWorkers,
            ioMode: ioMode,
            healthInterval: healthInterval,
            healthTimeout: healthTimeout,
            healthFailures: healthFailures,
            busyThreshold: busyThreshold,
            graceSeconds: graceSeconds,
            queueTimeoutMs: queueTimeoutMs,
            cacheTimeout: cacheTimeout,
            dirCacheTimeout: dirCacheTimeout,
            authPassword: authPassword
        )
        self = normalized
    }

    private init(
        uncheckedProfile profile: MountProfile,
        readWorkers: Int,
        writeWorkers: Int,
        ioMode: MountIOMode,
        healthInterval: TimeInterval,
        healthTimeout: TimeInterval,
        healthFailures: Int,
        busyThreshold: Int,
        graceSeconds: TimeInterval,
        queueTimeoutMs: Int,
        cacheTimeout: TimeInterval,
        dirCacheTimeout: TimeInterval,
        authPassword: String?
    ) {
        self.profile = profile
        self.readWorkers = readWorkers
        self.writeWorkers = writeWorkers
        self.ioMode = ioMode
        self.healthInterval = healthInterval
        self.healthTimeout = healthTimeout
        self.healthFailures = healthFailures
        self.busyThreshold = busyThreshold
        self.graceSeconds = graceSeconds
        self.queueTimeoutMs = queueTimeoutMs
        self.cacheTimeout = cacheTimeout
        self.dirCacheTimeout = dirCacheTimeout
        self.authPassword = authPassword
    }

    // MARK: - Strict Parser

    static let canonicalKeys: Set<String> = [
        "profile",
        "read_workers",
        "write_workers",
        "io_mode",
        "health_interval_s",
        "health_timeout_s",
        "health_failures",
        "busy_threshold",
        "grace_seconds",
        "queue_timeout_ms",
        "cache_attr_s",
        "cache_dir_s",
        "auth_password",
    ]

    static let legacyKeys: Set<String> = [
        "ro", "rdonly", "uid", "gid", "umask", "noexec", "nosuid", "noatime", "atime",
        "follow_symlinks", "reconnect_max", "reconnect_timeout",
        "parallel_sessions", "parallel_write_sessions", "nonblocking_io",
        "keepalive_interval", "keepalive_timeout", "keepalive_failures",
        "keepalive_busy_threshold", "max_pending_ops", "nodev", "cache_timeout", "dir_cache_timeout",
    ]

    init(from dict: [String: String]) throws {
        for key in dict.keys {
            if Self.canonicalKeys.contains(key) { continue }
            if Self.legacyKeys.contains(key) {
                throw MountError.invalidFormat("Legacy mount option '\(key)' is no longer supported.")
            }
            throw MountError.invalidFormat("Unknown mount option '\(key)'.")
        }

        let defaultProfile: MountProfile = .standard
        let parsedProfile = try Self.parseEnum(
            dict,
            key: "profile",
            defaultValue: defaultProfile
        )

        let readWorkers = try Self.parseInt(
            dict,
            key: "read_workers",
            defaultValue: 1,
            range: 1...8
        )
        let writeWorkers = try Self.parseInt(
            dict,
            key: "write_workers",
            defaultValue: 1,
            range: 1...8
        )
        let ioMode = try Self.parseEnum(
            dict,
            key: "io_mode",
            defaultValue: MountIOMode.blocking
        )
        let healthInterval = try Self.parseDouble(
            dict,
            key: "health_interval_s",
            defaultValue: 5,
            range: 1...300
        )
        let healthTimeout = try Self.parseDouble(
            dict,
            key: "health_timeout_s",
            defaultValue: 10,
            range: 1...120
        )
        let healthFailures = try Self.parseInt(
            dict,
            key: "health_failures",
            defaultValue: 5,
            range: 1...12
        )
        let busyThreshold = try Self.parseInt(
            dict,
            key: "busy_threshold",
            defaultValue: 32,
            range: 1...4096
        )
        let graceSeconds = try Self.parseDouble(
            dict,
            key: "grace_seconds",
            defaultValue: 20,
            range: 0...300
        )
        let queueTimeoutMs = try Self.parseInt(
            dict,
            key: "queue_timeout_ms",
            defaultValue: 2_000,
            range: 100...60_000
        )
        let cacheTimeout = try Self.parseDouble(
            dict,
            key: "cache_attr_s",
            defaultValue: 5,
            range: 0...300
        )
        let dirCacheTimeout = try Self.parseDouble(
            dict,
            key: "cache_dir_s",
            defaultValue: cacheTimeout,
            range: 0...300
        )
        let authPassword = dict["auth_password"]?.isEmpty == false ? dict["auth_password"] : nil

        self = Self.normalize(
            profile: parsedProfile,
            readWorkers: readWorkers,
            writeWorkers: writeWorkers,
            ioMode: ioMode,
            healthInterval: healthInterval,
            healthTimeout: healthTimeout,
            healthFailures: healthFailures,
            busyThreshold: busyThreshold,
            graceSeconds: graceSeconds,
            queueTimeoutMs: queueTimeoutMs,
            cacheTimeout: cacheTimeout,
            dirCacheTimeout: dirCacheTimeout,
            authPassword: authPassword
        )
    }

    private static func normalize(
        profile: MountProfile,
        readWorkers: Int,
        writeWorkers: Int,
        ioMode: MountIOMode,
        healthInterval: TimeInterval,
        healthTimeout: TimeInterval,
        healthFailures: Int,
        busyThreshold: Int,
        graceSeconds: TimeInterval,
        queueTimeoutMs: Int,
        cacheTimeout: TimeInterval,
        dirCacheTimeout: TimeInterval,
        authPassword: String?
    ) -> MountOptions {
        if profile == .git {
            return MountOptions(
                uncheckedProfile: .git,
                readWorkers: 1,
                writeWorkers: 1,
                ioMode: .blocking,
                healthInterval: 5,
                healthTimeout: 10,
                healthFailures: max(7, healthFailures),
                busyThreshold: max(64, busyThreshold),
                graceSeconds: min(300, max(0, graceSeconds)),
                queueTimeoutMs: min(60_000, max(100, queueTimeoutMs)),
                cacheTimeout: 0,
                dirCacheTimeout: 0,
                authPassword: authPassword
            )
        }

        return MountOptions(
            uncheckedProfile: profile,
            readWorkers: min(8, max(1, readWorkers)),
            writeWorkers: min(8, max(1, writeWorkers)),
            ioMode: ioMode,
            healthInterval: min(300, max(1, healthInterval)),
            healthTimeout: min(120, max(1, healthTimeout)),
            healthFailures: min(12, max(1, healthFailures)),
            busyThreshold: min(4096, max(1, busyThreshold)),
            graceSeconds: min(300, max(0, graceSeconds)),
            queueTimeoutMs: min(60_000, max(100, queueTimeoutMs)),
            cacheTimeout: min(300, max(0, cacheTimeout)),
            dirCacheTimeout: min(300, max(0, dirCacheTimeout)),
            authPassword: authPassword
        )
    }

    private static func parseInt(
        _ dict: [String: String],
        key: String,
        defaultValue: Int,
        range: ClosedRange<Int>
    ) throws -> Int {
        guard let raw = dict[key] else { return defaultValue }
        guard !raw.isEmpty else {
            throw MountError.invalidFormat("Missing value for '\(key)'")
        }
        guard let n = Int(raw), range.contains(n) else {
            throw MountError.invalidFormat("Invalid value for '\(key)': '\(raw)'")
        }
        return n
    }

    private static func parseDouble(
        _ dict: [String: String],
        key: String,
        defaultValue: Double,
        range: ClosedRange<Double>
    ) throws -> Double {
        guard let raw = dict[key] else { return defaultValue }
        guard !raw.isEmpty else {
            throw MountError.invalidFormat("Missing value for '\(key)'")
        }
        guard let n = Double(raw), range.contains(n) else {
            throw MountError.invalidFormat("Invalid value for '\(key)': '\(raw)'")
        }
        return n
    }

    private static func parseEnum<T: RawRepresentable>(
        _ dict: [String: String],
        key: String,
        defaultValue: T
    ) throws -> T where T.RawValue == String {
        guard let raw = dict[key] else { return defaultValue }
        guard !raw.isEmpty else {
            throw MountError.invalidFormat("Missing value for '\(key)'")
        }
        guard let value = T(rawValue: raw.lowercased()) else {
            throw MountError.invalidFormat("Invalid value for '\(key)': '\(raw)'")
        }
        return value
    }

    // MARK: - Request Encoding

    /// Canonical query dictionary used for mount requests.
    func asQueryDictionary(sessionPassword: String? = nil) -> [String: String] {
        var dict: [String: String] = [
            "profile": profile.rawValue,
            "read_workers": String(readWorkers),
            "write_workers": String(writeWorkers),
            "io_mode": ioMode.rawValue,
            "health_interval_s": Self.formatSeconds(healthInterval),
            "health_timeout_s": Self.formatSeconds(healthTimeout),
            "health_failures": String(healthFailures),
            "busy_threshold": String(busyThreshold),
            "grace_seconds": Self.formatSeconds(graceSeconds),
            "queue_timeout_ms": String(queueTimeoutMs),
            "cache_attr_s": Self.formatSeconds(cacheTimeout),
            "cache_dir_s": Self.formatSeconds(dirCacheTimeout),
        ]
        if let password = sessionPassword ?? authPassword, !password.isEmpty {
            dict["auth_password"] = password
        }
        return dict
    }

    private static func formatSeconds(_ value: TimeInterval) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
    }

}
