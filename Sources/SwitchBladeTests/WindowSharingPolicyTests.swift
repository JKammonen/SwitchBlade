import CoreGraphics
@testable import SwitchBladeCore

enum WindowSharingPolicyTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowSharingPolicy/listsShareableWindows", listsShareableWindows),
        ("WindowSharingPolicy/rejectsPrivateNonTeamsWindows", rejectsPrivateNonTeamsWindows),
        ("WindowSharingPolicy/rejectsTeamsSharingIndicator", rejectsTeamsSharingIndicator),
        ("WindowSharingPolicy/allowsPrivateMicrosoftTeamsWindows", allowsPrivateMicrosoftTeamsWindows),
        ("WindowSharingPolicy/minimizedWithoutSharingMatchRedactsTitle", minimizedWithoutSharingMatchRedactsTitle),
        ("WindowSharingPolicy/minimizedShareableMatchShowsTitle", minimizedShareableMatchShowsTitle),
        ("WindowSharingPolicy/minimizedPrivateNonTeamsMatchIsExcluded", minimizedPrivateNonTeamsMatchIsExcluded),
        ("WindowSharingPolicy/minimizedPrivateTeamsMatchShowsTitle", minimizedPrivateTeamsMatchShowsTitle),
        ("WindowSharingPolicy/minimizedTeamsSharingIndicatorIsExcluded", minimizedTeamsSharingIndicatorIsExcluded),
        ("WindowSharingPolicy/minimizedPreviewRequiresShareableExactMatch", minimizedPreviewRequiresShareableExactMatch),
        ("WindowSharingStateIndex/uniqueExactTitleReturnsWindowServerID", uniqueExactTitleReturnsWindowServerID),
        ("WindowSharingStateIndex/duplicateExactTitleDoesNotGuessID", duplicateExactTitleDoesNotGuessID),
        ("WindowSharingStateIndex/uniqueFrameReturnsWindowServerIDWhenTitlesDiffer", uniqueFrameReturnsWindowServerIDWhenTitlesDiffer),
        ("WindowSharingStateIndex/duplicateFrameDoesNotGuessID", duplicateFrameDoesNotGuessID)
    ]

    @MainActor static func listsShareableWindows() async throws {
        try expect(WindowSharingPolicy.canListWindow(
            appName: "Any App",
            bundleIdentifier: "com.example.app",
            title: "Window",
            sharingState: 1
        ))
    }

    @MainActor static func rejectsPrivateNonTeamsWindows() async throws {
        try expect(!WindowSharingPolicy.canListWindow(
            appName: "Passwords",
            bundleIdentifier: "com.apple.PasswordsUIAgent",
            title: "",
            sharingState: 0
        ))
        try expect(!WindowSharingPolicy.canListWindow(
            appName: "ChatGPT",
            bundleIdentifier: "com.openai.chat",
            title: "",
            sharingState: 0
        ))
    }

    @MainActor static func rejectsTeamsSharingIndicator() async throws {
        try expect(!WindowSharingPolicy.canListWindow(
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            title: "Sharing Indicator",
            sharingState: 0
        ))
        try expect(!WindowSharingPolicy.canListWindow(
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            title: "Sharing Indicator",
            sharingState: 1
        ))
    }

    @MainActor static func allowsPrivateMicrosoftTeamsWindows() async throws {
        try expect(WindowSharingPolicy.canListWindow(
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams2",
            title: "",
            sharingState: 0
        ))
        try expect(WindowSharingPolicy.canListWindow(
            appName: "Microsoft Teams",
            bundleIdentifier: "com.microsoft.teams",
            title: "",
            sharingState: 0
        ))
    }

    @MainActor static func minimizedWithoutSharingMatchRedactsTitle() async throws {
        try expectEqual(
            WindowSharingPolicy.minimizedTitleDecision(
                appName: "Mail",
                bundleIdentifier: "com.apple.mail",
                title: "Private Subject",
                matchingSharingStates: nil
            ),
            .redactTitle
        )
    }

    @MainActor static func minimizedShareableMatchShowsTitle() async throws {
        try expectEqual(
            WindowSharingPolicy.minimizedTitleDecision(
                appName: "Mail",
                bundleIdentifier: "com.apple.mail",
                title: "Inbox",
                matchingSharingStates: [1]
            ),
            .showTitle
        )
    }

    @MainActor static func minimizedPrivateNonTeamsMatchIsExcluded() async throws {
        try expectEqual(
            WindowSharingPolicy.minimizedTitleDecision(
                appName: "ChatGPT",
                bundleIdentifier: "com.openai.chat",
                title: "Sensitive",
                matchingSharingStates: [0]
            ),
            .exclude
        )
    }

    @MainActor static func minimizedPrivateTeamsMatchShowsTitle() async throws {
        try expectEqual(
            WindowSharingPolicy.minimizedTitleDecision(
                appName: "Microsoft Teams",
                bundleIdentifier: "com.microsoft.teams2",
                title: "Daily",
                matchingSharingStates: [0]
            ),
            .showTitle
        )
    }

    @MainActor static func minimizedTeamsSharingIndicatorIsExcluded() async throws {
        try expectEqual(
            WindowSharingPolicy.minimizedTitleDecision(
                appName: "Microsoft Teams",
                bundleIdentifier: "com.microsoft.teams2",
                title: "Sharing Indicator",
                matchingSharingStates: [0]
            ),
            .exclude
        )
    }

    @MainActor static func minimizedPreviewRequiresShareableExactMatch() async throws {
        try expect(WindowSharingPolicy.canCaptureMinimizedPreview(
            matchedSharingState: 1,
            titleDecision: .showTitle
        ))
        try expect(!WindowSharingPolicy.canCaptureMinimizedPreview(
            matchedSharingState: nil,
            titleDecision: .showTitle
        ))
        try expect(!WindowSharingPolicy.canCaptureMinimizedPreview(
            matchedSharingState: 0,
            titleDecision: .showTitle
        ))
        try expect(!WindowSharingPolicy.canCaptureMinimizedPreview(
            matchedSharingState: 1,
            titleDecision: .redactTitle
        ))
    }

    @MainActor static func uniqueExactTitleReturnsWindowServerID() async throws {
        let index = WindowSharingStateIndex(rawList: [
            sharingRow(windowID: 4561, pid: 67035, title: "Book", sharingState: 1),
            sharingRow(windowID: 99, pid: 100, title: "Other", sharingState: 1)
        ])

        try expectEqual(index.sharingStates(pid: 67035, title: "Book"), [1])
        try expectEqual(
            index.uniqueWindow(pid: 67035, title: "Book"),
            WindowSharingStateIndex.Match(windowID: 4561, sharingState: 1)
        )
    }

    @MainActor static func duplicateExactTitleDoesNotGuessID() async throws {
        let index = WindowSharingStateIndex(rawList: [
            sharingRow(windowID: 1, pid: 100, title: "Document", sharingState: 1),
            sharingRow(windowID: 2, pid: 100, title: "Document", sharingState: 1)
        ])

        try expectNil(index.uniqueWindow(pid: 100, title: "Document"))
    }

    @MainActor static func uniqueFrameReturnsWindowServerIDWhenTitlesDiffer() async throws {
        let documentFrame = CGRect(x: 289, y: 44, width: 923, height: 1366)
        let index = WindowSharingStateIndex(rawList: [
            sharingRow(
                windowID: 4561,
                pid: 67035,
                title: "WindowServer document title",
                sharingState: 1,
                bounds: documentFrame
            ),
            sharingRow(
                windowID: 99,
                pid: 67035,
                title: "Other",
                sharingState: 1,
                bounds: CGRect(x: 33, y: 63, width: 923, height: 1366)
            )
        ])

        try expectNil(index.uniqueWindow(pid: 67035, title: "AX document title"))
        try expectEqual(
            index.uniqueWindow(pid: 67035, bounds: documentFrame),
            WindowSharingStateIndex.Match(windowID: 4561, sharingState: 1)
        )
    }

    @MainActor static func duplicateFrameDoesNotGuessID() async throws {
        let duplicateFrame = CGRect(x: 289, y: 44, width: 923, height: 1366)
        let index = WindowSharingStateIndex(rawList: [
            sharingRow(
                windowID: 1,
                pid: 100,
                title: "Document A",
                sharingState: 1,
                bounds: duplicateFrame
            ),
            sharingRow(
                windowID: 2,
                pid: 100,
                title: "Document B",
                sharingState: 1,
                bounds: duplicateFrame
            )
        ])

        try expectNil(index.uniqueWindow(pid: 100, bounds: duplicateFrame))
    }

    private static func sharingRow(
        windowID: CGWindowID,
        pid: pid_t,
        title: String,
        sharingState: Int,
        bounds: CGRect? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 0,
            kCGWindowName as String: title,
            kCGWindowSharingState as String: sharingState
        ]
        if let bounds {
            row[kCGWindowBounds as String] = bounds.dictionaryRepresentation
        }
        return row
    }
}
