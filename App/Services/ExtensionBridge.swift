import Foundation

/// Bridge between the app/CLI and the FSKit system extension.
/// Uses `mount -F -t sshfs` to trigger FSKit-managed mounts
/// and `umount` to tear them down.
final class ExtensionBridge: @unchecked Sendable {
    static let shared = ExtensionBridge()

    static let fsType = "sshfs"

    /// Mount a remote directory via the FSKit extension.
    /// Constructs an ssh:// URL and calls `mount -F -t sshfs`.
    /// If `localPath` is empty, auto-creates `~/Volumes/<hostAlias>`.
    /// Returns the resolved mount point path.
    @discardableResult
    func requestMount(_ request: MountRequest) async throws -> String {
        var mountPoint: String
        if request.localPath.isEmpty {
            let mountsDir = PathUtilities.realHomeDirectory + "/Volumes"
            let dirName = mountPointName(label: request.label, hostAlias: request.hostAlias)
            mountPoint = "\(mountsDir)/\(dirName)"
        } else {
            mountPoint = PathUtilities.expandTilde(request.localPath)
        }

        // Create mount point if needed
        if !FileManager.default.fileExists(atPath: mountPoint) {
            try FileManager.default.createDirectory(atPath: mountPoint, withIntermediateDirectories: true)
        }

        let urlString = request.resourceURLString()

        let mountArgs = ["-F", "-t", Self.fsType, urlString, mountPoint]

        Log.bridge.debug("Requesting mount: \(Self.redactedResourceURLString(urlString), privacy: .public) -> \(mountPoint, privacy: .public)")

        // Run: mount -F -t sshfs ssh://alias/path?opts /local/path
        let result = try await run(
            "/sbin/mount",
            arguments: mountArgs
        )

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.bridge.error("Mount failed: \(stderr) (exit \(result.exitCode))")
            // Clean up auto-created mount point on failure
            if request.localPath.isEmpty {
                try? FileManager.default.removeItem(atPath: mountPoint)
            }
            throw MountError.mountFailed(stderr.isEmpty ? "mount exited with code \(result.exitCode)" : stderr)
        }

        Log.bridge.debug("Mount succeeded: \(mountPoint)")
        return mountPoint
    }

    /// Unmount a mount point. Does not throw if already unmounted.
    /// If `force` is true, uses `umount -f`.
    func requestUnmount(localPath: String, force: Bool = false) async throws {
        let resolved = PathUtilities.expandTilde(localPath)
        guard !resolved.isEmpty else {
            Log.bridge.debug("Skipping unmount: empty path")
            return
        }
        let args = force ? ["-f", resolved] : [resolved]
        Log.bridge.debug("Requesting \(force ? "force " : "")unmount: \(resolved)")
        let result = try await run("/sbin/umount", arguments: args)

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            // "not currently mounted" is fine — already in desired state
            if MountError.isAlreadyUnmountedMessage(stderr) {
                Log.bridge.debug("Already unmounted: \(resolved)")
            } else {
                Log.bridge.error("Unmount failed: \(stderr) (exit \(result.exitCode))")
                let detail = MountError.unmountFailureMessage(
                    localPath: resolved,
                    stderr: stderr,
                    exitCode: result.exitCode
                )
                if force {
                    throw MountError.mountFailed("\(detail). \(MountError.daemonRecoveryHint)")
                }
                throw MountError.mountFailed("\(detail). Retry with Force Unmount.")
            }
        } else {
            Log.bridge.debug("\(force ? "Force u" : "U")nmount succeeded: \(resolved)")
        }

        // Clean up auto-created mount point directory under ~/Volumes
        let userVolumes = PathUtilities.realHomeDirectory + "/Volumes"
        if resolved.hasPrefix(userVolumes) {
            try? FileManager.default.removeItem(atPath: resolved)
        }
    }

    /// List active sshfs mounts by parsing `mount` output.
    func activeMounts() async -> [ActiveMount] {
        guard let result = try? await run("/sbin/mount", arguments: ["-t", Self.fsType]) else {
            return []
        }
        // Parse lines like: ssh://alias/path on /local/path (sshfs, ...)
        return result.stdout
            .split(separator: "\n")
            .compactMap { line -> ActiveMount? in
                let parts = line.split(separator: " on ", maxSplits: 1)
                guard parts.count == 2 else { return nil }
                let remoteStr = String(parts[0])
                let rest = parts[1]
                // The local path is everything before the parenthesized options
                let local: String
                if let parenIdx = rest.lastIndex(of: "(") {
                    local = String(rest[rest.startIndex..<parenIdx]).trimmingCharacters(in: .whitespaces)
                } else {
                    local = String(rest).trimmingCharacters(in: .whitespaces)
                }
                return ActiveMount(remote: ParsedRemote.from(urlString: remoteStr), localPath: local)
            }
    }

    // MARK: - Path Helpers

    /// Build a Finder-friendly mount point directory name from the user's label.
    /// Falls back to hostAlias if label is nil or empty.
    private func mountPointName(label: String?, hostAlias: String) -> String {
        let raw = (label ?? hostAlias).trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return sanitizePathComponent(hostAlias) }

        // Allow spaces for Finder readability; replace filesystem-unsafe chars.
        var result = sanitizePathComponent(raw, allowSpaces: true)
        result = collapseRepeatedDashes(result)
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "- "))
        return result.isEmpty ? sanitizePathComponent(hostAlias, allowSpaces: false) : result
    }

    private func sanitizePathComponent(_ value: String, allowSpaces: Bool = false) -> String {
        let filtered = value.map { ch -> Character in
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "_" || ch == "." {
                return ch
            }
            if allowSpaces && ch == " " {
                return ch
            }
            return "-"
        }
        return String(filtered)
    }

    private func collapseRepeatedDashes(_ value: String) -> String {
        var result = String()
        result.reserveCapacity(value.count)
        var previousWasDash = false
        for ch in value {
            if ch == "-" {
                if !previousWasDash {
                    result.append(ch)
                }
                previousWasDash = true
            } else {
                result.append(ch)
                previousWasDash = false
            }
        }
        return result
    }

    private static func redactedResourceURLString(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString), let queryItems = components.queryItems else {
            return urlString
        }
        components.queryItems = queryItems.map { item in
            if item.name == "auth_password" {
                return URLQueryItem(name: item.name, value: "<redacted>")
            }
            return item
        }
        return components.string ?? urlString
    }

    // MARK: - Process Helper

    func run(_ path: String, arguments: [String]) async throws -> ProcessRunner.Result {
        try await ProcessRunner.runAsync(path, arguments: arguments)
    }
}
