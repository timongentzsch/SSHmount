import Foundation

/// SSH authentication methods, tried in order.
enum SSHAuthMethod: Sendable {
    case agent                          // ssh-agent
    case publicKey(path: String)        // ~/.ssh/id_ed25519, etc.
    case password(String)               // session-only password (not persisted)
}

/// Resolved SSH connection parameters after reading ~/.ssh/config.
struct SSHConnectionInfo: Sendable {
    let alias: String
    let hostname: String           // resolved hostname (may differ from input)
    let port: Int
    let user: String
    let identityFiles: [String]    // paths to private keys
    let proxyJump: String?         // ProxyJump host if any

    /// Build ordered list of auth methods to try.
    func authMethods() -> [SSHAuthMethod] {
        var methods: [SSHAuthMethod] = [.agent]

        for keyPath in identityFiles {
            methods.append(.publicKey(path: keyPath))
        }

        return methods
    }
}
