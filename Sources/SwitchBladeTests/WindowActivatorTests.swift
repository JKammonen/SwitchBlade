import CoreGraphics
import Foundation
@testable import SwitchBladeCore

enum WindowActivatorTests {

    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowActivator/framesAreClose_exactMatch", framesExact),
        ("WindowActivator/framesAreClose_withinTolerance", framesWithinTolerance),
        ("WindowActivator/framesAreClose_outsideTolerance", framesOutsideTolerance),
        ("WindowActivator/framesAreClose_customTolerance", framesCustomTolerance),
        ("WindowActivator/bestMatchIndex_prefersClosestFrameAmongTitleMatches", bestMatchPrefersClosestFrameAmongTitleMatches),
        ("WindowActivator/bestMatchIndex_defaultTieKeepsFirstCandidate", bestMatchDefaultTieKeepsFirstCandidate),
        ("WindowActivator/bestMatchIndex_sameAppTiePrefersNonMainWindow", bestMatchSameAppTiePrefersNonMainWindow),
        ("WindowActivator/bestMatchIndex_fallsBackToClosestFrameWhenTitleDrifts", bestMatchFallsBackToClosestFrameWhenTitleDrifts),
        ("WindowActivator/bestMatchIndex_emptyCandidates_returnsNil", bestMatchEmptyCandidatesReturnsNil),
        ("WindowActivator/bestMatchIndex_emptyItemTitle_matchesByFrameOnly", bestMatchEmptyItemTitleMatchesByFrameOnly),
        ("WindowActivator/bestMatchIndex_nilFrameCandidates_fallBackToTitleMatch", bestMatchNilFrameCandidatesFallBackToTitleMatch),
        ("WindowActivator/bestMatchIndex_strictAmbiguousEvidence_returnsNil", bestMatchStrictAmbiguousEvidenceReturnsNil),
        ("WindowActivator/bestMatchIndex_strictDuplicateTitle_usesUniqueFrame", bestMatchStrictDuplicateTitleUsesUniqueFrame),
        ("WindowActivator/bestScreen_emptyCandidates_returnsNil", bestScreenEmptyCandidatesReturnsNil),
        ("WindowActivator/bestScreen_windowOffAllScreens_picksNearestByCenter", bestScreenWindowOffAllScreensPicksNearestByCenter),
        ("WindowActivator/activate_frontmostWindow_skipsAppActivation", activateFrontmostWindowSkipsAppActivation),
        ("WindowActivator/activate_backgroundWindow_callsAppActivation", activateBackgroundWindowCallsAppActivation),
        ("WindowActivator/activate_hostedWindow_targetsOwnerAndActivatesHost", activateHostedWindowTargetsOwnerAndActivatesHost),
        ("WindowActivator/activateApplication_alwaysCallsAppActivation", activateApplicationCallsAppActivation),
        ("WindowActivator/reopenApplication_pressesDockBeforeAppActivation", reopenApplicationPressesDockBeforeAppActivation),
        ("WindowActivator/dockCandidate_prefersURLThenLocalizedTitle", dockCandidatePrefersURLThenLocalizedTitle),
        ("WindowActivator/activate_backgroundWindow_requiresRaiseAndAppActivation", activateBackgroundWindowRequiresBothSteps),
        ("WindowActivator/activationTargeting_acceptsAttributeUnsupportedRaiseAfterMainAndFocus", activationTargetingAcceptsAttributeUnsupportedRaiseAfterMainAndFocus),
        ("WindowActivator/activationTargeting_acceptsMinimizedTransitionCannotCompleteAfterRestoreAndFocus", activationTargetingAcceptsMinimizedTransitionCannotCompleteAfterRestoreAndFocus),
        ("WindowActivator/activationTargeting_keepsOtherAXFailuresClosed", activationTargetingKeepsOtherAXFailuresClosed),
        ("WindowActivator/activationConfirmation_waitsForObservedActiveState", activationConfirmationWaitsForObservedState),
        ("WindowActivator/activationConfirmation_rejectsUnconfirmedRequest", activationConfirmationRejectsUnconfirmedRequest),
        ("WindowActivator/shouldActivateApplication_falseForFrontmostAppWindow", shouldSkipActivationForFrontmostAppWindow),
        ("WindowActivator/shouldActivateApplication_trueForBackgroundAppWindow", shouldActivateForBackgroundAppWindow),
        ("WindowActivator/toAXScreenRect_flipsVerticallyOffsetDisplay", toAXScreenRect_flipsVerticallyOffsetDisplay),
        ("WindowActivator/snapFrame_halvesVisibleFrame", snapFrame_halvesVisibleFrame),
        ("WindowActivator/bestVisibleFrame_prefersLargestIntersection", bestVisibleFrame_prefersLargestIntersection)
    ]

    static func framesExact() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        try expect(WindowActivator.framesAreClose(a, a))
    }

    static func framesWithinTolerance() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        let b = CGRect(x: 105, y: 195, width: 803, height: 597)  // <12 pt drift on each axis
        try expect(WindowActivator.framesAreClose(a, b))
    }

    static func framesOutsideTolerance() throws {
        let a = CGRect(x: 100, y: 200, width: 800, height: 600)
        // 20-pt shift in x alone — should fail with default tolerance 12.
        let b = CGRect(x: 120, y: 200, width: 800, height: 600)
        try expect(!WindowActivator.framesAreClose(a, b))
    }

    static func framesCustomTolerance() throws {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        let b = CGRect(x: 30, y: 0, width: 100, height: 100)
        try expect(!WindowActivator.framesAreClose(a, b, tolerance: 10))
        try expect(WindowActivator.framesAreClose(a, b, tolerance: 50))
    }

    static func bestMatchPrefersClosestFrameAmongTitleMatches() throws {
        let item = makeItem(
            id: 55,
            pid: 100,
            title: "Untitled",
            bounds: CGRect(x: 200, y: 120, width: 900, height: 700)
        )

        let candidates = [
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 194, y: 118, width: 900, height: 700),
                isMain: true
            ),
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 200, y: 120, width: 900, height: 700)
            )
        ]

        try expectEqual(WindowActivator.bestMatchIndex(for: item, candidates: candidates), 1)
    }

    static func bestMatchDefaultTieKeepsFirstCandidate() throws {
        let item = makeItem(
            id: 66,
            pid: 100,
            title: "Untitled",
            isFrontmostApp: true,
            bounds: CGRect(x: 300, y: 160, width: 840, height: 620)
        )

        let candidates = [
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 300, y: 160, width: 840, height: 620),
                isMain: true,
                isFocused: true
            ),
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 300, y: 160, width: 840, height: 620)
            )
        ]

        try expectEqual(WindowActivator.bestMatchIndex(for: item, candidates: candidates), 0)
    }

    static func bestMatchSameAppTiePrefersNonMainWindow() throws {
        let item = makeItem(
            id: 77,
            pid: 100,
            title: "Untitled",
            isFrontmostApp: true,
            bounds: CGRect(x: 300, y: 160, width: 840, height: 620)
        )

        let candidates = [
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 300, y: 160, width: 840, height: 620),
                isMain: true,
                isFocused: true
            ),
            matchCandidate(
                title: "Untitled",
                frame: CGRect(x: 300, y: 160, width: 840, height: 620)
            )
        ]

        try expectEqual(
            WindowActivator.bestMatchIndex(
                for: item,
                candidates: candidates,
                preferNonMainOnTies: true
            ),
            1
        )
    }

    static func bestMatchFallsBackToClosestFrameWhenTitleDrifts() throws {
        let item = makeItem(
            id: 88,
            pid: 200,
            title: "Old title",
            bounds: CGRect(x: 40, y: 60, width: 1000, height: 720)
        )

        let candidates = [
            matchCandidate(
                title: "New title",
                frame: CGRect(x: 46, y: 66, width: 1000, height: 720)
            ),
            matchCandidate(
                title: "Other",
                frame: CGRect(x: 500, y: 300, width: 900, height: 600)
            )
        ]

        try expectEqual(WindowActivator.bestMatchIndex(for: item, candidates: candidates), 0)
    }

    static func bestMatchEmptyCandidatesReturnsNil() throws {
        let item = makeItem(id: 1, title: "Anything")
        try expectNil(WindowActivator.bestMatchIndex(for: item, candidates: []))
    }

    // Empty item title (e.g. a window with no title) makes titleMatches() pass
    // for every candidate, so the frame is the only discriminator.
    static func bestMatchEmptyItemTitleMatchesByFrameOnly() throws {
        let item = makeItem(
            id: 9,
            pid: 100,
            title: "",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )

        let candidates = [
            matchCandidate(title: "Far away", frame: CGRect(x: 600, y: 600, width: 800, height: 600)),
            matchCandidate(title: "Near", frame: CGRect(x: 104, y: 102, width: 800, height: 600))
        ]

        try expectEqual(WindowActivator.bestMatchIndex(for: item, candidates: candidates), 1)
    }

    // Candidates without frame data can't frame-match; the title match still
    // resolves through the fallback path.
    static func bestMatchNilFrameCandidatesFallBackToTitleMatch() throws {
        let item = makeItem(id: 12, pid: 100, title: "Doc")

        let candidates = [
            matchCandidate(title: "Other", frame: nil),
            matchCandidate(title: "Doc", frame: nil)
        ]

        try expectEqual(WindowActivator.bestMatchIndex(for: item, candidates: candidates), 1)
    }

    static func bestMatchStrictAmbiguousEvidenceReturnsNil() throws {
        let item = makeItem(
            id: 13,
            pid: 100,
            title: "Untitled",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let candidates = [
            matchCandidate(title: "Untitled", frame: CGRect(x: 102, y: 100, width: 800, height: 600)),
            matchCandidate(title: "Untitled", frame: CGRect(x: 105, y: 102, width: 800, height: 600))
        ]

        try expectNil(
            WindowActivator.bestMatchIndex(
                for: item,
                candidates: candidates,
                requireUniqueEvidence: true
            )
        )
    }

    static func bestMatchStrictDuplicateTitleUsesUniqueFrame() throws {
        let item = makeItem(
            id: 14,
            pid: 100,
            title: "Untitled",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600)
        )
        let candidates = [
            matchCandidate(title: "Untitled", frame: CGRect(x: 600, y: 500, width: 800, height: 600)),
            matchCandidate(title: "Untitled", frame: CGRect(x: 104, y: 102, width: 800, height: 600))
        ]

        try expectEqual(
            WindowActivator.bestMatchIndex(
                for: item,
                candidates: candidates,
                requireUniqueEvidence: true
            ),
            1
        )
    }

    static func bestScreenEmptyCandidatesReturnsNil() throws {
        try expectNil(
            WindowActivator.bestScreen(
                for: CGRect(x: 0, y: 0, width: 100, height: 100),
                candidates: []
            )
        )
    }

    // Window sits in the gap between two screens: it intersects neither and its
    // midpoint is contained by neither, so bestScreen falls through to
    // nearest-by-center. Candidate order is reversed to prove distance wins.
    static func bestScreenWindowOffAllScreensPicksNearestByCenter() throws {
        let near = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        let far = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 2000, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 2000, y: 0, width: 1000, height: 700)
        )
        let window = CGRect(x: 1100, y: 0, width: 200, height: 200)

        try expectEqual(
            WindowActivator.bestScreen(for: window, candidates: [far, near]),
            near
        )
    }

    static func activateFrontmostWindowSkipsAppActivation() throws {
        var raisedItems: [CGWindowID] = []
        var activatedPIDs: [pid_t] = []
        let activator = WindowActivator(
            raiseWindowOverride: { item in
                raisedItems.append(item.id)
                return true
            },
            activateApplicationOverride: { pid in
                activatedPIDs.append(pid)
                return true
            }
        )

        let succeeded = activator.activate(makeItem(id: 2, pid: 100, title: "Sibling", isFrontmostApp: true).actionTarget)

        try expect(succeeded)
        try expectEqual(raisedItems, [2])
        try expectEqual(activatedPIDs, [])
    }

    static func activateBackgroundWindowCallsAppActivation() throws {
        var raisedItems: [CGWindowID] = []
        var activatedPIDs: [pid_t] = []
        let activator = WindowActivator(
            raiseWindowOverride: { item in
                raisedItems.append(item.id)
                return true
            },
            activateApplicationOverride: { pid in
                activatedPIDs.append(pid)
                return true
            }
        )

        let succeeded = activator.activate(makeItem(id: 3, pid: 200, title: "Background", isFrontmostApp: false).actionTarget)

        try expect(succeeded)
        try expectEqual(raisedItems, [3])
        try expectEqual(activatedPIDs, [200])
    }

    static func activateHostedWindowTargetsOwnerAndActivatesHost() throws {
        var targetedWindowPIDs: [pid_t] = []
        var activatedPIDs: [pid_t] = []
        let activator = WindowActivator(
            raiseWindowOverride: { item in
                targetedWindowPIDs.append(item.windowProcessIdentifier)
                return true
            },
            activateApplicationOverride: { pid in
                activatedPIDs.append(pid)
                return true
            }
        )

        let item = makeItem(
            id: 3,
            pid: 36581,
            appName: "Steam",
            title: "Steam",
            windowOwnerPID: 36706
        )
        let succeeded = activator.activate(item.actionTarget)

        try expect(succeeded)
        try expectEqual(targetedWindowPIDs, [36706])
        try expectEqual(activatedPIDs, [36581])
    }

    static func activateApplicationCallsAppActivation() throws {
        var activatedPIDs: [pid_t] = []
        let activator = WindowActivator(
            activateApplicationOverride: { pid in
                activatedPIDs.append(pid)
                return true
            }
        )

        let succeeded = activator.activateApplication(pid: 300)

        try expect(succeeded)
        try expectEqual(activatedPIDs, [300])
    }

    static func reopenApplicationPressesDockBeforeAppActivation() throws {
        var calls: [String] = []
        let activator = WindowActivator(
            activateApplicationOverride: { pid in
                calls.append("activate:\(pid)")
                return true
            },
            reopenApplicationOverride: { pid in
                calls.append("reopen:\(pid)")
                return true
            }
        )

        try expect(activator.reopenApplication(pid: 301))
        try expectEqual(calls, ["reopen:301", "activate:301"])

        let failedReopen = WindowActivator(
            activateApplicationOverride: { _ in true },
            reopenApplicationOverride: { _ in false }
        )
        try expect(!failedReopen.reopenApplication(pid: 302))
    }

    static func dockCandidatePrefersURLThenLocalizedTitle() throws {
        let targetURL = URL(fileURLWithPath: "/Applications/Example.app")
        let candidates = [
            WindowActivator.DockApplicationCandidate(
                title: "Esimerkki",
                applicationURL: nil,
                isRunning: true
            ),
            WindowActivator.DockApplicationCandidate(
                title: "Example",
                applicationURL: targetURL,
                isRunning: true
            )
        ]

        try expectEqual(
            WindowActivator.bestDockApplicationCandidateIndex(
                targetTitle: "Esimerkki",
                targetURL: targetURL,
                candidates: candidates
            ),
            1
        )
        try expectEqual(
            WindowActivator.bestDockApplicationCandidateIndex(
                targetTitle: "Esimerkki",
                targetURL: nil,
                candidates: candidates
            ),
            0
        )
    }

    static func activateBackgroundWindowRequiresBothSteps() throws {
        let activator = WindowActivator(
            raiseWindowOverride: { _ in true },
            activateApplicationOverride: { _ in false }
        )

        let succeeded = activator.activate(
            makeItem(id: 4, pid: 400, title: "Background", isFrontmostApp: false).actionTarget
        )

        try expect(!succeeded)
    }

    static func activationTargetingAcceptsAttributeUnsupportedRaiseAfterMainAndFocus() throws {
        try expect(
            WindowActivator.activationTargetingSucceeded(
                raiseResult: .attributeUnsupported,
                mainResult: .success,
                focusResult: .success
            )
        )
    }

    static func activationTargetingAcceptsMinimizedTransitionCannotCompleteAfterRestoreAndFocus() throws {
        try expect(
            WindowActivator.activationTargetingSucceeded(
                raiseResult: .cannotComplete,
                mainResult: .cannotComplete,
                focusResult: .success,
                itemWasMinimized: true,
                unminimizeResult: .success
            )
        )
        try expect(
            WindowActivator.activationTargetingSucceeded(
                raiseResult: .success,
                mainResult: .cannotComplete,
                focusResult: .success,
                itemWasMinimized: true,
                unminimizeResult: .success
            )
        )
    }

    static func activationTargetingKeepsOtherAXFailuresClosed() throws {
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .cannotComplete,
                mainResult: .success,
                focusResult: .success
            )
        )
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .attributeUnsupported,
                mainResult: .failure,
                focusResult: .success
            )
        )
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .attributeUnsupported,
                mainResult: .success,
                focusResult: .failure
            )
        )
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .cannotComplete,
                mainResult: .cannotComplete,
                focusResult: .success,
                itemWasMinimized: false,
                unminimizeResult: nil
            )
        )
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .cannotComplete,
                mainResult: .cannotComplete,
                focusResult: .failure,
                itemWasMinimized: true,
                unminimizeResult: .success
            )
        )
        try expect(
            !WindowActivator.activationTargetingSucceeded(
                raiseResult: .cannotComplete,
                mainResult: .cannotComplete,
                focusResult: .success,
                itemWasMinimized: true,
                unminimizeResult: .cannotComplete
            )
        )
    }

    static func activationConfirmationWaitsForObservedState() throws {
        var observations = [false, false, true]
        var waits = 0
        let confirmed = WindowActivator.confirmActivationRequest(
            requestAccepted: true,
            attempts: 3,
            isActive: { observations.removeFirst() },
            wait: { waits += 1 }
        )
        try expect(confirmed)
        try expectEqual(waits, 2)
    }

    static func activationConfirmationRejectsUnconfirmedRequest() throws {
        var observations = 0
        let rejected = WindowActivator.confirmActivationRequest(
            requestAccepted: false,
            attempts: 3,
            isActive: { observations += 1; return true },
            wait: {}
        )
        try expect(!rejected)
        try expectEqual(observations, 0)

        let neverConfirmed = WindowActivator.confirmActivationRequest(
            requestAccepted: true,
            attempts: 3,
            isActive: { false },
            wait: {}
        )
        try expect(!neverConfirmed)
    }

    static func shouldSkipActivationForFrontmostAppWindow() throws {
        let item = makeItem(id: 2, pid: 100, title: "Sibling", isFrontmostApp: true)
        try expect(!WindowActivator.shouldActivateApplication(afterTargeting: item))
    }

    static func shouldActivateForBackgroundAppWindow() throws {
        let item = makeItem(id: 2, pid: 100, title: "Background window", isFrontmostApp: false)
        try expect(WindowActivator.shouldActivateApplication(afterTargeting: item))
    }

    static func snapFrame_halvesVisibleFrame() throws {
        let screenFrame = CGRect(x: 0, y: 0, width: 1240, height: 860)
        let visibleFrame = CGRect(x: 20, y: 20, width: 1200, height: 800)

        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .left),
            CGRect(x: 20, y: 20, width: 600, height: 800)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .right),
            CGRect(x: 620, y: 20, width: 600, height: 800)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .top),
            CGRect(x: 20, y: 20, width: 1200, height: 400)
        )
        try expectEqual(
            WindowActivator.snapFrame(inVisibleFrame: visibleFrame, screenFrame: screenFrame, to: .bottom),
            CGRect(x: 20, y: 420, width: 1200, height: 400)
        )
    }

    static func toAXScreenRect_flipsVerticallyOffsetDisplay() throws {
        let rootFrame = CGRect(x: 0, y: 0, width: 1440, height: 1800)
        let appKitVisibleFrameAboveMain = CGRect(x: 0, y: 900, width: 1440, height: 860)

        try expectEqual(
            WindowActivator.toAXScreenRect(appKitVisibleFrameAboveMain, rootScreenFrame: rootFrame),
            CGRect(x: 0, y: 40, width: 1440, height: 860)
        )
    }

    static func bestVisibleFrame_prefersLargestIntersection() throws {
        let primary = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 0, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 0, y: 0, width: 1000, height: 700)
        )
        let secondary = WindowActivator.ScreenGeometry(
            frame: CGRect(x: 1000, y: 0, width: 1000, height: 740),
            visibleFrame: CGRect(x: 1000, y: 0, width: 1000, height: 700)
        )
        let spanningWindow = CGRect(x: 850, y: 100, width: 500, height: 400)

        let chosen = WindowActivator.bestScreen(
            for: spanningWindow,
            candidates: [primary, secondary]
        )

        try expectEqual(chosen, secondary)
    }

    private static func matchCandidate(
        title: String?,
        frame: CGRect?,
        isMain: Bool = false,
        isFocused: Bool = false
    ) -> WindowActivator.WindowMatchCandidate {
        WindowActivator.WindowMatchCandidate(
            title: title,
            frame: frame,
            isMain: isMain,
            isFocused: isFocused
        )
    }
}
