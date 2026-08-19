import AppKit
@testable import SwitchBladeCore

enum WindowItemTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowItem/displayTitle_usesTitleWhenAvailable", displayTitle_usesTitle),
        ("WindowItem/displayTitle_fallsBackToAppName_whenEmpty", displayTitle_fallsBack),
        ("WindowItem/displayTitle_redactsTitleWhenMarkedPrivate", displayTitle_redactsTitle),
        ("WindowItem/subtitle_isAppName_whenTitlePresent", subtitle_appName),
        ("WindowItem/subtitle_isFallback_whenTitleEmpty", subtitle_fallback),
        ("WindowItem/subtitle_isFallback_whenTitleRedacted", subtitle_redactedTitle),
        ("WindowItem/appFallback_hasApplicationSemantics", appFallbackHasApplicationSemantics),
        ("WindowItem/id_isWindowID", id_isWindowID),
        ("WindowItem/withPreview_setsPreview_keepsOtherFields", withPreview_setsPreview),
        ("WindowItem/withPreview_canClearPreview", withPreview_canClear),
        ("WindowItem/withFrontmostState_updatesOnlyFrontmostFlag", withFrontmostState_updatesOnlyFlag),
        ("WindowItem/hostedWindow_preservesWindowOwnerPID", hostedWindowPreservesWindowOwnerPID),
        ("WindowItem/equatable_sameContents_areEqual", equatable_sameContents)
    ]

    @MainActor static func displayTitle_usesTitle() throws {
        let item = makeItem(id: 1, appName: "Safari", title: "Apple News")
        try expectEqual(item.displayTitle, "Apple News")
    }

    @MainActor static func displayTitle_fallsBack() throws {
        let item = makeItem(id: 1, appName: "Calculator", title: "")
        try expectEqual(item.displayTitle, "Calculator")
    }

    @MainActor static func displayTitle_redactsTitle() throws {
        let item = makeItem(id: 1, appName: "Mail", title: "Private Subject", isTitleRedacted: true)
        try expectEqual(item.displayTitle, "Mail")
        try expectEqual(item.title, "Private Subject")
    }

    @MainActor static func subtitle_appName() throws {
        let item = makeItem(id: 1, appName: "Safari", title: "Apple News")
        try expectEqual(item.subtitle, "Safari")
    }

    @MainActor static func subtitle_fallback() throws {
        let item = makeItem(id: 1, appName: "Calculator", title: "")
        try expectEqual(item.subtitle, "App")
    }

    @MainActor static func subtitle_redactedTitle() throws {
        let item = makeItem(id: 1, appName: "Mail", title: "Private Subject", isTitleRedacted: true)
        try expectEqual(item.subtitle, "App")
    }

    @MainActor static func appFallbackHasApplicationSemantics() throws {
        LocalizationState.selection = .english
        let id = SyntheticApplicationID.make(
            pid: 42,
            bundleIdentifier: "com.example.app",
            appName: "Example"
        )
        let item = makeItem(id: id, pid: 42, appName: "Example", title: "")

        try expect(item.isApplicationFallback)
        try expect(item.actionTarget.isApplicationFallback)
        try expectEqual(item.displayTitle, "Example")
        try expectEqual(item.subtitle, "Application")
    }

    @MainActor static func id_isWindowID() throws {
        let item = makeItem(id: 42)
        try expectEqual(item.id, 42)
    }

    @MainActor static func withPreview_setsPreview() throws {
        let item = makeItem(id: 1)
        try expectNil(item.preview)

        let img = NSImage(size: CGSize(width: 10, height: 10))
        let updated = item.withPreview(img)

        try expect(updated.preview === img)
        try expectEqual(updated.id, item.id)
        try expectEqual(updated.appName, item.appName)
        try expectEqual(updated.title, item.title)
    }

    @MainActor static func withPreview_canClear() throws {
        let img = NSImage(size: CGSize(width: 10, height: 10))
        let cleared = makeItem(id: 1).withPreview(img).withPreview(nil)
        try expectNil(cleared.preview)
    }

    @MainActor static func withFrontmostState_updatesOnlyFlag() throws {
        let item = makeItem(id: 1, pid: 200, appName: "ChatGPT", title: "Window", isFrontmostApp: false)
        let updated = item.withFrontmostState(true)

        try expect(updated.isFrontmostApp)
        try expectEqual(updated.id, item.id)
        try expectEqual(updated.pid, item.pid)
        try expectEqual(updated.appName, item.appName)
        try expectEqual(updated.title, item.title)
        try expectEqual(updated.bounds, item.bounds)
        try expectEqual(updated.isMinimized, item.isMinimized)
        try expectEqual(updated.canCapturePreview, item.canCapturePreview)
        try expectEqual(updated.isTitleRedacted, item.isTitleRedacted)
        try expectEqual(updated.bundleIdentifier, item.bundleIdentifier)
    }

    @MainActor static func hostedWindowPreservesWindowOwnerPID() throws {
        let item = makeItem(id: 1, pid: 100, windowOwnerPID: 200)
        let preview = NSImage(size: CGSize(width: 10, height: 10))

        try expectEqual(item.windowProcessIdentifier, 200)
        try expectEqual(item.actionTarget.pid, 100)
        try expectEqual(item.actionTarget.windowProcessIdentifier, 200)
        try expectEqual(item.withPreview(preview).windowOwnerPID, 200)
        try expectEqual(item.withFrontmostState(true).windowOwnerPID, 200)
    }

    @MainActor static func equatable_sameContents() throws {
        let a = makeItem(id: 1, appName: "X", title: "Y")
        let b = makeItem(id: 1, appName: "X", title: "Y")
        try expectEqual(a, b)
    }
}
