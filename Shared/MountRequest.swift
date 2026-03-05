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
