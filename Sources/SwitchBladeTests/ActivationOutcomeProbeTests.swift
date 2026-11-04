import AppKit
import Foundation
@testable import SwitchBladeCore

/// Diagnostic-only outcome probe: what it counts as covering, that it is bound
/// to its selection, that it never holds the action lane, and that it logs
/// identities and geometry only. Switching behavior is unchanged by it.
enum ActivationOutcomeProbeTests {
    static let all: [(String, @MainActor () async throws -> Void)] = [
        ("ActivationOutcomeProbe/countsOnlyNormalOpaqueOverlappingSurfacesAbove", countsOnlyCoveringSurfaces),
        ("ActivationOutcomeProbe/targetMissingFromScreenIsReported", targetMissingIsReported),
        ("ActivationOutcomeProbe/fieldsAreBoundedAndTitleFree", fieldsAreBoundedAndTitleFree),
        ("ActivationOutcomeProbe/store_recordsCoveredSelectionWithItsCorrelation", storeRecordsCoveredSelection),
        ("ActivationOutcomeProbe/store_userDepartureDiscardsMeasurement", storeDepartureDiscards),
        ("ActivationOutcomeProbe/store_newerSelectionDiscardsAndLaneStaysFree", storeNewerSelectionDiscards)
    ]

    private static let target = CGRect(x: 100, y: 100, width: 800, height: 600)

    private static func surface(_ id: CGWindowID, pid: pid_t, layer: Int = 0, bounds: CGRect = target,
                                alpha: Double = 1) -> WindowStackSurface {
        WindowStackSurface(windowID: id, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
    }

    static func countsOnlyCoveringSurfaces() throws {
        let surfaces = [
            surface(90, pid: 1, layer: 25, bounds: CGRect(x: 0, y: 0, width: 2000, height: 30)), // menu bar level
            surface(91, pid: 999),                                                                // own panel
            surface(92, pid: 300, alpha: 0),                                                      // transparent
            surface(93, pid: 300, layer: 3),                                                      // floating
            surface(94, pid: 300, bounds: CGRect(x: 2000, y: 0, width: 300, height: 300)),        // no overlap
            surface(95, pid: 300, bounds: CGRect(x: 100, y: 100, width: 400, height: 600)),       // half cover
            surface(96, pid: 400, layer: -1, bounds: CGRect(x: 500, y: 100, width: 100, height: 100)), // Electron
            surface(97, pid: 200, bounds: CGRect(x: 100, y: 100, width: 800, height: 150)),       // same-app sibling
            surface(2, pid: 200),                                                                 // target
            surface(98, pid: 300)                                                                 // below target
        ]
        let measurement = ActivationOutcomeProbe.measure(targetWindowID: 2, targetPID: 200, targetOwnerPID: 200,
                                                         ownPID: 999, surfaces: surfaces, frontmostPID: 200)
        try expect(measurement.targetOnScreen)
        try expectEqual(measurement.coveringWindowIDs, [95, 96, 97])
        try expectEqual(measurement.coveringOtherAppCount, 2)
        try expectEqual(measurement.coveringSameAppCount, 1)
        try expectEqual(measurement.coveringOwnerPIDs, [200, 300, 400])
        try expectEqual(measurement.maximumCoverFraction, 0.5)
    }

    static func targetMissingIsReported() throws {
        let measurement = ActivationOutcomeProbe.measure(targetWindowID: 2, targetPID: 200, targetOwnerPID: 200,
                                                         ownPID: 999, surfaces: [surface(5, pid: 300)],
                                                         frontmostPID: 300)
        try expect(!measurement.targetOnScreen)
        try expectEqual(measurement.coveringCount, 0)
        let fields = ActivationOutcomeProbe.fields(for: measurement, targetPID: 200)
        guard case .bool(let frontmost)? = fields["target_app_frontmost"] else { return try expect(false) }
        try expect(!frontmost)
    }

    static func fieldsAreBoundedAndTitleFree() throws {
        let covering = (10..<24).map { surface(CGWindowID($0), pid: pid_t(300 + $0)) }
        let measurement = ActivationOutcomeProbe.measure(targetWindowID: 2, targetPID: 200, targetOwnerPID: 200,
                                                         ownPID: 999, surfaces: covering + [surface(2, pid: 200)],
                                                         frontmostPID: 200)
        let fields = ActivationOutcomeProbe.fields(for: measurement, targetPID: 200)
        guard case .int(let count)? = fields["covering_count"],
              case .string(let ids)? = fields["covering_window_ids"] else { return try expect(false) }
        try expectEqual(count, 14, "the count stays complete")
        try expectEqual(ids.split(separator: ",").count, ActivationOutcomeProbe.maximumListedCoveringWindows)
        try expect(!fields.keys.contains { $0.contains("title") || $0.contains("name") }, "no titles in the probe")
    }

    // MARK: - Store binding

    private final class Reader: WindowStackReading, @unchecked Sendable {
        let surfaces = LockedValue<[WindowStackSurface]>([])
        let frontmost = LockedValue<pid_t?>(nil)
        let reads = LockedValue(0)
        func onScreenSurfacesFrontToBack() -> [WindowStackSurface] { reads.withValue { $0 += 1 }; return surfaces.value }
        func frontmostApplicationPID() -> pid_t? { frontmost.value }
    }

    @MainActor private static func makeStore(reader: Reader, delay: UInt64 = 40_000_000)
        -> (SwitcherStore, MockWindowCatalog, MockWindowActivator) {
        let catalog = MockWindowCatalog()
        let activator = MockWindowActivator()
        let store = SwitcherStore(
            catalog: catalog, activator: activator, permissionService: MockPermissionService(),
            userDefaults: makeIsolatedUserDefaults(), focusedRankUpgradeDelayNanoseconds: 5_000_000_000,
            workspaceNotificationCenter: NotificationCenter(), initialFrontmostAppPID: 100, switchBladePID: 999,
            windowStackReader: reader, activationOutcomeProbeDelayNanoseconds: delay
        )
        catalog.visibleItems = [makeItem(id: 1, pid: 100, isFrontmostApp: true),
                                makeItem(id: 2, pid: 200), makeItem(id: 3, pid: 300)]
        return (store, catalog, activator)
    }

    private static func record(_ events: Set<String>) -> (rows: LockedValue<[(String, [String: PerformanceMetricValue])]>,
                                                          restore: () -> Void) {
        let rows = LockedValue<[(String, [String: PerformanceMetricValue])]>([])
        let previous = PerformanceDiagnostics.testObserver.value
        PerformanceDiagnostics.testObserver.value = { event, fields in
            previous?(event, fields)
            if events.contains(event) { rows.withValue { $0.append((event, fields)) } }
        }
        return (rows, { PerformanceDiagnostics.testObserver.value = previous })
    }

    private static func string(_ fields: [String: PerformanceMetricValue]?, _ key: String) -> String? {
        guard case .string(let value)? = fields?[key] else { return nil }
        return value
    }

    @MainActor private static func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 where !predicate() { try await Task.sleep(nanoseconds: 5_000_000) }
        try expect(predicate(), "expected diagnostic state was not reached")
    }

    @MainActor static func storeRecordsCoveredSelection() async throws {
        let reader = Reader()
        reader.surfaces.value = [surface(50, pid: 100), surface(2, pid: 200)]
        reader.frontmost.value = 200
        let (store, _, activator) = makeStore(reader: reader)
        defer { store.cancel() }
        let recorded = record(["activation_outcome_probe", "selection_action_dispatch"])
        defer { recorded.restore() }
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        try await waitFor { recorded.rows.value.contains { $0.0 == "activation_outcome_probe" } }
        try expectEqual(activator.activatedItems.map(\.id), [2])
        let probe = recorded.rows.value.first { $0.0 == "activation_outcome_probe" }?.1
        let dispatch = recorded.rows.value.first { $0.0 == "selection_action_dispatch" }?.1
        guard case .int(let other)? = probe?["covering_other_app_count"] else { return try expect(false) }
        try expectEqual(other, 1, "the source app's window still lies over the target")
        try expectNotNil(string(dispatch, "correlation_id"))
        try expectEqual(string(probe, "correlation_id"), string(dispatch, "correlation_id"))
    }

    @MainActor static func storeDepartureDiscards() async throws {
        let reader = Reader()
        reader.surfaces.value = [surface(2, pid: 200)]
        let (store, _, _) = makeStore(reader: reader, delay: 60_000_000)
        defer { store.cancel() }
        let recorded = record(["activation_outcome_probe", "activation_outcome_probe_discarded", "selection_action_dispatch"])
        defer { recorded.restore() }
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        try await waitFor { recorded.rows.value.contains { $0.0 == "selection_action_dispatch" } }
        store.handleAppActivation(pid: 200)
        store.handleAppActivation(pid: 300)
        try await waitFor { recorded.rows.value.contains { $0.0 == "activation_outcome_probe_discarded" } }
        let discard = recorded.rows.value.first { $0.0 == "activation_outcome_probe_discarded" }?.1
        try expectEqual(string(discard, "reason"), "user-departed")
        try expect(!recorded.rows.value.contains { $0.0 == "activation_outcome_probe" })
        try expectEqual(reader.reads.value, 0, "a departed selection is not measured")
    }

    @MainActor static func storeNewerSelectionDiscards() async throws {
        let reader = Reader()
        reader.surfaces.value = [surface(2, pid: 200), surface(3, pid: 300)]
        let (store, _, activator) = makeStore(reader: reader, delay: 150_000_000)
        defer { store.cancel() }
        let recorded = record(["activation_outcome_probe", "activation_outcome_probe_discarded", "selection_action_dispatch"])
        defer { recorded.restore() }
        await openSwitcher(store)
        store.selectedID = 2
        store.commitSelection()
        try await waitFor { recorded.rows.value.filter { $0.0 == "selection_action_dispatch" }.count == 1 }
        // Within the probe delay: the lane is already free for the next switch.
        await openSwitcher(store)
        store.selectedID = 3
        store.commitSelection()
        try await waitFor { activator.activatedItems.count == 2 }
        try await waitFor { recorded.rows.value.contains { $0.0 == "activation_outcome_probe_discarded" } }
        try await waitFor { recorded.rows.value.contains { $0.0 == "activation_outcome_probe" } }
        let discard = recorded.rows.value.first { $0.0 == "activation_outcome_probe_discarded" }?.1
        try expectEqual(string(discard, "reason"), "superseded")
        let probes = recorded.rows.value.filter { $0.0 == "activation_outcome_probe" }.map(\.1)
        try expectEqual(probes.count, 1, "only the newest selection is measured")
        guard case .int(let id)? = probes.first?["window_id"] else { return try expect(false) }
        try expectEqual(id, 3)
    }
}
