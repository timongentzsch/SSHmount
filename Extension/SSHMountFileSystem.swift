import Foundation
import FSKit

/// FSKit filesystem module.
/// Subclasses FSUnaryFileSystem — a single resource maps to a single volume.
/// The resource is our SSH connection URL, the volume is the remote directory.
@available(macOS 26.0, *)
final class SSHMountFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    /// Track the active volume so we can tear it down on unload.
    private var activeVolume: SSHMountVolume?
    /// Proactive connection health monitor.
    private var healthMonitor: ConnectionHealthMonitor?

    // MARK: - FSUnaryFileSystemOperations

    /// Derive a stable UUID from the resource URL so each unique connection
    /// gets its own container identity. Prevents "Resource busy" when remounting.
    private static func containerUUID(for url: URL) -> UUID {
        let key = "\(url.host ?? "")\(url.path)?\(url.query ?? "")"
        // UUID v5 (SHA-1 name-based) in a fixed namespace
        let namespace = UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890")!
        return uuidV5(namespace: namespace, name: key)
    }

    /// Probe whether we can handle this resource.
    func probeResource(
        resource: FSResource,
        replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void
    ) {
        if let urlResource = resource as? FSGenericURLResource,
           let scheme = urlResource.url.scheme,
           scheme == "ssh" || scheme == "sftp" {
            let uuid = Self.containerUUID(for: urlResource.url)
            let result = FSProbeResult.usable(
                name: urlResource.url.host ?? "ssh-mount",
                containerID: FSContainerIdentifier(uuid: uuid)
            )
            reply(result, nil)
        } else {
            reply(.notRecognized, nil)
        }
    }

    /// Load: create SSH connection and return the volume.
    func loadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSVolume?, Error?) -> Void
    ) {
        guard let urlResource = resource as? FSGenericURLResource else {
            reply(nil, MountError.mountFailed("Expected FSGenericURLResource"))
            return
        }

        let url = urlResource.url

        guard let alias = url.host, !alias.isEmpty else {
            reply(nil, MountError.invalidFormat("URL must be ssh://<host-alias>/path"))
            return
        }

        var rawPath = url.path.isEmpty ? "~" : url.path
        // URL path includes leading "/" (e.g. ssh://alias/~ -> "/~"), strip it for SFTP
        if rawPath.hasPrefix("/") {
            rawPath = String(rawPath.dropFirst())
        }
        if rawPath.isEmpty { rawPath = "~" }

        // Parse mount/runtime options from query parameters.
        var optionsDict: [String: String] = [:]
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                optionsDict[item.name] = item.value ?? ""
            }
        }

        if optionsDict["nodev"] != nil {
            reply(nil, MountError.invalidFormat("Unsupported mount option: nodev"))
            return
        }

        let mountOpts = MountOptions(from: optionsDict)
        if !optionsDict.isEmpty {
            var redactedOptions = optionsDict
            if redactedOptions["auth_password"] != nil {
                redactedOptions["auth_password"] = "<redacted>"
            }
            Log.fs.debug("Mount options: \(redactedOptions.description, privacy: .public)")
        }

        // Resolve SSH config from ~/.ssh/config aliases only.
        let configParser = SSHConfigParser()
        let connInfo: SSHConnectionInfo
        do {
            connInfo = try configParser.resolve(alias: alias)
        } catch {
            reply(nil, error)
            return
        }

        // Create SFTP session and connect.
        let sftp = SFTPSession(host: connInfo.hostname, port: connInfo.port, connectionInfo: connInfo, options: mountOpts)

        // Authentication strictly follows ssh config + ssh-agent.
        let authMethods = connInfo.authMethods()

        do {
            try sftp.connect(authMethods: authMethods)
        } catch {
            reply(nil, error)
            return
        }

        // Resolve ~ and relative paths to absolute
        let remotePath: String
        do {
            remotePath = try sftp.resolvePath(rawPath)
        } catch {
            sftp.disconnect()
            reply(nil, error)
            return
        }

        // Create the health monitor
        let monitor = ConnectionHealthMonitor()

        // Optional extra read sessions for parallel read throughput.
        // Each session has its own serial queue in SSHMountVolume.
        let ioMode: SFTPSession.IOMode = mountOpts.nonBlockingIO ? .nonBlocking : .blocking
        var readSessions: [SFTPSession] = []
        if mountOpts.parallelSessions > 1 {
            for idx in 1..<mountOpts.parallelSessions {
                let readSession = SFTPSession(
                    host: connInfo.hostname,
                    port: connInfo.port,
                    connectionInfo: connInfo,
                    options: mountOpts,
                    ioMode: ioMode
                )
                do {
                    try readSession.connect(authMethods: authMethods)
                    readSessions.append(readSession)
                } catch {
                    readSession.disconnect()
                    Log.fs.notice("parallel_sessions: failed to initialize read session \(idx + 1, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
            Log.fs.info("parallel_sessions requested=\(mountOpts.parallelSessions, privacy: .public) active=\(readSessions.count + 1, privacy: .public)")
        }

        // Dedicated write sessions for non-blocking I/O loops.
        var writeSessions: [SFTPSession] = []
        if mountOpts.nonBlockingIO {
            let requestedWriteSessions = mountOpts.parallelWriteSessions
            for idx in 0..<requestedWriteSessions {
                let ioWriteSession = SFTPSession(
                    host: connInfo.hostname,
                    port: connInfo.port,
                    connectionInfo: connInfo,
                    options: mountOpts,
                    ioMode: .nonBlocking
                )
                do {
                    try ioWriteSession.connect(authMethods: authMethods)
                    writeSessions.append(ioWriteSession)
                } catch {
                    ioWriteSession.disconnect()
                    Log.fs.notice("parallel_write_sessions: failed to initialize write session \(idx + 1, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    break
                }
            }
            Log.fs.info("parallel_write_sessions requested=\(mountOpts.parallelWriteSessions, privacy: .public) active=\(writeSessions.count, privacy: .public)")
        }

        // Create the volume (wires up health monitor callbacks in init)
        let volumeID = FSVolume.Identifier(uuid: UUID())
        let volumeName = FSFileName(string: "\(alias):\(remotePath)")
        let volume = SSHMountVolume(
            volumeID: volumeID,
            volumeName: volumeName,
            sftp: sftp,
            readSessions: readSessions,
            writeSessions: writeSessions,
            remotePath: remotePath,
            options: mountOpts,
            healthMonitor: monitor
        )

        // Start monitoring after volume is fully initialized
        monitor.start()

        activeVolume = volume
        healthMonitor = monitor
        containerStatus = .ready
        Log.fs.info("loadResource succeeded - returning volume for \(remotePath, privacy: .public)")
        reply(volume, nil)
    }

    /// Unload: disconnect SSH and tear down.
    func unloadResource(
        resource: FSResource,
        options: FSTaskOptions,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        healthMonitor?.stop()
        healthMonitor = nil
        activeVolume?.shutdown()
        activeVolume = nil
        containerStatus = .notReady(status: MountError.mountFailed("unloaded"))
        reply(nil)
    }
}

// MARK: - UUID v5 (SHA-1 name-based)

import CommonCrypto

private func uuidV5(namespace: UUID, name: String) -> UUID {
    let nsBytes = withUnsafeBytes(of: namespace.uuid) { Array($0) }
    var data = nsBytes
    data.append(contentsOf: name.utf8)

    var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
    _ = data.withUnsafeBufferPointer { ptr in
        CC_SHA1(ptr.baseAddress, CC_LONG(ptr.count), &digest)
    }

    // Set version (5) and variant (RFC 4122)
    digest[6] = (digest[6] & 0x0F) | 0x50
    digest[8] = (digest[8] & 0x3F) | 0x80

    return UUID(uuid: (
        digest[0], digest[1], digest[2], digest[3],
        digest[4], digest[5], digest[6], digest[7],
        digest[8], digest[9], digest[10], digest[11],
        digest[12], digest[13], digest[14], digest[15]
    ))
}
