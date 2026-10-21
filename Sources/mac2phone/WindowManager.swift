import Foundation
import AppKit
import CoreGraphics
import ApplicationServices

/// Knows what is on screen and where, so touch can behave the way it does on an
/// iPad desktop: a tap on a window that is not in front only brings it forward,
/// and only the window you are already in responds to real interaction.
enum WindowManager {

    struct Info {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect          // global, top-left origin, same space as CGDisplayBounds
        let owner: String
        let title: String
    }

    /// Height of the region at the top of a window that drags the whole window.
    static let titleBarHeight: CGFloat = 30
    /// How close to an edge counts as "grab to resize".
    static let resizeMargin: CGFloat = 14

    // MARK: - Reading the screen

    /// On-screen normal windows, front-most first.
    static func windows() -> [Info] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return [] }

        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  frame.width > 40, frame.height > 40
            else { return nil }

            return Info(id: id,
                        pid: pid,
                        frame: frame,
                        owner: entry[kCGWindowOwnerName as String] as? String ?? "",
                        title: entry[kCGWindowName as String] as? String ?? "")
        }
    }

    static func window(at point: CGPoint) -> Info? {
        windows().first { $0.frame.contains(point) }
    }

    /// The window a click would currently go to.
    static func frontWindow() -> Info? {
        guard let front = NSWorkspace.shared.frontmostApplication else { return windows().first }
        return windows().first { $0.pid == front.processIdentifier } ?? windows().first
    }

    static func isFront(_ window: Info) -> Bool {
        // Different windows of the same app must still require a focus touch.
        frontWindow()?.id == window.id
    }

    // MARK: - What a touch on a window means

    enum Region {
        case titleBar
        case resize(edges: Edges)
        case content
    }

    struct Edges: OptionSet {
        let rawValue: Int
        static let left   = Edges(rawValue: 1 << 0)
        static let right  = Edges(rawValue: 1 << 1)
        static let top    = Edges(rawValue: 1 << 2)
        static let bottom = Edges(rawValue: 1 << 3)
    }

    static func region(of window: Info, at point: CGPoint) -> Region {
        var edges: Edges = []
        if point.x - window.frame.minX < resizeMargin { edges.insert(.left) }
        if window.frame.maxX - point.x < resizeMargin { edges.insert(.right) }
        if window.frame.maxY - point.y < resizeMargin { edges.insert(.bottom) }
        // The top edge is where the title bar lives; dragging there should move
        // the window, which is far more common than resizing upward.
        if point.y - window.frame.minY < resizeMargin && edges.isEmpty == false { edges.insert(.top) }

        if !edges.isEmpty { return .resize(edges: edges) }
        if point.y - window.frame.minY < titleBarHeight { return .titleBar }
        return .content
    }

    // MARK: - Acting on windows

    private static func axWindow(for info: Info) -> AXUIElement? {
        let app = AXUIElementCreateApplication(info.pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return nil }

        // AX gives no z-order, so match the one whose frame is where CoreGraphics
        // says this window is.
        var best: AXUIElement?
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for window in windows {
            guard let frame = axFrame(window) else { continue }
            let distance = abs(frame.minX - info.frame.minX) + abs(frame.minY - info.frame.minY)
                         + abs(frame.width - info.frame.width) + abs(frame.height - info.frame.height)
            if distance < bestDistance {
                bestDistance = distance
                best = window
            }
        }
        return bestDistance < 8 ? best : nil
    }

    private static func axFrame(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success
        else { return nil }

        var origin = CGPoint.zero
        var size = CGSize.zero
        guard let p = positionValue, CFGetTypeID(p) == AXValueGetTypeID(),
              AXValueGetValue(p as! AXValue, .cgPoint, &origin),
              let s = sizeValue, CFGetTypeID(s) == AXValueGetTypeID(),
              AXValueGetValue(s as! AXValue, .cgSize, &size)
        else { return nil }

        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    static func focus(_ info: Info) -> Bool {
        var raised = false
        if let window = axWindow(for: info) {
            raised = AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        if let app = NSRunningApplication(processIdentifier: info.pid) {
            app.activate()
        }
        return raised
    }

    @discardableResult
    static func setFrame(_ info: Info, origin: CGPoint?, size: CGSize?) -> Bool {
        guard let window = axWindow(for: info) else { return false }
        var ok = true
        if var size {
            size.width = max(size.width, 200)
            size.height = max(size.height, 120)
            if let value = AXValueCreate(.cgSize, &size) {
                ok = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value) == .success && ok
            }
        }
        if var origin {
            if let value = AXValueCreate(.cgPoint, &origin) {
                ok = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value) == .success && ok
            }
        }
        return ok
    }

    // MARK: - Window buttons
    //
    // The traffic lights are about 12 points across. Aiming at them through a
    // phone screen is miserable, so the same actions are available directly.

    @discardableResult
    private static func press(_ info: Info, button attribute: String) -> Bool {
        guard let window = axWindow(for: info) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
              let raw = value, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        return AXUIElementPerformAction(raw as! AXUIElement, kAXPressAction as CFString) == .success
    }

    @discardableResult
    static func close(_ info: Info) -> Bool { press(info, button: kAXCloseButtonAttribute) }

    @discardableResult
    static func minimize(_ info: Info) -> Bool { press(info, button: kAXMinimizeButtonAttribute) }

    @discardableResult
    static func zoom(_ info: Info) -> Bool { press(info, button: kAXZoomButtonAttribute) }

    /// Snap a window to a half or the whole of the display it is on.
    @discardableResult
    static func tile(_ info: Info, to spot: String, within display: CGRect) -> Bool {
        // Leave the menu bar alone.
        let usable = CGRect(x: display.minX, y: display.minY + 25,
                            width: display.width, height: display.height - 25)
        let frame: CGRect
        switch spot {
        case "left":   frame = CGRect(x: usable.minX, y: usable.minY, width: usable.width / 2, height: usable.height)
        case "right":  frame = CGRect(x: usable.midX, y: usable.minY, width: usable.width / 2, height: usable.height)
        case "top":    frame = CGRect(x: usable.minX, y: usable.minY, width: usable.width, height: usable.height / 2)
        case "bottom": frame = CGRect(x: usable.minX, y: usable.midY, width: usable.width, height: usable.height / 2)
        default:       frame = usable
        }
        return setFrame(info, origin: frame.origin, size: frame.size)
    }

    /// Reads the window's live frame, which matters mid-drag because the app may
    /// clamp what we asked for.
    static func liveFrame(_ info: Info) -> CGRect? {
        guard let window = axWindow(for: info) else { return nil }
        return axFrame(window)
    }
}
