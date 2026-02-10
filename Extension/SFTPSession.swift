import Foundation
import CLibSSH2

// MARK: - SFTP Types

/// Process-wide libssh2 runtime lifecycle.
/// libssh2_init/libssh2_exit are global and must be balanced across sessions.
private enum LibSSH2Runtime {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var refCount = 0

    static func acquire() throws {
        lock.lock()
        defer { lock.unlock() }

        if refCount == 0 {
            guard libssh2_init(0) == 0 else {
                throw MountError.connectionFailed("libssh2_init failed")
            }
        }
        refCount += 1
    }

    static func release() {
        lock.lock()
        defer { lock.unlock() }

        guard refCount > 0 else { return }
        refCount -= 1
        if refCount == 0 {
            libssh2_exit()
        }
    }
}

struct SFTPDirectoryEntry: Sendable {
    let name: String
    let isDirectory: Bool
    let isSymlink: Bool
    let size: UInt64
    let permissions: UInt32
    let modifiedAt: Date
}

struct SFTPFileAttributes: Sendable {
    let size: UInt64
    let permissions: UInt32
    let uid: UInt32
    let gid: UInt32
    let accessedAt: Date
    let modifiedAt: Date
    let isDirectory: Bool
    let isSymlink: Bool
}

// MARK: - SFTP Session

/// Wraps an SSH connection + SFTP subsystem using libssh2.
/// Each mount gets one SFTPSession instance.
final class SFTPSession: @unchecked Sendable {

    enum IOMode: Sendable {
        case blocking
        case nonBlocking
    }

    let host: String
    let port: Int
    let connectionInfo: SSHConnectionInfo
    let mountOptions: MountOptions
    let ioMode: IOMode

    private var sshSession: OpaquePointer?    // LIBSSH2_SESSION*
    private var sftpSession: OpaquePointer?   // LIBSSH2_SFTP*
    private var sock: Int32 = -1
    private var storedAuthMethods: [SSHAuthMethod] = []
    private var didAcquireLibSSH2 = false

    // MARK: - File Handle Cache

    /// Cached SFTP file handle with metadata for LRU eviction.
    private struct CachedHandle {
        let handle: OpaquePointer          // LIBSSH2_SFTP_HANDLE*
        let forWriting: Bool
        var lastUsed: Date
    }

    /// LRU cache of open SFTP file handles, keyed by remote path.
    private var handleCache: [String: CachedHandle] = [:]
    /// Maximum number of handles to keep open.
    private let maxCachedHandles = 16
    private var isNonBlockingIO: Bool { ioMode == .nonBlocking }

    private func shouldRetryEAGAIN() -> Bool {
        guard isNonBlockingIO, let session = sshSession else { return false }
        return ssh2_session_last_errno(session) == SSH2_ERROR_EAGAIN
    }

    private func waitSocketReady(timeoutMs: Int32 = 10_000) throws {
        guard isNonBlockingIO, let session = sshSession, sock >= 0 else { return }

        let blockDirections = ssh2_session_block_directions(session)
        var events: Int16 = 0
        if (blockDirections & SSH2_SESSION_BLOCK_INBOUND) != 0 {
            events |= Int16(POLLIN)
        }
        if (blockDirections & SSH2_SESSION_BLOCK_OUTBOUND) != 0 {
            events |= Int16(POLLOUT)
        }
        if events == 0 {
            events = Int16(POLLIN | POLLOUT)
        }

        var fds = pollfd(fd: sock, events: events, revents: 0)
        let pollRC = Darwin.poll(&fds, 1, timeoutMs)
        if pollRC == 0 {
            throw POSIXError(.ETIMEDOUT)
        }
        if pollRC < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func closeFileHandle(_ handle: OpaquePointer) {
        if !isNonBlockingIO {
            _ = ssh2_sftp_close(handle)
            return
        }

        while true {
            let rc = ssh2_sftp_close(handle)
            if rc == SSH2_ERROR_EAGAIN {
                do {
                    try waitSocketReady()
                } catch {
                    return
                }
                continue
            }
            return
        }
    }

    /// Acquire a cached SFTP file handle, or open a new one.
    /// Caller must NOT close the returned handle — it is managed by the cache.
    func acquireHandle(path: String, forWriting: Bool) throws -> OpaquePointer {
        // If we have a cached handle with compatible mode, reuse it
        if let cached = handleCache[path], cached.forWriting || !forWriting {
            handleCache[path]!.lastUsed = Date()
            return cached.handle
        }

        // If there's a cached handle with wrong mode, close it first
        if let existing = handleCache.removeValue(forKey: path) {
            closeFileHandle(existing.handle)
        }

        // Evict least-recently-used if at capacity
        if handleCache.count >= maxCachedHandles {
            evictLRUHandle()
        }

        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }

        let flags: UInt = forWriting
            ? UInt(LIBSSH2_FXF_READ | LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT)
            : UInt(LIBSSH2_FXF_READ)
        let mode: Int = forWriting
            ? Int(LIBSSH2_SFTP_S_IRUSR | LIBSSH2_SFTP_S_IWUSR | LIBSSH2_SFTP_S_IRGRP | LIBSSH2_SFTP_S_IROTH)
            : 0

        while true {
            let handle = libssh2_sftp_open_ex(
                sftp, path, UInt32(path.utf8.count),
                flags, mode,
                LIBSSH2_SFTP_OPENFILE
            )
            if let handle {
                handleCache[path] = CachedHandle(handle: handle, forWriting: forWriting, lastUsed: Date())
                return handle
            }
            if shouldRetryEAGAIN() {
                try waitSocketReady()
                continue
            }
            throw sftpError("open failed for \(path)")
        }
    }

    /// Release a cached handle for a specific path (called on closeItem).
    func releaseHandle(path: String) {
        if let entry = handleCache.removeValue(forKey: path) {
            closeFileHandle(entry.handle)
        }
    }

    /// Close all cached handles (called before disconnect/reconnect).
    func releaseAllHandles() {
        for entry in handleCache.values {
            closeFileHandle(entry.handle)
        }
        handleCache.removeAll()
    }

    /// Evict the least-recently-used handle.
    private func evictLRUHandle() {
        guard let oldest = handleCache.min(by: { $0.value.lastUsed < $1.value.lastUsed }) else { return }
        closeFileHandle(oldest.value.handle)
        handleCache.removeValue(forKey: oldest.key)
    }

    init(
        host: String,
        port: Int,
        connectionInfo: SSHConnectionInfo,
        options: MountOptions = MountOptions(),
        ioMode: IOMode = .blocking
    ) {
        self.host = host
        self.port = port
        self.connectionInfo = connectionInfo
        self.mountOptions = options
        self.ioMode = ioMode
    }

    deinit {
        disconnect()
    }

    // MARK: - Connection

    func connect(authMethods: [SSHAuthMethod]) throws {
        storedAuthMethods = authMethods
        if !didAcquireLibSSH2 {
            try LibSSH2Runtime.acquire()
            didAcquireLibSSH2 = true
        }

        do {
            // 1. Create TCP socket
            sock = socket(AF_INET, SOCK_STREAM, 0)
            guard sock >= 0 else {
                throw MountError.connectionFailed("socket() failed: \(errno)")
            }

            // 1b. Socket timeouts, connect timeout, and aggressive TCP keepalive
            var timeout = timeval(tv_sec: 10, tv_usec: 0)
            setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            // Cap TCP connect() to 5s so reconnect attempts fail fast when host is unreachable
            var connectTimeout: Int32 = 5
            setsockopt(sock, IPPROTO_TCP, 0x20, &connectTimeout, socklen_t(MemoryLayout<Int32>.size)) // TCP_CONNECTIONTIMEOUT
            var keepAlive: Int32 = 1
            setsockopt(sock, SOL_SOCKET, SO_KEEPALIVE, &keepAlive, socklen_t(MemoryLayout<Int32>.size))
            // Start TCP keepalive probes after 5s idle, every 1s, give up after 3 failures → dead in ~8s
            var keepIdle: Int32 = 5
            setsockopt(sock, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, socklen_t(MemoryLayout<Int32>.size))
            var keepIntvl: Int32 = 1
            setsockopt(sock, IPPROTO_TCP, 0x101, &keepIntvl, socklen_t(MemoryLayout<Int32>.size)) // TCP_KEEPINTVL
            var keepCnt: Int32 = 3
            setsockopt(sock, IPPROTO_TCP, 0x102, &keepCnt, socklen_t(MemoryLayout<Int32>.size)) // TCP_KEEPCNT

            // 2. Resolve and connect
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM

            var res: UnsafeMutablePointer<addrinfo>?
            let portStr = String(port)
            let rc = getaddrinfo(host, portStr, &hints, &res)
            guard rc == 0, let addrInfo = res else {
                close(sock)
                sock = -1
                let errMsg = rc != 0 ? String(cString: gai_strerror(rc)) : "unknown"
                throw MountError.connectionFailed("getaddrinfo failed for \(host):\(port) - \(errMsg)")
            }
            defer { freeaddrinfo(res) }

            let connectResult = Darwin.connect(sock, addrInfo.pointee.ai_addr, addrInfo.pointee.ai_addrlen)
            guard connectResult == 0 else {
                close(sock)
                sock = -1
                throw MountError.connectionFailed("connect() failed to \(host):\(port) - errno \(errno)")
            }

            // 3. Create SSH session
            sshSession = ssh2_session_init()
            guard let session = sshSession else {
                close(sock)
                sock = -1
                throw MountError.connectionFailed("libssh2_session_init failed")
            }

            // Set blocking mode and SSH-level timeout
            libssh2_session_set_blocking(session, 1)
            ssh2_session_set_timeout(session, 10_000) // 10s SSH operation timeout

            // 4. SSH handshake
            let hsrc = libssh2_session_handshake(session, sock)
            guard hsrc == 0 else {
                throw sshError("Handshake failed", session: session, code: hsrc)
            }

            // 5. Authenticate
            let user = connectionInfo.user
            var authenticated = false

            Log.sftp.info("Authenticating \(user, privacy: .private)@\(self.host, privacy: .public):\(self.port, privacy: .public)")

            var authChain = authMethods
            if let sessionPassword = mountOptions.authPassword, !sessionPassword.isEmpty {
                authChain.append(.password(sessionPassword))
            }

            for method in authChain {
                switch method {
                case .agent:
                    Log.sftp.debug("Trying SSH agent auth")
                    if tryAgentAuth(session: session, user: user) {
                        Log.sftp.info("SSH agent auth succeeded")
                        authenticated = true
                    } else {
                        Log.sftp.debug("SSH agent auth failed")
                    }

                case .publicKey(let keyPath):
                    Log.sftp.debug("Trying public key auth")
                    if tryPublicKeyAuth(session: session, user: user, keyPath: keyPath) {
                        Log.sftp.info("Public key auth succeeded")
                        authenticated = true
                    } else {
                        Log.sftp.debug("Public key auth failed")
                    }

                case .password(let password):
                    Log.sftp.debug("Trying password auth")
                    if tryPasswordAuth(session: session, user: user, password: password) {
                        Log.sftp.info("Password auth succeeded")
                        authenticated = true
                    } else {
                        Log.sftp.debug("Password auth failed")
                    }
                }

                if authenticated { break }
            }

            guard authenticated else {
                Log.sftp.error("All auth methods exhausted for \(user, privacy: .private)@\(self.host, privacy: .public)")
                throw MountError.authFailed("All authentication methods failed for \(user)@\(host)")
            }

            // 6. Open SFTP subsystem
            sftpSession = libssh2_sftp_init(session)
            guard sftpSession != nil else {
                throw sshError("SFTP init failed", session: session, code: -1)
            }

            // 7. Disable libssh2's built-in keepalive — ConnectionHealthMonitor
            //    runs explicit SFTP probes with configurable interval/timeout.
            ssh2_keepalive_config(session, 0, 0)

            // Dedicated I/O sessions can run in non-blocking mode with EAGAIN/poll loops.
            if isNonBlockingIO {
                libssh2_session_set_blocking(session, 0)
            }
        } catch {
            disconnect()
            throw error
        }
    }

    func disconnect() {
        releaseAllHandles()
        if let sftp = sftpSession {
            if isNonBlockingIO {
                while true {
                    let rc = libssh2_sftp_shutdown(sftp)
                    if rc == SSH2_ERROR_EAGAIN {
                        do {
                            try waitSocketReady()
                        } catch {
                            break
                        }
                        continue
                    }
                    break
                }
            } else {
                libssh2_sftp_shutdown(sftp)
            }
            sftpSession = nil
        }
        if let session = sshSession {
            if isNonBlockingIO {
                while true {
                    let rc = ssh2_session_disconnect(session, "bye")
                    if rc == SSH2_ERROR_EAGAIN {
                        do {
                            try waitSocketReady()
                        } catch {
                            break
                        }
                        continue
                    }
                    break
                }
            } else {
                _ = ssh2_session_disconnect(session, "bye")
            }
            libssh2_session_free(session)
            sshSession = nil
        }
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        if didAcquireLibSSH2 {
            LibSSH2Runtime.release()
            didAcquireLibSSH2 = false
        }
    }

    // MARK: - Connection Status & Reconnect

    /// Probe whether the connection is alive by doing an actual SFTP round-trip.
    /// An SFTP stat on "." requires the server to reply.
    func sendKeepalive(timeoutMs: Int32 = 3_000) -> Bool {
        guard let session = sshSession, let sftp = sftpSession else { return false }
        let effectiveTimeout = max(1_000, timeoutMs)
        ssh2_session_set_timeout(session, Int(effectiveTimeout))
        defer { ssh2_session_set_timeout(session, 10_000) }
        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        return libssh2_sftp_stat_ex(sftp, ".", 1, LIBSSH2_SFTP_STAT, &attrs) == 0
    }

    /// Classify whether an error indicates the SSH/SFTP connection is broken.
    static func isConnectionError(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        // libssh2 / SFTP session-level failures
        if msg.contains("no session") || msg.contains("connection") ||
           msg.contains("socket") || msg.contains("handshake") ||
           msg.contains("sftp init failed") {
            return true
        }
        // POSIX-level I/O errors that typically mean the pipe is dead
        if let posix = error as? POSIXError,
           [.EIO, .ECONNRESET, .EPIPE, .ETIMEDOUT, .ENETDOWN, .ENETRESET].contains(posix.code) {
            return true
        }
        return false
    }

    /// Tear down the existing connection and make a single reconnect attempt.
    /// The caller (ConnectionHealthMonitor) handles retry scheduling with
    /// exponential backoff, so this method must NOT retry internally.
    func reconnect() throws {
        disconnect()
        do {
            try connect(authMethods: storedAuthMethods)
        } catch {
            disconnect()
            throw error
        }
    }

    // MARK: - Authentication Helpers

    private func tryAgentAuth(session: OpaquePointer, user: String) -> Bool {
        guard let agent = libssh2_agent_init(session) else { return false }
        defer { libssh2_agent_free(agent) }

        guard libssh2_agent_connect(agent) == 0 else { return false }
        defer { libssh2_agent_disconnect(agent) }

        guard libssh2_agent_list_identities(agent) == 0 else { return false }

        var prev: UnsafeMutablePointer<libssh2_agent_publickey>?
        while libssh2_agent_get_identity(agent, &prev, prev) == 0 {
            guard let identity = prev else { break }
            if libssh2_agent_userauth(agent, user, identity) == 0 {
                return true
            }
        }
        return false
    }

    private func tryPublicKeyAuth(session: OpaquePointer, user: String, keyPath: String) -> Bool {
        let pubKeyPath = keyPath + ".pub"
        let hasPub = FileManager.default.fileExists(atPath: pubKeyPath)

        let rc = ssh2_userauth_publickey_fromfile(
            session,
            user,
            hasPub ? pubKeyPath : nil,
            keyPath,
            nil
        )
        return rc == 0
    }

    private func tryPasswordAuth(session: OpaquePointer, user: String, password: String) -> Bool {
        guard !password.isEmpty else { return false }
        let rc = ssh2_userauth_password(session, user, password)
        return rc == 0
    }

    // MARK: - Directory Operations

    func readDirectory(path: String) throws -> [SFTPDirectoryEntry] {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }

        let handle = ssh2_sftp_opendir(sftp, path)
        guard handle != nil else {
            throw sftpError("opendir failed for \(path)")
        }
        defer { ssh2_sftp_closedir(handle) }

        var entries: [SFTPDirectoryEntry] = []
        let bufSize = 512
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        let longBuf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer {
            buf.deallocate()
            longBuf.deallocate()
        }

        var attrs = LIBSSH2_SFTP_ATTRIBUTES()

        while true {
            let rc = libssh2_sftp_readdir_ex(handle, buf, bufSize, longBuf, bufSize, &attrs)
            if rc <= 0 { break }

            let name = String(cString: buf)
            if name == "." || name == ".." { continue }

            let hasPerm = (attrs.flags & UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)) != 0
            let isDir = hasPerm && (attrs.permissions & UInt(LIBSSH2_SFTP_S_IFDIR)) != 0
            let isSymlink = hasPerm && (attrs.permissions & UInt(LIBSSH2_SFTP_S_IFLNK)) == UInt(LIBSSH2_SFTP_S_IFLNK)

            let entry = SFTPDirectoryEntry(
                name: name,
                isDirectory: isDir,
                isSymlink: isSymlink,
                size: attrs.filesize,
                permissions: UInt32(attrs.permissions & 0o7777),
                modifiedAt: Date(timeIntervalSince1970: TimeInterval(attrs.mtime))
            )
            entries.append(entry)
        }

        return entries
    }

    func mkdir(path: String, permissions: Int = 0o755) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let rc = libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), Int(permissions))
        guard rc == 0 else { throw sftpError("mkdir failed for \(path)") }
    }

    // MARK: - File Operations

    func readFile(path: String, offset: UInt64, length: Int, into buffer: UnsafeMutableRawBufferPointer) throws -> Int {
        let requestedLength = min(length, buffer.count)
        guard requestedLength > 0 else { return 0 }
        guard let bufferBase = buffer.baseAddress else { return 0 }

        let handle = try acquireHandle(path: path, forWriting: false)

        libssh2_sftp_seek64(handle, offset)

        var totalRead = 0

        while totalRead < requestedLength {
            let remaining = requestedLength - totalRead
            let base = bufferBase.advanced(by: totalRead)
            let rc = libssh2_sftp_read(handle, base.assumingMemoryBound(to: CChar.self), remaining)
            if rc == Int(SSH2_ERROR_EAGAIN) {
                try waitSocketReady()
                continue
            }
            if rc < 0 {
                releaseHandle(path: path)
                throw sftpError("read failed for \(path)")
            }
            if rc == 0 { break } // EOF
            totalRead += rc
        }

        return totalRead
    }

    func readFile(path: String, offset: UInt64, length: Int) throws -> Data {
        guard length > 0 else { return Data() }
        var data = Data(count: length)
        let totalRead = try data.withUnsafeMutableBytes { ptr in
            try readFile(path: path, offset: offset, length: length, into: ptr)
        }
        if totalRead < data.count {
            data.removeSubrange(totalRead..<data.count)
        }
        return data
    }

    func writeFile(path: String, offset: UInt64, data: Data) throws -> Int {
        let handle = try acquireHandle(path: path, forWriting: true)

        libssh2_sftp_seek64(handle, offset)

        var totalWritten = 0
        while totalWritten < data.count {
            let rc = data.withUnsafeBytes { ptr -> Int in
                let base = ptr.baseAddress!.advanced(by: totalWritten)
                let remaining = data.count - totalWritten
                return libssh2_sftp_write(handle, base.assumingMemoryBound(to: CChar.self), remaining)
            }
            if rc == Int(SSH2_ERROR_EAGAIN) {
                try waitSocketReady()
                continue
            }
            if rc < 0 {
                releaseHandle(path: path)
                throw sftpError("write failed for \(path)")
            }
            if rc == 0 { break }
            totalWritten += rc
        }

        return totalWritten
    }

    func createFile(path: String, permissions: Int = 0o644) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }

        let handle = libssh2_sftp_open_ex(
            sftp, path, UInt32(path.utf8.count),
            UInt(LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC | LIBSSH2_FXF_WRITE),
            Int(permissions),
            LIBSSH2_SFTP_OPENFILE
        )
        guard handle != nil else { throw sftpError("create failed for \(path)") }
        ssh2_sftp_close(handle)
    }

    func remove(path: String) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let rc = libssh2_sftp_unlink_ex(sftp, path, UInt32(path.utf8.count))
        guard rc == 0 else { throw sftpError("unlink failed for \(path)") }
    }

    func rmdir(path: String) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let rc = libssh2_sftp_rmdir_ex(sftp, path, UInt32(path.utf8.count))
        guard rc == 0 else { throw sftpError("rmdir failed for \(path)") }
    }

    func rename(from oldPath: String, to newPath: String) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let rc = libssh2_sftp_rename_ex(
            sftp,
            oldPath, UInt32(oldPath.utf8.count),
            newPath, UInt32(newPath.utf8.count),
            Int(LIBSSH2_SFTP_RENAME_OVERWRITE | LIBSSH2_SFTP_RENAME_ATOMIC | LIBSSH2_SFTP_RENAME_NATIVE)
        )
        guard rc == 0 else { throw sftpError("rename failed \(oldPath) → \(newPath)") }
    }

    func symlink(target: String, linkPath: String) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        // libssh2_sftp_symlink_ex with LIBSSH2_SFTP_SYMLINK:
        //   path = what the link points to (target content)
        //   target param = path of the new symlink to create
        var linkBuf = Array(linkPath.utf8CString)
        let rc = libssh2_sftp_symlink_ex(
            sftp,
            target, UInt32(target.utf8.count),
            &linkBuf, UInt32(linkPath.utf8.count),
            LIBSSH2_SFTP_SYMLINK
        )
        guard rc == 0 else { throw sftpError("symlink failed: \(linkPath) -> \(target)") }
    }

    func readlink(path: String) throws -> String {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let bufSize = 1024
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        let rc = libssh2_sftp_symlink_ex(
            sftp,
            path, UInt32(path.utf8.count),
            buf, UInt32(bufSize),
            LIBSSH2_SFTP_READLINK
        )
        guard rc >= 0 else { throw sftpError("readlink failed for \(path)") }
        return String(cString: buf)
    }

    // MARK: - Path Resolution

    /// Resolve a path to its absolute form via SFTP realpath.
    func realpath(_ path: String) throws -> String {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let bufSize = 1024
        let buf = UnsafeMutablePointer<CChar>.allocate(capacity: bufSize)
        defer { buf.deallocate() }

        let rc = libssh2_sftp_symlink_ex(
            sftp,
            path, UInt32(path.utf8.count),
            buf, UInt32(bufSize),
            LIBSSH2_SFTP_REALPATH
        )
        guard rc >= 0 else { throw sftpError("realpath failed for \(path)") }
        return String(cString: buf)
    }

    /// Resolve `~` and `~/...` to absolute paths. Pass through absolute paths unchanged.
    func resolvePath(_ path: String) throws -> String {
        if path == "~" {
            return try realpath(".")
        } else if path.hasPrefix("~/") {
            let home = try realpath(".")
            let rest = String(path.dropFirst(2))
            return home.hasSuffix("/") ? home + rest : home + "/" + rest
        } else if path.hasPrefix("/") {
            return path
        } else {
            // Relative path — resolve against home
            let home = try realpath(".")
            return home.hasSuffix("/") ? home + path : home + "/" + path
        }
    }

    // MARK: - Metadata

    func stat(path: String, followSymlinks: Bool = true) throws -> SFTPFileAttributes {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }

        var attrs = LIBSSH2_SFTP_ATTRIBUTES()
        let statType = followSymlinks ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT
        let rc = libssh2_sftp_stat_ex(
            sftp, path, UInt32(path.utf8.count),
            statType, &attrs
        )
        guard rc == 0 else { throw sftpError("stat failed for \(path)") }

        let mode = attrs.permissions
        let isDir = (mode & UInt(LIBSSH2_SFTP_S_IFDIR)) != 0
        let isSymlink = (mode & UInt(LIBSSH2_SFTP_S_IFLNK)) == UInt(LIBSSH2_SFTP_S_IFLNK)

        return SFTPFileAttributes(
            size: attrs.filesize,
            permissions: UInt32(mode & 0o7777),
            uid: UInt32(attrs.uid),
            gid: UInt32(attrs.gid),
            accessedAt: Date(timeIntervalSince1970: TimeInterval(attrs.atime)),
            modifiedAt: Date(timeIntervalSince1970: TimeInterval(attrs.mtime)),
            isDirectory: isDir,
            isSymlink: isSymlink
        )
    }

    func setstat(path: String, attrs: inout LIBSSH2_SFTP_ATTRIBUTES) throws {
        guard let sftp = sftpSession else { throw MountError.sftpError("No session") }
        let rc = libssh2_sftp_stat_ex(
            sftp, path, UInt32(path.utf8.count),
            LIBSSH2_SFTP_SETSTAT, &attrs
        )
        guard rc == 0 else { throw sftpError("setstat failed for \(path)") }
    }

    // MARK: - Error Helpers

    private func sshError(_ msg: String, session: OpaquePointer, code: Int32) -> MountError {
        var errmsg: UnsafeMutablePointer<CChar>?
        var errlen: Int32 = 0
        libssh2_session_last_error(session, &errmsg, &errlen, 0)
        let detail = errmsg.map { String(cString: $0) } ?? "unknown"
        return MountError.connectionFailed("\(msg): \(detail) (code \(code))")
    }

    private func sftpError(_ msg: String) -> MountError {
        guard let sftp = sftpSession else {
            return MountError.sftpError(msg)
        }
        let code = libssh2_sftp_last_error(sftp)
        return MountError.sftpError("\(msg) (SFTP error \(code))")
    }
}
