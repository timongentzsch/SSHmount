import Foundation

/// Parsed mount/runtime options from URL query parameters.
struct MountOptions: Sendable {
    /// Read-only mount (rdonly or ro).
    let readOnly: Bool
    /// Override UID for all files (uid=N).
    let overrideUID: UInt32?
    /// Override GID for all files (gid=N).
    let overrideGID: UInt32?
    /// Umask applied to permissions (umask=NNN in octal, e.g. umask=022).
    let umask: UInt32?
    /// Strip execute bits from files (noexec).
    let noExec: Bool
    /// Strip setuid/setgid bits (nosuid).
    let nosuid: Bool
    /// Don't update access times (noatime).
    let noatime: Bool
    /// Cache timeout for attributes in seconds (cache_timeout=N, 0 = no cache).
    let cacheTimeout: TimeInterval
    /// Cache timeout for directory listings in seconds (dir_cache_timeout=N, falls back to cache_timeout).
    let dirCacheTimeout: TimeInterval
    /// Follow symlinks in stat calls (follow_symlinks=yes/no, default yes).
    let followSymlinks: Bool
    /// Max reconnect attempts (reconnect_max=N, default 10).
    let reconnectMax: Int
    /// Seconds to wait for reconnection before returning errors to FS callers (reconnect_timeout=N, default 15).
    let reconnectTimeout: TimeInterval
    /// Number of SSH/SFTP sessions to use for parallel reads (parallel_sessions=N, default 1).
    let parallelSessions: Int
    /// Number of dedicated write sessions for parallel writes (parallel_write_sessions=N, default 1).
    let parallelWriteSessions: Int
    /// Enable non-blocking libssh2 I/O loops for dedicated read/write sessions (nonblocking_io=yes/no, default yes).
    let nonBlockingIO: Bool
    /// Session-only password auth fallback (auth_password=...); never persisted to saved config.
    let authPassword: String?

    /// Raw options dictionary for forward compatibility.
    let raw: [String: String]

    init(from dict: [String: String] = [:]) {
        raw = dict

        readOnly = dict["rdonly"] != nil || dict["ro"] != nil
        overrideUID = Self.intOpt(dict, "uid").map { UInt32($0) }
        overrideGID = Self.intOpt(dict, "gid").map { UInt32($0) }
        noExec = dict["noexec"] != nil
        nosuid = dict["nosuid"] != nil
        noatime = dict["noatime"] != nil
        followSymlinks = Self.boolOpt(dict, "follow_symlinks", defaultValue: true)
        cacheTimeout = TimeInterval(Self.intOpt(dict, "cache_timeout") ?? 5)
        let dirCacheRaw = Self.intOpt(dict, "dir_cache_timeout")
        dirCacheTimeout = TimeInterval(dirCacheRaw ?? Self.intOpt(dict, "cache_timeout") ?? 5)
        reconnectMax = max(1, Self.intOpt(dict, "reconnect_max") ?? 10)
        reconnectTimeout = TimeInterval(max(1, Self.intOpt(dict, "reconnect_timeout") ?? 15))
        parallelSessions = min(8, max(1, Self.intOpt(dict, "parallel_sessions") ?? 1))
        parallelWriteSessions = min(8, max(1, Self.intOpt(dict, "parallel_write_sessions") ?? 1))
        nonBlockingIO = Self.boolOpt(dict, "nonblocking_io", defaultValue: true)
        authPassword = dict["auth_password"]?.isEmpty == false ? dict["auth_password"] : nil

        if let umaskStr = dict["umask"], let val = UInt32(umaskStr, radix: 8) {
            umask = val
        } else {
            umask = nil
        }
    }

    /// Parse a bool option: "yes"/"true"/"1" or just present with no value -> true.
    private static func boolOpt(_ dict: [String: String], _ key: String, defaultValue: Bool = false) -> Bool {
        guard let val = dict[key] else { return defaultValue }
        if val.isEmpty { return true }
        let lower = val.lowercased()
        if lower == "no" || lower == "false" || lower == "0" { return false }
        return true
    }

    /// Parse an integer option.
    private static func intOpt(_ dict: [String: String], _ key: String) -> Int? {
        guard let val = dict[key], let n = Int(val) else { return nil }
        return n
    }
}
