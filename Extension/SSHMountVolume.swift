import Foundation
@preconcurrency import FSKit
import CLibSSH2

// MARK: - FSKit Item Type from SFTP Types

@available(macOS 26.0, *)
extension SFTPFileTyped {
    var fsItemType: FSItem.ItemType {
        if isSymlink { return .symlink }
        if isDirectory { return .directory }
        return .file
    }
}

/// The mounted volume. Implements FSKit volume operations
/// by translating them into SFTP calls.
@available(macOS 26.0, *)
final class SSHMountVolume: FSVolume,
                            FSVolume.Operations,
                            FSVolume.OpenCloseOperations,
                            FSVolume.ReadWriteOperations,
                            @unchecked Sendable {

    // MARK: - Constants

    private static let defaultBlockSize = 4096
    private static let defaultIOSize = 262_144
    private static func pendingOperationLimit(for profile: MountProfile) -> Int {
        profile == .git ? 64 : 128
    }

    let sftp: SFTPSession
    let remotePath: String
    let mountOptions: MountOptions
    let healthMonitor: ConnectionHealthMonitor

    /// Serial queue for primary-session SFTP operations (metadata + fallback I/O).
    /// libssh2 is not thread-safe per session.
    private let sftpQueue = DispatchQueue(label: "com.sshmount.sftp-serial", qos: .utility)

    /// Dispatch work onto the serial SFTP queue without introducing additional Sendable constraints.
    private func enqueueSFTPOperation(onTimeout: (() -> Void)? = nil, _ work: @escaping () -> Void) {
        enqueueOperation(on: sftpQueue, onTimeout: onTimeout, work)
    }

    /// Global queue backpressure so overload does not create an unbounded async backlog.
    private let pendingOperationSemaphore: DispatchSemaphore

    private func enqueueOperation(on queue: DispatchQueue, onTimeout: (() -> Void)? = nil, _ work: @escaping () -> Void) {
        let waitStart = Date()
        let timeout = DispatchTime.now() + .milliseconds(mountOptions.queueTimeoutMs)
        guard pendingOperationSemaphore.wait(timeout: timeout) == .success else {
            healthMonitor.recordQueueWait(milliseconds: Double(mountOptions.queueTimeoutMs), saturated: true)
            healthMonitor.triggerReconnect(reason: .workerExhausted)
            onTimeout?()
            return
        }
        let waitedMs = Date().timeIntervalSince(waitStart) * 1000
        healthMonitor.recordQueueWait(milliseconds: waitedMs, saturated: false)
        let semaphore = pendingOperationSemaphore
        queue.async(execute: DispatchWorkItem(block: {
            defer { semaphore.signal() }
            work()
        }))
    }

    /// Dedicated SSH session and serial queue for keepalive probes.
    /// Runs independently of all I/O queues so probes are never blocked by load.
    private let keepaliveSession: SFTPSession
    private let keepaliveQueue = DispatchQueue(label: "com.sshmount.sftp-keepalive", qos: .userInitiated)

    /// Dedicated I/O worker with its own SSH/SFTP session and serial queue.
    private final class IOWorker: @unchecked Sendable {
        let sftp: SFTPSession
        let queue: DispatchQueue

        init(sftp: SFTPSession, label: String) {
            self.sftp = sftp
            self.queue = DispatchQueue(label: label, qos: .utility)
        }
    }

    private let readWorkers: [IOWorker]
    private let writeWorkers: [IOWorker]
    private let readWorkerLock = NSLock()
    private var nextReadWorkerIndex = 0
    private let shutdownLock = NSLock()
    private var isShutdown = false

    // MARK: - Item ↔ Path Tracking

    private let itemTracker = ItemTracker()

    // MARK: - Attribute & Directory Cache

    private let cache = AttributeCache()

    init(
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName,
        sftp: SFTPSession,
        keepaliveSession: SFTPSession,
        readSessions: [SFTPSession] = [],
        writeSessions: [SFTPSession] = [],
        remotePath: String,
        options: MountOptions = MountOptions(),
        healthMonitor: ConnectionHealthMonitor
    ) {
        self.sftp = sftp
        self.keepaliveSession = keepaliveSession
        self.readWorkers = readSessions.enumerated().map {
            IOWorker(sftp: $0.element, label: "com.sshmount.sftp-read-\($0.offset)")
        }
        self.writeWorkers = writeSessions.enumerated().map {
            IOWorker(sftp: $0.element, label: "com.sshmount.sftp-write-\($0.offset)")
        }
        self.remotePath = remotePath
        self.mountOptions = options
        self.pendingOperationSemaphore = DispatchSemaphore(
            value: Self.pendingOperationLimit(for: options.profile)
        )
        self.healthMonitor = healthMonitor
        super.init(volumeID: volumeID, volumeName: volumeName)
        setupHealthMonitor()
    }

    private func setupHealthMonitor() {
        // Keepalive probes run on a dedicated session + queue, never blocked by I/O.
        healthMonitor.onSendSSHKeepalive = { [weak self] timeoutMs in
            guard let self else { return false }
            return self.keepaliveQueue.sync {
                self.keepaliveSession.sendSSHKeepalive(timeoutMs: timeoutMs)
            }
        }

        healthMonitor.onSendSFTPProbe = { [weak self] timeoutMs in
            guard let self else { return false }
            return self.keepaliveQueue.sync {
                self.keepaliveSession.probeSFTP(timeoutMs: timeoutMs)
            }
        }

        healthMonitor.onReconnectNeeded = { [weak self] reason in
            guard let self else { return false }
            // Reconnect the keepalive session first (it's the canary).
            let keepaliveOk = self.keepaliveQueue.sync {
                do {
                    try self.keepaliveSession.reconnect()
                    return true
                } catch {
                    Log.volume.notice("Keepalive session reconnect failed (\(reason.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
            guard keepaliveOk else { return false }

            // Then reconnect the primary session.
            return self.sftpQueue.sync {
                do {
                    self.sftp.releaseAllHandles()
                    try self.sftp.reconnect()
                    return true
                } catch {
                    Log.volume.notice("Primary session reconnect failed (\(reason.rawValue, privacy: .public)): \(error.localizedDescription, privacy: .public)")
                    return false
                }
            }
        }

        healthMonitor.onStateChanged = { [weak self] newState in
            guard let self else { return }
            if newState == .connected {
                // Caches are stale after reconnection
                self.invalidateAllCaches()
                self.reconnectIOSessions()
            }
        }
    }

    /// Get or create an FSItem for a remote path.
    private func item(forPath path: String) -> (FSItem, UInt64) {
        itemTracker.item(forPath: path)
    }

    /// Resolve an FSItem back to its remote path.
    private func path(for item: FSItem) -> String? {
        itemTracker.path(for: item)
    }

    /// Remove tracking for an item (called on reclaim).
    private func untrack(_ item: FSItem) {
        itemTracker.untrack(item)
    }

    /// Build the full child path from a directory item + child name.
    private func childPath(directory: FSItem, name: String) -> String? {
        itemTracker.childPath(directory: directory, name: name)
    }

    /// Dispatch reads to worker sessions in round-robin order.
    /// Falls back to the primary session if no worker sessions are configured.
    private func enqueueReadOperation(onTimeout: (() -> Void)? = nil, _ work: @escaping (_ session: SFTPSession) -> Void) {
        guard !readWorkers.isEmpty else {
            enqueueSFTPOperation(onTimeout: onTimeout) { work(self.sftp) }
            return
        }

        readWorkerLock.lock()
        let index = nextReadWorkerIndex % readWorkers.count
        nextReadWorkerIndex += 1
        let worker = readWorkers[index]
        readWorkerLock.unlock()

        enqueueOperation(on: worker.queue, onTimeout: onTimeout, {
            work(worker.sftp)
        })
    }

    private func enqueueWriteOperation(path: String, onTimeout: (() -> Void)? = nil, _ work: @escaping (_ session: SFTPSession) -> Void) {
        guard !writeWorkers.isEmpty else {
            enqueueSFTPOperation(onTimeout: onTimeout) { work(self.sftp) }
            return
        }

        let worker: IOWorker
        if writeWorkers.count == 1 {
            worker = writeWorkers[0]
        } else {
            var hash: UInt64 = 1469598103934665603
            for byte in path.utf8 {
                hash ^= UInt64(byte)
                hash &*= 1099511628211
            }
            worker = writeWorkers[Int(hash % UInt64(writeWorkers.count))]
        }

        enqueueOperation(on: worker.queue, onTimeout: onTimeout, {
            work(worker.sftp)
        })
    }

    private func withHealthTracked<T>(_ op: () throws -> T) throws -> T {
        healthMonitor.recordOperationStart()
        var success = false
        defer { healthMonitor.recordOperationResult(success: success) }
        let value = try op()
        success = true
        return value
    }

    private func withIOSessionReconnect<T>(_ session: SFTPSession, op: () throws -> T) throws -> T {
        try withHealthTracked {
            do {
                return try op()
            } catch {
                guard SFTPSession.isConnectionError(error) else { throw error }
                session.releaseAllHandles()
                try session.reconnect()
                return try op()
            }
        }
    }

    /// Dispatch to the appropriate reconnect strategy based on which session is being used.
    private func withSessionReconnect<T>(_ session: SFTPSession, op: () throws -> T) throws -> T {
        if session === self.sftp {
            return try withReconnect(op)
        } else {
            return try withIOSessionReconnect(session, op: op)
        }
    }

    private var allWorkers: [IOWorker] { readWorkers + writeWorkers }
    private var reconnectWaitTimeout: TimeInterval {
        max(15, mountOptions.healthTimeout * Double(mountOptions.healthFailures + 1))
    }

    private func reconnectIOSessions() {
        for worker in allWorkers {
            worker.queue.async {
                worker.sftp.releaseAllHandles()
                do {
                    try worker.sftp.reconnect()
                } catch {
                    Log.volume.notice("Worker reconnect failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func releaseHandleAcrossSessions(path: String) {
        sftp.releaseHandle(path: path)
        for worker in allWorkers {
            worker.queue.sync {
                worker.sftp.releaseHandle(path: path)
            }
        }
    }

    private func syncPathAcrossSessions(path: String) throws {
        try sftp.syncHandle(path: path)
        for worker in allWorkers {
            try worker.queue.sync {
                try worker.sftp.syncHandle(path: path)
            }
        }
    }

    private func syncAllWriteHandlesAcrossSessions() throws {
        try sftp.syncAllWriteHandles()
        for worker in allWorkers {
            try worker.queue.sync {
                try worker.sftp.syncAllWriteHandles()
            }
        }
    }

    private func disconnectAllSessions() {
        shutdownLock.lock()
        if isShutdown {
            shutdownLock.unlock()
            return
        }
        isShutdown = true
        shutdownLock.unlock()

        for worker in allWorkers {
            worker.queue.sync {
                worker.sftp.disconnect()
            }
        }
        keepaliveQueue.sync {
            keepaliveSession.disconnect()
        }
        sftp.disconnect()
    }

    func shutdown() {
        disconnectAllSessions()
    }

    // MARK: - Reconnect Wrapper

    /// Flush all attribute and directory caches (called after reconnection).
    private func invalidateAllCaches() {
        cache.invalidateAll()
        Log.volume.debug("All caches invalidated after reconnection")
    }

    /// Execute an SFTP operation with resilience to transient disconnections.
    ///
    /// If the health monitor indicates the connection is suspended or reconnecting,
    /// waits up to `reconnect_timeout` seconds for recovery before failing.
    /// On connection error during the operation, triggers reconnection and retries once.
    private func withReconnect<T>(_ op: () throws -> T) throws -> T {
        try withHealthTracked {
            // If we know the connection is down, wait for reconnection first
            if healthMonitor.state == .reconnecting {
                Log.volume.debug("withReconnect: connection not ready (state=\(self.healthMonitor.state.description, privacy: .public)), waiting")
                let recovered = healthMonitor.waitForConnected(timeout: reconnectWaitTimeout)
                if !recovered {
                    Log.volume.error("withReconnect: timed out waiting for reconnection")
                    throw POSIXError(.ETIMEDOUT)
                }
            }

            do {
                return try op()
            } catch {
                guard SFTPSession.isConnectionError(error) else { throw error }
                Log.volume.notice("Connection error detected, triggering reconnect")
                healthMonitor.triggerReconnect(reason: .transportError)
                let recovered = healthMonitor.waitForConnected(timeout: reconnectWaitTimeout)
                guard recovered else {
                    Log.volume.error("withReconnect: reconnect failed")
                    throw POSIXError(.ETIMEDOUT)
                }
                return try op()
            }
        }
    }

    // MARK: - Error Mapping

    /// Map an SFTP error to the most appropriate POSIX error code.
    private static func posixCode(from error: Error, fallback: POSIXErrorCode = .EIO) -> POSIXErrorCode {
        if let mountError = error as? MountError {
            return mountError.posixErrorCode
        }
        if let posixError = error as? POSIXError {
            return posixError.code
        }
        return fallback
    }

    // MARK: - Attributes Helpers

    /// Convert SFTPFileAttributes → FSItem.Attributes.
    private func fsAttributes(from sftpAttrs: SFTPFileAttributes, itemID: UInt64, parentID: UInt64) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        attrs.type = sftpAttrs.fsItemType
        attrs.mode = sftpAttrs.permissions
        attrs.uid = sftpAttrs.uid
        attrs.gid = sftpAttrs.gid

        attrs.size = sftpAttrs.size
        attrs.allocSize = sftpAttrs.size
        attrs.fileID = FSItem.Identifier(rawValue: itemID)!
        attrs.parentID = FSItem.Identifier(rawValue: parentID)!
        attrs.linkCount = sftpAttrs.isDirectory ? 2 : 1
        attrs.modifyTime = timespec(tv_sec: Int(sftpAttrs.modifiedAt.timeIntervalSince1970), tv_nsec: 0)
        attrs.accessTime = attrs.modifyTime
        attrs.changeTime = attrs.modifyTime
        attrs.birthTime = attrs.modifyTime
        return attrs
    }

    /// Get item ID for a path (creates one if needed).
    private func itemID(forPath path: String) -> UInt64 {
        itemTracker.itemID(forPath: path)
    }

    // MARK: - Cached SFTP Stat

    /// Stat with optional caching based on cache_timeout option.
    private func cachedStat(path: String) throws -> SFTPFileAttributes {
        let timeout = mountOptions.cacheTimeout
        if timeout > 0, let cached = cache.cachedAttrs(forPath: path) {
            return cached
        }

        let attrs = try withReconnect {
            try sftp.stat(path: path)
        }

        if timeout > 0 {
            cache.setAttrs(attrs, forPath: path, timeout: timeout)
        }

        return attrs
    }

    /// Invalidate cache entry for a path (called after writes/creates/deletes).
    private func invalidateCache(_ path: String, includeParent: Bool = true) {
        guard mountOptions.cacheTimeout > 0 || mountOptions.dirCacheTimeout > 0 else { return }
        cache.invalidate(path, includeParent: includeParent)
    }

    /// Read directory with optional caching based on dir_cache_timeout.
    private func cachedReadDir(path: String) throws -> [SFTPDirectoryEntry] {
        let timeout = mountOptions.dirCacheTimeout
        if timeout > 0, let cached = cache.cachedDirEntries(forPath: path) {
            return cached
        }

        let entries = try withReconnect { try sftp.readDirectory(path: path) }

        if timeout > 0 {
            cache.setDirEntries(entries, forPath: path, timeout: timeout)
        }

        return entries
    }

    // MARK: - Volume Lifecycle

    func mount(
        options: FSTaskOptions,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        disconnectAllSessions()
        reply()
    }

    func synchronize(
        flags: FSSyncFlags,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        enqueueSFTPOperation(onTimeout: {
            reply(POSIXError(.EAGAIN))
        }) {
            do {
                try self.syncAllWriteHandlesAcrossSessions()
                reply(nil)
            } catch {
                Log.volume.notice("synchronize failed: \(error.localizedDescription, privacy: .public)")
                reply(POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Activate / Deactivate

    func activate(
        options: FSTaskOptions,
        replyHandler reply: @escaping (FSItem?, Error?) -> Void
    ) {
        // Register the root item
        let (rootItem, _) = item(forPath: remotePath)
        reply(rootItem, nil)
    }

    func deactivate(
        options: FSDeactivateOptions,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        disconnectAllSessions()
        reply(nil)
    }

    // MARK: - Lookup

    func lookupItem(
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let childName = name.string else {
            reply(nil, nil, POSIXError(.ENOENT))
            return
        }
        guard let fullPath = childPath(directory: directory, name: childName) else {
            reply(nil, nil, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, nil, POSIXError(.EAGAIN))
        }) {
            do {
                let _ = try self.cachedStat(path: fullPath)
                let (childItem, _) = self.item(forPath: fullPath)
                reply(childItem, name, nil)
            } catch {
                Log.volume.notice("lookupItem failed for \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, nil, POSIXError(Self.posixCode(from: error, fallback: .ENOENT)))
            }
        }
    }

    func reclaimItem(
        _ item: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        untrack(item)
        reply(nil)
    }

    // MARK: - Attributes

    func getAttributes(
        _ desiredAttributes: FSItem.GetAttributesRequest,
        of item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            Log.volume.debug("getAttributes: item not tracked")
            reply(nil, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, POSIXError(.EAGAIN))
        }) {
            do {
                let sftpAttrs = try self.cachedStat(path: itemPath)
                let id = self.itemID(forPath: itemPath)
                let parentPath = (itemPath as NSString).deletingLastPathComponent
                let parentID = self.itemID(forPath: parentPath)
                let attrs = self.fsAttributes(from: sftpAttrs, itemID: id, parentID: parentID)
                reply(attrs, nil)
            } catch {
                Log.volume.notice("getAttributes failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            reply(nil, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, POSIXError(.EAGAIN))
        }) {
            do {
                var attrs = LIBSSH2_SFTP_ATTRIBUTES()
                attrs.flags = 0

                if newAttributes.isValid(.mode) {
                    attrs.permissions = UInt(newAttributes.mode)
                    attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
                }
                if newAttributes.isValid(.uid) || newAttributes.isValid(.gid) {
                    attrs.uid = UInt(newAttributes.uid)
                    attrs.gid = UInt(newAttributes.gid)
                    attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_UIDGID)
                }
                if newAttributes.isValid(.size) {
                    attrs.filesize = newAttributes.size
                    attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_SIZE)
                }
                if newAttributes.isValid(.modifyTime) || newAttributes.isValid(.accessTime) {
                    attrs.mtime = UInt(newAttributes.modifyTime.tv_sec)
                    attrs.atime = attrs.mtime
                    attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)
                }

                try self.withReconnect { try self.sftp.setstat(path: itemPath, attrs: &attrs) }
                self.invalidateCache(itemPath, includeParent: false)

                let updated = try self.withReconnect {
                    try self.sftp.stat(path: itemPath)
                }
                let id = self.itemID(forPath: itemPath)
                let parentPath = (itemPath as NSString).deletingLastPathComponent
                let parentID = self.itemID(forPath: parentPath)
                reply(self.fsAttributes(from: updated, itemID: id, parentID: parentID), nil)
            } catch {
                Log.volume.notice("setAttributes failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Directory Enumeration

    func enumerateDirectory(
        _ directory: FSItem,
        startingAt cookie: FSDirectoryCookie,
        verifier: FSDirectoryVerifier,
        attributes: FSItem.GetAttributesRequest?,
        packer: FSDirectoryEntryPacker,
        replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void
    ) {
        guard let dirPath = path(for: directory) else {
            reply(verifier, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(verifier, POSIXError(.EAGAIN))
        }) {
            do {
                let entries = try self.cachedReadDir(path: dirPath)
                let dirID = self.itemID(forPath: dirPath)
                var cookieCounter: UInt64 = 1

                for entry in entries {
                    if cookieCounter <= cookie.rawValue {
                        cookieCounter += 1
                        continue
                    }

                    let childPath = dirPath.hasSuffix("/")
                        ? dirPath + entry.name
                        : dirPath + "/" + entry.name
                    let childID = self.itemID(forPath: childPath)

                    let itemType = entry.fsItemType

                    var entryAttrs: FSItem.Attributes? = nil
                    if attributes != nil {
                        entryAttrs = FSItem.Attributes()
                        entryAttrs!.type = itemType
                        entryAttrs!.fileID = FSItem.Identifier(rawValue: childID)!
                        entryAttrs!.parentID = FSItem.Identifier(rawValue: dirID)!
                        entryAttrs!.size = entry.size
                        entryAttrs!.mode = entry.permissions
                        entryAttrs!.linkCount = entry.isDirectory ? 2 : 1
                        let mtime = timespec(tv_sec: Int(entry.modifiedAt.timeIntervalSince1970), tv_nsec: 0)
                        entryAttrs!.modifyTime = mtime
                        entryAttrs!.accessTime = mtime
                    }

                    let packed = packer.packEntry(
                        name: FSFileName(string: entry.name),
                        itemType: itemType,
                        itemID: FSItem.Identifier(rawValue: childID)!,
                        nextCookie: FSDirectoryCookie(rawValue: cookieCounter),
                        attributes: entryAttrs
                    )

                    if !packed {
                        reply(verifier, nil)
                        return
                    }

                    cookieCounter += 1
                }

                reply(verifier, nil)
            } catch {
                Log.volume.notice("enumerateDirectory failed for \(dirPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(verifier, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Create / Remove

    func createItem(
        named name: FSFileName,
        type: FSItem.ItemType,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let childName = name.string,
              let fullPath = childPath(directory: directory, name: childName) else {
            reply(nil, nil, POSIXError(.EINVAL))
            return
        }

        let mode = attributes.isValid(.mode) ? Int(attributes.mode) : 0o644

        enqueueSFTPOperation(onTimeout: {
            reply(nil, nil, POSIXError(.EAGAIN))
        }) {
            do {
                try self.withReconnect {
                    switch type {
                    case .directory:
                        try self.sftp.mkdir(path: fullPath, permissions: mode)
                    default:
                        try self.sftp.createFile(path: fullPath, permissions: mode)
                    }
                }

                self.invalidateCache(fullPath)
                let (newItem, _) = self.item(forPath: fullPath)
                reply(newItem, name, nil)
            } catch {
                Log.volume.error("createItem failed for \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let childName = name.string,
              let fullPath = childPath(directory: directory, name: childName) else {
            reply(POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(POSIXError(.EAGAIN))
        }) {
            do {
                self.releaseHandleAcrossSessions(path: fullPath)
                try self.withReconnect {
                    let attrs = try self.sftp.stat(path: fullPath)
                    if attrs.isDirectory {
                        try self.sftp.rmdir(path: fullPath)
                    } else {
                        try self.sftp.remove(path: fullPath)
                    }
                }
                self.invalidateCache(fullPath)
                self.untrack(item)
                reply(nil)
            } catch {
                Log.volume.notice("removeItem failed for \(fullPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func renameItem(
        _ item: FSItem,
        inDirectory sourceDirectory: FSItem,
        named sourceName: FSFileName,
        to destinationName: FSFileName,
        inDirectory destinationDirectory: FSItem,
        overItem: FSItem?,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let srcName = sourceName.string,
              let dstName = destinationName.string,
              let srcPath = childPath(directory: sourceDirectory, name: srcName),
              let dstPath = childPath(directory: destinationDirectory, name: dstName) else {
            reply(nil, POSIXError(.EINVAL))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, POSIXError(.EAGAIN))
        }) {
            do {
                self.releaseHandleAcrossSessions(path: srcPath)
                self.releaseHandleAcrossSessions(path: dstPath)
                try self.withReconnect { try self.sftp.rename(from: srcPath, to: dstPath) }
                self.invalidateCache(srcPath)
                self.invalidateCache(dstPath)
                self.untrack(item)
                let _ = self.item(forPath: dstPath)
                if let over = overItem { self.untrack(over) }
                reply(destinationName, nil)
            } catch {
                Log.volume.notice("renameItem failed \(srcPath, privacy: .public) → \(dstPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Symlinks

    func readSymbolicLink(
        _ item: FSItem,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            reply(nil, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, POSIXError(.EAGAIN))
        }) {
            do {
                let target = try self.withReconnect { try self.sftp.readlink(path: itemPath) }
                reply(FSFileName(string: target), nil)
            } catch {
                Log.volume.notice("readSymbolicLink failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func createSymbolicLink(
        named name: FSFileName,
        inDirectory directory: FSItem,
        attributes: FSItem.SetAttributesRequest,
        linkContents contents: FSFileName,
        replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void
    ) {
        guard let childName = name.string,
              let linkPath = childPath(directory: directory, name: childName),
              let target = contents.string else {
            reply(nil, nil, POSIXError(.EINVAL))
            return
        }

        enqueueSFTPOperation(onTimeout: {
            reply(nil, nil, POSIXError(.EAGAIN))
        }) {
            do {
                try self.withReconnect { try self.sftp.symlink(target: target, linkPath: linkPath) }
                self.invalidateCache(linkPath)
                let (newItem, _) = self.item(forPath: linkPath)
                reply(newItem, name, nil)
            } catch {
                Log.volume.error("createSymbolicLink failed for \(linkPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(nil, nil, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func createLink(
        to item: FSItem,
        named name: FSFileName,
        inDirectory directory: FSItem,
        replyHandler reply: @escaping (FSFileName?, Error?) -> Void
    ) {
        // Hard links not supported over SFTP
        reply(nil, POSIXError(.ENOTSUP))
    }

    // MARK: - Open / Close (FSVolume.OpenCloseOperations)

    func openItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        // Handles are opened lazily on first read/write via the handle cache
        reply(nil)
    }

    func closeItem(
        _ item: FSItem,
        modes: FSVolume.OpenModes,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            reply(nil)
            return
        }
        enqueueSFTPOperation(onTimeout: {
            reply(POSIXError(.EAGAIN))
        }) {
            do {
                if self.mountOptions.profile == .git {
                    try self.syncPathAcrossSessions(path: itemPath)
                }
                self.releaseHandleAcrossSessions(path: itemPath)
                reply(nil)
            } catch {
                Log.volume.notice("closeItem failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Read / Write (FSVolume.ReadWriteOperations)

    func read(
        from item: FSItem,
        at offset: Int64,
        length: Int,
        into buffer: FSMutableFileDataBuffer,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            reply(0, POSIXError(.ENOENT))
            return
        }

        enqueueReadOperation(onTimeout: {
            reply(0, POSIXError(.EAGAIN))
        }) { session in
            do {
                if offset < 0 {
                    reply(0, POSIXError(.EINVAL))
                    return
                }
                let bytesRead = try buffer.withUnsafeMutableBytes { dst in
                    let readLength = min(length, dst.count, Self.defaultIOSize)
                    guard readLength > 0 else { return 0 }
                    let readOffset = UInt64(offset)
                    return try self.withSessionReconnect(session) {
                        try session.readFile(path: itemPath, offset: readOffset, length: readLength, into: dst)
                    }
                }
                reply(bytesRead, nil)
            } catch {
                Log.volume.notice("read failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(0, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: Int64,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        guard let itemPath = path(for: item) else {
            reply(0, POSIXError(.ENOENT))
            return
        }
        guard offset >= 0 else {
            reply(0, POSIXError(.EINVAL))
            return
        }

        enqueueWriteOperation(path: itemPath, onTimeout: {
            reply(0, POSIXError(.EAGAIN))
        }) { session in
            do {
                let writeOffset = UInt64(offset)
                let chunk = contents.count > Self.defaultIOSize ? Data(contents.prefix(Self.defaultIOSize)) : contents
                let written = try self.withSessionReconnect(session) {
                    try session.writeFile(path: itemPath, offset: writeOffset, data: chunk)
                }
                self.invalidateCache(itemPath, includeParent: false)
                reply(written, nil)
            } catch {
                Log.volume.error("write failed for \(itemPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                reply(0, POSIXError(Self.posixCode(from: error)))
            }
        }
    }

    // MARK: - Volume Properties

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsSymbolicLinks = true
        caps.supportsPersistentObjectIDs = false
        caps.supportsHardLinks = false
        caps.caseFormat = .sensitive
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        let stats = FSStatFSResult(fileSystemTypeName: "sshfs")
        stats.blockSize = Self.defaultBlockSize
        stats.ioSize = Self.defaultIOSize
        stats.totalBlocks = 1_000_000
        stats.freeBlocks = 500_000
        stats.availableBlocks = 500_000
        return stats
    }

    // MARK: - Path Conf

    var maximumLinkCount: Int { 1 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { true }
    var truncatesLongNames: Bool { false }
}
