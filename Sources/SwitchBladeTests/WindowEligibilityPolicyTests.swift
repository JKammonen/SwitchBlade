import AppKit
@testable import SwitchBladeCore

enum WindowEligibilityPolicyTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("WindowEligibilityPolicy/rejectsOwnProcessUnconditionally", rejectsOwnProcess),
        ("WindowEligibilityPolicy/rejectsAccessoryAndUnfinishedApps", rejectsAccessoryAndUnfinishedApps),
        ("WindowEligibilityPolicy/allowsFinishedRegularExternalApp", allowsFinishedRegularExternalApp),
        ("WindowEligibilityPolicy/windowRowsAllowAccessoryApps", windowRowsAllowAccessoryApps),
        ("ApplicationFallback/windowScopesExcludeAppOnlyRows", fallbackWindowScopesExcludeAppOnlyRows),
        ("ApplicationFallback/currentAppIncludesOnlyFrontmostApp", fallbackCurrentAppIncludesOnlyFrontmostApp),
        ("ApplicationFallback/currentAppExcludesAccessoryAppOnlyRow", currentAppExcludesAccessoryAppOnlyRow),
        ("ApplicationFallback/currentSpaceRestoresRememberedAXEmptyApp", currentSpaceRestoresRememberedAXEmptyApp),
        ("ApplicationFallback/rememberedWindowRejectsUnsafeStates", rememberedWindowRejectsUnsafeStates),
        ("RunningApplicationSnapshot/coalescesDuplicateProcessIdentifiers", coalescesDuplicateProcessIdentifiers),
        ("HostedWindowApplication/resolvesNestedAccessoryToRegularHost", resolvesNestedAccessoryToRegularHost),
        ("HostedWindowApplication/resolvesStandaloneAccessoryToSelf", resolvesStandaloneAccessoryToSelf),
        ("HostedWindowApplication/prefersDeepestNestedRegularHost", prefersDeepestNestedRegularHost),
        ("MinimizedAXScanPlan/keepsRegularAppBeyondAccessoryPrefix", minimizedScanPlanKeepsRegularAppBeyondAccessoryPrefix),
        ("MinimizedAXScanPlan/prioritizesHelperAndWindowServerEvidence", minimizedScanPlanPrioritizesHelperAndWindowServerEvidence),
        ("MinimizedAXScanExecution/scansCandidateBeyondLegacyApplicationLimit", minimizedScanExecutionScansCandidateBeyondLegacyApplicationLimit),
        ("HostedWindowSurface/filtersMirroredHelperSurface", filtersMirroredHelperSurface),
        ("HostedWindowSurface/keepsUniqueHelperSurface", keepsUniqueHelperSurface),
        ("WindowLayerEligibility/acceptsOnlyNamedFloatingCandidates", acceptsOnlyNamedFloatingCandidates),
        ("WindowLayerEligibility/retainsBackgroundedPluginWithVisibleHost", retainsBackgroundedPluginWithVisibleHost),
        ("AXWindowEligibility/filtersUnmatchedAuxiliarySurface", filtersUnmatchedAuxiliarySurface),
        ("AXWindowEligibility/filtersDuplicateSystemDialogSurfaces", filtersDuplicateSystemDialogSurfaces),
        ("AXWindowEligibility/keepsMatchedUntitledWindow", keepsMatchedUntitledWindow),
        ("AXWindowEligibility/titledSurfaceWithoutAXFrameIsFiltered", titledSurfaceWithoutAXFrameIsFiltered),
        ("AXWindowEligibility/unavailableAXFailsOpen", unavailableAXFailsOpen),
        ("AXWindowEligibility/ambiguousCandidateReuseFailsOpen", ambiguousCandidateReuseFailsOpen),
        ("AXWindowEligibility/keepsAXMatchedFloatingWindow", keepsAXMatchedFloatingWindow),
        ("AXWindowEligibility/keepsRememberedFloatingWindowWhileAXHidden", keepsRememberedFloatingWindowWhileAXHidden),
        ("AXWindowEligibility/floatingWindowFailsClosedWithoutAX", floatingWindowFailsClosedWithoutAX),
        ("AXWindowEligibility/rejectsStandardAXMatchForFloatingLayer", rejectsStandardAXMatchForFloatingLayer)
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

    @MainActor static func windowRowsAllowAccessoryApps() throws {
        try expect(WindowEligibilityPolicy.canIncludeWindowApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .accessory,
            isFinishedLaunching: true
        ))
        try expect(!WindowEligibilityPolicy.canIncludeWindowApplication(
            processIdentifier: 42,
            currentProcessIdentifier: 42,
            activationPolicy: .accessory,
            isFinishedLaunching: true
        ))
        try expect(!WindowEligibilityPolicy.canIncludeWindowApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .prohibited,
            isFinishedLaunching: true
        ))
        try expect(!WindowEligibilityPolicy.canIncludeWindowApplication(
            processIdentifier: 43,
            currentProcessIdentifier: 42,
            activationPolicy: .accessory,
            isFinishedLaunching: false
        ))
    }

    @MainActor static func fallbackWindowScopesExcludeAppOnlyRows() throws {
        let represented = applicationDescriptor(
            pid: 100,
            policy: .regular,
            bundleIdentifier: "com.example.visible",
            path: "/Applications/Visible.app"
        )
        let appOnly = applicationDescriptor(
            pid: 200,
            policy: .regular,
            bundleIdentifier: "com.example.app-only",
            path: "/Applications/App Only.app"
        )
        let accessory = applicationDescriptor(
            pid: 300,
            policy: .accessory,
            bundleIdentifier: "com.example.helper",
            path: "/Applications/Helper.app"
        )
        let unfinished = applicationDescriptor(
            pid: 400,
            policy: .regular,
            bundleIdentifier: "com.example.launching",
            path: "/Applications/Launching.app",
            isFinishedLaunching: false
        )

        for scope in [SBWindowScope.currentSpace, .allSpaces] {
            try expectEqual(
                ApplicationFallbackPolicy.processIdentifiers(
                    from: [represented, appOnly, accessory, unfinished],
                    representedApplicationPIDs: [100],
                    currentProcessIdentifier: 999,
                    frontmostPID: 100,
                    scope: scope
                ),
                [],
                "window scopes should contain windows, not app-only placeholder rows"
            )
        }
    }

    @MainActor static func fallbackCurrentAppIncludesOnlyFrontmostApp() throws {
        let frontmost = applicationDescriptor(
            pid: 100,
            policy: .regular,
            bundleIdentifier: "com.example.frontmost",
            path: "/Applications/Frontmost.app"
        )
        let background = applicationDescriptor(
            pid: 200,
            policy: .regular,
            bundleIdentifier: "com.example.background",
            path: "/Applications/Background.app"
        )

        try expectEqual(
            ApplicationFallbackPolicy.processIdentifiers(
                from: [frontmost, background],
                representedApplicationPIDs: [],
                currentProcessIdentifier: 999,
                frontmostPID: 100,
                scope: .currentApp
            ),
            [100]
        )
    }

    @MainActor static func currentAppExcludesAccessoryAppOnlyRow() throws {
        let accessory = applicationDescriptor(
            pid: 100,
            policy: .accessory,
            bundleIdentifier: "com.example.standalone-accessory",
            path: "/Applications/Standalone Accessory.app"
        )

        try expectEqual(
            ApplicationFallbackPolicy.processIdentifiers(
                from: [accessory],
                representedApplicationPIDs: [],
                currentProcessIdentifier: 999,
                frontmostPID: 100,
                scope: .currentApp
            ),
            [],
            "accessory apps require a concrete window row"
        )
    }

    @MainActor static func currentSpaceRestoresRememberedAXEmptyApp() throws {
        try expect(RememberedWindowFallbackPolicy.shouldInclude(
            scope: .currentSpace,
            activationPolicy: .regular,
            isFinishedLaunching: true,
            isHidden: false,
            isAlreadyRepresented: false,
            axWindowListIsEmpty: true,
            hasRetainedOffscreenWindow: true
        ))
    }

    @MainActor static func rememberedWindowRejectsUnsafeStates() throws {
        let base = (
            scope: SBWindowScope.currentSpace,
            activationPolicy: NSApplication.ActivationPolicy.regular,
            isFinishedLaunching: true,
            isHidden: false,
            isAlreadyRepresented: false,
            axWindowListIsEmpty: true,
            hasRetainedOffscreenWindow: true
        )

        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: .allSpaces,
            activationPolicy: base.activationPolicy,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: base.isHidden,
            isAlreadyRepresented: base.isAlreadyRepresented,
            axWindowListIsEmpty: base.axWindowListIsEmpty,
            hasRetainedOffscreenWindow: base.hasRetainedOffscreenWindow
        ))
        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: base.scope,
            activationPolicy: .accessory,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: base.isHidden,
            isAlreadyRepresented: base.isAlreadyRepresented,
            axWindowListIsEmpty: base.axWindowListIsEmpty,
            hasRetainedOffscreenWindow: base.hasRetainedOffscreenWindow
        ))
        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: base.scope,
            activationPolicy: base.activationPolicy,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: true,
            isAlreadyRepresented: base.isAlreadyRepresented,
            axWindowListIsEmpty: base.axWindowListIsEmpty,
            hasRetainedOffscreenWindow: base.hasRetainedOffscreenWindow
        ))
        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: base.scope,
            activationPolicy: base.activationPolicy,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: base.isHidden,
            isAlreadyRepresented: true,
            axWindowListIsEmpty: base.axWindowListIsEmpty,
            hasRetainedOffscreenWindow: base.hasRetainedOffscreenWindow
        ))
        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: base.scope,
            activationPolicy: base.activationPolicy,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: base.isHidden,
            isAlreadyRepresented: base.isAlreadyRepresented,
            axWindowListIsEmpty: false,
            hasRetainedOffscreenWindow: base.hasRetainedOffscreenWindow
        ))
        try expect(!RememberedWindowFallbackPolicy.shouldInclude(
            scope: base.scope,
            activationPolicy: base.activationPolicy,
            isFinishedLaunching: base.isFinishedLaunching,
            isHidden: base.isHidden,
            isAlreadyRepresented: base.isAlreadyRepresented,
            axWindowListIsEmpty: base.axWindowListIsEmpty,
            hasRetainedOffscreenWindow: false
        ))
    }

    @MainActor static func coalescesDuplicateProcessIdentifiers() throws {
        guard let runningApplication = NSWorkspace.shared.runningApplications.first(where: {
            $0.processIdentifier > 0
        }) else {
            try expect(false, "expected at least one running application with a valid process identifier")
            return
        }

        let snapshot = RunningApplicationSnapshot.coalescing([
            runningApplication,
            runningApplication
        ])

        try expectEqual(snapshot.applications.count, 1)
        try expectEqual(snapshot.applicationsByProcessIdentifier.count, 1)
        try expectEqual(snapshot.discardedInvalidProcessIdentifiers, 0)
        try expectEqual(snapshot.coalescedDuplicateProcessIdentifiers, 1)
        try expect(
            snapshot.applicationsByProcessIdentifier[runningApplication.processIdentifier]
                === runningApplication
        )
    }

    @MainActor static func resolvesNestedAccessoryToRegularHost() throws {
        let host = applicationDescriptor(
            pid: 100,
            policy: .regular,
            bundleIdentifier: "com.example.editor",
            path: "/Applications/Editor.app"
        )
        let helper = applicationDescriptor(
            pid: 101,
            policy: .accessory,
            bundleIdentifier: "org.renderer.process",
            path: "/Applications/Editor.app/Contents/Frameworks/Renderer.app"
        )

        try expectEqual(
            HostedWindowApplicationPolicy.hostProcessIdentifier(
                for: helper,
                among: [host, helper],
                currentProcessIdentifier: 999
            ),
            100
        )
    }

    @MainActor static func resolvesStandaloneAccessoryToSelf() throws {
        let unrelatedRegularApp = applicationDescriptor(
            pid: 100,
            policy: .regular,
            bundleIdentifier: "com.example.editor",
            path: "/Applications/Editor.app"
        )
        let standaloneAccessory = applicationDescriptor(
            pid: 101,
            policy: .accessory,
            bundleIdentifier: "com.example.standalone-accessory",
            path: "/Applications/Standalone Accessory.app"
        )

        try expectEqual(
            HostedWindowApplicationPolicy.hostProcessIdentifier(
                for: standaloneAccessory,
                among: [unrelatedRegularApp, standaloneAccessory],
                currentProcessIdentifier: 999
            ),
            101
        )
    }

    @MainActor static func prefersDeepestNestedRegularHost() throws {
        let suite = applicationDescriptor(
            pid: 100,
            policy: .regular,
            bundleIdentifier: "com.example.suite",
            path: "/Applications/Suite.app"
        )
        let editor = applicationDescriptor(
            pid: 101,
            policy: .regular,
            bundleIdentifier: "com.example.suite.editor",
            path: "/Applications/Suite.app/Contents/Applications/Editor.app"
        )
        let helper = applicationDescriptor(
            pid: 102,
            policy: .accessory,
            bundleIdentifier: "org.renderer.process",
            path: "/Applications/Suite.app/Contents/Applications/Editor.app/Contents/Frameworks/Renderer.app"
        )

        try expectEqual(
            HostedWindowApplicationPolicy.hostProcessIdentifier(
                for: helper,
                among: [suite, editor, helper],
                currentProcessIdentifier: 999
            ),
            101
        )
    }

    @MainActor static func minimizedScanPlanKeepsRegularAppBeyondAccessoryPrefix() throws {
        let accessoryCandidates = (0 ..< 40).map { offset in
            MinimizedAXScanCandidate(
                windowProcessIdentifier: pid_t(1_000 + offset),
                hostProcessIdentifier: pid_t(1_000 + offset),
                activationPolicy: .accessory
            )
        }
        let regularCandidate = MinimizedAXScanCandidate(
            windowProcessIdentifier: 42,
            hostProcessIdentifier: 42,
            activationPolicy: .regular
        )

        let ordered = MinimizedAXScanPlan.ordered(
            accessoryCandidates + [regularCandidate],
            windowServerProcessIdentifiers: []
        )

        try expectEqual(ordered.count, 41)
        try expectEqual(ordered.first, regularCandidate)
        try expectEqual(
            Array(ordered.dropFirst()),
            accessoryCandidates,
            "every accessory candidate should remain in stable order after the regular app is prioritized"
        )
    }

    @MainActor static func minimizedScanPlanPrioritizesHelperAndWindowServerEvidence() throws {
        let standaloneAccessory = MinimizedAXScanCandidate(
            windowProcessIdentifier: 201,
            hostProcessIdentifier: 201,
            activationPolicy: .accessory
        )
        let evidencedAccessory = MinimizedAXScanCandidate(
            windowProcessIdentifier: 202,
            hostProcessIdentifier: 202,
            activationPolicy: .accessory
        )
        let nestedHelper = MinimizedAXScanCandidate(
            windowProcessIdentifier: 203,
            hostProcessIdentifier: 100,
            activationPolicy: .accessory
        )
        let regularApplication = MinimizedAXScanCandidate(
            windowProcessIdentifier: 100,
            hostProcessIdentifier: 100,
            activationPolicy: .regular
        )

        let ordered = MinimizedAXScanPlan.ordered(
            [standaloneAccessory, evidencedAccessory, nestedHelper, regularApplication],
            windowServerProcessIdentifiers: [202]
        )

        try expectEqual(
            ordered.map(\.windowProcessIdentifier),
            [100, 203, 202, 201]
        )
        try expectEqual(ordered[1].hostProcessIdentifier, 100)
    }

    @MainActor static func minimizedScanExecutionScansCandidateBeyondLegacyApplicationLimit() throws {
        let candidates = (0 ..< 53).map { offset in
            MinimizedAXScanCandidate(
                windowProcessIdentifier: pid_t(1_000 + offset),
                hostProcessIdentifier: pid_t(1_000 + offset),
                activationPolicy: .accessory
            )
        }
        let ordered = MinimizedAXScanPlan.ordered(
            candidates,
            windowServerProcessIdentifiers: []
        )
        let targetPID = candidates.last!.windowProcessIdentifier

        let execution: MinimizedAXScanExecutionResult<pid_t> = MinimizedAXScanExecution.run(
            candidates: ordered,
            maximumWindows: 128,
            maximumElapsedSeconds: 2.0,
            startedAt: 0,
            now: { 0.5 },
            isCancelled: { false },
            windowsForCandidate: { candidate in
                let offset = Int(candidate.windowProcessIdentifier - 1_000)
                if offset < 49 { return [] }
                if candidate.windowProcessIdentifier == targetPID { return [true] }
                return nil
            },
            itemForWindow: { candidate, _, isMinimized in
                isMinimized ? candidate.windowProcessIdentifier : nil
            }
        )

        try expectEqual(execution.items, [targetPID])
        try expectEqual(execution.scannedApplications, 53)
        try expectEqual(execution.scannedWindows, 1)
        try expectEqual(execution.applicationsWithoutWindows, 49)
        try expectEqual(execution.applicationsWithUnavailableAX, 3)
        try expect(!execution.isBudgetExhausted)
        try expect(execution.isComplete)
    }

    @MainActor static func filtersMirroredHelperSurface() throws {
        let sharedBounds = CGRect(x: 100, y: 80, width: 1200, height: 800)
        let direct = makeItem(id: 1, pid: 100, bounds: sharedBounds)
        let mirroredHelper = makeItem(
            id: 2,
            pid: 100,
            bounds: sharedBounds,
            windowOwnerPID: 101
        )

        try expectEqual(
            HostedWindowSurfacePolicy.filteringMirroredHostedSurfaces([
                direct,
                mirroredHelper
            ]).map(\.id),
            [1]
        )
    }

    @MainActor static func keepsUniqueHelperSurface() throws {
        let direct = makeItem(
            id: 1,
            pid: 100,
            bounds: CGRect(x: 100, y: 80, width: 1200, height: 800)
        )
        let uniqueHelper = makeItem(
            id: 2,
            pid: 100,
            bounds: CGRect(x: 140, y: 120, width: 900, height: 650),
            windowOwnerPID: 101
        )

        try expectEqual(
            HostedWindowSurfacePolicy.filteringMirroredHostedSurfaces([
                direct,
                uniqueHelper
            ]).map(\.id),
            [1, 2]
        )
    }

    @MainActor static func acceptsOnlyNamedFloatingCandidates() throws {
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))

        try expect(WindowLayerEligibilityPolicy.canConsider(layer: normalLayer, title: ""))
        try expect(WindowLayerEligibilityPolicy.canConsider(layer: floatingLayer, title: "Pigments/1-Pigments"))
        try expect(!WindowLayerEligibilityPolicy.canConsider(layer: floatingLayer, title: ""))
        try expect(!WindowLayerEligibilityPolicy.canConsider(layer: 8, title: "Overlay"))
        try expect(WindowLayerEligibilityPolicy.requiresFloatingAXMatch(layer: floatingLayer))
        try expect(!WindowLayerEligibilityPolicy.requiresFloatingAXMatch(layer: normalLayer))
        try expect(WindowLayerEligibilityPolicy.canCaptureState(layer: floatingLayer))
        try expect(!WindowLayerEligibilityPolicy.canCaptureState(layer: 8))
    }

    @MainActor static func retainsBackgroundedPluginWithVisibleHost() throws {
        let normalLayer = Int(CGWindowLevelForKey(.normalWindow))
        let floatingLayer = Int(CGWindowLevelForKey(.floatingWindow))

        try expect(WindowLayerEligibilityPolicy.canIncludeInCurrentSpace(
            layer: normalLayer,
            isOnScreen: true,
            hostHasOnScreenWindow: true
        ))
        try expect(!WindowLayerEligibilityPolicy.canIncludeInCurrentSpace(
            layer: normalLayer,
            isOnScreen: false,
            hostHasOnScreenWindow: true
        ))
        try expect(WindowLayerEligibilityPolicy.canIncludeInCurrentSpace(
            layer: floatingLayer,
            isOnScreen: false,
            hostHasOnScreenWindow: true
        ))
        try expect(!WindowLayerEligibilityPolicy.canIncludeInCurrentSpace(
            layer: floatingLayer,
            isOnScreen: false,
            hostHasOnScreenWindow: false
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

    @MainActor static func keepsAXMatchedFloatingWindow() throws {
        let main = makeItem(
            id: 1,
            pid: 100,
            title: "Untitled",
            bounds: CGRect(x: 687, y: 30, width: 1763, height: 1410)
        )
        let floating = makeItem(
            id: 2,
            pid: 100,
            title: "Pigments/1-Pigments",
            bounds: CGRect(x: 364, y: 133, width: 1920, height: 1222)
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: main.title, frame: main.bounds),
            AXTopLevelWindowCandidate(
                title: floating.title,
                frame: floating.bounds,
                isFloatingWindow: true
            )
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, floating],
            candidates: candidates,
            requiredFloatingWindowIDs: [floating.id]
        )

        try expectEqual(filtered.map(\.id), [1, 2])
    }

    @MainActor static func floatingWindowFailsClosedWithoutAX() throws {
        let main = makeItem(id: 1, pid: 100, title: "Untitled")
        let floating = makeItem(id: 2, pid: 100, title: "Pigments/1-Pigments")

        try expectEqual(
            AXWindowEligibilityPolicy.filteredItems(
                [main, floating],
                candidates: nil,
                requiredFloatingWindowIDs: [floating.id]
            ).map(\.id),
            [main.id]
        )
    }

    @MainActor static func keepsRememberedFloatingWindowWhileAXHidden() throws {
        let main = makeItem(id: 1, pid: 100, title: "Untitled")
        let floating = makeItem(id: 2, pid: 100, title: "Kontakt 8/5-Kontakt 8")

        try expectEqual(
            AXWindowEligibilityPolicy.filteredItems(
                [main, floating],
                candidates: [AXTopLevelWindowCandidate(title: main.title, frame: main.bounds)],
                requiredFloatingWindowIDs: [floating.id],
                trustedFloatingWindowIDs: [floating.id]
            ).map(\.id),
            [main.id, floating.id]
        )
    }

    @MainActor static func rejectsStandardAXMatchForFloatingLayer() throws {
        let main = makeItem(id: 1, pid: 100, title: "Untitled")
        let floating = makeItem(
            id: 2,
            pid: 100,
            title: "Pigments/1-Pigments",
            bounds: CGRect(x: 364, y: 133, width: 1920, height: 1222)
        )
        let candidates = [
            AXTopLevelWindowCandidate(title: floating.title, frame: floating.bounds)
        ]

        let filtered = AXWindowEligibilityPolicy.filteredItems(
            [main, floating],
            candidates: candidates,
            requiredFloatingWindowIDs: [floating.id]
        )

        try expectEqual(filtered.map(\.id), [main.id])
    }

    private static func applicationDescriptor(
        pid: pid_t,
        policy: NSApplication.ActivationPolicy,
        bundleIdentifier: String,
        path: String,
        isFinishedLaunching: Bool = true
    ) -> RunningApplicationDescriptor {
        RunningApplicationDescriptor(
            processIdentifier: pid,
            activationPolicy: policy,
            isFinishedLaunching: isFinishedLaunching,
            bundleIdentifier: bundleIdentifier,
            bundleURL: URL(fileURLWithPath: path, isDirectory: true)
        )
    }
}
