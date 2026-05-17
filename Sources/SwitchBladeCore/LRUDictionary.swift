import Foundation

/// Capacity-bounded dictionary that evicts the least-recently-inserted /
/// least-recently-updated key when full. Read is O(1); insert/update/remove
/// is O(n) because `keysInOrder` is a plain array scanned linearly to keep
/// recency order. Acceptable while capacity stays small (currently 40) —
/// rewrite as a doubly-linked-list + dict if capacity grows materially.
///
/// Not thread-safe. Callers are expected to provide isolation themselves —
/// the only consumer right now is `PreviewCacheStore` on @MainActor.
struct LRUDictionary<Key: Hashable, Value> {
    private(set) var storage: [Key: Value] = [:]
    private(set) var keysInOrder: [Key] = []
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "LRUDictionary capacity must be positive")
        self.capacity = capacity
    }

    var count: Int { storage.count }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            if let newValue {
                touch(key)
                storage[key] = newValue
                evictIfNeeded()
            } else {
                storage.removeValue(forKey: key)
                keysInOrder.removeAll { $0 == key }
            }
        }
    }

    /// Drops every key not in `liveKeys`. O(n).
    mutating func keepOnly(_ liveKeys: Set<Key>) {
        storage = storage.filter { liveKeys.contains($0.key) }
        keysInOrder.removeAll { !liveKeys.contains($0) }
    }

    private mutating func touch(_ key: Key) {
        if storage[key] != nil {
            keysInOrder.removeAll { $0 == key }
        }
        keysInOrder.append(key)
    }

    private mutating func evictIfNeeded() {
        while storage.count > capacity, let oldest = keysInOrder.first {
            keysInOrder.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }
}
