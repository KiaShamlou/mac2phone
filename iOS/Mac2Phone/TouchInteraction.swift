import Foundation
import CoreGraphics


/// Pure interaction rules, compiled into the iOS app and the macOS test suite.
enum ControlStyle: Int, CaseIterable {
    case ipad = 0, direct = 1, trackpad = 2

    var label: String {
        switch self {
        case .ipad: return "Touch"
        case .direct: return "Pointer"
        case .trackpad: return "Trackpad"
        }
    }

    var icon: String {
        switch self {
        case .ipad: return "hand.draw"
        case .direct: return "hand.point.up.left.fill"
        case .trackpad: return "rectangle.and.hand.point.up.left.fill"
        }
    }

    var hint: String {
        switch self {
        case .ipad: return "Tap to click · swipe to scroll · hold, then drag"
        case .direct: return "Touch to point · drag to select or move"
        case .trackpad: return "Slide to point · tap to click · hold to drag"
        }
    }

    var next: ControlStyle { ControlStyle(rawValue: (rawValue + 1) % Self.allCases.count) ?? .ipad }
    func showsCursor(preference: Bool, controlling: Bool) -> Bool {
        preference && !(self == .ipad && controlling)
    }
}

struct TouchGeometry {
    let videoSize: CGSize
    let scale: CGFloat
    let origin: CGPoint

    var valid: Bool {
        videoSize.width > 0 && videoSize.height > 0 && scale > 0 &&
        videoSize.width.isFinite && videoSize.height.isFinite && scale.isFinite &&
        origin.x.isFinite && origin.y.isFinite
    }

    func contains(_ point: CGPoint) -> Bool {
        valid && CGRect(origin: origin, size: CGSize(width: videoSize.width * scale,
                                                     height: videoSize.height * scale)).contains(point)
    }

    func normalised(_ point: CGPoint) -> CGPoint {
        guard valid, point.x.isFinite, point.y.isFinite else { return .zero }
        return CGPoint(x: min(1, max(0, (point.x - origin.x) / (videoSize.width * scale))),
                       y: min(1, max(0, (point.y - origin.y) / (videoSize.height * scale))))
    }

    func delta(_ point: CGPoint) -> CGPoint {
        guard valid, point.x.isFinite, point.y.isFinite else { return .zero }
        return CGPoint(x: point.x / (videoSize.width * scale),
                       y: point.y / (videoSize.height * scale))
    }
}

/// A temporary, local presentation adjustment. The full device viewport and
/// saved pan/zoom stay unchanged, so typing never reshapes the remote Mac.
enum KeyboardAvoidance {
    static func viewport(in bounds: CGRect, keyboard: CGRect, controlsHeight: CGFloat,
                         topInset: CGFloat = 0) -> CGRect {
        guard bounds.width > 0, bounds.height > 0,
              [bounds.minX, bounds.minY, bounds.width, bounds.height,
               keyboard.minX, keyboard.minY, keyboard.width, keyboard.height,
               controlsHeight, topInset].allSatisfy(\.isFinite) else { return bounds }
        let overlap = bounds.intersection(keyboard)
        // Floating iPad keyboards do not consume the whole bottom of the view.
        guard !overlap.isNull, overlap.height > 1,
              overlap.width >= bounds.width * 0.9,
              overlap.maxY >= bounds.maxY - 1 else { return bounds }
        let top = min(bounds.maxY - 1, bounds.minY + max(0, topInset))
        let bottom = max(top + 1, overlap.minY - max(0, controlsHeight) - 12)
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
    }

    static func adjusted(_ geometry: TouchGeometry, to viewport: CGRect) -> TouchGeometry {
        guard geometry.valid, viewport.width > 0, viewport.height > 0,
              [viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy(\.isFinite)
        else { return geometry }
        // Prefer only moving up. Scale down only if the picture cannot fit in
        // the space above the keyboard, accessory keys, and floating controls.
        let scale = min(geometry.scale, viewport.width / geometry.videoSize.width,
                        viewport.height / geometry.videoSize.height)
        let size = CGSize(width: geometry.videoSize.width * scale,
                          height: geometry.videoSize.height * scale)
        let x = scale < geometry.scale ? viewport.midX - size.width / 2
            : max(viewport.minX, min(geometry.origin.x, viewport.maxX - size.width))
        let origin = CGPoint(x: x,
                             y: max(viewport.minY, min(geometry.origin.y, viewport.maxY - size.height)))
        return TouchGeometry(videoSize: geometry.videoSize, scale: scale, origin: origin)
    }
}

/// The wire retains legacy "distance per 60 Hz frame" units, but estimates
/// velocity using time so 60/120 Hz devices produce the same momentum.
struct TouchVelocity {
    private var sample: CGPoint = .zero
    private var timestamp: TimeInterval?

    mutating func reset(at time: TimeInterval) { sample = .zero; timestamp = time }
    mutating func record(delta: CGPoint, at time: TimeInterval) {
        guard let previous = timestamp else { reset(at: time); return }
        let dt = time - previous
        timestamp = time
        guard dt > 0, dt < 0.15, delta.x.isFinite, delta.y.isFinite else {
            sample = .zero; return
        }
        sample = CGPoint(x: min(0.1, max(-0.1, delta.x / dt / 60)),
                         y: min(0.1, max(-0.1, delta.y / dt / 60)))
    }
    func ending(at time: TimeInterval) -> CGPoint {
        guard let timestamp, time >= timestamp, time - timestamp < 0.08 else { return .zero }
        return sample
    }
}

/// Own exactly one remote gesture. Finger-count changes consume its ending
/// once; a later finger lift cannot release the same gesture again.
struct RemoteGesture {
    enum Kind: Equatable { case none, routed, scroll, button(Int) }
    var kind: Kind = .none

    mutating func finish(velocity: CGPoint = .zero) -> [String: Any]? {
        let previous = kind
        kind = .none
        switch previous {
        case .none: return nil
        case .routed: return ["t": "dend", "vx": Double(velocity.x), "vy": Double(velocity.y)]
        case .scroll: return ["t": "se", "vx": Double(velocity.x), "vy": Double(velocity.y)]
        case .button(let button): return ["t": "u", "b": button]
        }
    }
}
