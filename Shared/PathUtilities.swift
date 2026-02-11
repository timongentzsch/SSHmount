import Foundation
import Darwin

/// Shared path utilities for home directory resolution and tilde expansion.
enum PathUtilities {
    /// Get the real user home directory (bypasses sandbox container redirection).
    static var realHomeDirectory: String {
        if let pw = getpwuid(getuid()) {
            return String(cString: pw.pointee.pw_dir)
        }
        return NSHomeDirectory()
    }

    /// Expand `~` or `~/...` to the user's home directory.
    static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        let home = realHomeDirectory
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home + String(path.dropFirst(1))
        }
        return path
    }

    /// Replace the user's home directory prefix with `~`.
    static func abbreviateHome(_ path: String) -> String {
        let home = realHomeDirectory
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}
