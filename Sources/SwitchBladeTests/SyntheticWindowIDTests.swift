import CoreGraphics
@testable import SwitchBladeCore

enum SyntheticWindowIDTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("SyntheticWindowID/topBitIsReserved", topBitIsReserved),
        ("SyntheticWindowID/stableWithinLaunch", stableWithinLaunch),
        ("SyntheticWindowID/differsByPidIndexAndTitle", differsByPidIndexAndTitle),
        ("SyntheticWindowID/noCollisionsOverManyDistinctInputs", noCollisionsOverManyDistinctInputs),
        ("SyntheticWindowID/isSyntheticDetectsRealAndSynthetic", isSyntheticDetectsRealAndSynthetic),
        ("SyntheticApplicationID/usesDistinctNamespace", applicationFallbackUsesDistinctNamespace)
    ]

    @MainActor static func topBitIsReserved() async throws {
        let id = SyntheticWindowID.make(pid: 1234, index: 0, title: "Untitled")
        try expect(id & SyntheticWindowID.markerBit != 0)
    }

    @MainActor static func stableWithinLaunch() async throws {
        let a = SyntheticWindowID.make(pid: 42, index: 3, title: "Window")
        let b = SyntheticWindowID.make(pid: 42, index: 3, title: "Window")
        try expectEqual(a, b)
    }

    @MainActor static func differsByPidIndexAndTitle() async throws {
        let base = SyntheticWindowID.make(pid: 42, index: 0, title: "Untitled")
        try expect(base != SyntheticWindowID.make(pid: 43, index: 0, title: "Untitled"))
        try expect(base != SyntheticWindowID.make(pid: 42, index: 1, title: "Untitled"))
        try expect(base != SyntheticWindowID.make(pid: 42, index: 0, title: "Untitled 2"))
    }

    /// Smoke check on 2000 distinct tuples spanning realistic minimized-window
    /// shapes. The old 16-bit-title-hash implementation collided within a
    /// single app at ~0.7% by 30 windows; the new 31-bit hash drops per-launch
    /// birthday collision probability for this fixture to ~0.09%. CI also sets
    /// `SWIFT_DETERMINISTIC_HASHING=1` so the test is fully deterministic in
    /// the gate. Local runs without that env var are flaky < 1 in 1000.
    @MainActor static func noCollisionsOverManyDistinctInputs() async throws {
        let titles = ["Untitled", "Untitled 2", "Document", "Project", "Notes"]
        var ids: Set<CGWindowID> = []
        var expected = 0
        for pidOffset in 0..<20 {
            for index in 0..<20 {
                for title in titles {
                    let id = SyntheticWindowID.make(
                        pid: pid_t(1000 + pidOffset),
                        index: index,
                        title: title
                    )
                    ids.insert(id)
                    expected += 1
                }
            }
        }
        try expectEqual(ids.count, expected)
    }

    @MainActor static func isSyntheticDetectsRealAndSynthetic() async throws {
        // Real CGWindowIDs are small uints assigned by macOS; the top bit is
        // never set in practice.
        try expect(!SyntheticWindowID.isSynthetic(0))
        try expect(!SyntheticWindowID.isSynthetic(12345))
        try expect(!SyntheticWindowID.isSynthetic(0x7FFF_FFFF))

        let synthetic = SyntheticWindowID.make(pid: 99, index: 7, title: "Title")
        try expect(SyntheticWindowID.isSynthetic(synthetic))
    }

    @MainActor static func applicationFallbackUsesDistinctNamespace() async throws {
        let appID = SyntheticApplicationID.make(
            pid: 99,
            bundleIdentifier: "com.example.app",
            appName: "Example"
        )
        let minimizedID = SyntheticWindowID.make(pid: 99, index: 0, title: "Example")

        try expect(SyntheticApplicationID.isSynthetic(appID))
        try expect(!SyntheticWindowID.isSynthetic(appID))
        try expect(!SyntheticApplicationID.isSynthetic(minimizedID))
        try expectNotEqual(appID, minimizedID)
    }
}
