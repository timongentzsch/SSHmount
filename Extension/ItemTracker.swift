import Synchronization
@preconcurrency import FSKit

/// Thread-safe bidirectional mapping between FSItems and remote paths.
/// Assigns inode-like IDs to each tracked path.
@available(macOS 26.0, *)
final class ItemTracker: Sendable {
    private struct State: ~Copyable {
        var itemToPath: [ObjectIdentifier: String] = [:]
        var pathToItem: [String: FSItem] = [:]
        var pathToID: [String: UInt64] = [:]
        var nextItemID: UInt64 = 10
    }

    private let state = Mutex(State())

    /// Get or create an FSItem for a remote path.
    func item(forPath path: String) -> (FSItem, UInt64) {
        state.withLock { state in
            if let existing = state.pathToItem[path], let id = state.pathToID[path] {
                return (existing, id)
            }

            let fsItem = FSItem()
            let id = state.nextItemID
            state.nextItemID += 1

            state.itemToPath[ObjectIdentifier(fsItem)] = path
            state.pathToItem[path] = fsItem
            state.pathToID[path] = id
            return (fsItem, id)
        }
    }

    /// Resolve an FSItem back to its remote path.
    func path(for item: FSItem) -> String? {
        state.withLock { state in
            state.itemToPath[ObjectIdentifier(item)]
        }
    }

    /// Remove tracking for an item (called on reclaim).
    func untrack(_ item: FSItem) {
        state.withLock { state in
            let oid = ObjectIdentifier(item)
            if let path = state.itemToPath.removeValue(forKey: oid) {
                state.pathToItem.removeValue(forKey: path)
                state.pathToID.removeValue(forKey: path)
            }
        }
    }

    /// Build the full child path from a directory item + child name.
    func childPath(directory: FSItem, name: String) -> String? {
        guard let dirPath = path(for: directory) else { return nil }
        if dirPath.hasSuffix("/") {
            return dirPath + name
        }
        return dirPath + "/" + name
    }

    /// Get item ID for a path (creates one if needed).
    func itemID(forPath path: String) -> UInt64 {
        state.withLock { state in
            if let id = state.pathToID[path] { return id }
            let id = state.nextItemID
            state.nextItemID += 1
            state.pathToID[path] = id
            return id
        }
    }
}
