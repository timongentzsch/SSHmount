import Foundation

/// IPC payload between CLI/App and the FSKit extension.
struct MountRequest: Codable, Sendable {
    let hostAlias: String
    let remotePath: String
    let localPath: String
    /// User-facing label used as mount point directory name (Finder display name).
    let label: String?
    /// Canonical typed options encoded as URL query parameters.
    let options: MountOptions?
    /// Session-only password. Not persisted in saved config.
    let sessionPassword: String?

    /// sessionPassword is excluded from Codable — it should never be persisted.
    private enum CodingKeys: String, CodingKey {
        case hostAlias, remotePath, localPath, label, options
    }

    init(
        hostAlias: String,
        remotePath: String,
        localPath: String,
        label: String?,
        options: MountOptions?,
        sessionPassword: String?
    ) {
        self.hostAlias = hostAlias
        self.remotePath = remotePath
        self.localPath = localPath
        self.label = label
        self.options = options
        self.sessionPassword = sessionPassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAlias = try c.decode(String.self, forKey: .hostAlias)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        localPath = try c.decode(String.self, forKey: .localPath)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        options = try c.decodeIfPresent(MountOptions.self, forKey: .options)
        sessionPassword = nil
    }

    /// Parse "alias:/path" into components.
    static func parse(remote: String, localPath: String) throws -> MountRequest {
        guard let colonIndex = remote.firstIndex(of: ":") else {
            throw MountError.invalidFormat("Missing ':' in remote spec: \(remote)")
        }

        let alias = String(remote[remote.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
        let pathStart = remote.index(after: colonIndex)
        let path = String(remote[pathStart...]).trimmingCharacters(in: .whitespaces)

        guard !alias.isEmpty else { throw MountError.invalidFormat("Empty host alias") }
        guard !path.isEmpty else { throw MountError.invalidFormat("Empty remote path") }

        return MountRequest(
            hostAlias: alias,
            remotePath: path,
            localPath: localPath,
            label: nil,
            options: nil,
            sessionPassword: nil
        )
    }

    /// Build the FSKit resource URL consumed by `mount -F -t sshfs`.
    func resourceURLString() -> String {
        var urlString = "ssh://\(hostAlias)/\(remotePath)"
        if let query = Self.encodedQuery(from: options, sessionPassword: sessionPassword), !query.isEmpty {
            urlString += "?\(query)"
        }
        return urlString
    }

    private static func encodedQuery(from options: MountOptions?, sessionPassword: String?) -> String? {
        let queryDict = (options ?? .defaultStandard).asQueryDictionary(sessionPassword: sessionPassword)
        let queryItems = queryDict
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard !queryItems.isEmpty else { return nil }
        var components = URLComponents()
        components.queryItems = queryItems
        return components.percentEncodedQuery
    }
}

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

/// SSH_FX_* error codes from the SFTP protocol (draft-ietf-secsh-filexfer).
enum SFTPErrorCode: UInt, Sendable, CustomStringConvertible {
    case ok                 = 0
    case eof                = 1
    case noSuchFile         = 2
    case permissionDenied   = 3
    case failure            = 4
    case badMessage         = 5
    case noConnection       = 6
    case connectionLost     = 7
    case opUnsupported      = 8
    case invalidHandle      = 9
    case noSuchPath         = 10
    case fileAlreadyExists  = 11
    case writeProtect       = 12
    case noMedia            = 13
    case noSpaceOnFilesystem = 14
    case quotaExceeded      = 15
    case unknownPrincipal   = 16
    case lockConflict       = 17
    case dirNotEmpty        = 18
    case notADirectory      = 19
    case invalidFilename    = 20
    case linkLoop           = 21

    /// Map SFTP error code to the most appropriate POSIX error.
    /// Returns nil for non-error codes (ok, eof).
    var posixCode: POSIXErrorCode? {
        switch self {
        case .ok:                   return nil
        case .eof:                  return nil
        case .noSuchFile:           return .ENOENT
        case .permissionDenied:     return .EACCES
        case .failure:              return .EIO
        case .badMessage:           return .EINVAL
        case .noConnection:         return .ENOTCONN
        case .connectionLost:       return .ECONNRESET
        case .opUnsupported:        return .ENOTSUP
        case .invalidHandle:        return .EBADF
        case .noSuchPath:           return .ENOENT
        case .fileAlreadyExists:    return .EEXIST
        case .writeProtect:         return .EROFS
        case .noMedia:              return .ENXIO
        case .noSpaceOnFilesystem:  return .ENOSPC
        case .quotaExceeded:        return .EDQUOT
        case .unknownPrincipal:     return .EACCES
        case .lockConflict:         return .EAGAIN
        case .dirNotEmpty:          return .ENOTEMPTY
        case .notADirectory:        return .ENOTDIR
        case .invalidFilename:      return .EINVAL
        case .linkLoop:             return .ELOOP
        }
    }

    var description: String {
        switch self {
        case .ok:                   return "SSH_FX_OK"
        case .eof:                  return "SSH_FX_EOF"
        case .noSuchFile:           return "SSH_FX_NO_SUCH_FILE"
        case .permissionDenied:     return "SSH_FX_PERMISSION_DENIED"
        case .failure:              return "SSH_FX_FAILURE"
        case .badMessage:           return "SSH_FX_BAD_MESSAGE"
        case .noConnection:         return "SSH_FX_NO_CONNECTION"
        case .connectionLost:       return "SSH_FX_CONNECTION_LOST"
        case .opUnsupported:        return "SSH_FX_OP_UNSUPPORTED"
        case .invalidHandle:        return "SSH_FX_INVALID_HANDLE"
        case .noSuchPath:           return "SSH_FX_NO_SUCH_PATH"
        case .fileAlreadyExists:    return "SSH_FX_FILE_ALREADY_EXISTS"
        case .writeProtect:         return "SSH_FX_WRITE_PROTECT"
        case .noMedia:              return "SSH_FX_NO_MEDIA"
        case .noSpaceOnFilesystem:  return "SSH_FX_NO_SPACE_ON_FILESYSTEM"
        case .quotaExceeded:        return "SSH_FX_QUOTA_EXCEEDED"
        case .unknownPrincipal:     return "SSH_FX_UNKNOWN_PRINCIPAL"
        case .lockConflict:         return "SSH_FX_LOCK_CONFLICT"
        case .dirNotEmpty:          return "SSH_FX_DIR_NOT_EMPTY"
        case .notADirectory:        return "SSH_FX_NOT_A_DIRECTORY"
        case .invalidFilename:      return "SSH_FX_INVALID_FILENAME"
        case .linkLoop:             return "SSH_FX_LINK_LOOP"
        }
    }
}
