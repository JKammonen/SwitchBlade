import AppKit
@testable import SwitchBladeCore

enum IconNamingTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("IconNaming/repeatedBundleNameGetsUniqueNames", repeatedBundleNameGetsUniqueNames)
    ]

    @MainActor static func repeatedBundleNameGetsUniqueNames() throws {
        let bundleID = "com.switchblade.test.\(UUID().uuidString)"
        let first = IconNaming.named(NSImage(size: NSSize(width: 1, height: 1)), bundleIdentifier: bundleID, appName: "Test")!
        let second = IconNaming.named(NSImage(size: NSSize(width: 1, height: 1)), bundleIdentifier: bundleID, appName: "Test")!

        try expectNotNil(first.name())
        try expectNotNil(second.name())
        try expect(first.name() != second.name())
    }
}
