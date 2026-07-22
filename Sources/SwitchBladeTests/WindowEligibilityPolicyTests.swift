import AppKit
@testable import SwitchBladeCore

enum WindowEligibilityPolicyTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowEligibilityPolicy/rejectsOwnProcessUnconditionally", rejectsOwnProcess),
        ("WindowEligibilityPolicy/rejectsAccessoryAndUnfinishedApps", rejectsAccessoryAndUnfinishedApps),
        ("WindowEligibilityPolicy/allowsFinishedRegularExternalApp", allowsFinishedRegularExternalApp),
        ("AXWindowEligibility/filtersUnmatchedAuxiliarySurface", filtersUnmatchedAuxiliarySurface),
        ("AXWindowEligibility/filtersDuplicateSystemDialogSurfaces", filtersDuplicateSystemDialogSurfaces),
        ("AXWindowEligibility/keepsMatchedUntitledWindow", keepsMatchedUntitledWindow),
        ("AXWindowEligibility/titledSurfaceWithoutAXFrameIsFiltered", titledSurfaceWithoutAXFrameIsFiltered),
        ("AXWindowEligibility/unavailableAXFailsOpen", unavailableAXFailsOpen),
        ("AXWindowEligibility/ambiguousCandidateReuseFailsOpen", ambiguousCandidateReuseFailsOpen)
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

    @MainActor static func filtersUnmatchedAuxiliarySurface() throws {
        let main = makeItem(
            id: 1,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 800)
        )
        let auxiliary = makeItem(
            id: 2,
            pid: 100,
            title: "",
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: "Document", frame: main.bounds)
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, auxiliary],
            candidates: candidates
        )

        try expectEqual(filtered.map(\.id), [1])
    }

    @MainActor static func keepsMatchedUntitledWindow() throws {
        let main = makeItem(
            id: 1,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 800)
        )
        let untitled = makeItem(
            id: 2,
            pid: 100,
            title: "",
            bounds: CGRect(x: 150, y: 120, width: 900, height: 650)
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: "Document", frame: main.bounds),
            AXTopLevelWindowCandidate(title: nil, frame: untitled.bounds)
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, untitled],
            candidates: candidates
        )

        try expectEqual(filtered.map(\.id), [1, 2])
    }

    @MainActor static func filtersDuplicateSystemDialogSurfaces() throws {
        let main = makeItem(
            id: 1,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 800)
        )
        let dialogFrame = CGRect(x: 700, y: 300, width: 532, height: 357)
        let firstDialog = makeItem(
            id: 2,
            pid: 100,
            title: "Preview 1",
            bounds: dialogFrame
        )
        let secondDialog = makeItem(
            id: 3,
            pid: 100,
            title: "Preview 2",
            bounds: dialogFrame
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: "Document", frame: main.bounds),
            AXTopLevelWindowCandidate(
                title: "Preview 1",
                frame: firstDialog.bounds,
                isSwitcherWindow: false
            ),
            AXTopLevelWindowCandidate(
                title: "Preview 2",
                frame: secondDialog.bounds,
                isSwitcherWindow: false
            )
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, firstDialog, secondDialog],
            candidates: candidates
        )

        try expectEqual(filtered.map(\.id), [1])
    }

    @MainActor static func titledSurfaceWithoutAXFrameIsFiltered() throws {
        let main = makeItem(
            id: 1,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 800)
        )
        let auxiliary = makeItem(
            id: 2,
            pid: 100,
            title: "Document",
            bounds: CGRect(x: 0, y: 0, width: 500, height: 500)
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: "Document", frame: main.bounds)
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, auxiliary],
            candidates: candidates
        )

        try expectEqual(filtered.map(\.id), [1])
    }

    @MainActor static func unavailableAXFailsOpen() throws {
        let items = [
            makeItem(id: 1, pid: 100, title: "Document"),
            makeItem(id: 2, pid: 100, title: "")
        ]

        try expectEqual(
            AXWindowEligibilityPolicy.filteredItems(items, candidates: nil).map(\.id),
            [1, 2]
        )
        try expectEqual(
            AXWindowEligibilityPolicy.filteredItems(items, candidates: []).map(\.id),
            [1, 2]
        )
    }

    @MainActor static func ambiguousCandidateReuseFailsOpen() throws {
        let sharedFrame = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let items = [
            makeItem(id: 1, pid: 100, title: "Document", bounds: sharedFrame),
            makeItem(id: 2, pid: 100, title: "", bounds: sharedFrame)
        ]
        let candidates = [
            AXTopLevelWindowCandidate(title: "Document", frame: sharedFrame)
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            items,
            candidates: candidates
        )

        try expectEqual(filtered.map(\.id), [1, 2])
    }
}
