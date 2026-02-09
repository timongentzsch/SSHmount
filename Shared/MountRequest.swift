import Foundation

/// IPC payload between CLI/App and the FSKit extension.
struct MountRequest: Codable, Sendable {
    let hostAlias: String
    let remotePath: String
    let localPath: String
    /// User-facing label used as mount point directory name (Finder display name).
    let label: String?
    /// Comma-separated mount options passed via URL query parameters.
    let mountOptions: String?
    /// Session-only password. Not persisted in saved config.
    let sessionPassword: String?

    private enum CodingKeys: String, CodingKey {
        case hostAlias, remotePath, localPath, label, mountOptions
    }

    init(
        hostAlias: String,
        remotePath: String,
        localPath: String,
        label: String?,
        mountOptions: String?,
        sessionPassword: String?
    ) {
        self.hostAlias = hostAlias
        self.remotePath = remotePath
        self.localPath = localPath
        self.label = label
        self.mountOptions = mountOptions
        self.sessionPassword = sessionPassword
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostAlias = try c.decode(String.self, forKey: .hostAlias)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        localPath = try c.decode(String.self, forKey: .localPath)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        mountOptions = try c.decodeIfPresent(String.self, forKey: .mountOptions)
        sessionPassword = nil
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostAlias, forKey: .hostAlias)
        try c.encode(remotePath, forKey: .remotePath)
        try c.encode(localPath, forKey: .localPath)
        try c.encodeIfPresent(label, forKey: .label)
        try c.encodeIfPresent(mountOptions, forKey: .mountOptions)
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
            mountOptions: nil,
            sessionPassword: nil
        )
    }

    /// Build the FSKit resource URL consumed by `mount -F -t sshfs`.
    func resourceURLString() -> String {
        var urlString = "ssh://\(hostAlias)/\(remotePath)"
        if let query = Self.encodedQuery(from: mountOptions, sessionPassword: sessionPassword), !query.isEmpty {
            urlString += "?\(query)"
        }
        return urlString
    }

    private static func encodedQuery(from options: String?, sessionPassword: String?) -> String? {
        var queryItems: [URLQueryItem] = []

        if let options {
            let parts = options
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

            for part in parts {
                if let eq = part.firstIndex(of: "=") {
                    let key = String(part[..<eq]).trimmingCharacters(in: .whitespaces)
                    let value = String(part[part.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    guard !key.isEmpty else { continue }
                    queryItems.append(URLQueryItem(name: key, value: value))
                } else {
                    queryItems.append(URLQueryItem(name: part, value: nil))
                }
            }
        }

        if let sessionPassword, !sessionPassword.isEmpty {
            queryItems.append(URLQueryItem(name: "auth_password", value: sessionPassword))
        }

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

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): "Invalid format: \(msg)"
        case .connectionFailed(let msg): "Connection failed: \(msg)"
        case .authFailed(let msg): "Authentication failed: \(msg)"
        case .mountFailed(let msg): "Mount failed: \(msg)"
        case .sftpError(let msg): "SFTP error: \(msg)"
        }
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
