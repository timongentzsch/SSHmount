import Foundation

/// Persisted mount configuration for saved connections.
struct MountConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var label: String
    var hostAlias: String
    var remotePath: String
    var localPath: String
    var mountOnLaunch: Bool
    /// Comma-separated mount options passed via URL query parameters.
    var mountOptions: String

    private enum CodingKeys: String, CodingKey {
        case id, label, hostAlias, remotePath, localPath, mountOnLaunch, mountOptions

        // Legacy keys used by older builds.
        case host, user, port, password, sftpOptions
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        hostAlias: String,
        remotePath: String,
        localPath: String,
        mountOnLaunch: Bool = false,
        mountOptions: String = ""
    ) {
        self.id = id
        self.label = label.isEmpty ? "\(hostAlias):\(remotePath)" : label
        self.hostAlias = hostAlias
        self.remotePath = remotePath
        self.localPath = localPath
        self.mountOnLaunch = mountOnLaunch
        self.mountOptions = mountOptions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()

        let decodedHostAlias = try c.decodeIfPresent(String.self, forKey: .hostAlias)
        let legacyHost = try c.decodeIfPresent(String.self, forKey: .host)

        hostAlias = decodedHostAlias ?? legacyHost ?? ""
        remotePath = try c.decode(String.self, forKey: .remotePath)
        localPath = try c.decode(String.self, forKey: .localPath)
        mountOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .mountOnLaunch) ?? false
        mountOptions = try c.decodeIfPresent(String.self, forKey: .mountOptions) ?? ""

        let decodedLabel = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        label = decodedLabel.isEmpty ? "\(hostAlias):\(remotePath)" : decodedLabel
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(hostAlias, forKey: .hostAlias)
        try c.encode(remotePath, forKey: .remotePath)
        try c.encode(localPath, forKey: .localPath)
        try c.encode(mountOnLaunch, forKey: .mountOnLaunch)
        try c.encode(mountOptions, forKey: .mountOptions)
    }

    func toRequest(sessionPassword: String? = nil) -> MountRequest {
        MountRequest(
            hostAlias: hostAlias,
            remotePath: remotePath,
            localPath: localPath,
            label: label,
            mountOptions: mountOptions.isEmpty ? nil : mountOptions,
            sessionPassword: sessionPassword
        )
    }
}

/// Runtime state of a mount.
enum MountStatus: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case unreachable
    case error(String)

    var isActive: Bool {
        switch self {
        case .connected, .reconnecting, .unreachable: true
        default: false
        }
    }

    var text: String {
        switch self {
        case .disconnected: "Disconnected"
        case .connecting: "Connecting..."
        case .connected: "Connected"
        case .reconnecting: "Reconnecting..."
        case .unreachable: "Unreachable"
        case .error(let msg): "Error: \(msg)"
        }
    }
}

/// Parsed remote URL info from a system mount entry.
struct ParsedRemote: Sendable {
    let host: String?
    let path: String

    /// Parse "ssh://alias/path" into components.
    static func from(urlString: String) -> ParsedRemote {
        guard let url = URL(string: urlString) else {
            return ParsedRemote(host: nil, path: urlString)
        }
        return ParsedRemote(
            host: url.host,
            path: url.path.isEmpty ? "~" : url.path
        )
    }
}

/// A system-level active mount entry.
struct ActiveMount: Sendable {
    let remote: ParsedRemote
    let localPath: String
}
