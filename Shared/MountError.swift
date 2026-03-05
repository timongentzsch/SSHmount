import Foundation

enum MountError: LocalizedError {
    case invalidFormat(String)
    case connectionFailed(String)
    case authFailed(String)
    case mountFailed(String)
    case sftpError(String)
    /// SFTP error with numeric code for better POSIX error mapping.
    case sftpCodedError(String, code: UInt)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): "Invalid format: \(msg)"
        case .connectionFailed(let msg): "Connection failed: \(msg)"
        case .authFailed(let msg): "Authentication failed: \(msg)"
        case .mountFailed(let msg): "Mount failed: \(msg)"
        case .sftpError(let msg): "SFTP error: \(msg)"
        case .sftpCodedError(let msg, _): "SFTP error: \(msg)"
        }
    }

    /// Map an SFTP error code to the most appropriate POSIX error.
    var posixErrorCode: POSIXErrorCode {
        guard case .sftpCodedError(_, let code) = self else { return .EIO }
        return SFTPErrorCode(rawValue: code)?.posixCode ?? .EIO
    }

    static func isAlreadyUnmountedMessage(_ stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("not currently mounted")
            || normalized.contains("not mounted")
    }

    static func isBusyUnmountMessage(_ stderr: String) -> Bool {
        let normalized = stderr.lowercased()
        return normalized.contains("resource busy")
            || normalized.contains("device busy")
            || normalized.contains("target is busy")
            || normalized.contains("in use")
    }

    static let daemonRecoveryCommand = "sudo pkill -9 fskitd && pkill -9 fskit_agent"
    static var daemonRecoveryHint: String {
        "If this mount is still stuck, restart FSKit daemons: \(daemonRecoveryCommand)"
    }

    static func unmountFailureMessage(localPath: String, stderr: String, exitCode: Int32) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if isBusyUnmountMessage(trimmed) {
            let detail = trimmed.isEmpty ? "mount point is busy" : trimmed
            return "Unmount failed because files in \(localPath) are still in use. Close Finder windows, terminal sessions, editors, or background jobs using this mount and retry. Inspect active processes with: lsof +D \"\(localPath)\". System message: \(detail)"
        }
        if trimmed.isEmpty {
            return "umount exited with code \(exitCode)"
        }
        return trimmed
    }
}
