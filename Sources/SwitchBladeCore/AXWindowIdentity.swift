import ApplicationServices
import CoreGraphics
import Darwin

/// Bridges an AX window to its WindowServer ID. This is an undocumented
/// system symbol, isolated here and resolved dynamically: absence or failure
/// must never degrade a concrete-window action into title/frame guessing.
enum AXWindowIdentity {
    private typealias ReadWindowID = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> Int32

    static func windowID(of element: AXUIElement) -> CGWindowID? {
        guard let process = dlopen(nil, RTLD_LAZY) else { return nil }
        defer { dlclose(process) }
        guard let symbol = dlsym(process, "_AXUIElementGetWindow") else { return nil }
        let read = unsafeBitCast(symbol, to: ReadWindowID.self)
        var id: CGWindowID = 0
        guard read(element, &id) == AXError.success.rawValue, id != 0 else { return nil }
        return id
    }
}
