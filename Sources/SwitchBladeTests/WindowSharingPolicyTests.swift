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
        ("WindowSharingStateIndex/uniqueExactTitleReturnsWindowServerID", uniqueExactTitleReturnsWindowServerID),
        ("WindowSharingStateIndex/duplicateExactTitleDoesNotGuessID", duplicateExactTitleDoesNotGuessID)
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

    private static func sharingRow(
        windowID: CGWindowID,
        pid: pid_t,
        title: String,
        sharingState: Int
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: windowID,
            kCGWindowOwnerPID as String: pid,
            kCGWindowLayer as String: 0,
            kCGWindowName as String: title,
            kCGWindowSharingState as String: sharingState
        ]
    }
}
