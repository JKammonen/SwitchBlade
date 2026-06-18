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
        ("WindowSharingPolicy/minimizedTeamsSharingIndicatorIsExcluded", minimizedTeamsSharingIndicatorIsExcluded)
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
}
