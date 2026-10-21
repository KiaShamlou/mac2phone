import SwiftUI
import UIKit
import AVFoundation

/// Bridge so SwiftUI chrome can drive the UIKit surface.
final class MirrorController: ObservableObject {
    @Published var controlEnabled = false { didSet { view?.controlEnabled = controlEnabled } }
    /// 0 = iPad, 1 = direct pointer, 2 = trackpad. See `ControlStyle`.
    @Published var controlStyle = 0 { didSet { view?.controlStyle = ControlStyle(rawValue: controlStyle) ?? .ipad } }
    @Published var swipeReversed = false { didSet { view?.swipeReversed = swipeReversed } }
    @Published var keyboardVisible = false
    @Published var viewportSize: CGSize = .zero
    fileprivate weak var view: MirrorUIView?

    func cancelInteraction() { view?.cancelInteraction(); view?.resignFirstResponder(); keyboardVisible = false }
    func fit() { view?.fitToScreen(animated: true) }
    func actualSize() { view?.zoomToActualSize() }
    func toggleKeyboard() {
        guard let view else { return }
        if view.isFirstResponder {
            view.resignFirstResponder()
            keyboardVisible = false
        } else {
            view.becomeFirstResponder()
            keyboardVisible = true
        }
    }
}

struct MirrorView: UIViewRepresentable {
    // Observed, not just held: the surface has to resize the moment the Mac
    // reports its video dimensions, otherwise the video layer stays 0x0.
    @ObservedObject var client: StreamClient
    @ObservedObject var controller: MirrorController
    var controlsHeight: CGFloat = 0
    var topOverlayHeight: CGFloat = 0

    func makeUIView(context: Context) -> MirrorUIView {
        let view = MirrorUIView()
        view.client = client
        view.controlEnabled = controller.controlEnabled
        view.controlStyle = ControlStyle(rawValue: controller.controlStyle) ?? .ipad
        view.swipeReversed = controller.swipeReversed
        view.onViewportSizeChanged = { [weak controller] size in
            DispatchQueue.main.async { controller?.viewportSize = size }
        }
        view.onKeyboardVisibilityChanged = { [weak controller] in controller?.keyboardVisible = $0 }
        controller.view = view
        return view
    }

    func updateUIView(_ view: MirrorUIView, context: Context) {
        view.client = client
        view.controlEnabled = controller.controlEnabled
        view.controlStyle = ControlStyle(rawValue: controller.controlStyle) ?? .ipad
        view.swipeReversed = controller.swipeReversed
        view.videoSize = client.videoSize
        view.controlsHeight = controlsHeight
        view.topOverlayHeight = topOverlayHeight
    }
}

// MARK: - The surface itself

final class MirrorUIView: UIView, UIKeyInput {

    var client: StreamClient? {
        didSet {
            guard oldValue !== client, let client else { return }
            contentView.layer.addSublayer(client.displayLayer)
            setNeedsLayout()
        }
    }

    var controlEnabled = false { willSet { if newValue != controlEnabled { cancelInteraction() } } }
    var controlStyle: ControlStyle = .ipad { willSet { if newValue != controlStyle { cancelInteraction() } } }
    var naturalScrolling = true
    var swipeReversed = false
    var videoSize: CGSize = .zero {
        didSet {
            guard videoSize != oldValue, videoSize.width > 0 else { return }
            cancelInteraction()
            fitToScreen(animated: false)
        }
    }

    private let contentView = UIView()
    private var scale: CGFloat = 1
    private var origin: CGPoint = .zero
    private var didInitialFit = false
    var controlsHeight: CGFloat = 0 { didSet { if oldValue != controlsHeight { setNeedsLayout() } } }
    var topOverlayHeight: CGFloat = 0 { didSet { if oldValue != topOverlayHeight { setNeedsLayout() } } }
    private let unobscuredArea = UILayoutGuide()
    private var keyboardViewport = CGRect.zero

    // Gesture bookkeeping
    private var gesture: Gesture = .none
    private var startPoint: CGPoint = .zero
    private var lastPoint: CGPoint = .zero
    private var startOrigin: CGPoint = .zero
    private var startTime: TimeInterval = 0
    private var startDistance: CGFloat = 0
    private var lastDistance: CGFloat = 0
    private var startScale: CGFloat = 1
    private var startCentre: CGPoint = .zero
    private var lastCentre: CGPoint = .zero
    private var velocity = TouchVelocity()
    private var remoteGesture = RemoteGesture()
    private var lastBoundsSize: CGSize = .zero
    private var ignoreUntilAllLifted = false
    private let touchIndicator = UIView()
    private var twoFingerDecided = false
    private var lastTapTime: TimeInterval = 0
    private var lastTapPoint: CGPoint = .zero
    private var longPressTimer: Timer?
    private var didLongPress = false

    private var stickyModifiers: [String] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        contentView.backgroundColor = .black
        contentView.isUserInteractionEnabled = false
        addSubview(contentView)
        touchIndicator.isUserInteractionEnabled = false
        touchIndicator.backgroundColor = UIColor.systemTeal.withAlphaComponent(0.22)
        touchIndicator.layer.borderWidth = 2
        touchIndicator.layer.borderColor = UIColor.systemTeal.cgColor
        touchIndicator.layer.cornerRadius = 18
        touchIndicator.isHidden = true
        addSubview(touchIndicator)
        accessibilityLabel = "Remote Mac display"
        // Keep the surface full-screen for stable remote display settings,
        // but let UIKit track the actual docked keyboard (including key bar).
        keyboardLayoutGuide.usesBottomSafeArea = false
        keyboardLayoutGuide.followsUndockedKeyboard = false
        addLayoutGuide(unobscuredArea)
        NSLayoutConstraint.activate([
            unobscuredArea.topAnchor.constraint(equalTo: topAnchor),
            unobscuredArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            unobscuredArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            unobscuredArea.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let available = KeyboardAvoidance.viewport(in: bounds, keyboard: keyboardLayoutGuide.layoutFrame,
            controlsHeight: controlsHeight, topInset: safeAreaInsets.top + topOverlayHeight)
        if keyboardViewport != available {
            cancelInteraction()
            keyboardViewport = available
        }
        if bounds.size != lastBoundsSize || (!didInitialFit && videoSize.width > 0) {
            lastBoundsSize = bounds.size
            onViewportSizeChanged?(bounds.size)
            didInitialFit = videoSize.width > 0
            cancelInteraction()
            fitToScreen(animated: false)
        }
        applyTransform()
    }

    // MARK: - Zoom / pan

    func fitToScreen(animated: Bool) {
        guard videoSize.width > 0, bounds.width > 0 else { return }
        scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        origin = CGPoint(x: (bounds.width - videoSize.width * scale) / 2,
                         y: (bounds.height - videoSize.height * scale) / 2)
        applyTransform(animated: animated)
    }

    func zoomToActualSize() {
        guard videoSize.width > 0 else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let anchor = CGPoint(x: (centre.x - origin.x) / scale, y: (centre.y - origin.y) / scale)
        scale = 1 / UIScreen.main.scale
        origin = CGPoint(x: centre.x - anchor.x * scale, y: centre.y - anchor.y * scale)
        clampOrigin()
        applyTransform(animated: true)
    }

    private func clampOrigin() {
        guard videoSize.width > 0 else { return }
        let w = videoSize.width * scale, h = videoSize.height * scale
        let slackX = min(bounds.width * 0.35, w)
        let slackY = min(bounds.height * 0.35, h)
        origin.x = min(max(origin.x, bounds.width - w - slackX), slackX)
        origin.y = min(max(origin.y, bounds.height - h - slackY), slackY)
        if w <= bounds.width { origin.x = (bounds.width - w) / 2 }
        if h <= bounds.height { origin.y = (bounds.height - h) / 2 }
    }

    private func applyTransform(animated: Bool = false) {
        guard videoSize.width > 0 else { return }
        let displayed = geometry
        let frame = CGRect(origin: displayed.origin,
                           size: CGSize(width: videoSize.width * displayed.scale,
                                        height: videoSize.height * displayed.scale))
        let update = {
            CATransaction.begin()
            CATransaction.setDisableActions(!animated)
            self.contentView.frame = frame
            self.client?.displayLayer.frame = CGRect(origin: .zero, size: frame.size)
            CATransaction.commit()
        }
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut], animations: update)
        } else {
            update()
        }
    }

    /// Deltas travel normalised too, so the Mac can convert them to desktop
    /// points itself. Doing that conversion on the phone is what made scrolling
    /// wildly over-sensitive: the scale factor was applied twice.
    private var geometry: TouchGeometry {
        let saved = TouchGeometry(videoSize: videoSize, scale: scale, origin: origin)
        guard !keyboardViewport.isEmpty, keyboardViewport != bounds else { return saved }
        // Touches use the exact same adjusted transform as the video layer.
        return KeyboardAvoidance.adjusted(saved, to: keyboardViewport)
    }

    private func normalisedDelta(_ delta: CGPoint) -> (Double, Double) {
        let value = geometry.delta(delta)
        return (Double(value.x), Double(value.y))
    }

    private func normalised(_ point: CGPoint) -> (Double, Double) {
        let value = geometry.normalised(point)
        return (Double(value.x), Double(value.y))
    }

    private func showTouch(at point: CGPoint) {
        touchIndicator.frame = CGRect(x: point.x - 18, y: point.y - 18, width: 36, height: 36)
        touchIndicator.isHidden = !controlEnabled || controlStyle != .ipad
    }

    /// Cancellation never turns into a tap, a context menu, or a momentum flick.
    func cancelInteraction() {
        cancelLongPress()
        if let end = remoteGesture.finish() { client?.sendInput(end) }
        if controlEnabled { client?.sendInput(["t": "cancel"]) }
        gesture = .none
        ignoreUntilAllLifted = true
        didLongPress = false
        lastTapTime = 0
        touchIndicator.isHidden = true
        clearModifiers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelInteraction() }
    }

    // MARK: - Touches
    //
    // The Mac has no touch input, so these map onto what macOS does understand:
    // real trackpad events. One finger drives the pointer, two scroll or pinch,
    // three swipe between spaces — the same vocabulary as the built-in trackpad.

    private enum Gesture {
        case none
        case viewPan          // moving the picture, not the Mac
        case viewPinch
        case pointerPending   // might become a tap, a drag, or a right-click
        case pointerDrag
        case scroll
        case pinchZoom
        case swipe
        case twoFingerPending   // still deciding: pinch, scroll, or a two-finger tap
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = liveTouches(event, touches)
        cancelLongPress()
        if all.count == touches.count { ignoreUntilAllLifted = false }
        guard !ignoreUntilAllLifted else { return }
        if all.count > 1 {
            if controlEnabled, controlStyle != .trackpad,
               !all.allSatisfy({ geometry.contains($0.location(in: self)) }) {
                cancelInteraction()
                return
            }
            if let end = remoteGesture.finish() { client?.sendInput(end) }
            touchIndicator.isHidden = true
            lastTapTime = 0
        }
        velocity.reset(at: CACurrentMediaTime())

        if all.count >= 3 {
            gesture = controlEnabled ? .swipe : .viewPan
            startCentre = centroid(all)
            lastCentre = startCentre
            startOrigin = origin
            return
        }

        if all.count == 2 {
            let points = all.map { $0.location(in: self) }
            startDistance = max(1, hypot(points[0].x - points[1].x, points[0].y - points[1].y))
            startCentre = centroid(all)
            lastCentre = startCentre
            startScale = scale
            startOrigin = origin
            gesture = .twoFingerPending
            startTime = CACurrentMediaTime()
            twoFingerDecided = false
            return
        }

        guard let touch = all.first else { return }
        startPoint = touch.location(in: self)
        lastPoint = startPoint
        startOrigin = origin
        startTime = CACurrentMediaTime()
        didLongPress = false

        if controlEnabled {
            guard geometry.contains(startPoint) || controlStyle == .trackpad else {
                gesture = .none
                ignoreUntilAllLifted = true
                return
            }
            client?.sendInput(["t": "cancel"])
            showTouch(at: startPoint)
            gesture = .pointerPending
            scheduleLongPress()
        } else {
            gesture = .viewPan
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        let all = liveTouches(event, touches)
        guard !ignoreUntilAllLifted else { return }
        if let point = all.first?.location(in: self), all.count == 1 { showTouch(at: point) }

        switch gesture {
        case .viewPan:
            let point = all.count >= 2 ? centroid(all) : (all.first?.location(in: self) ?? startPoint)
            let anchor = all.count >= 2 ? startCentre : startPoint
            origin = CGPoint(x: startOrigin.x + point.x - anchor.x,
                             y: startOrigin.y + point.y - anchor.y)
            clampOrigin()
            applyTransform()

        case .viewPinch:
            applyViewPinch(all)

        case .pointerPending:
            guard let touch = all.first else { return }
            let point = touch.location(in: self)
            guard hypot(point.x - startPoint.x, point.y - startPoint.y) > 10 else { return }
            cancelLongPress()

            if controlStyle == .ipad {
                // The Mac works out what this drag is: scrolling the window
                // under the finger, moving it by its title bar, resizing it by
                // an edge, or dragging content because you pressed and held.
                gesture = .pointerDrag
                let (x, y) = normalised(startPoint)
                client?.sendInput(["t": "dbeg", "x": x, "y": y,
                                   "mode": didLongPress ? "drag" : "auto"])
                remoteGesture.kind = .routed
                let (dx, dy) = normalisedDelta(CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y))
                let (px, py) = normalised(point)
                client?.sendInput(["t": "dmov", "x": px, "y": py, "dx": dx, "dy": dy])
                velocity.reset(at: CACurrentMediaTime())
                lastPoint = point
                return
            }

            gesture = .pointerDrag
            if controlStyle == .trackpad {
                if didLongPress {
                    client?.sendInput(["t": "d", "b": 0])
                    remoteGesture.kind = .button(0)
                }
            } else {
                let (x, y) = normalised(startPoint)
                client?.sendInput(["t": "m", "x": x, "y": y])
                client?.sendInput(["t": "d", "b": 0])
                remoteGesture.kind = .button(0)
            }
            lastPoint = point

        case .pointerDrag:
            guard let touch = all.first else { return }
            let point = touch.location(in: self)
            if controlStyle == .ipad {
                let (x, y) = normalised(point)
                let (dx, dy) = normalisedDelta(CGPoint(x: point.x - lastPoint.x, y: point.y - lastPoint.y))
                velocity.record(delta: CGPoint(x: dx, y: dy), at: CACurrentMediaTime())
                client?.sendInput(["t": "dmov", "x": x, "y": y, "dx": dx, "dy": dy])
            } else if controlStyle == .trackpad {
                let speed = pointerSpeed(from: lastPoint, to: point)
                client?.sendInput(["t": "rm",
                                   "dx": Double(point.x - lastPoint.x) * speed,
                                   "dy": Double(point.y - lastPoint.y) * speed,
                                   "drag": didLongPress])
            } else {
                let (x, y) = normalised(point)
                client?.sendInput(["t": "g", "x": x, "y": y, "b": 0])
            }
            lastPoint = point

        case .scroll:
            let centre = all.count >= 2 ? centroid(all) : (all.first?.location(in: self) ?? lastCentre)
            var (dx, dy) = normalisedDelta(CGPoint(x: centre.x - lastCentre.x, y: centre.y - lastCentre.y))
            if !naturalScrolling { dx = -dx; dy = -dy }
            velocity.record(delta: CGPoint(x: dx, y: dy), at: CACurrentMediaTime())
            if controlStyle == .ipad {
                let (x, y) = normalised(centre)
                client?.sendInput(["t": "dmov", "x": x, "y": y, "dx": dx, "dy": dy])
            } else {
                client?.sendInput(["t": "s", "dx": dx * Double(videoSize.width),
                                   "dy": dy * Double(videoSize.height)])
            }
            lastCentre = centre

        case .pinchZoom:
            guard all.count >= 2 else { return }
            let points = all.map { $0.location(in: self) }
            let distance = max(1, hypot(points[0].x - points[1].x, points[0].y - points[1].y))
            let delta = Double(distance - lastDistance)
            lastDistance = distance
            if abs(delta) > 0.5 {
                if controlStyle == .ipad {
                    let (nd, _) = normalisedDelta(CGPoint(x: delta, y: 0))
                    client?.sendInput(["t": "pinch", "d": nd])
                } else {
                    client?.sendInput(["t": "z", "d": delta * 1.2])
                }
            }

        case .swipe:
            let centre = centroid(all)
            let dx = centre.x - startCentre.x
            let dy = centre.y - startCentre.y
            // Low enough to be comfortable on a phone, and the anchor resets
            // after each one so a long drag walks through several spaces.
            guard max(abs(dx), abs(dy)) > 42 else { return }
            let horizontal = swipeReversed ? (dx < 0 ? "right" : "left") : (dx < 0 ? "left" : "right")
            let vertical = swipeReversed ? (dy < 0 ? "up" : "down") : (dy < 0 ? "down" : "up")
            let direction = abs(dx) > abs(dy) * 1.3 ? horizontal
                          : (abs(dy) > abs(dx) * 1.3 ? vertical : horizontal)
            client?.sendInput(["t": "sw", "d": direction])
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            startCentre = centre

        case .twoFingerPending:
            guard all.count == 2, !twoFingerDecided else { return }
            let points = all.map { $0.location(in: self) }
            let distance = max(1, hypot(points[0].x - points[1].x, points[0].y - points[1].y))
            let centre = centroid(all)

            if abs(distance - startDistance) > 24 {
                twoFingerDecided = true
                if controlEnabled {
                    gesture = .pinchZoom
                    lastDistance = distance
                } else {
                    gesture = .viewPinch
                }
            } else if hypot(centre.x - startCentre.x, centre.y - startCentre.y) > 14 {
                twoFingerDecided = true
                if controlEnabled {
                    gesture = .scroll
                    velocity.reset(at: CACurrentMediaTime())
                    lastCentre = centre
                    if controlStyle == .ipad {
                        let (x, y) = normalised(centre)
                        client?.sendInput(["t": "dbeg", "x": x, "y": y, "mode": "scroll"])
                        remoteGesture.kind = .routed
                    } else {
                        let (x, y) = normalised(centre)
                        if controlStyle != .trackpad { client?.sendInput(["t": "m", "x": x, "y": y]) }
                        client?.sendInput(["t": "sb"])
                        remoteGesture.kind = .scroll
                    }
                } else {
                    gesture = .viewPan
                }
            }

        case .none:
            break
        }
    }

    private func applyViewPinch(_ all: [UITouch]) {
        guard all.count >= 2 else { return }
        let points = all.map { $0.location(in: self) }
        let distance = max(1, hypot(points[0].x - points[1].x, points[0].y - points[1].y))
        let centre = centroid(all)
        scale = min(6, max(0.05, startScale * distance / startDistance))
        let anchor = CGPoint(x: (startCentre.x - startOrigin.x) / startScale,
                             y: (startCentre.y - startOrigin.y) / startScale)
        origin = CGPoint(x: centre.x - anchor.x * scale, y: centre.y - anchor.y * scale)
        clampOrigin()
        applyTransform()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finishTouches(event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        cancelInteraction()
    }

    private func finishTouches(_ event: UIEvent?) {
        cancelLongPress()
        let remaining = liveTouches(event, []).count
        guard !ignoreUntilAllLifted else {
            if remaining == 0 { ignoreUntilAllLifted = false }
            return
        }
        touchIndicator.isHidden = true

        switch gesture {
        case .pointerPending:
            if CACurrentMediaTime() - startTime < 0.5 || didLongPress {
                let button = didLongPress ? 1 : 0
                // A tap landing soon after the last one, in the same spot, is the
                // second half of a double-tap. The Mac is told which click in the
                // series this is, so the first tap never has to be held back.
                let now = CACurrentMediaTime()
                var clickState = 1
                if button == 0,
                   now - lastTapTime < 0.32,
                   hypot(startPoint.x - lastTapPoint.x, startPoint.y - lastTapPoint.y) < 34 {
                    clickState = 2
                    lastTapTime = 0
                } else {
                    lastTapTime = now
                    lastTapPoint = startPoint
                }
                let (x, y) = normalised(startPoint)
                switch controlStyle {
                case .ipad:
                    client?.sendInput(["t": button == 1 ? "tap2" : "tap",
                                       "x": x, "y": y, "n": clickState])
                case .trackpad:
                    client?.sendInput(["t": "ch", "b": button, "n": clickState])
                case .direct:
                    client?.sendInput(["t": "c", "x": x, "y": y, "b": button, "n": clickState])
                }
                if !didLongPress { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
            }

        case .twoFingerPending:
            // Two fingers down and straight back up is the iPad way to ask for a
            // context menu.
            if controlEnabled, CACurrentMediaTime() - startTime < 0.35 {
                let (x, y) = normalised(startCentre)
                client?.sendInput(controlStyle == .ipad
                                  ? ["t": "tap2", "x": x, "y": y]
                                  : (controlStyle == .trackpad ? ["t": "ch", "b": 1, "n": 1]
                                     : ["t": "c", "x": x, "y": y, "b": 1, "n": 1]))
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        case .pointerDrag, .scroll:
            var ending = velocity.ending(at: CACurrentMediaTime())
            if controlStyle != .ipad {
                ending.x *= videoSize.width
                ending.y *= videoSize.height
            }
            if let end = remoteGesture.finish(velocity: ending) { client?.sendInput(end) }
        default:
            break
        }

        gesture = .none
        twoFingerDecided = false
        ignoreUntilAllLifted = remaining > 0
    }

    /// A trackpad speeds up when you move fast, so a small screen can still
    /// cross a whole desktop without lifting a finger.
    private func pointerSpeed(from: CGPoint, to: CGPoint) -> Double {
        guard videoSize.width > 0 else { return 1 }
        let distance = Double(hypot(to.x - from.x, to.y - from.y))
        let base = Double(videoSize.width) / Double(max(bounds.width, 1)) * 0.55
        let acceleration = min(2.6, 0.8 + distance / 9.0)
        return base * acceleration
    }

    private func liveTouches(_ event: UIEvent?, _ fallback: Set<UITouch>) -> [UITouch] {
        let set = event?.allTouches?.filter { $0.phase != .ended && $0.phase != .cancelled } ?? fallback
        return Array(set)
    }

    private func centroid(_ touches: [UITouch]) -> CGPoint {
        guard !touches.isEmpty else { return .zero }
        var x: CGFloat = 0, y: CGFloat = 0
        for touch in touches {
            let point = touch.location(in: self)
            x += point.x
            y += point.y
        }
        return CGPoint(x: x / CGFloat(touches.count), y: y / CGFloat(touches.count))
    }

    private func scheduleLongPress() {
        longPressTimer = Timer.scheduledTimer(withTimeInterval: 0.55, repeats: false) { [weak self] _ in
            guard let self, self.gesture == .pointerPending else { return }
            self.didLongPress = true
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }

    private func cancelLongPress() {
        longPressTimer?.invalidate()
        longPressTimer = nil
    }

    // MARK: - Keyboard

    var onViewportSizeChanged: ((CGSize) -> Void)?
    var onKeyboardVisibilityChanged: ((Bool) -> Void)?
    override var canBecomeFirstResponder: Bool { controlEnabled }
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result { onKeyboardVisibilityChanged?(true) }
        return result
    }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onKeyboardVisibilityChanged?(false) }
        return result
    }
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard controlEnabled, let client else { return }
        if text == "\n" {
            client.sendInput(["t": "key", "k": "return", "m": stickyModifiers])
        } else if !stickyModifiers.isEmpty {
            client.sendInput(["t": "key", "k": text.lowercased(), "m": stickyModifiers])
        } else {
            client.sendInput(["t": "txt", "s": text])
        }
        clearModifiers()
    }

    func deleteBackward() {
        guard controlEnabled else { return }
        client?.sendInput(["t": "key", "k": "delete", "m": stickyModifiers])
        clearModifiers()
    }

    private func clearModifiers() {
        guard !stickyModifiers.isEmpty else { return }
        stickyModifiers.removeAll()
        refreshModifierButtons()
    }

    // Hardware keyboards paired to the phone work too.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard controlEnabled else { super.pressesBegan(presses, with: event); return }
        var handled = false
        for press in presses {
            guard let key = press.key else { continue }
            var modifiers: [String] = []
            if key.modifierFlags.contains(.command) { modifiers.append("cmd") }
            if key.modifierFlags.contains(.shift) { modifiers.append("shift") }
            if key.modifierFlags.contains(.control) { modifiers.append("ctrl") }
            if key.modifierFlags.contains(.alternate) { modifiers.append("alt") }

            if let name = MirrorUIView.hidKeyNames[key.keyCode] {
                client?.sendInput(["t": "key", "k": name, "m": modifiers])
                handled = true
            } else if !modifiers.isEmpty, !key.charactersIgnoringModifiers.isEmpty {
                client?.sendInput(["t": "key", "k": key.charactersIgnoringModifiers.lowercased(), "m": modifiers])
                handled = true
            } else if !key.characters.isEmpty {
                client?.sendInput(["t": "txt", "s": key.characters])
                handled = true
            }
        }
        if !handled { super.pressesBegan(presses, with: event) }
    }

    private static let hidKeyNames: [UIKeyboardHIDUsage: String] = [
        .keyboardReturnOrEnter: "return", .keyboardTab: "tab", .keyboardEscape: "escape",
        .keyboardDeleteOrBackspace: "delete", .keyboardDeleteForward: "forwarddelete",
        .keyboardLeftArrow: "left", .keyboardRightArrow: "right",
        .keyboardUpArrow: "up", .keyboardDownArrow: "down",
        .keyboardHome: "home", .keyboardEnd: "end",
        .keyboardPageUp: "pageup", .keyboardPageDown: "pagedown"
    ]

    // MARK: - Key bar above the keyboard

    private var modifierButtons: [String: UIButton] = [:]

    override var inputAccessoryView: UIView? {
        if let existing = cachedAccessory { return existing }
        let accessory = buildAccessory()
        cachedAccessory = accessory
        return accessory
    }
    private var cachedAccessory: UIView?

    private func buildAccessory() -> UIView {
        let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 54), inputViewStyle: .keyboard)
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.delaysContentTouches = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        func button(_ title: String, label: String, action: @escaping () -> Void) -> UIButton {
            var config = UIButton.Configuration.gray()
            config.title = title
            config.cornerStyle = .capsule
            config.baseForegroundColor = .label
            let b = UIButton(configuration: config, primaryAction: UIAction { _ in action() })
            b.titleLabel?.font = .systemFont(ofSize: 16, weight: .medium)
            b.accessibilityLabel = label
            b.widthAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
            return b
        }
        for (title, name) in [("esc", "escape"), ("tab", "tab")] {
            stack.addArrangedSubview(button(title, label: name.capitalized) { [weak self] in self?.sendKey(name) })
        }
        for (title, modifier, label) in [("⌘", "cmd", "Command"), ("⇧", "shift", "Shift"),
                                         ("⌃", "ctrl", "Control"), ("⌥", "alt", "Option")] {
            let b = button(title, label: label) { [weak self] in self?.toggleModifier(modifier) }
            b.accessibilityValue = "Off"
            modifierButtons[modifier] = b
            stack.addArrangedSubview(b)
        }
        for (title, name) in [("←", "left"), ("↓", "down"), ("↑", "up"), ("→", "right")] {
            stack.addArrangedSubview(button(title, label: "\(name.capitalized) arrow") { [weak self] in self?.sendKey(name) })
        }
        // Keep dismissal visible while the shortcut keys scroll on small phones.
        let hide = button("⌄", label: "Hide keyboard") { [weak self] in self?.resignFirstResponder() }
        hide.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(scroll)
        bar.addSubview(hide)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: hide.leadingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            hide.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            hide.topAnchor.constraint(equalTo: bar.topAnchor, constant: 5),
            hide.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -5),
            hide.widthAnchor.constraint(equalToConstant: 44)
        ])
        return bar
    }

    private func sendKey(_ name: String) {
        guard controlEnabled else { return }
        client?.sendInput(["t": "key", "k": name, "m": stickyModifiers])
        clearModifiers()
    }

    private func toggleModifier(_ name: String) {
        if let index = stickyModifiers.firstIndex(of: name) {
            stickyModifiers.remove(at: index)
        } else {
            stickyModifiers.append(name)
        }
        refreshModifierButtons()
    }

    private func refreshModifierButtons() {
        for (name, button) in modifierButtons {
            let active = stickyModifiers.contains(name)
            var config = active ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
            config.title = button.configuration?.title
            config.cornerStyle = .capsule
            config.baseForegroundColor = active ? .white : .label
            button.configuration = config
            button.accessibilityValue = active ? "On" : "Off"
        }
    }
}
