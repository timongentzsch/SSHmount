import Foundation

/// Thread-safe time-based cache for SFTP attributes and directory listings.
@available(macOS 26.0, *)
final class AttributeCache: @unchecked Sendable {

    private struct CachedAttrs {
        let attrs: SFTPFileAttributes
        let expiry: Date
    }

    private struct CachedDirEntries {
        let entries: [SFTPDirectoryEntry]
        let expiry: Date
    }

    private var attrCache: [String: CachedAttrs] = [:]
    private var dirCache: [String: CachedDirEntries] = [:]
    private let lock = NSLock()

    // MARK: - Attribute Cache

    /// Get cached attributes for a path, or nil if expired/missing.
    func cachedAttrs(forPath path: String) -> SFTPFileAttributes? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = attrCache[path], cached.expiry > Date() else { return nil }
        return cached.attrs
    }

    /// Store attributes for a path with a TTL.
    func setAttrs(_ attrs: SFTPFileAttributes, forPath path: String, timeout: TimeInterval) {
        lock.lock()
        attrCache[path] = CachedAttrs(attrs: attrs, expiry: Date().addingTimeInterval(timeout))
        lock.unlock()
    }

    // MARK: - Directory Cache

    /// Get cached directory entries for a path, or nil if expired/missing.
    func cachedDirEntries(forPath path: String) -> [SFTPDirectoryEntry]? {
        lock.lock()
        defer { lock.unlock() }
        guard let cached = dirCache[path], cached.expiry > Date() else { return nil }
        return cached.entries
    }

    /// Store directory entries for a path with a TTL.
    func setDirEntries(_ entries: [SFTPDirectoryEntry], forPath path: String, timeout: TimeInterval) {
        lock.lock()
        dirCache[path] = CachedDirEntries(entries: entries, expiry: Date().addingTimeInterval(timeout))
        lock.unlock()
    }

    // MARK: - Invalidation

    /// Invalidate cache entry for a path, optionally including its parent directory.
    func invalidate(_ path: String, includeParent: Bool = true) {
        lock.lock()
        attrCache.removeValue(forKey: path)
        dirCache.removeValue(forKey: path)
        if includeParent {
            let parent = (path as NSString).deletingLastPathComponent
            attrCache.removeValue(forKey: parent)
            dirCache.removeValue(forKey: parent)
        }
        lock.unlock()
    }

    /// Flush all caches (called after reconnection).
    func invalidateAll() {
        lock.lock()
        attrCache.removeAll()
        dirCache.removeAll()
        lock.unlock()
    }
}
