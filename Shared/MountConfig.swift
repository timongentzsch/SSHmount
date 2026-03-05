import Foundation

/// Persisted mount configuration for saved connections.
struct MountConfig: Codable, Identifiable, Sendable {
    let id: UUID
    var label: String
    var hostAlias: String
    var remotePath: String
    var localPath: String
    var mountOnLaunch: Bool
    var options: MountOptions

    private enum CodingKeys: String, CodingKey {
        case id, label, hostAlias, remotePath, localPath, mountOnLaunch, options
    }

    init(
        id: UUID = UUID(),
        label: String = "",
        hostAlias: String,
        remotePath: String,
        localPath: String,
        mountOnLaunch: Bool = false,
        options: MountOptions = .defaultStandard
    ) {
        self.id = id
        self.label = label.isEmpty ? "\(hostAlias):\(remotePath)" : label
        self.hostAlias = hostAlias
        self.remotePath = remotePath
        self.localPath = localPath
        self.mountOnLaunch = mountOnLaunch
        self.options = options
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        hostAlias = try c.decode(String.self, forKey: .hostAlias)
        remotePath = try c.decode(String.self, forKey: .remotePath)
        localPath = try c.decode(String.self, forKey: .localPath)
        mountOnLaunch = try c.decodeIfPresent(Bool.self, forKey: .mountOnLaunch) ?? false
        options = try c.decodeIfPresent(MountOptions.self, forKey: .options) ?? .defaultStandard

        let decodedLabel = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        label = decodedLabel.isEmpty ? "\(hostAlias):\(remotePath)" : decodedLabel
    }

    func toRequest(sessionPassword: String? = nil) -> MountRequest {
        MountRequest(
            hostAlias: hostAlias,
            remotePath: remotePath,
            localPath: localPath,
            label: label,
            options: options,
            sessionPassword: sessionPassword
        )
    }
}
