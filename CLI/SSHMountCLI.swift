import Foundation
import ArgumentParser

@main
struct SSHMountCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sshmount",
        abstract: "Mount remote directories over SSH/SFTP.",
        subcommands: [Mount.self, Unmount.self, List.self, Status.self, Test.self],
        defaultSubcommand: Mount.self
    )

    static let fsType = "sshfs"
}

// MARK: - sshmount mount alias:/path /local/path

struct Mount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Mount a remote directory."
    )

    @Argument(help: "Remote path: <hostAlias>:<path>")
    var remote: String

    @Argument(help: "Local mount point.")
    var mountPoint: String

    @Option(name: .long, help: "Profile: standard or git.")
    var profile: String = "standard"

    @Option(name: .long, help: "Number of read worker sessions (1-8).")
    var readWorkers: Int = 1

    @Option(name: .long, help: "Number of write worker sessions (1-8).")
    var writeWorkers: Int = 1

    @Option(name: .long, help: "I/O mode: blocking or nonblocking.")
    var ioMode: String = "blocking"

    @Option(name: .long, help: "Health probe interval in seconds (1-300).")
    var healthInterval: Int = 5

    @Option(name: .long, help: "Health probe timeout in seconds (1-120).")
    var healthTimeout: Int = 10

    @Option(name: .long, help: "Consecutive health failures before reconnect (1-12).")
    var healthFailures: Int = 5

    @Option(name: .long, help: "In-flight operation threshold that suppresses reconnect escalation (1-4096).")
    var busyThreshold: Int = 32

    @Option(name: .long, help: "Grace window in seconds after successful I/O (0-300).")
    var graceSeconds: Int = 20

    @Option(name: .long, help: "Queue wait timeout in milliseconds (100-60000).")
    var queueTimeoutMs: Int = 2_000

    @Option(name: .long, help: "Attribute cache TTL in seconds (0-300).")
    var cacheAttr: Int = 5

    @Option(name: .long, help: "Directory cache TTL in seconds (0-300).")
    var cacheDir: Int = 5

    @Flag(name: .shortAndLong, help: "Verbose output.")
    var verbose = false

    func run() throws {
        let parsedRequest = try MountRequest.parse(remote: remote, localPath: mountPoint)
        let request = MountRequest(
            hostAlias: parsedRequest.hostAlias,
            remotePath: parsedRequest.remotePath,
            localPath: parsedRequest.localPath,
            label: nil,
            options: try parsedOptions(),
            sessionPassword: nil
        )

        // Enforce configured aliases only.
        let parser = SSHConfigParser()
        try parser.validateAlias(request.hostAlias)

        // Ensure mount point exists.
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: mountPoint, isDirectory: &isDir) || !isDir.boolValue {
            throw MountError.mountFailed("Mount point does not exist or is not a directory: \(mountPoint)")
        }

        let urlString = request.resourceURLString()

        if verbose {
            if let connInfo = try? parser.resolve(alias: request.hostAlias) {
                print("Alias:       \(request.hostAlias)")
                print("Hostname:    \(connInfo.hostname)")
                print("User:        \(connInfo.user)")
                print("Port:        \(connInfo.port)")
                print("Identities:  \(connInfo.identityFiles)")
            }
            print("Remote path: \(request.remotePath)")
            print("Mount point: \(request.localPath)")
            if let options = request.options {
                print("Profile:     \(options.profile.rawValue)")
                print("Read workers:\(options.readWorkers)")
                print("Write worker:\(options.writeWorkers)")
                print("I/O mode:    \(options.ioMode.rawValue)")
                print("Health:      \(Int(options.healthInterval))s /\(Int(options.healthTimeout))s x\(options.healthFailures)")
                print("Busy/Grace:  \(options.busyThreshold) / \(Int(options.graceSeconds))s")
                print("Queue t/o:   \(options.queueTimeoutMs)ms")
                print("Cache:       attr \(Int(options.cacheTimeout))s dir \(Int(options.dirCacheTimeout))s")
            }
            print("Resource URL: \(urlString)")
        }

        // Call mount -F -t sshfs ssh://alias/path?opts /mount/point
        let result = try ProcessRunner.runSync(
            "/sbin/mount",
            arguments: ["-F", "-t", SSHMountCLI.fsType, urlString, mountPoint]
        )

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount exited with code \(result.exitCode)" : stderr)
        }

        print("Mounted \(request.hostAlias):\(request.remotePath) -> \(mountPoint)")
    }

    private func parsedOptions() throws -> MountOptions {
        let dict: [String: String] = [
            "profile": profile,
            "read_workers": String(readWorkers),
            "write_workers": String(writeWorkers),
            "io_mode": ioMode,
            "health_interval_s": String(healthInterval),
            "health_timeout_s": String(healthTimeout),
            "health_failures": String(healthFailures),
            "busy_threshold": String(busyThreshold),
            "grace_seconds": String(graceSeconds),
            "queue_timeout_ms": String(queueTimeoutMs),
            "cache_attr_s": String(cacheAttr),
            "cache_dir_s": String(cacheDir),
        ]
        return try MountOptions(from: dict)
    }
}

// MARK: - sshmount unmount /local/path

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Unmount a mounted directory."
    )

    @Argument(help: "Local mount point to unmount.")
    var mountPoint: String

    @Flag(name: .shortAndLong, help: "Force unmount (passes -f to umount).")
    var force = false

    func run() throws {
        let args = force ? ["-f", mountPoint] : [mountPoint]
        let result = try ProcessRunner.runSync("/sbin/umount", arguments: args)

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if MountError.isAlreadyUnmountedMessage(stderr) {
                print("Already unmounted \(mountPoint)")
                return
            }
            let detail = MountError.unmountFailureMessage(
                localPath: mountPoint,
                stderr: stderr,
                exitCode: result.exitCode
            )
            if force {
                throw MountError.mountFailed("\(detail). \(MountError.daemonRecoveryHint)")
            }
            throw MountError.mountFailed("\(detail). Retry with --force.")
        }

        print("Unmounted \(mountPoint)\(force ? " (forced)" : "")")
    }
}

// MARK: - sshmount list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all active mounts."
    )

    func run() throws {
        let listResult = try ProcessRunner.runSync("/sbin/mount", arguments: [])
        guard listResult.exitCode == 0 else {
            let stderr = listResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount listing failed" : stderr)
        }
        let output = listResult.stdout

        let sshfsMounts = output
            .split(separator: "\n")
            .filter { $0.contains("(\(SSHMountCLI.fsType)") }

        if sshfsMounts.isEmpty {
            print("No active SSH mounts.")
        } else {
            print("Active SSH mounts:")
            for mount in sshfsMounts {
                print("  \(mount)")
            }
        }
    }
}

// MARK: - sshmount status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show extension and connection status."
    )

    func run() throws {
        print("SSHMount Status")
        print("  FS type:  \(SSHMountCLI.fsType)")
        print("  Extension: com.sshmount.app.fs")

        let statusResult = try ProcessRunner.runSync("/sbin/mount", arguments: [])
        guard statusResult.exitCode == 0 else {
            let stderr = statusResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount status query failed" : stderr)
        }
        let output = statusResult.stdout

        let count = output
            .split(separator: "\n")
            .filter { $0.contains("(\(SSHMountCLI.fsType)") }
            .count

        print("  Mounts:   \(count) active")
    }
}

// MARK: - sshmount test alias:/path

struct Test: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Test SFTP connection directly (no FSKit/extension needed)."
    )

    @Argument(help: "Remote path: <hostAlias>:<path>")
    var remote: String

    func run() throws {
        let request = try MountRequest.parse(remote: remote, localPath: "/tmp")

        let parser = SSHConfigParser()
        try parser.validateAlias(request.hostAlias)

        let connInfo = try parser.resolve(alias: request.hostAlias)

        print("=== SSHMount SFTP Test ===")
        print("Alias:  \(request.hostAlias)")
        print("Host:   \(connInfo.hostname):\(connInfo.port)")
        print("User:   \(connInfo.user)")
        print("Path:   \(request.remotePath)")
        print()

        print("[1/5] Resolved via ~/.ssh/config:")
        print("  Hostname: \(connInfo.hostname)")
        print("  Port:     \(connInfo.port)")
        print("  User:     \(connInfo.user)")
        print("  Keys:     \(connInfo.identityFiles)")
        if let proxy = connInfo.proxyJump {
            print("  Proxy:    \(proxy)")
        }
        print()

        let sftp = SFTPSession(host: connInfo.hostname, port: connInfo.port, connectionInfo: connInfo)

        print("[2/5] Connecting...")
        let authMethods = connInfo.authMethods()
        try sftp.connect(authMethods: authMethods)
        print("  Connected and authenticated!")
        print()

        let resolvedPath = try sftp.resolvePath(request.remotePath)
        if resolvedPath != request.remotePath {
            print("  Resolved path: \(request.remotePath) -> \(resolvedPath)")
            print()
        }

        print("[3/5] Stat \(resolvedPath)...")
        let attrs = try sftp.stat(path: resolvedPath)
        print("  Type:        \(attrs.isDirectory ? "directory" : "file")")
        print("  Size:        \(attrs.size) bytes")
        print("  Permissions: \(String(format: "%o", attrs.permissions))")
        print("  UID/GID:     \(attrs.uid)/\(attrs.gid)")
        print("  Modified:    \(attrs.modifiedAt)")
        print()

        if attrs.isDirectory {
            print("[4/5] Listing \(resolvedPath)...")
            let entries = try sftp.readDirectory(path: resolvedPath)
            print("  \(entries.count) entries:")
            for entry in entries.prefix(20) {
                let typeChar: Character = entry.isDirectory ? "d" : "-"
                let perms = String(format: "%o", entry.permissions)
                let size = String(format: "%8d", entry.size)
                print("  \(typeChar) \(perms) \(size)  \(entry.name)")
            }
            if entries.count > 20 {
                print("  ... and \(entries.count - 20) more")
            }
        } else {
            print("[4/5] Reading first 256 bytes of \(resolvedPath)...")
            let data = try sftp.readFile(path: resolvedPath, offset: 0, length: 256)
            if let text = String(data: data, encoding: .utf8) {
                print("  \(text)")
            } else {
                print("  (\(data.count) bytes, binary)")
            }
        }
        print()

        print("[5/5] Disconnecting...")
        sftp.disconnect()
        print("  Done!")
        print()
        print("=== All tests passed ===")
    }
}
