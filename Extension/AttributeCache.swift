import Foundation
import Synchronization

/// Thread-safe time-based cache for SFTP attributes and directory listings.
@available(macOS 26.0, *)
final class AttributeCache: Sendable {

    private struct CachedAttrs: Sendable {
        let attrs: SFTPFileAttributes
        let expiry: Date
    }

    private struct CachedDirEntries: Sendable {
        let entries: [SFTPDirectoryEntry]
        let expiry: Date
    }

    private struct State: ~Copyable {
        var attrCache: [String: CachedAttrs] = [:]
        var dirCache: [String: CachedDirEntries] = [:]
    }

    private let state = Mutex(State())

    // MARK: - Attribute Cache

    /// Get cached attributes for a path, or nil if expired/missing.
    func cachedAttrs(forPath path: String) -> SFTPFileAttributes? {
        state.withLock { state in
            guard let cached = state.attrCache[path], cached.expiry > Date() else { return nil }
            return cached.attrs
        }
    }

    /// Store attributes for a path with a TTL.
    func setAttrs(_ attrs: SFTPFileAttributes, forPath path: String, timeout: TimeInterval) {
        state.withLock { state in
            state.attrCache[path] = CachedAttrs(attrs: attrs, expiry: Date().addingTimeInterval(timeout))
        }
    }

    // MARK: - Directory Cache

    /// Get cached directory entries for a path, or nil if expired/missing.
    func cachedDirEntries(forPath path: String) -> [SFTPDirectoryEntry]? {
        state.withLock { state in
            guard let cached = state.dirCache[path], cached.expiry > Date() else { return nil }
            return cached.entries
        }
    }

    /// Store directory entries for a path with a TTL.
    func setDirEntries(_ entries: [SFTPDirectoryEntry], forPath path: String, timeout: TimeInterval) {
        state.withLock { state in
            state.dirCache[path] = CachedDirEntries(entries: entries, expiry: Date().addingTimeInterval(timeout))
        }
    }

    // MARK: - Invalidation

    /// Invalidate cache entry for a path, optionally including its parent directory.
    func invalidate(_ path: String, includeParent: Bool = true) {
        state.withLock { state in
            state.attrCache.removeValue(forKey: path)
            state.dirCache.removeValue(forKey: path)
            if includeParent {
                let parent = (path as NSString).deletingLastPathComponent
                state.attrCache.removeValue(forKey: parent)
                state.dirCache.removeValue(forKey: parent)
            }
        }
    }

    /// Flush all caches (called after reconnection).
    func invalidateAll() {
        state.withLock { state in
            state.attrCache.removeAll()
            state.dirCache.removeAll()
        }
    }
}
