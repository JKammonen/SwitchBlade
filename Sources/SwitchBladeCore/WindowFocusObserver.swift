import AppKit
import ApplicationServices

/// Capture the AX window while its app is foreground; resolve that same
/// element off-main even if the app reports another focused window later.
struct WindowFocusCapture: Sendable {
    let pid: pid_t
    let diagnosticID: String
    let invalidatesMembership: Bool
    let resolve: @Sendable () -> WindowItem?

    init(pid: pid_t, invalidatesMembership: Bool = true, diagnosticID: String = UUID().uuidString,
         resolve: @escaping @Sendable () -> WindowItem?) {
        self.pid = pid
        self.diagnosticID = diagnosticID
        self.invalidatesMembership = invalidatesMembership
        self.resolve = resolve
    }
}

@MainActor
protocol WindowFocusObserving: AnyObject {
    var onFocus: ((WindowFocusCapture) -> Void)? { get set }
    var shouldCaptureFocus: (() -> Bool)? { get set }
    func observe(pid: pid_t?)
    func cancelPendingFocusReads()
}

extension WindowFocusObserving {
    var shouldCaptureFocus: (() -> Bool)? {
        get { nil }
        set { }
    }
    func cancelPendingFocusReads() { }
}

/// AX registration can fail with cannotComplete during app activation. Retry
/// once after activation settles; changing app cancels the old retry entirely.
@MainActor
final class WindowFocusRegistration {
    private let attempt: (pid_t, Int) -> AXError
    private let reset: () -> Void
    private let retryDelay: UInt64
    private var desiredPID: pid_t?
    private(set) var registeredPID: pid_t?
    private var generation = 0
    private var retryTask: Task<Void, Never>?

    init(retryDelay: UInt64 = 150_000_000,
         attempt: @escaping (pid_t, Int) -> AXError, reset: @escaping () -> Void) {
        self.retryDelay = retryDelay
        self.attempt = attempt
        self.reset = reset
    }

    func observe(pid: pid_t?) {
        let unchanged = desiredPID == pid && (registeredPID == pid || retryTask != nil)
        PerformanceDiagnostics.record("focus_observer_request", fields: [
            "pid": .int(Int(pid ?? -1)), "previous_desired_pid": .int(Int(desiredPID ?? -1)),
            "registered_pid": .int(Int(registeredPID ?? -1)), "retry_pending": .bool(retryTask != nil),
            "outcome": .string(unchanged ? "unchanged" : (pid == nil ? "stop" : "register"))
        ])
        if unchanged { return }
        generation &+= 1
        retryTask?.cancel()
        retryTask = nil
        registeredPID = nil
        reset()
        desiredPID = pid
        guard let pid else { return }
        register(pid: pid, generation: generation, attemptIndex: 0)
    }

    private func register(pid: pid_t, generation: Int, attemptIndex: Int) {
        guard desiredPID == pid, self.generation == generation else { return }
        let start = ProcessInfo.processInfo.systemUptime
        let result = attempt(pid, attemptIndex)
        PerformanceDiagnostics.record("window_focus_observer", fields: [
            "pid": .int(Int(pid)), "registration_result": .int(Int(result.rawValue)),
            "attempt": .int(attemptIndex),
            "milliseconds": .double((ProcessInfo.processInfo.systemUptime - start) * 1000)
        ])
        if result == .success {
            registeredPID = pid
        } else if result == .cannotComplete, attemptIndex == 0 {
            let delay = retryDelay
            retryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: delay)
                guard let self, !Task.isCancelled, self.generation == generation,
                      self.desiredPID == pid else { return }
                self.retryTask = nil
                self.register(pid: pid, generation: generation, attemptIndex: 1)
            }
        }
    }

    deinit { retryTask?.cancel() }
}

/// Keep successful subscriptions while retrying only missing coverage.
struct WindowFocusSubscriptions {
    static let notifications = [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification,
                                kAXWindowCreatedNotification]
    private(set) var registered = Set<String>()

    mutating func register(using add: (String) -> AXError) -> [AXError] {
        Self.notifications.map { notification in
            if registered.contains(notification) { return .success }
            let result = add(notification)
            if result == .success || result == .notificationAlreadyRegistered {
                registered.insert(notification)
                return .success
            }
            return result
        }
    }
}

@MainActor
final class WindowFocusObserver: WindowFocusObserving {
    var onFocus: ((WindowFocusCapture) -> Void)?
    var shouldCaptureFocus: (() -> Bool)?
    private let catalog: WindowCatalog
    private var registration: Registration?
    private var observedPID: pid_t?
    private lazy var captureDriver = WindowFocusReadRecovery(
        frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        isAllowed: { [weak self] in self?.shouldCaptureFocus?() ?? (self != nil) },
        read: { [weak self] request in
            self?.readFocus(request) ?? .failure(.invalidUIElement, "discarded-no-registration")
        }, deliver: { [weak self] capture in self?.onFocus?(capture) }
    )
    private lazy var registrationDriver = WindowFocusRegistration(
        attempt: { [weak self] pid, attempt in
            self?.installObservation(pid: pid, attemptIndex: attempt) ?? .failure
        }, reset: { [weak self] in self?.registration = nil }
    )

    // These immutable CF handles may be released from deinit off-main. The
    // observer itself only delivers on the main run loop.
    private final class Registration: @unchecked Sendable {
        let observer: AXObserver
        let application: AXUIElement
        // Only the main-actor owner mutates subscription coverage.
        var subscriptions = WindowFocusSubscriptions()
        init(observer: AXObserver, application: AXUIElement) {
            self.observer = observer
            self.application = application
        }
        deinit {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    private struct CapturedWindow: @unchecked Sendable {
        let element: AXUIElement
    }

    init(catalog: WindowCatalog) { self.catalog = catalog }

    func observe(pid: pid_t?) {
        cancelPendingFocusReads()
        observedPID = pid == getpid() ? nil : pid
        registrationDriver.observe(pid: observedPID)
    }

    func cancelPendingFocusReads() { captureDriver.cancel(reason: "observer-or-action-change") }

    private func installObservation(pid: pid_t, attemptIndex: Int) -> AXError {
        guard AXIsProcessTrusted() else { return .apiDisabled }
        let candidate: Registration
        if let registration {
            candidate = registration
        } else {
            let application = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(application, 0.05)
            var observer: AXObserver?
            let status = AXObserverCreate(pid, { _, _, notification, context in
                guard let context else { return }
                MainActor.assumeIsolated {
                    Unmanaged<WindowFocusObserver>.fromOpaque(context).takeUnretainedValue()
                        .captureFocus(trigger: WindowFocusObserver.diagnosticTrigger(notification as String))
                }
            }, &observer)
            guard status == .success, let observer else { return status == .success ? .failure : status }
            candidate = Registration(observer: observer, application: application)
        }
        // Additional notifications only trigger a read of actual focus; a
        // created/main window is never assumed to be the focused one.
        let results = candidate.subscriptions.register {
            AXObserverAddNotification(candidate.observer, candidate.application, $0 as CFString,
                                      Unmanaged.passUnretained(self).toOpaque())
        }
        PerformanceDiagnostics.record("window_focus_subscriptions", fields: [
            "pid": .int(Int(pid)), "attempt": .int(attemptIndex),
            "focused_result": .int(Int(results[0].rawValue)),
            "main_result": .int(Int(results[1].rawValue)),
            "created_result": .int(Int(results[2].rawValue)),
            "registered_count": .int(candidate.subscriptions.registered.count)
        ])
        if !candidate.subscriptions.registered.isEmpty {
            if registration == nil {
                registration = candidate
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(candidate.observer), .commonModes)
                captureFocus(invalidatesMembership: false, trigger: "registration")
            }
            // A subscription retry only repairs coverage. A new read here
            // could outlive a self-action's cancellation and rank its sibling.
        }
        if attemptIndex == 0, results.contains(.cannotComplete) { return .cannotComplete }
        return candidate.subscriptions.registered.isEmpty ? (results.first ?? .failure) : .success
    }

    private static func diagnosticTrigger(_ notification: String) -> String {
        switch notification {
        case kAXFocusedWindowChangedNotification: return "focused-window-changed"
        case kAXMainWindowChangedNotification: return "main-window-changed"
        case kAXWindowCreatedNotification: return "window-created"
        default: return "other-notification"
        }
    }

    private func captureFocus(invalidatesMembership: Bool = true, trigger: String) {
        guard let pid = observedPID else { return }
        captureDriver.capture(pid: pid, trigger: trigger, invalidatesMembership: invalidatesMembership)
    }

    private func readFocus(_ request: WindowFocusReadRecovery.Request) -> WindowFocusReadRecovery.Result {
        guard observedPID == request.pid, let registration else {
            return .failure(.invalidUIElement, "discarded-no-registration")
        }
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(
            registration.application, kAXFocusedWindowAttribute as CFString, &value
        )
        guard error == .success else { return .failure(error, "ax-error") }
        guard let value else { return .failure(.success, "missing-value") }
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return .failure(.success, "unexpected-value-type")
        }
        let window = value as! AXUIElement
        let captured = CapturedWindow(element: window)
        let catalog = catalog
        return .captured(WindowFocusCapture(pid: request.pid, invalidatesMembership: request.invalidatesMembership,
                                            diagnosticID: request.diagnosticID, resolve: {
            catalog.observedWindowItem(pid: request.pid, window: captured.element)
        }))
    }
}
