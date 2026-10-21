import Foundation
import IOKit
import IOKit.ps
import IOKit.pwr_mgt

/// Keeps the Mac usable with its lid shut, without leaving it running flat out
/// the whole time nobody is looking.
///
/// Two mechanisms are needed, because they cover two different kinds of sleep:
///
///   * Power assertions stop *idle* sleep and keep the framebuffer composited.
///     Any process may take these out; no privileges involved.
///   * Closing the lid is not idle sleep — it is an immediate, deliberate sleep
///     that assertions do not override. Only `pmset disablesleep` prevents it,
///     and only root may set it. That is what the helper daemon exists for.
final class PowerManager {

    enum State: String {
        /// Normal Mac behaviour: closing the lid sleeps it.
        case off
        /// Lid shut, nobody connected. Awake enough to answer the phone, and
        /// otherwise as cheap as the machine can be.
        case idle
        /// A phone is watching.
        case active
    }

    static let flagPath = "/Library/Application Support/Mac2Phone/keepawake"
    static let helperPlist = "/Library/LaunchDaemons/com.kianoosh.mac2phone.helper.plist"

    private var assertions: [IOPMAssertionID] = []
    private(set) var state: State = .off

    /// Whether to ask macOS for Low Power Mode while idling with the lid shut.
    var lowPowerWhenIdle = true

    static var helperInstalled: Bool {
        FileManager.default.fileExists(atPath: helperPlist)
    }

    static var lidSleepDisabled: Bool {
        pmsetValue(named: "SleepDisabled") == "1"
    }

    static var onBattery: Bool {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let state = description[kIOPSPowerSourceStateKey] as? String {
                return state == kIOPSBatteryPowerValue
            }
        }
        return false
    }

    private static func pmsetValue(named name: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["-g"]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where line.contains(name) {
            return line.split(separator: " ").last.map(String.init)
        }
        return nil
    }

    // MARK: - Switching state

    func set(_ newState: State) {
        guard newState != state else { return }
        state = newState

        for assertion in assertions { IOPMAssertionRelease(assertion) }
        assertions.removeAll()

        switch newState {
        case .off:
            break
        case .idle:
            // Enough to stay reachable — and deliberately *not* the display
            // assertion, because compositing a screen nobody is looking at is
            // pure waste.
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep, "Mac2Phone is waiting for a phone")
        case .active:
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep, "Mac2Phone is showing this screen on a phone")
            hold(kIOPMAssertionTypePreventSystemSleep, "Mac2Phone is streaming")
            // Without this the framebuffer can go dark and there is nothing to capture.
            hold(kIOPMAssertionTypeNoDisplaySleep, "Mac2Phone needs the screen composited")
        }

        writeFlag(for: newState)
        if newState == .active { nudgeDisplayAwake() }
    }

    private func hold(_ type: String, _ reason: String) {
        var id: IOPMAssertionID = 0
        let status = IOPMAssertionCreateWithName(type as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 reason as CFString,
                                                 &id)
        if status == kIOReturnSuccess { assertions.append(id) }
    }

    /// Tells the system a person is present, which brings a dimmed or dark
    /// display back so there is something to capture.
    func nudgeDisplayAwake() {
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Mac2Phone" as CFString, kIOPMUserActiveLocal, &id)
    }

    private func writeFlag(for state: State) {
        guard PowerManager.helperInstalled else { return }
        let word: String
        switch state {
        case .off:    word = "none"
        case .idle:   word = lowPowerWhenIdle ? "saver" : "full"
        case .active: word = "full"
        }
        // Deliberately not atomic. An atomic write creates a temporary file in
        // the same directory and renames it over the target — but that directory
        // is root-owned, so it would fail silently, and the rename would also
        // swap the inode out from under launchd's WatchPaths.
        do {
            try word.write(toFile: PowerManager.flagPath, atomically: false, encoding: .utf8)
        } catch {
            FileHandle.standardError.write(Data("could not update the keep-awake flag: \(error)\n".utf8))
        }
    }
}
