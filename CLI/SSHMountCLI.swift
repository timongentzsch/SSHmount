import Foundation
import ArgumentParser

private struct CLIProcessResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

private func runProcess(_ path: String, arguments: [String]) throws -> CLIProcessResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    try process.run()
    process.waitUntilExit()

    let stdout = String(
        data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""
    let stderr = String(
        data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
        encoding: .utf8
    ) ?? ""

    return CLIProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
}

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

    @Option(name: [.customShort("o"), .long], help: "Comma-separated mount options (e.g. rdonly,nosuid,follow_symlinks=no).")
    var mountOptions: String?

    @Flag(name: .shortAndLong, help: "Verbose output.")
    var verbose = false

    func run() throws {
        let parsedRequest = try MountRequest.parse(remote: remote, localPath: mountPoint)
        let request = MountRequest(
            hostAlias: parsedRequest.hostAlias,
            remotePath: parsedRequest.remotePath,
            localPath: parsedRequest.localPath,
            label: nil,
            mountOptions: mountOptions,
            sessionPassword: nil
        )

        // Enforce configured aliases only.
        let parser = SSHConfigParser()
        let knownAliases = Set(parser.knownHosts())
        guard knownAliases.contains(request.hostAlias) else {
            throw MountError.invalidFormat("Unknown host alias '\(request.hostAlias)'. Add it to ~/.ssh/config first.")
        }

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
            if let opts = mountOptions { print("Mount opts:  \(opts)") }
            print("Resource URL: \(urlString)")
        }

        // Call mount -F -t sshfs ssh://alias/path?opts /mount/point
        let result = try runProcess(
            "/sbin/mount",
            arguments: ["-F", "-t", SSHMountCLI.fsType, urlString, mountPoint]
        )

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount exited with code \(result.exitCode)" : stderr)
        }

        print("Mounted \(request.hostAlias):\(request.remotePath) -> \(mountPoint)")
    }
}

// MARK: - sshmount unmount /local/path

struct Unmount: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Unmount a mounted directory."
    )

    @Argument(help: "Local mount point to unmount.")
    var mountPoint: String

    func run() throws {
        let result = try runProcess("/sbin/umount", arguments: [mountPoint])

        if result.exitCode != 0 {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "umount failed" : stderr)
        }

        print("Unmounted \(mountPoint)")
    }
}

// MARK: - sshmount list

struct List: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List all active mounts."
    )

    func run() throws {
        let result = try runProcess("/sbin/mount", arguments: [])
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount listing failed" : stderr)
        }
        let output = result.stdout

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

        let result = try runProcess("/sbin/mount", arguments: [])
        guard result.exitCode == 0 else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw MountError.mountFailed(stderr.isEmpty ? "mount status query failed" : stderr)
        }
        let output = result.stdout

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
        let knownAliases = Set(parser.knownHosts())
        guard knownAliases.contains(request.hostAlias) else {
            throw MountError.invalidFormat("Unknown host alias '\(request.hostAlias)'. Add it to ~/.ssh/config first.")
        }

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
