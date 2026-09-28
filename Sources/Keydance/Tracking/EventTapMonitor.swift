import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum TrackerState: Equatable {
    case permissionRequired
    case paused
    case running
    case secureInput
    case interrupted(String)

    var title: String {
        switch self {
        case .permissionRequired: return "Permission required"
        case .paused: return "Tracking paused"
        case .running: return "Tracking"
        case .secureInput: return "Secure Input active"
        case .interrupted: return "Tracker interrupted"
        }
    }
}

final class TrackingProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.keydance.analytics", qos: .utility)
    private var engine: TypingEngine
    private var timer: DispatchSourceTimer?
    private let onSummary: @Sendable (SessionSummary) -> Void
    private let onSnapshot: @Sendable (LiveSessionSnapshot) -> Void

    init(
        words: [String],
        onSummary: @escaping @Sendable (SessionSummary) -> Void,
        onSnapshot: @escaping @Sendable (LiveSessionSnapshot) -> Void = { _ in }
    ) {
        engine = TypingEngine(estimator: DictionaryEstimator(words: words))
        self.onSummary = onSummary
        self.onSnapshot = onSnapshot
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    deinit { timer?.cancel() }

    func consume(_ input: TypingInput) {
        queue.async { [weak self] in
            guard let self else { return }
            if let completed = self.engine.consume(input) {
                self.onSummary(completed)
            }
        }
    }

    func finishAndClear(completion: (@Sendable (Bool) -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self else { completion?(false); return }
            if let completed = self.engine.finalize() {
                self.onSummary(completed)
                completion?(true)
            } else {
                completion?(false)
            }
            self.engine.reset()
            self.onSnapshot(self.engine.diagnosticSnapshot())
        }
    }

    func clearEphemeral() {
        queue.async { [weak self] in
            self?.engine.clearEphemeral()
        }
    }

    func discardAndClear(completion: (@Sendable () -> Void)? = nil) {
        queue.async { [weak self] in
            self?.engine.reset()
            if let self { self.onSnapshot(self.engine.diagnosticSnapshot()) }
            completion?()
        }
    }

    private func tick() {
        if let completed = engine.advance(to: .now) { onSummary(completed) }
        onSnapshot(engine.diagnosticSnapshot())
    }
}

final class EventTapMonitor: @unchecked Sendable {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let processor: TrackingProcessor
    private var lastState: TrackerState = .paused
    private var pendingPointerDistance = 0.0
    private var pendingPointerEvents = 0
    private var lastPointerEmissionAt: Date?
    var onStateChange: (@Sendable (TrackerState) -> Void)?
    init(processor: TrackingProcessor) { self.processor = processor }

    var hasPermission: Bool { CGPreflightListenEventAccess() }
    var isRunning: Bool {
        guard let tap else { return false }
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
    }

    @discardableResult
    func requestPermission() -> Bool { CGRequestListenEventAccess() }

    func start() {
        if isRunning { setState(.running); return }
        stop(clear: false)
        guard hasPermission else { setState(.permissionRequired); return }
        let eventTypes: [CGEventType] = [
            .keyDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged,
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel
        ]
        let mask = eventTypes.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: Self.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            setState(.interrupted("macOS could not create the event tap."))
            return
        }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: tap, enable: true)
        setState(.running)
    }

    func stop(clear: Bool = true) {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        source = nil; tap = nil
        if clear { processor.finishAndClear() }
    }

    func checkHealth() {
        guard hasPermission else {
            if tap != nil { stop() }
            setState(.permissionRequired)
            return
        }
        guard let tap else { return }
        if IsSecureEventInputEnabled() {
            processor.clearEphemeral()
            setState(.secureInput)
        } else if !CGEvent.tapIsEnabled(tap: tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            setState(.interrupted("The event tap stopped and was re-enabled."))
        } else if lastState == .secureInput || lastState.isInterrupted {
            setState(.running)
        }
    }

    private static let callback: CGEventTapCallBack = { _, type, event, pointer in
        guard let pointer else { return Unmanaged.passUnretained(event) }
        let monitor = Unmanaged<EventTapMonitor>.fromOpaque(pointer).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            monitor.setState(.interrupted("The event tap was disabled and has been re-enabled."))
            return Unmanaged.passUnretained(event)
        }
        monitor.handle(event)
        return Unmanaged.passUnretained(event)
    }

    private func handle(_ event: CGEvent) {
        if IsSecureEventInputEnabled() {
            processor.clearEphemeral()
            setState(.secureInput)
            return
        }
        if lastState != .running { setState(.running) }
        let timestamp = Date()
        switch event.type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Double(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Double(event.getIntegerValueField(.mouseEventDeltaY))
            pendingPointerDistance += hypot(dx, dy)
            pendingPointerEvents += 1
            if lastPointerEmissionAt == nil || timestamp.timeIntervalSince(lastPointerEmissionAt!) >= 0.05 {
                processor.consume(.pointerMovement(distance: pendingPointerDistance, eventCount: pendingPointerEvents, at: timestamp))
                pendingPointerDistance = 0
                pendingPointerEvents = 0
                lastPointerEmissionAt = timestamp
            }
            return
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            processor.consume(.click(at: timestamp))
            return
        case .scrollWheel:
            let vertical = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            let horizontal = Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            processor.consume(.scroll(distance: hypot(vertical, horizontal), at: timestamp))
            return
        default:
            break
        }

        let flags = event.flags
        if !flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty {
            processor.consume(.shortcut(at: timestamp))
            return
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 51 || keyCode == 117 {
            processor.consume(.deletion(at: timestamp))
            return
        }
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 8)
        event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &length, unicodeString: &buffer)
        guard length > 0, let text = String(utf16CodeUnits: buffer, count: length).first else {
            processor.consume(.navigation(at: timestamp))
            return
        }
        if text.isWhitespace {
            processor.consume(.boundary(text, at: timestamp))
        } else if text.unicodeScalars.allSatisfy({ $0.properties.generalCategory != .control }) {
            let label = text.isLetter ? String(text).lowercased() : String(text)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            processor.consume(.printable(text, keyLabel: label, isRepeat: isRepeat, at: timestamp))
        } else {
            processor.consume(.navigation(at: timestamp))
        }
    }

    private func setState(_ state: TrackerState) {
        lastState = state
        onStateChange?(state)
    }
}

private extension TrackerState {
    var isInterrupted: Bool {
        if case .interrupted = self { return true }
        return false
    }
}
