import AppKit
import CoreGraphics

/// One on-screen WindowServer surface, front-to-back. Titles are never read:
/// the probe needs identity, owner, layer and geometry only.
struct WindowStackSurface: Equatable, Sendable {
    let windowID: CGWindowID
    let ownerPID: pid_t
    let layer: Int
    let bounds: CGRect
    let alpha: Double
}

protocol WindowStackReading: Sendable {
    /// On-screen surfaces in WindowServer front-to-back order.
    func onScreenSurfacesFrontToBack() -> [WindowStackSurface]
    func frontmostApplicationPID() -> pid_t?
}

struct SystemWindowStackReader: WindowStackReading {
    func onScreenSurfacesFrontToBack() -> [WindowStackSurface] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            guard let id = entry[kCGWindowNumber as String] as? UInt32,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let layer = entry[kCGWindowLayer as String] as? Int,
                  let boundsDictionary = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { return nil }
            let alpha = (entry[kCGWindowAlpha as String] as? Double) ?? 1
            return WindowStackSurface(windowID: id, ownerPID: pid, layer: layer, bounds: bounds, alpha: alpha)
        }
    }

    func frontmostApplicationPID() -> pid_t? {
        NSWorkspace.shared.frontmostApplication?.processIdentifier
    }
}

/// Diagnostic only: whether the selected window is actually on screen after a
/// reported switch, and which normal-level windows lie above it. App activity
/// and AX focus of the matched element do not prove visibility; another app's
/// window can remain on top. Nothing here changes switching behavior.
enum ActivationOutcomeProbe {
    static let maximumListedCoveringWindows = 8
    private static let normalLayer = Int(CGWindowLevelForKey(.normalWindow))

    /// Normal application windows, including the Electron layer just below
    /// normal that listing admits with AX validation.
    static func isNormalStackLayer(_ layer: Int) -> Bool {
        layer == normalLayer || WindowLayerEligibilityPolicy.requiresStandardAXMatch(layer: layer)
    }

    struct Measurement: Equatable, Sendable {
        let frontmostPID: pid_t?
        let targetOnScreen: Bool
        let targetLayer: Int?
        let coveringWindowIDs: [CGWindowID]
        let coveringOwnerPIDs: [pid_t]
        let coveringOtherAppCount: Int
        let coveringSameAppCount: Int
        /// Largest single-window share of the target's area, 0...1.
        let maximumCoverFraction: Double

        var coveringCount: Int { coveringOtherAppCount + coveringSameAppCount }
    }

    /// A surface covers the target when it is listed before it, is a
    /// normal-level window (including the Electron layer just below normal),
    /// is not fully transparent, is not SwitchBlade's own panel, and overlaps.
    static func measure(
        targetWindowID: CGWindowID,
        targetPID: pid_t,
        targetOwnerPID: pid_t,
        ownPID: pid_t,
        surfaces: [WindowStackSurface],
        frontmostPID: pid_t?
    ) -> Measurement {
        guard let index = surfaces.firstIndex(where: { $0.windowID == targetWindowID }) else {
            return Measurement(frontmostPID: frontmostPID, targetOnScreen: false, targetLayer: nil,
                               coveringWindowIDs: [], coveringOwnerPIDs: [], coveringOtherAppCount: 0,
                               coveringSameAppCount: 0, maximumCoverFraction: 0)
        }
        let target = surfaces[index]
        let targetArea = target.bounds.width * target.bounds.height
        var ids: [CGWindowID] = []
        var owners = Set<pid_t>()
        var other = 0
        var same = 0
        var maximumFraction = 0.0
        for surface in surfaces[..<index] {
            guard isNormalStackLayer(surface.layer),
                  surface.alpha > 0, surface.ownerPID != ownPID else { continue }
            let overlap = surface.bounds.intersection(target.bounds)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            if surface.ownerPID == targetPID || surface.ownerPID == targetOwnerPID { same += 1 } else { other += 1 }
            owners.insert(surface.ownerPID)
            ids.append(surface.windowID)
            if targetArea > 0 {
                maximumFraction = max(maximumFraction, Double(overlap.width * overlap.height / targetArea))
            }
        }
        return Measurement(
            frontmostPID: frontmostPID, targetOnScreen: true, targetLayer: target.layer,
            coveringWindowIDs: ids, coveringOwnerPIDs: owners.sorted(),
            coveringOtherAppCount: other, coveringSameAppCount: same,
            maximumCoverFraction: min(1, maximumFraction)
        )
    }

    static func fields(for measurement: Measurement, targetPID: pid_t) -> [String: PerformanceMetricValue] {
        func list<T: BinaryInteger>(_ values: [T]) -> String {
            values.prefix(maximumListedCoveringWindows).map { String($0) }.joined(separator: ",")
        }
        return [
            "frontmost_pid": .int(Int(measurement.frontmostPID ?? -1)),
            "target_app_frontmost": .bool(measurement.frontmostPID == targetPID),
            "target_on_screen": .bool(measurement.targetOnScreen),
            "target_layer": .int(measurement.targetLayer ?? Int(Int32.min)),
            "covering_count": .int(measurement.coveringCount),
            "covering_other_app_count": .int(measurement.coveringOtherAppCount),
            "covering_same_app_count": .int(measurement.coveringSameAppCount),
            "covering_max_fraction": .double(measurement.maximumCoverFraction),
            "covering_window_ids": .string(list(measurement.coveringWindowIDs)),
            "covering_owner_pids": .string(list(measurement.coveringOwnerPIDs))
        ]
    }
}
