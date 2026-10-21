import Foundation
import CoreGraphics

/// Turns the Mac's desktop on its side, so a phone held upright can show a
/// whole desktop instead of a letterboxed strip of one.
///
/// There is no public API for this. The IOKit route every older tool uses
/// (`IOServiceRequestProbe` with `kIOFBSetTransform`) returns
/// `kIOReturnUnsupported` on Apple Silicon. What System Settings itself uses is
/// `SLSSetDisplayRotation` in SkyLight, looked up here at run time — so if a
/// future macOS drops it, rotation quietly becomes unavailable rather than
/// taking the app down with it.
enum DisplayRotation {

    private typealias SetRotation = @convention(c) (UInt32, Int32) -> Int32

    private static let setter: SetRotation? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "SLSSetDisplayRotation") else {
            return nil
        }
        return unsafeBitCast(symbol, to: SetRotation.self)
    }()

    static var isSupported: Bool { setter != nil }

    static func current(_ displayID: CGDirectDisplayID) -> Int {
        Int(CGDisplayRotation(displayID).rounded())
    }

    @discardableResult
    static func set(_ degrees: Int, on displayID: CGDirectDisplayID) -> Bool {
        guard let setter else { return false }
        let normalised = ((degrees % 360) + 360) % 360
        guard [0, 90, 180, 270].contains(normalised) else { return false }
        guard current(displayID) != normalised else { return true }

        if setter(displayID, Int32(normalised)) != 0 { return false }

        // Mirrored displays have to follow, or the picture ends up sideways on
        // one of them.
        let mirrorSource = CGDisplayMirrorsDisplay(displayID)
        if mirrorSource != kCGNullDirectDisplay, mirrorSource != displayID {
            _ = setter(mirrorSource, Int32(normalised))
        }
        for other in onlineDisplays() where CGDisplayMirrorsDisplay(other) == displayID {
            _ = setter(other, Int32(normalised))
        }
        return true
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(16, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
