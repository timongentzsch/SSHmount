import os.log

/// Centralized loggers for all subsystems.
enum Log {
    static let sftp      = Logger(subsystem: "com.sshmount.app.fs", category: "sftp")
    static let volume    = Logger(subsystem: "com.sshmount.app.fs", category: "volume")
    static let fs        = Logger(subsystem: "com.sshmount.app.fs", category: "filesystem")
    static let config    = Logger(subsystem: "com.sshmount.app.fs", category: "sshconfig")
    static let bridge    = Logger(subsystem: "com.sshmount.app",    category: "bridge")
    static let app       = Logger(subsystem: "com.sshmount.app",    category: "app")
}
