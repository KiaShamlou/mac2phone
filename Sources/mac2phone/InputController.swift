import Foundation
import CoreGraphics
import ApplicationServices

/// Turns touch / keyboard messages from the phone into real macOS events.
final class InputController {

    /// Global CoreGraphics bounds of the display being mirrored.
    var bounds: CGRect = .zero
    var enabled: Bool = true { willSet { if !newValue { releaseAll() } } }

    private var lastPoint: CGPoint = .zero
    private var downButtons = Set<Int>()
    private var scrolling = false
    private var momentumWork: DispatchWorkItem?
    private var momentumActive = false
    private var momentumGeneration = 0
    /// Tests can inspect events without posting input to the user's desktop.
    struct Event {
        let type: CGEventType
        var scrollPhase: Int64 = 0
        var momentumPhase: Int64 = 0
    }
    var eventObserver: ((Event) -> Void)?
    private lazy var source = CGEventSource(stateID: .hidSystemState)

    var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func requestAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // MARK: - Pointer

    /// nx / ny are normalised 0...1 inside the mirrored display.
    func move(nx: Double, ny: Double) {
        guard enabled, nx.isFinite, ny.isFinite else { return }
        lastPoint = point(nx: nx, ny: ny)
        post(type: .mouseMoved, button: .left, at: lastPoint, clickCount: 0)
    }

    func down(button: Int) {
        guard enabled else { return }
        guard (0...2).contains(button), downButtons.insert(button).inserted else { return }
        post(type: downType(button), button: cgButton(button), at: lastPoint, clickCount: 1)
    }

    func up(button: Int) {
        guard enabled else { return }
        guard downButtons.remove(button) != nil else { return }
        post(type: upType(button), button: cgButton(button), at: lastPoint, clickCount: 1)
    }

    /// `clickState` is the position in a click series: 1 for a first click, 2 for
    /// the second of a double-click. macOS decides "double-click" from this field,
    /// so the first tap can be delivered immediately instead of waiting to see
    /// whether a second one is coming.
    func click(nx: Double, ny: Double, button: Int, clickState: Int = 1) {
        guard enabled, nx.isFinite, ny.isFinite else { return }
        lastPoint = point(nx: nx, ny: ny)
        post(type: .mouseMoved, button: .left, at: lastPoint, clickCount: 0)
        let state = max(1, min(3, clickState))
        post(type: downType(button), button: cgButton(button), at: lastPoint, clickCount: state)
        post(type: upType(button), button: cgButton(button), at: lastPoint, clickCount: state)
    }

    func drag(nx: Double, ny: Double, button: Int) {
        guard enabled, nx.isFinite, ny.isFinite else { return }
        lastPoint = point(nx: nx, ny: ny)
        let type: CGEventType = button == 1 ? .rightMouseDragged : .leftMouseDragged
        post(type: type, button: cgButton(button), at: lastPoint, clickCount: 1)
    }

    // MARK: - Trackpad

    /// macOS has no touch input, but it does have trackpad events. Sending those
    /// instead of plain wheel ticks is what gives rubber-banding, inertia and
    /// per-pixel precision — the difference between "a mouse" and "a trackpad".
    private enum ScrollField {
        static let isContinuous  = CGEventField(rawValue: 88)!
        static let scrollPhase   = CGEventField(rawValue: 99)!
        static let momentumPhase = CGEventField(rawValue: 123)!
    }

    private enum ScrollPhase: Int64 {
        case none = 0, began = 1, changed = 2, ended = 4
    }

    func scrollBegin() {
        guard enabled else { return }
        cancelScroll()
        scrolling = true
        postScroll(dx: 0, dy: 0, phase: .began, momentum: 0)
    }

    func scroll(dx: Double, dy: Double) {
        guard enabled, dx.isFinite, dy.isFinite else { return }
        if !scrolling { scrollBegin() }
        postScroll(dx: dx, dy: dy, phase: .changed, momentum: 0)
    }

    func scrollEnd(velocityX: Double, velocityY: Double) {
        guard scrolling else { return }
        scrolling = false
        postScroll(dx: 0, dy: 0, phase: .ended, momentum: 0)
        guard enabled, velocityX.isFinite, velocityY.isFinite,
              max(abs(velocityX), abs(velocityY)) > 4 else { return }
        let generation = momentumGeneration
        momentumActive = true
        momentumStep(vx: min(150, max(-150, velocityX)),
                     vy: min(150, max(-150, velocityY)), step: 0, generation: generation)
    }

    private func momentumStep(vx: Double, vy: Double, step: Int, generation: Int) {
        guard enabled, generation == momentumGeneration, momentumActive else { return }
        guard step < 45, max(abs(vx), abs(vy)) > 0.5 else {
            cancelScroll()
            return
        }
        postScroll(dx: vx, dy: vy, phase: .none, momentum: step == 0 ? 1 : 2)
        let work = DispatchWorkItem { [weak self] in
            self?.momentumStep(vx: vx * 0.90, vy: vy * 0.90, step: step + 1, generation: generation)
        }
        momentumWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60, execute: work)
    }

    func cancelScroll() {
        momentumGeneration &+= 1
        momentumWork?.cancel()
        momentumWork = nil
        if scrolling { postScroll(dx: 0, dy: 0, phase: .ended, momentum: 0) }
        if momentumActive { postScroll(dx: 0, dy: 0, phase: .none, momentum: 3) }
        scrolling = false
        momentumActive = false
    }

    private func postScroll(dx: Double, dy: Double, phase: ScrollPhase, momentum: Int64) {
        if let eventObserver {
            eventObserver(Event(type: .scrollWheel, scrollPhase: phase.rawValue, momentumPhase: momentum))
            return
        }
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(min(10_000, max(-10_000, dy)).rounded()),
                                  wheel2: Int32(min(10_000, max(-10_000, dx)).rounded()),
                                  wheel3: 0) else { return }
        event.setIntegerValueField(ScrollField.isContinuous, value: 1)
        event.setIntegerValueField(ScrollField.scrollPhase, value: phase.rawValue)
        event.setIntegerValueField(ScrollField.momentumPhase, value: momentum)
        emit(event)
    }

    /// Pinch. Real magnify gesture events need private CoreGraphics fields that
    /// Apple does not publish, so this rides command+scroll instead: the same
    /// thing a trackpad pinch ends up doing in Preview, Safari, Maps, Finder,
    /// and every editor that supports zoom.
    func zoom(delta: Double) {
        guard enabled, delta.isFinite else { return }
        guard let event = CGEvent(scrollWheelEvent2Source: source,
                                  units: .pixel,
                                  wheelCount: 2,
                                  wheel1: Int32(min(10_000, max(-10_000, delta)).rounded()),
                                  wheel2: 0,
                                  wheel3: 0) else { return }
        event.setIntegerValueField(ScrollField.isContinuous, value: 1)
        event.flags = .maskCommand
        emit(event)
    }

    /// Three-finger swipes. Mission Control and the space switcher answer to
    /// control+arrow, which behaves identically and needs no private API.
    func swipe(_ direction: String) {
        switch direction {
        case "left":  key("left",  modifiers: ["ctrl"])
        case "right": key("right", modifiers: ["ctrl"])
        case "up":    key("up",    modifiers: ["ctrl"])
        case "down":  key("down",  modifiers: ["ctrl"])
        default: break
        }
    }

    /// Trackpad mode: nudge the pointer from wherever it already is, so a small
    /// phone screen can still reach every pixel of a large desktop.
    func moveRelative(dx: Double, dy: Double, dragging: Bool) {
        guard enabled, dx.isFinite, dy.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let current = CGEvent(source: nil)?.location ?? lastPoint
        var point = CGPoint(x: current.x + dx, y: current.y + dy)
        point.x = min(max(point.x, bounds.minX), bounds.maxX - 1)
        point.y = min(max(point.y, bounds.minY), bounds.maxY - 1)
        lastPoint = point
        if dragging {
            post(type: .leftMouseDragged, button: .left, at: point, clickCount: 1)
        } else {
            post(type: .mouseMoved, button: .left, at: point, clickCount: 0)
        }
    }

    /// Click wherever the pointer currently is (trackpad mode taps).
    func clickHere(button: Int, clickState: Int = 1) {
        guard enabled else { return }
        lastPoint = CGEvent(source: nil)?.location ?? lastPoint
        let state = max(1, min(3, clickState))
        post(type: downType(button), button: cgButton(button), at: lastPoint, clickCount: state)
        post(type: upType(button), button: cgButton(button), at: lastPoint, clickCount: state)
    }

    // MARK: - Keyboard

    /// Types arbitrary text without needing a keycode for every character.
    func type(text: String) {
        guard enabled, !text.isEmpty else { return }
        for chunk in text.chunked(by: 16) {
            let units = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { continue }
            down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            up.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            emit(down)
            emit(up)
        }
    }

    func key(_ name: String, modifiers: [String]) {
        guard enabled, let code = InputController.keyCodes[name.lowercased()] else { return }
        var flags: CGEventFlags = []
        for m in modifiers {
            switch m.lowercased() {
            case "cmd", "command", "meta": flags.insert(.maskCommand)
            case "shift":                  flags.insert(.maskShift)
            case "alt", "option":          flags.insert(.maskAlternate)
            case "ctrl", "control":        flags.insert(.maskControl)
            case "fn":                     flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)
        else { return }
        down.flags = flags
        up.flags = flags
        emit(down)
        emit(up)
    }

    /// Releases anything left held down when a client disconnects.
    func releaseAll() {
        cancelScroll()
        for b in downButtons {
            post(type: upType(b), button: cgButton(b), at: lastPoint, clickCount: 1)
        }
        downButtons.removeAll()
    }

    // MARK: - Helpers

    private func point(nx: Double, ny: Double) -> CGPoint {
        let x = bounds.minX + min(max(nx, 0), 1) * bounds.width
        let y = bounds.minY + min(max(ny, 0), 1) * bounds.height
        return CGPoint(x: x, y: y)
    }

    private func cgButton(_ b: Int) -> CGMouseButton {
        switch b {
        case 1: return .right
        case 2: return .center
        default: return .left
        }
    }

    private func downType(_ b: Int) -> CGEventType {
        switch b {
        case 1: return .rightMouseDown
        case 2: return .otherMouseDown
        default: return .leftMouseDown
        }
    }

    private func upType(_ b: Int) -> CGEventType {
        switch b {
        case 1: return .rightMouseUp
        case 2: return .otherMouseUp
        default: return .leftMouseUp
        }
    }

    private func post(type: CGEventType, button: CGMouseButton, at p: CGPoint, clickCount: Int) {
        if let eventObserver { eventObserver(Event(type: type)); return }
        guard let event = CGEvent(mouseEventSource: source,
                                  mouseType: type,
                                  mouseCursorPosition: p,
                                  mouseButton: button) else { return }
        if clickCount > 0 {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        emit(event)
    }

    private func emit(_ event: CGEvent) {
        if let eventObserver { eventObserver(Event(type: event.type)) }
        else { event.post(tap: .cghidEventTap) }
    }

    /// ANSI virtual key codes.
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "equal": 24, "minus": 27, "rightbracket": 30, "leftbracket": 33, "backslash": 42,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "quote": 39, "semicolon": 41, "comma": 43, "slash": 44, "period": 47, "grave": 50,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]
}

private extension String {
    func chunked(by size: Int) -> [String] {
        guard count > size else { return [self] }
        var result: [String] = []
        var current = ""
        for ch in self {
            current.append(ch)
            if current.count == size { result.append(current); current = "" }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
