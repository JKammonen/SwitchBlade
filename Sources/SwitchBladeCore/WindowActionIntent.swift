import Foundation

/// Invalidates future native side effects; an OS call already issued cannot be recalled.
final class WindowActionIntent: @unchecked Sendable {
    private let valid = LockedValue(true)
    var isValid: Bool { valid.value }
    func invalidate() { valid.value = false }

    @TaskLocal static var current: WindowActionIntent?
    static var permitsSideEffect: Bool { current?.isValid ?? true }
}
