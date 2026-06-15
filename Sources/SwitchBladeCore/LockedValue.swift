import Foundation

/// NSLock-backed value cell that can be read and written from any isolation
/// context. Used as a Sendable bridge for state mirrored from @MainActor
/// settings (current language, "restrict to current Space", etc.) so non-actor
/// hot paths can read it without an actor hop.
public final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T

    public init(_ initial: T) { _value = initial }

    public var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }

    @discardableResult
    public func withValue<R>(_ body: (inout T) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&_value)
    }
}
