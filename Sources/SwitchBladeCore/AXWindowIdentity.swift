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
        read(element).id
    }

    /// Raw result for diagnostics. `Int32.min` means the symbol is missing;
    /// success with a zero ID is reported as `AXError.noValue`.
    static func read(_ element: AXUIElement) -> (id: CGWindowID?, error: Int32) {
        guard let readWindowID else { return (nil, Int32.min) }
        var id: CGWindowID = 0
        let error = readWindowID(element, &id)
        guard error == AXError.success.rawValue else { return (nil, error) }
        return id == 0 ? (nil, AXError.noValue.rawValue) : (id, 0)
    }
}
