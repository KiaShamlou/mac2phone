import Foundation
import CoreGraphics

/// Switches the Mac to a resolution that suits the phone it is being shown on,
/// and puts it back afterwards.
///
/// A display only offers the modes its hardware advertises, so this picks the
/// closest one rather than inventing a size: the aspect ratio matters most
/// (letterboxing wastes a phone screen), then how near it lands to the target.
enum DisplayMode {

    static func current(_ displayID: CGDirectDisplayID) -> CGDisplayMode? {
        CGDisplayCopyDisplayMode(displayID)
    }

    static func all(_ displayID: CGDirectDisplayID) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return [] }
        return modes.filter { $0.isUsableForDesktopGUI() }
    }

    static func describe(_ mode: CGDisplayMode) -> String {
        let hidpi = mode.pixelWidth > mode.width ? " HiDPI" : ""
        return "\(mode.width)x\(mode.height)\(hidpi) @\(Int(mode.refreshRate))Hz"
    }

    /// The display's own full resolution — the sane thing to fall back to when
    /// there is no record of what it was set to before.
    static func native(for displayID: CGDirectDisplayID) -> CGDisplayMode? {
        all(displayID).max { a, b in
            (a.pixelWidth, a.width) < (b.pixelWidth, b.width)
        }
    }

    /// `aspect` is width / height — greater than 1 for a landscape desktop,
    /// less than 1 once the display has been turned upright.
    static func best(for displayID: CGDirectDisplayID, targetWidth: Int, aspect: Double) -> CGDisplayMode? {
        let modes = all(displayID)
        guard !modes.isEmpty, targetWidth > 0, aspect > 0 else { return nil }

        var best: CGDisplayMode?
        var bestScore = Double.greatestFiniteMagnitude

        for mode in modes {
            let width = Double(mode.width)
            let height = Double(mode.height)
            guard width > 0, height > 0 else { continue }

            let modeAspect = width / height
            // Log-ratio so 2:1 vs 1:2 error the same amount either way.
            let aspectError = abs(log(modeAspect / aspect))
            let sizeError = abs(log(width / Double(targetWidth)))

            // Aspect dominates: a shape that fills the phone beats an exact width.
            var score = aspectError * 3.0 + sizeError
            // A HiDPI mode at the same point size keeps text sharp for free.
            if mode.pixelWidth > mode.width { score -= 0.12 }

            if score < bestScore {
                bestScore = score
                best = mode
            }
        }
        return best
    }

    // MARK: - Crash safety
    //
    // `.forSession` already means a reboot undoes any change, but a Mac whose
    // screen cannot be read is a bad place to be stuck at 960x540 until then.
    // So the mode being replaced is written to disk and restored on next launch
    // if the process died before it could put things back itself.

    struct Saved: Codable {
        var displayID: UInt32
        var width: Int
        var height: Int
        var pixelWidth: Int
        var refreshRate: Double
        var rotation: Int?
    }

    private static var stateURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mac2Phone", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("display-restore.json")
    }

    static func remember(_ mode: CGDisplayMode, displayID: CGDirectDisplayID, rotation: Int) {
        let saved = Saved(displayID: displayID,
                          width: mode.width,
                          height: mode.height,
                          pixelWidth: mode.pixelWidth,
                          refreshRate: mode.refreshRate,
                          rotation: rotation)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    static func forget() {
        try? FileManager.default.removeItem(at: stateURL)
    }

    /// Returns a pending restore left behind by a previous run, and clears it.
    static func takePending() -> Saved? {
        guard let data = try? Data(contentsOf: stateURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return nil }
        forget()
        return saved
    }

    static func match(_ saved: Saved) -> CGDisplayMode? {
        all(saved.displayID).first {
            $0.width == saved.width && $0.height == saved.height
                && $0.pixelWidth == saved.pixelWidth
                && abs($0.refreshRate - saved.refreshRate) < 1
        }
    }

    @discardableResult
    static func apply(_ mode: CGDisplayMode, to displayID: CGDirectDisplayID) -> Bool {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        // For this login session only, so a crash can never leave it stuck.
        guard CGConfigureDisplayWithDisplayMode(config, displayID, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .forSession) == .success
    }
}
