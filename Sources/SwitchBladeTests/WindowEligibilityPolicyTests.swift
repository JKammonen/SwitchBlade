import AppKit
@testable import SwitchBladeCore

enum WindowEligibilityPolicyTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowEligibilityPolicy/rejectsOwnProcessUnconditionally", rejectsOwnProcess),
        ("WindowEligibilityPolicy/rejectsAccessoryAndUnfinishedApps", rejectsAccessoryAndUnfinishedApps),
        ("WindowEligibilityPolicy/allowsFinishedRegularExternalApp", allowsFinishedRegularExternalApp)
    ]

    @MainActor static func rejectsOwnProcess() throws {
        for policy in [NSApplication.ActivationPolicy.regular, .accessory, .prohibited] {
            try expect(!WindowEligibilityPolicy.canIncludeApplication(
                processIdentifier: 42,
                currentProcessIdentifier: 42,
                activationPolicy: policy,
                isFinishedLaunching: true
            ))
        }
    }

    @MainActor static func rejectsAccessoryAndUnfinishedApps() throws {
        try expect(!WindowEligibilityPolicy.canIncludeApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .accessory,
            isFinishedLaunching: true
        ))
        try expect(!WindowEligibilityPolicy.canIncludeApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .regular,
            isFinishedLaunching: false
        ))
    }

    @MainActor static func allowsFinishedRegularExternalApp() throws {
        try expect(WindowEligibilityPolicy.canIncludeApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .regular,
            isFinishedLaunching: true
        ))
    }
}
