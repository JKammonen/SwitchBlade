@testable import SwitchBladeCore

enum WindowSharingPolicyTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowSharingPolicy/listsShareableWindows", listsShareableWindows),
        ("WindowSharingPolicy/rejectsPrivateNonTeamsWindows", rejectsPrivateNonTeamsWindows),
        ("WindowSharingPolicy/rejectsTeamsSharingIndicator", rejectsTeamsSharingIndicator),
        ("WindowSharingPolicy/allowsPrivateMicrosoftTeamsWindows", allowsPrivateMicrosoftTeamsWindows)
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
}
