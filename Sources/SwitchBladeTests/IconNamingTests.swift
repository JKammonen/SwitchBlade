import AppKit
@testable import SwitchBladeCore

enum IconNamingTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("IconNaming/repeatedIdentityReusesOneNamedCopy", repeatedIdentityReusesOneNamedCopy),
        ("IconNaming/distinctIdentitiesGetDistinctNames", distinctIdentitiesGetDistinctNames),
    ]

    /// Every named NSImage is retained by AppKit's name registry, so repeated
    /// snapshots of the same app must not register a new copy each time.
    @MainActor static func repeatedIdentityReusesOneNamedCopy() throws {
        let bundleID = "com.switchblade.test.\(UUID().uuidString)"
        let first = IconNaming.named(NSImage(size: NSSize(width: 1, height: 1)), bundleIdentifier: bundleID, appName: "Test")!
        let second = IconNaming.named(NSImage(size: NSSize(width: 1, height: 1)), bundleIdentifier: bundleID, appName: "Test")!

        try expect(first === second)
        try expectEqual(first.name(), bundleID)
        try expect(NSImage(named: bundleID) === first)
    }

    @MainActor static func distinctIdentitiesGetDistinctNames() throws {
        let source = NSImage(size: NSSize(width: 1, height: 1))
        let first = IconNaming.named(source, bundleIdentifier: "com.switchblade.test.\(UUID().uuidString)", appName: "A")!
        let second = IconNaming.named(source, bundleIdentifier: "com.switchblade.test.\(UUID().uuidString)", appName: "B")!

        try expect(first !== second)
        try expectNotNil(first.name())
        try expect(first.name() != second.name())
        try expect(source.name() == nil)
    }
}
