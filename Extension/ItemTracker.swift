@preconcurrency import FSKit

/// Thread-safe bidirectional mapping between FSItems and remote paths.
/// Assigns inode-like IDs to each tracked path.
@available(macOS 26.0, *)
final class ItemTracker: @unchecked Sendable {
    private var itemToPath: [ObjectIdentifier: String] = [:]
    private var pathToItem: [String: FSItem] = [:]
    private var pathToID: [String: UInt64] = [:]
    private var nextItemID: UInt64 = 10
    private let lock = NSLock()

    /// Get or create an FSItem for a remote path.
    func item(forPath path: String) -> (FSItem, UInt64) {
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
    func path(for item: FSItem) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return itemToPath[ObjectIdentifier(item)]
    }

    /// Remove tracking for an item (called on reclaim).
    func untrack(_ item: FSItem) {
        lock.lock()
        defer { lock.unlock() }
        let oid = ObjectIdentifier(item)
        if let path = itemToPath.removeValue(forKey: oid) {
            pathToItem.removeValue(forKey: path)
            pathToID.removeValue(forKey: path)
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
        lock.lock()
        defer { lock.unlock() }
        if let id = pathToID[path] { return id }
        let id = nextItemID
        nextItemID += 1
        pathToID[path] = id
        return id
    }
}
