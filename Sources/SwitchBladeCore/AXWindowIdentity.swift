import ApplicationServices
import CoreGraphics
import Darwin

/// Bridges an AX window to its WindowServer ID. This is an undocumented
/// system symbol, isolated here and resolved dynamically: absence or failure
/// must never degrade a concrete-window action into title/frame guessing.
enum AXWindowIdentity {
    private typealias ReadWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32

    /// Resolved once; lookup through RTLD_DEFAULT covers the linked
    /// ApplicationServices image.
    private static let readWindowID: ReadWindowID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_AXUIElementGetWindow") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ReadWindowID.self)
    }()

    /// Whether the system still exports the identity symbol.
    static var isAvailable: Bool { readWindowID != nil }

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let readWindowID else { return nil }
        var id: CGWindowID = 0
        guard readWindowID(element, &id) == AXError.success.rawValue, id != 0 else { return nil }
        return id
    }
}
