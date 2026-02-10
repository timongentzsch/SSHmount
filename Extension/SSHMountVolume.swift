import Foundation
@preconcurrency import FSKit
import CLibSSH2

/// The mounted volume. Implements FSKit volume operations
/// by translating them into SFTP calls.
@available(macOS 26.0, *)
final class SSHMountVolume: FSVolume,
                            FSVolume.Operations,
                            FSVolume.OpenCloseOperations,
                            FSVolume.ReadWriteOperations,
                            @unchecked Sendable {

    let sftp: SFTPSession
    let remotePath: String
    let mountOpts: MountOptions
    let healthMonitor: ConnectionHealthMonitor

    /// Serial queue for primary-session SFTP operations (metadata + fallback I/O).
    /// libssh2 is not thread-safe per session.
    private let sftpQueue = DispatchQueue(label: "com.sshmount.sftp-serial")

    /// Dispatch work onto the serial SFTP queue without introducing additional Sendable constraints.
    private func enqueueSFTPOperation(_ work: @escaping () -> Void) {
        enqueueOperation(on: sftpQueue, work)
    }

    /// Global queue backpressure so overload does not create an unbounded async backlog.
    private let pendingOperationSemaphore: DispatchSemaphore

    private func enqueueOperation(on queue: DispatchQueue, _ work: @escaping () -> Void) {
        pendingOperationSemaphore.wait()
        let semaphore = pendingOperationSemaphore
        queue.async(execute: DispatchWorkItem(block: {
            defer { semaphore.signal() }
            work()
        }))
    }

    /// Dedicated I/O worker with its own SSH/SFTP session and serial queue.
    private final class IOWorker: @unchecked Sendable {
        let sftp: SFTPSession
        let queue: DispatchQueue

        init(sftp: SFTPSession, label: String) {
            self.sftp = sftp
            self.queue = DispatchQueue(label: label)
        }
    }

    private let readWorkers: [IOWorker]
    private let writeWorkers: [IOWorker]
    private let readWorkerLock = NSLock()
    private var nextReadWorkerIndex = 0
    private let shutdownLock = NSLock()
    private var isShutdown = false

    // MARK: - Item ↔ Path Tracking

    /// Map FSItem (by ObjectIdentifier) → remote path.
    private var itemToPath: [ObjectIdentifier: String] = [:]
    /// Map remote path → FSItem (keeps items alive while tracked).
    private var pathToItem: [String: FSItem] = [:]
    /// Map remote path → item ID (inode-like).
    private var pathToID: [String: UInt64] = [:]
    private var nextItemID: UInt64 = 10
    private let lock = NSLock()

    // MARK: - Attribute Cache

    private struct CachedAttrs {
        let attrs: SFTPFileAttributes
        let expiry: Date
    }
    private var attrCache: [String: CachedAttrs] = [:]

    // MARK: - Directory Listing Cache

    private struct CachedDirEntries {
        let entries: [SFTPDirectoryEntry]
        let expiry: Date
    }
    private var dirCache: [String: CachedDirEntries] = [:]

    private let cacheLock = NSLock()

    init(
        volumeID: FSVolume.Identifier,
        volumeName: FSFileName,
        sftp: SFTPSession,
        readSessions: [SFTPSession] = [],
        writeSessions: [SFTPSession] = [],
        remotePath: String,
        options: MountOptions = MountOptions(),
        healthMonitor: ConnectionHealthMonitor
    ) {
        self.sftp = sftp
        self.readWorkers = readSessions.enumerated().map {
            IOWorker(sftp: $0.element, label: "com.sshmount.sftp-read-\($0.offset)")
        }
        self.writeWorkers = writeSessions.enumerated().map {
            IOWorker(sftp: $0.element, label: "com.sshmount.sftp-write-\($0.offset)")
        }
        self.remotePath = remotePath
        self.mountOpts = options
        self.pendingOperationSemaphore = DispatchSemaphore(value: options.maxPendingOperations)
        self.healthMonitor = healthMonitor
        super.init(volumeID: volumeID, volumeName: volumeName)
        setupHealthMonitor()
    }

    private func setupHealthMonitor() {
        healthMonitor.onSendKeepalive = { [weak self] in
            guard let self else { return false }
            let timeoutMs = Int32((self.mountOpts.keepaliveTimeout * 1000).rounded())
            return self.sftpQueue.sync { self.sftp.sendKeepalive(timeoutMs: timeoutMs) }
        }

        healthMonitor.onReconnectNeeded = { [weak self] in
            guard let self else { return false }
            return self.sftpQueue.sync {
                do {
                    self.sftp.releaseAllHandles()
                    try self.sftp.reconnect()
                    return true
                } catch {
                    Log.volume.notice("Health monitor reconnect failed: \(error.localizedDescription, privacy: .public)")
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
        lock.lock()
        defer { lock.unlock() }

        if let existing = pathToItem[path], let id = pathToID[path] {
            return (existing, id)
        }

        let fsItem = FSItem()
        let id = nextItemID
        nextItemID += 1

        itemToPath[ObjectIdentifier(fsItem)] = path
        pathToItem[path] = fsItem
        pathToID[path] = id
        return (fsItem, id)
    }

    /// Resolve an FSItem back to its remote path.
    private func path(for item: FSItem) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return itemToPath[ObjectIdentifier(item)]
    }

    /// Remove tracking for an item (called on reclaim).
    private func untrack(_ item: FSItem) {
        lock.lock()
        defer { lock.unlock() }
        let oid = ObjectIdentifier(item)
        if let path = itemToPath.removeValue(forKey: oid) {
            pathToItem.removeValue(forKey: path)
            pathToID.removeValue(forKey: path)
        }
    }

    /// Build the full child path from a directory item + child name.
    private func childPath(directory: FSItem, name: String) -> String? {
        guard let dirPath = path(for: directory) else { return nil }
        if dirPath.hasSuffix("/") {
            return dirPath + name
        }
        return dirPath + "/" + name
    }

    /// Dispatch reads to worker sessions in round-robin order.
    /// Falls back to the primary session if no worker sessions are configured.
    private func enqueueReadOperation(_ work: @escaping (_ session: SFTPSession) -> Void) {
        guard !readWorkers.isEmpty else {
            enqueueSFTPOperation { work(self.sftp) }
            return
        }

        readWorkerLock.lock()
        let index = nextReadWorkerIndex % readWorkers.count
        nextReadWorkerIndex += 1
        let worker = readWorkers[index]
        readWorkerLock.unlock()

        enqueueOperation(on: worker.queue, {
            work(worker.sftp)
        })
    }

    private func enqueueWriteOperation(path: String, _ work: @escaping (_ session: SFTPSession) -> Void) {
        guard !writeWorkers.isEmpty else {
            enqueueSFTPOperation { work(self.sftp) }
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

        enqueueOperation(on: worker.queue, {
            work(worker.sftp)
        })
    }

    private func withIOSessionReconnect<T>(_ session: SFTPSession, op: () throws -> T) throws -> T {
        do {
            return try op()
        } catch {
            guard SFTPSession.isConnectionError(error) else { throw error }
            session.releaseAllHandles()
            try session.reconnect()
            return try op()
        }
    }

    private func reconnectIOSessions() {
        for worker in readWorkers {
            worker.queue.async {
                worker.sftp.releaseAllHandles()
                do {
                    try worker.sftp.reconnect()
                } catch {
                    Log.volume.notice("Read worker reconnect failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        for worker in writeWorkers {
            worker.queue.async {
                worker.sftp.releaseAllHandles()
                do {
                    try worker.sftp.reconnect()
                } catch {
                    Log.volume.notice("Write worker reconnect failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func releaseHandleAcrossSessions(path: String) {
        sftp.releaseHandle(path: path)
        for worker in readWorkers {
            worker.queue.sync {
                worker.sftp.releaseHandle(path: path)
            }
        }
        for worker in writeWorkers {
            worker.queue.sync {
                worker.sftp.releaseHandle(path: path)
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

        for worker in readWorkers {
            worker.queue.sync {
                worker.sftp.disconnect()
            }
        }
        for worker in writeWorkers {
            worker.queue.sync {
                worker.sftp.disconnect()
            }
        }
        sftp.disconnect()
    }

    func shutdown() {
        disconnectAllSessions()
    }

    // MARK: - Reconnect Wrapper

    /// Flush all attribute and directory caches (called after reconnection).
    private func invalidateAllCaches() {
        cacheLock.lock()
        attrCache.removeAll()
        dirCache.removeAll()
        cacheLock.unlock()
        Log.volume.debug("All caches invalidated after reconnection")
    }

    /// Execute an SFTP operation with resilience to transient disconnections.
    ///
    /// If the health monitor indicates the connection is suspended or reconnecting,
    /// waits up to `reconnect_timeout` seconds for recovery before failing.
    /// On connection error during the operation, triggers reconnection and retries once.
    private func withReconnect<T>(_ op: () throws -> T) throws -> T {
        // If we know the connection is down, wait for reconnection first
        if healthMonitor.state != .connected {
            Log.volume.debug("withReconnect: connection not ready (state=\(self.healthMonitor.state.description, privacy: .public)), waiting")
            let recovered = healthMonitor.waitForConnected(timeout: mountOpts.reconnectTimeout)
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
            healthMonitor.triggerReconnect()
            let recovered = healthMonitor.waitForConnected(timeout: mountOpts.reconnectTimeout)
            guard recovered else {
                Log.volume.error("withReconnect: reconnect failed")
                throw POSIXError(.ETIMEDOUT)
            }
            return try op()
        }
    }

    // MARK: - Attributes Helpers

    /// Apply permission overrides from mount options.
    private func applyPermissionOverrides(_ mode: UInt32, isDirectory: Bool) -> UInt32 {
        var m = mode
        if let umask = mountOpts.umask { m &= ~umask }
        if mountOpts.noExec && !isDirectory { m &= ~0o111 }
        if mountOpts.nosuid { m &= ~0o6000 }
        return m
    }

    /// Convert SFTPFileAttributes → FSItem.Attributes, applying mount option overrides.
    private func fsAttributes(from sftpAttrs: SFTPFileAttributes, itemID: UInt64, parentID: UInt64) -> FSItem.Attributes {
        let attrs = FSItem.Attributes()
        if sftpAttrs.isSymlink {
            attrs.type = .symlink
        } else if sftpAttrs.isDirectory {
            attrs.type = .directory
        } else {
            attrs.type = .file
        }

        attrs.mode = applyPermissionOverrides(sftpAttrs.permissions, isDirectory: sftpAttrs.isDirectory)

        // Override uid/gid if requested
        attrs.uid = mountOpts.overrideUID ?? sftpAttrs.uid
        attrs.gid = mountOpts.overrideGID ?? sftpAttrs.gid

        attrs.size = sftpAttrs.size
        attrs.allocSize = sftpAttrs.size
        attrs.fileID = FSItem.Identifier(rawValue: itemID)!
        attrs.parentID = FSItem.Identifier(rawValue: parentID)!
        attrs.linkCount = sftpAttrs.isDirectory ? 2 : 1
        attrs.modifyTime = timespec(tv_sec: Int(sftpAttrs.modifiedAt.timeIntervalSince1970), tv_nsec: 0)
        if mountOpts.noatime {
            attrs.accessTime = attrs.modifyTime
        } else {
            attrs.accessTime = timespec(tv_sec: Int(sftpAttrs.accessedAt.timeIntervalSince1970), tv_nsec: 0)
        }
        attrs.changeTime = attrs.modifyTime
        attrs.birthTime = attrs.modifyTime
        return attrs
    }

    /// Get item ID for a path (creates one if needed).
    private func itemID(forPath path: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        if let id = pathToID[path] { return id }
        let id = nextItemID
        nextItemID += 1
        pathToID[path] = id
        return id
    }

    // MARK: - Cached SFTP Stat

    /// Stat with optional caching based on cache_timeout option.
    private func cachedStat(path: String) throws -> SFTPFileAttributes {
        let timeout = mountOpts.cacheTimeout
        if timeout > 0 {
            cacheLock.lock()
            if let cached = attrCache[path], cached.expiry > Date() {
                cacheLock.unlock()
                return cached.attrs
            }
            cacheLock.unlock()
        }

        let attrs = try withReconnect {
            try sftp.stat(path: path, followSymlinks: mountOpts.followSymlinks)
        }

        if timeout > 0 {
            cacheLock.lock()
            attrCache[path] = CachedAttrs(attrs: attrs, expiry: Date().addingTimeInterval(timeout))
            cacheLock.unlock()
        }

        return attrs
    }

    /// Invalidate cache entry for a path (called after writes/creates/deletes).
    private func invalidateCache(_ path: String, includeParent: Bool = true) {
        guard mountOpts.cacheTimeout > 0 || mountOpts.dirCacheTimeout > 0 else { return }
        cacheLock.lock()
        attrCache.removeValue(forKey: path)
        dirCache.removeValue(forKey: path)
        if includeParent {
            // Structural changes also invalidate parent directory metadata.
            let parent = (path as NSString).deletingLastPathComponent
            attrCache.removeValue(forKey: parent)
            dirCache.removeValue(forKey: parent)
        }
        cacheLock.unlock()
    }

    /// Read directory with optional caching based on dir_cache_timeout.
    private func cachedReadDir(path: String) throws -> [SFTPDirectoryEntry] {
        let timeout = mountOpts.dirCacheTimeout
        if timeout > 0 {
            cacheLock.lock()
            if let cached = dirCache[path], cached.expiry > Date() {
                cacheLock.unlock()
                return cached.entries
            }
            cacheLock.unlock()
        }

        let entries = try withReconnect { try sftp.readDirectory(path: path) }

        if timeout > 0 {
            cacheLock.lock()
            dirCache[path] = CachedDirEntries(entries: entries, expiry: Date().addingTimeInterval(timeout))
            cacheLock.unlock()
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
        // SFTP writes are synchronous — nothing to flush
        reply(nil)
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

        enqueueSFTPOperation {
            do {
                let _ = try self.cachedStat(path: fullPath)
                let (childItem, _) = self.item(forPath: fullPath)
                reply(childItem, name, nil)
            } catch {
                reply(nil, nil, POSIXError(.ENOENT))
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

        enqueueSFTPOperation {
            do {
                let sftpAttrs = try self.cachedStat(path: itemPath)
                let id = self.itemID(forPath: itemPath)
                let parentPath = (itemPath as NSString).deletingLastPathComponent
                let parentID = self.itemID(forPath: parentPath)
                let attrs = self.fsAttributes(from: sftpAttrs, itemID: id, parentID: parentID)
                reply(attrs, nil)
            } catch {
                reply(nil, POSIXError(.EIO))
            }
        }
    }

    func setAttributes(
        _ newAttributes: FSItem.SetAttributesRequest,
        on item: FSItem,
        replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void
    ) {
        if mountOpts.readOnly { reply(nil, POSIXError(.EROFS)); return }
        guard let itemPath = path(for: item) else {
            reply(nil, POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation {
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
                    // Skip atime updates if noatime is set
                    if self.mountOpts.noatime {
                        attrs.atime = attrs.mtime
                    } else {
                        attrs.atime = UInt(newAttributes.accessTime.tv_sec)
                    }
                    attrs.flags |= UInt(LIBSSH2_SFTP_ATTR_ACMODTIME)
                }

                try self.withReconnect { try self.sftp.setstat(path: itemPath, attrs: &attrs) }
                self.invalidateCache(itemPath, includeParent: false)

                let updated = try self.withReconnect {
                    try self.sftp.stat(path: itemPath, followSymlinks: self.mountOpts.followSymlinks)
                }
                let id = self.itemID(forPath: itemPath)
                let parentPath = (itemPath as NSString).deletingLastPathComponent
                let parentID = self.itemID(forPath: parentPath)
                reply(self.fsAttributes(from: updated, itemID: id, parentID: parentID), nil)
            } catch {
                reply(nil, POSIXError(.EIO))
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

        enqueueSFTPOperation {
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

                    let itemType: FSItem.ItemType
                    if entry.isSymlink {
                        itemType = .symlink
                    } else if entry.isDirectory {
                        itemType = .directory
                    } else {
                        itemType = .file
                    }

                    var entryAttrs: FSItem.Attributes? = nil
                    if attributes != nil {
                        entryAttrs = FSItem.Attributes()
                        entryAttrs!.type = itemType
                        entryAttrs!.fileID = FSItem.Identifier(rawValue: childID)!
                        entryAttrs!.parentID = FSItem.Identifier(rawValue: dirID)!
                        entryAttrs!.size = entry.size
                        entryAttrs!.mode = self.applyPermissionOverrides(entry.permissions, isDirectory: entry.isDirectory)
                        entryAttrs!.linkCount = entry.isDirectory ? 2 : 1
                        let mtime = timespec(tv_sec: Int(entry.modifiedAt.timeIntervalSince1970), tv_nsec: 0)
                        entryAttrs!.modifyTime = mtime
                        if self.mountOpts.noatime {
                            entryAttrs!.accessTime = mtime
                        }
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
                reply(verifier, POSIXError(.EIO))
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
        if mountOpts.readOnly { reply(nil, nil, POSIXError(.EROFS)); return }
        guard let childName = name.string,
              let fullPath = childPath(directory: directory, name: childName) else {
            reply(nil, nil, POSIXError(.EINVAL))
            return
        }

        let mode = attributes.isValid(.mode) ? Int(attributes.mode) : 0o644

        enqueueSFTPOperation {
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
                Log.volume.error("createItem failed: \(error)")
                reply(nil, nil, POSIXError(.EIO))
            }
        }
    }

    func removeItem(
        _ item: FSItem,
        named name: FSFileName,
        fromDirectory directory: FSItem,
        replyHandler reply: @escaping (Error?) -> Void
    ) {
        if mountOpts.readOnly { reply(POSIXError(.EROFS)); return }
        guard let childName = name.string,
              let fullPath = childPath(directory: directory, name: childName) else {
            reply(POSIXError(.ENOENT))
            return
        }

        enqueueSFTPOperation {
            do {
                self.releaseHandleAcrossSessions(path: fullPath)
                try self.withReconnect {
                    let attrs = try self.sftp.stat(path: fullPath, followSymlinks: self.mountOpts.followSymlinks)
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
                reply(POSIXError(.EIO))
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
        if mountOpts.readOnly { reply(nil, POSIXError(.EROFS)); return }
        guard let srcName = sourceName.string,
              let dstName = destinationName.string,
              let srcPath = childPath(directory: sourceDirectory, name: srcName),
              let dstPath = childPath(directory: destinationDirectory, name: dstName) else {
            reply(nil, POSIXError(.EINVAL))
            return
        }

        enqueueSFTPOperation {
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
                reply(nil, POSIXError(.EIO))
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

        enqueueSFTPOperation {
            do {
                let target = try self.withReconnect { try self.sftp.readlink(path: itemPath) }
                reply(FSFileName(string: target), nil)
            } catch {
                reply(nil, POSIXError(.EIO))
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
        if mountOpts.readOnly { reply(nil, nil, POSIXError(.EROFS)); return }
        guard let childName = name.string,
              let linkPath = childPath(directory: directory, name: childName),
              let target = contents.string else {
            reply(nil, nil, POSIXError(.EINVAL))
            return
        }

        enqueueSFTPOperation {
            do {
                try self.withReconnect { try self.sftp.symlink(target: target, linkPath: linkPath) }
                self.invalidateCache(linkPath)
                let (newItem, _) = self.item(forPath: linkPath)
                reply(newItem, name, nil)
            } catch {
                Log.volume.error("createSymbolicLink failed: \(error)")
                reply(nil, nil, POSIXError(.EIO))
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
        enqueueSFTPOperation {
            self.releaseHandleAcrossSessions(path: itemPath)
            reply(nil)
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

        enqueueReadOperation { session in
            do {
                if offset < 0 {
                    reply(0, POSIXError(.EINVAL))
                    return
                }
                let bytesRead = try buffer.withUnsafeMutableBytes { dst in
                    let readLength = min(length, dst.count)
                    guard readLength > 0 else { return 0 }
                    let readOffset = UInt64(offset)
                    if session === self.sftp {
                        return try self.withReconnect {
                            try session.readFile(path: itemPath, offset: readOffset, length: readLength, into: dst)
                        }
                    } else {
                        return try self.withIOSessionReconnect(session) {
                            try session.readFile(path: itemPath, offset: readOffset, length: readLength, into: dst)
                        }
                    }
                }
                reply(bytesRead, nil)
            } catch {
                reply(0, POSIXError(.EIO))
            }
        }
    }

    func write(
        contents: Data,
        to item: FSItem,
        at offset: Int64,
        replyHandler reply: @escaping (Int, Error?) -> Void
    ) {
        if mountOpts.readOnly { reply(0, POSIXError(.EROFS)); return }
        guard let itemPath = path(for: item) else {
            reply(0, POSIXError(.ENOENT))
            return
        }
        guard offset >= 0 else {
            reply(0, POSIXError(.EINVAL))
            return
        }

        enqueueWriteOperation(path: itemPath) { session in
            do {
                let writeOffset = UInt64(offset)
                let written: Int
                if session === self.sftp {
                    written = try self.withReconnect {
                        try session.writeFile(path: itemPath, offset: writeOffset, data: contents)
                    }
                } else {
                    written = try self.withIOSessionReconnect(session) {
                        try session.writeFile(path: itemPath, offset: writeOffset, data: contents)
                    }
                }
                self.invalidateCache(itemPath, includeParent: false)
                reply(written, nil)
            } catch {
                Log.volume.error("write failed: \(error)")
                reply(0, POSIXError(.EIO))
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
        stats.blockSize = 4096
        stats.ioSize = 262144
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
