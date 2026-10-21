import Foundation
import CoreGraphics

/// Turns touches from the phone into the right kind of macOS interaction.
///
/// The rule that makes this feel like an iPad rather than a remote mouse: a
/// window you are not already in cannot be operated by accident. Touching it
/// brings it forward and nothing else. Only the front window gets clicks,
/// drags, moves and resizes.
///
/// Everything arrives normalised to the display, so the phone never has to know
/// about scale factors, HiDPI backing stores, or how the video is fitted.
final class TouchRouter {

    private enum Role {
        case none
        case scroll
        case mouseDrag
        case move(window: WindowManager.Info, startFrame: CGRect)
        case resize(window: WindowManager.Info, edges: WindowManager.Edges, startFrame: CGRect)
    }

    private let input: InputController
    private var role: Role = .none
    private var dragStart: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var lastVelocity: CGPoint = .zero
    private var lastWindowUpdate: TimeInterval = 0

    /// User-facing scroll multiplier; 1.0 means content tracks the finger.
    var scrollSpeed: Double = 1.0
    var bounds: CGRect = .zero
    /// Reports what a drag turned out to be, so the phone can confirm it.
    var onRole: ((String) -> Void)?

    init(input: InputController) {
        self.input = input
    }

    // MARK: - Entry point

    func handle(_ message: [String: Any]) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        func number(_ key: String) -> Double {
            let value = (message[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? min(10_000, max(-10_000, value)) : 0
        }

        switch message["t"] as? String ?? "" {
        case "tap":
            tap(at: point(number("x"), number("y")),
                button: 0,
                clickState: (message["n"] as? NSNumber)?.intValue ?? 1)
        case "tap2":
            tap(at: point(number("x"), number("y")), button: 1, clickState: 1)
        case "dbeg":
            beginDrag(at: point(number("x"), number("y")),
                      forceContentDrag: (message["mode"] as? String) == "drag",
                      forceScroll: (message["mode"] as? String) == "scroll")
        case "dmov":
            moveDrag(to: point(number("x"), number("y")),
                     delta: CGPoint(x: number("dx") * bounds.width, y: number("dy") * bounds.height))
        case "dend":
            endDrag(velocity: CGPoint(x: number("vx") * bounds.width, y: number("vy") * bounds.height))
        case "pinch":
            input.zoom(delta: number("d") * bounds.width * 0.5)
        case "sw":
            input.swipe(message["d"] as? String ?? "")
        case "win":
            windowAction(message["a"] as? String ?? "",
                         at: message["x"] != nil ? point(number("x"), number("y")) : nil)
        default:
            break
        }
    }

    private func point(_ nx: Double, _ ny: Double) -> CGPoint {
        CGPoint(x: bounds.minX + min(max(nx, 0), 1) * bounds.width,
                y: bounds.minY + min(max(ny, 0), 1) * bounds.height)
    }

    private func normalised(_ p: CGPoint) -> (Double, Double) {
        guard bounds.width > 0, bounds.height > 0 else { return (0, 0) }
        return (Double((p.x - bounds.minX) / bounds.width),
                Double((p.y - bounds.minY) / bounds.height))
    }

    // MARK: - Taps

    private func tap(at p: CGPoint, button: Int, clickState: Int) {
        if button == 0, clickState >= 2,
           let window = WindowManager.window(at: p), WindowManager.isFront(window),
           case .titleBar = WindowManager.region(of: window, at: p) {
            // Same as double-clicking a title bar on the Mac itself.
            WindowManager.zoom(window)
            onRole?("zoom")
            return
        }
        if let window = WindowManager.window(at: p), !WindowManager.isFront(window) {
            // First touch on a background window only brings it forward — the
            // same protection an iPad gives you against fat-fingering a button
            // in an app you were not even looking at.
            WindowManager.focus(window)
            onRole?("focus")
            return
        }
        let (nx, ny) = normalised(p)
        input.click(nx: nx, ny: ny, button: button, clickState: clickState)
    }

    // MARK: - Window actions

    private func windowAction(_ action: String, at p: CGPoint?) {
        let target: WindowManager.Info?
        if let p { target = WindowManager.window(at: p) } else { target = WindowManager.frontWindow() }
        guard let window = target else { return }

        switch action {
        case "close":    WindowManager.close(window)
        case "min":      WindowManager.minimize(window)
        case "zoom":     WindowManager.zoom(window)
        case "full", "left", "right", "top", "bottom":
            WindowManager.tile(window, to: action, within: bounds)
        default: break
        }
        onRole?(action)
    }

    // MARK: - Drags

    private func beginDrag(at p: CGPoint, forceContentDrag: Bool, forceScroll: Bool) {
        cancel()
        lastWindowUpdate = 0
        dragStart = p
        lastPoint = p
        lastVelocity = .zero

        guard let window = WindowManager.window(at: p) else {
            startScroll(at: p, contentDrag: forceContentDrag)
            return
        }

        if !WindowManager.isFront(window) {
            WindowManager.focus(window)
            onRole?("focus")
            // Focus consumes this gesture. Do not scroll a newly focused app.
            return
        }
        if forceScroll {
            startScroll(at: p, contentDrag: false)
            return
        }

        let frame = WindowManager.liveFrame(window) ?? window.frame
        switch WindowManager.region(of: window, at: p) {
        case .titleBar:
            role = .move(window: window, startFrame: frame)
            onRole?("move")
        case .resize(let edges):
            role = .resize(window: window, edges: edges, startFrame: frame)
            onRole?("resize")
        case .content:
            startScroll(at: p, contentDrag: forceContentDrag)
        }
    }

    private func startScroll(at p: CGPoint, contentDrag: Bool) {
        let (nx, ny) = normalised(p)
        input.move(nx: nx, ny: ny)
        if contentDrag {
            role = .mouseDrag
            input.down(button: 0)
            onRole?("drag")
        } else {
            role = .scroll
            input.scrollBegin()
            onRole?("scroll")
        }
    }

    private func moveDrag(to p: CGPoint, delta: CGPoint) {
        defer { lastPoint = p }

        switch role {
        case .scroll:
            lastVelocity = delta
            input.scroll(dx: Double(delta.x) * scrollSpeed, dy: Double(delta.y) * scrollSpeed)

        case .mouseDrag:
            let (nx, ny) = normalised(p)
            input.drag(nx: nx, ny: ny, button: 0)

        case .move(let window, let startFrame):
            guard throttleWindowUpdate() else { return }
            let origin = CGPoint(x: startFrame.minX + (p.x - dragStart.x),
                                 y: startFrame.minY + (p.y - dragStart.y))
            WindowManager.setFrame(window, origin: origin, size: nil)

        case .resize(let window, let edges, let startFrame):
            guard throttleWindowUpdate() else { return }
            var frame = startFrame
            let dx = p.x - dragStart.x
            let dy = p.y - dragStart.y
            if edges.contains(.right)  { frame.size.width += dx }
            if edges.contains(.bottom) { frame.size.height += dy }
            if edges.contains(.left)   { frame.origin.x += dx; frame.size.width -= dx }
            if edges.contains(.top)    { frame.origin.y += dy; frame.size.height -= dy }
            if frame.width < 200 {
                frame.size.width = 200
                if edges.contains(.left) { frame.origin.x = startFrame.maxX - 200 }
            }
            if frame.height < 120 {
                frame.size.height = 120
                if edges.contains(.top) { frame.origin.y = startFrame.maxY - 120 }
            }
            WindowManager.setFrame(window, origin: frame.origin, size: frame.size)

        case .none:
            break
        }
    }

    private func endDrag(velocity: CGPoint) {
        switch role {
        case .move, .resize:
            // Apply the final sample even when it was throttled during movement.
            lastWindowUpdate = 0
            moveDrag(to: lastPoint, delta: .zero)
        case .scroll:
            input.scrollEnd(velocityX: Double(velocity.x) * scrollSpeed,
                            velocityY: Double(velocity.y) * scrollSpeed)
        case .mouseDrag:
            input.up(button: 0)
        default:
            break
        }
        role = .none
    }

    /// Accessibility calls cross a process boundary and are far too slow to run
    /// on every touch sample.
    private func throttleWindowUpdate() -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastWindowUpdate > 1.0 / 60 else { return false }
        lastWindowUpdate = now
        return true
    }

    func cancel() {
        if case .mouseDrag = role { input.up(button: 0) }
        input.cancelScroll()
        role = .none
    }
}
