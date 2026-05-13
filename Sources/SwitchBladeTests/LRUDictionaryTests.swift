@testable import SwitchBladeCore

enum LRUDictionaryTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("LRU/inserts_under_capacity_keepAll", insertsUnderCapacity),
        ("LRU/evictsOldestWhenAtCapacity", evictsOldest),
        ("LRU/reinsertingMovesToFront", reinsertMovesToFront),
        ("LRU/nilAssignment_removes", nilRemoves),
        ("LRU/keepOnly_dropsAllOthers", keepOnly),
        ("LRU/keysInOrder_reflectInsertionOrder", insertionOrder)
    ]

    static func insertsUnderCapacity() throws {
        var lru = LRUDictionary<Int, String>(capacity: 3)
        lru[1] = "a"
        lru[2] = "b"
        try expectEqual(lru.count, 2)
        try expectEqual(lru[1], "a")
        try expectEqual(lru[2], "b")
    }

    static func evictsOldest() throws {
        var lru = LRUDictionary<Int, String>(capacity: 2)
        lru[1] = "a"
        lru[2] = "b"
        lru[3] = "c"           // forces eviction of key 1
        try expectEqual(lru.count, 2)
        try expectNil(lru[1])
        try expectEqual(lru[2], "b")
        try expectEqual(lru[3], "c")
    }

    static func reinsertMovesToFront() throws {
        var lru = LRUDictionary<Int, String>(capacity: 2)
        lru[1] = "a"
        lru[2] = "b"
        lru[1] = "a-prime"     // re-inserts key 1 → key 2 is now oldest
        lru[3] = "c"           // evicts key 2, not key 1
        try expectEqual(lru[1], "a-prime")
        try expectNil(lru[2])
        try expectEqual(lru[3], "c")
    }

    static func nilRemoves() throws {
        var lru = LRUDictionary<Int, String>(capacity: 3)
        lru[1] = "a"
        lru[1] = nil
        try expectEqual(lru.count, 0)
        try expect(!lru.keysInOrder.contains(1))
    }

    static func keepOnly() throws {
        var lru = LRUDictionary<Int, String>(capacity: 5)
        lru[1] = "a"; lru[2] = "b"; lru[3] = "c"
        lru.keepOnly(Set([2]))
        try expectEqual(lru.count, 1)
        try expectEqual(lru[2], "b")
        try expectNil(lru[1])
        try expectNil(lru[3])
    }

    static func insertionOrder() throws {
        var lru = LRUDictionary<String, Int>(capacity: 3)
        lru["a"] = 1; lru["b"] = 2; lru["c"] = 3
        try expectEqual(lru.keysInOrder, ["a", "b", "c"])
        lru["a"] = 10           // re-insert → "a" moves to the back
        try expectEqual(lru.keysInOrder, ["b", "c", "a"])
    }
}
