import Foundation
import CoreGraphics
import CoreMedia
import Carbon.HIToolbox
import AVFoundation
import AppKit
import Combine
import SwiftUI

/// Wires capture -> encoders -> server, and owns all runtime state.
final class AppController {

    private let options: Options
    private let capturer = ScreenCapturer()
    private let videoEncoder = VideoEncoder()
    private let jpegEncoder = JPEGEncoder()
    private let input = InputController()
    private let audio = AudioCapture()
    private lazy var touch = TouchRouter(input: input)
    private let power = PowerManager()
    private var server: Server!
    let nearby = NearbyService()
    private var nearbySubscription: AnyCancellable?
    private var approvalWindow: NSWindow?

    private let control = DispatchQueue(label: "mac2phone.control")
    private var enabled = true
    private var needsKeyframe = false
    private var encoderSize: (width: Int, height: Int) = (0, 0)
    private var lastAnnounce = Date.distantPast
    private var savedDisplayMode: CGDisplayMode?
    private var savedDisplayID: CGDirectDisplayID = 0
    private var matchPhoneDisplay = true
    private var phoneAspect: Double = 19.5 / 9.0
    private var phoneTargetWidth = 960
    private var phonePortrait = false
    private var savedRotation = 0
    private lazy var menuBar = MenuBarController(controller: self)

    init(options: Options) {
        self.options = options
    }

    // MARK: - Start

    func start() async {
        if options.list {
            await printDisplays()
            exit(0)
        }

        Speech.enabled = options.speak

        if !CGPreflightScreenCaptureAccess() {
            print("""

            ⚠️  Screen Recording permission is not granted yet.
                A system prompt should appear now. Approve Mac2Phone in
                System Settings ▸ Privacy & Security ▸ Screen & System Audio Recording,
                then start it again.

            """)
            Speech.say("Screen recording permission is required. Please approve it in system settings.")
            CGRequestScreenCaptureAccess()
        }

        if options.control && !input.isTrusted {
            print("""
            ℹ️  Remote control needs Accessibility permission.
                Approve Mac2Phone in System Settings ▸ Privacy & Security ▸ Accessibility.
                Mirroring works without it; touch and keyboard input will not.

            """)
            input.requestAccessibility(prompt: true)
        }

        restoreLeftoverDisplayMode()

        // Restore the user's explicit preference. Merely installing a helper
        // must not silently opt the Mac into a different power policy.
        if UserDefaults.standard.bool(forKey: "lidAwake") {
            power.set(.idle)
            print("☾ staying awake with the lid closed (idling cheaply until a phone connects)")
        }

        capturer.maxWidth = options.width
        capturer.fps = options.fps
        capturer.showsCursor = options.cursor
        capturer.displayIndex = options.display

        videoEncoder.useHEVC = options.codec != "h264"
        videoEncoder.bitrate = options.bitrate
        videoEncoder.fps = options.fps

        jpegEncoder.quality = options.quality
        jpegEncoder.maxWidth = 1600

        input.enabled = options.control

        do {
            let stored = try PairingStore.load("host")
            let pairing = try stored ?? Pairing.generate(host: NetUtil.localHostName(), port: options.port)
            if stored == nil { try PairingStore.save(pairing, account: "host") }
            server = Server(port: options.port, pairing: pairing)
            server.requireApproval = true
        } catch {
            fputs("Pairing setup failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
        server.capabilities = { [weak self] in
            guard let self else { return [:] }
            return ["platform": "macos", "touchMode": "ipad", "control": self.enabled && self.options.control && self.input.isTrusted,
                    "screen": self.enabled && CGPreflightScreenCaptureAccess(),
                    "audioAvailable": AudioCapture.findDevice() != nil]
        }
        server.currentVideoConfig = { [weak self] in self?.videoConfigPayload() }
        server.currentAudioConfig = { [weak self] in
            guard let self, self.audio.isRunning else { return nil }
            return (Int(self.audio.sampleRate), self.audio.channels)
        }
        server.onViewersChanged = { [weak self] viewers in self?.viewersChanged(viewers) }
        server.onInput = { [weak self] message in self?.handleInput(message) }
        server.onSettings = { [weak self] message in self?.handleSettings(message) }
        server.onKeyframeRequest = { [weak self] in self?.control.async { self?.needsKeyframe = true } }
        server.onAudioWantedChanged = { [weak self] wanted in self?.audioWantedChanged(wanted) }
        touch.onRole = { [weak self] role in self?.server.send(status: ["t": "role", "r": role]) }

        audio.onPCM = { [weak self] pcm, pts in self?.server.send(audio: pcm, ptsMicros: pts) }

        capturer.onFrame = { [weak self] pixelBuffer, pts in self?.handleFrame(pixelBuffer, pts) }
        capturer.onStopped = { [weak self] error in
            FileHandle.standardError.write(Data("capture stopped: \(error.localizedDescription)\n".utf8))
            self?.restartCaptureIfNeeded()
        }

        videoEncoder.onSample = { [weak self] data, isKeyframe, pts in
            self?.server.send(videoSample: data, isKeyframe: isKeyframe, ptsMicros: pts)
        }
        videoEncoder.onFormat = { [weak self] format in
            guard let self else { return }
            let payload = VideoEncoder.encodeFormatPayload(format,
                                                           displayWidth: Int(self.capturer.displayBounds.width),
                                                           displayHeight: Int(self.capturer.displayBounds.height))
            self.server.sendVideoConfigToAll(payload)
        }

        do {
            try server.start()
        } catch {
            FileHandle.standardError.write(Data("could not listen on port \(options.port): \(error)\n".utf8))
            Speech.say("Mac to phone could not start. The port is busy.")
            exit(1)
        }

        DispatchQueue.main.async {
            self.menuBar.install()
            self.nearby.grant = { [weak self] done in
                guard let self, self.enabled, CGPreflightScreenCaptureAccess() else { done(nil); return }
                done(try? self.server.grant(host: NetUtil.localAddresses().first?.ip ?? NetUtil.localHostName()).link)
            }
            self.nearbySubscription = self.nearby.$incoming.sink { [weak self] request in
                guard let self else { return }
                if request == nil { self.approvalWindow?.close(); self.approvalWindow = nil; return }
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Mac2Phone · Connection request"
                window.contentView = NSHostingView(rootView: NearbyMacApproval(service: self.nearby, allowsControl: self.options.control && self.input.isTrusted))
                window.isReleasedWhenClosed = false; window.center(); window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true); self.approvalWindow = window
            }
            self.nearby.start()
        }

        if options.hotkey { installHotKeys() }
        printBanner()
        announce(intro: true)
    }

    // MARK: - Capture lifecycle

    private func viewersChanged(_ viewers: Server.Viewers) {
        control.async {
            if viewers.total > 0 && self.enabled && !self.capturer.isRunning {
                Task { await self.startCapture() }
            } else if viewers.total == 0 {
                DispatchQueue.main.async {
                    self.touch.cancel()
                    self.input.releaseAll()
                }
                // Everyone has gone: put the Mac back exactly as it was, whether
                // or not the capture happened to still be running.
                self.restoreDisplayMode()
                if self.audio.isRunning { self.audio.stop() }
                if self.capturer.isRunning {
                    Task {
                        await self.capturer.stop()
                        self.control.async {
                            self.videoEncoder.teardown()
                            self.encoderSize = (0, 0)
                        }
                    }
                }
            }
            // Full speed only while somebody is actually watching; the rest of
            // the time stay just awake enough to answer the phone.
            if self.lidAwake {
                self.power.set(viewers.total > 0 ? .active : .idle)
            }
            if viewers.native == 0 { self.restoreDisplayMode() }
            if viewers.total > 0 {
                self.needsKeyframe = true
                self.power.nudgeDisplayAwake()
                self.sendLidState()
                self.warnIfLidWillSleep()
            }
            DispatchQueue.main.async { self.menuBar.refreshIcon() }
        }
    }

    // MARK: - What the menu bar shows

    struct Status {
        var headline: String
        var detail: String?
        var addresses: [String]
        var enabled: Bool
        var matchesDisplay: Bool
        var displayMode: String?
        var lidAwake: Bool
        var lidHelperInstalled: Bool
        var powerState: String
        var onBattery: Bool
        var screenRecording: Bool
        var accessibility: Bool
        var microphone: Bool
        var audioDeviceInstalled: Bool
        var viewers: Server.Viewers
    }

    var status: Status {
        let viewers = server?.viewers ?? Server.Viewers()
        let headline: String
        var detail: String?

        if !enabled {
            headline = "Mirroring is off"
            detail = "⌃⌥⌘M to turn it back on"
        } else if viewers.native > 0 {
            headline = viewers.native == 1 ? "A phone is connected" : "\(viewers.native) phones connected"
            let size = capturer.pixelSize
            detail = "\(size.width)×\(size.height) · \(videoEncoder.describeMode)"
                + (audio.isRunning ? " · audio" : "")
        } else if viewers.desktop > 0 {
            headline = "A desktop is connected"
            detail = "JPEG · encrypted TLS"
        } else {
            headline = "Waiting for a device"
            detail = "Copy a pairing link to connect"
        }

        var addresses = [NetUtil.localHostName() + ":\(options.port)"]
        addresses += NetUtil.localAddresses().map { "\($0.ip):\(options.port)" }

        let displayID = capturer.displayID != 0 ? capturer.displayID : CGMainDisplayID()
        let mode = DisplayMode.current(displayID).map { DisplayMode.describe($0) }

        return Status(headline: headline,
                      detail: detail,
                      addresses: addresses,
                      enabled: enabled,
                      matchesDisplay: matchPhoneDisplay,
                      displayMode: mode,
                      lidAwake: UserDefaults.standard.bool(forKey: "lidAwake"),
                      lidHelperInstalled: PowerManager.helperInstalled,
                      powerState: power.state.rawValue,
                      onBattery: PowerManager.onBattery,
                      screenRecording: CGPreflightScreenCaptureAccess(),
                      accessibility: input.isTrusted,
                      microphone: AudioCapture.microphonePermission() == .granted,
                      audioDeviceInstalled: AudioCapture.findDevice() != nil,
                      viewers: viewers)
    }

    func setEnabled(_ on: Bool) {
        control.async {
            guard on != self.enabled else { return }
            self.applyEnabled(on)
        }
    }

    func setMatchDisplay(_ on: Bool) {
        control.async {
            guard on != self.matchPhoneDisplay else { return }
            self.matchPhoneDisplay = on
            if on { self.matchDisplayToPhone() } else { self.restoreDisplayMode() }
        }
    }

    func speakAddress() { announce(intro: false) }

    func copyPairingLink() {
        do {
            guard enabled, CGPreflightScreenCaptureAccess() else { return }
            let link = try server.grant(host: NetUtil.localAddresses().first?.ip ?? NetUtil.localHostName()).link
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link, forType: .string)
        } catch { pairingAlert(error.localizedDescription) }
    }

    func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "Reset pairing for all devices?"
        alert.informativeText = "Connected devices will disconnect. Copy a new pairing link to reconnect each device."
        alert.addButton(withTitle: "Reset Pairing")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let value = try Pairing.generate(host: NetUtil.localHostName(), port: options.port)
            try PairingStore.save(value, account: "host")
            server.rotatePairing(value) { error in
                if let error { DispatchQueue.main.async { self.pairingAlert(error.localizedDescription) } }
            }
        } catch { pairingAlert(error.localizedDescription) }
    }

    private func pairingAlert(_ message: String) {
        let alert = NSAlert(); alert.messageText = "Pairing"; alert.informativeText = message; alert.runModal()
    }


    // MARK: - Working with the lid shut

    var lidAwake: Bool { UserDefaults.standard.bool(forKey: "lidAwake") }
    var lidHelperInstalled: Bool { PowerManager.helperInstalled }

    func setLidAwake(_ on: Bool) {
        guard on != lidAwake || power.state == .off && on else {
            return
        }
        UserDefaults.standard.set(on, forKey: "lidAwake")
        if on {
            power.set((server?.viewers.total ?? 0) > 0 ? .active : .idle)
            print("☾ staying awake with the lid closed")
            if !PowerManager.helperInstalled {
                server?.send(status: ["t": "warn",
                                      "m": "Idle sleep is now blocked, but closing the lid still sleeps this Mac until the helper is installed: sudo Scripts/install-helper.sh"])
            }
        } else {
            power.set(.off)
            print("☾ normal sleep behaviour restored")
        }
        sendLidState()
        DispatchQueue.main.async { self.menuBar.refreshIcon() }
    }

    func wakeDisplay() { power.nudgeDisplayAwake() }

    func sendLidState() {
        server?.send(status: ["t": "lid",
                              "awake": lidAwake,
                              "helper": PowerManager.helperInstalled,
                              "power": power.state.rawValue,
                              "battery": PowerManager.onBattery])
    }

    private var warnedAboutLid = false

    /// Silence here means the Mac vanishes the moment the lid is shut, with no
    /// hint as to why, so say it once per run.
    private func warnIfLidWillSleep() {
        guard !warnedAboutLid, !lidAwake else { return }
        warnedAboutLid = true
        let message = PowerManager.helperInstalled
            ? "This Mac will sleep when you close its lid. Turn on “Keep the Mac awake” under Settings ▸ With the lid closed."
            : "This Mac will sleep when you close its lid. To prevent that, run on the Mac: sudo Scripts/install-helper.sh"
        server?.send(status: ["t": "warn", "m": message])
    }

    private func startCapture() async {
        do {
            try await capturer.start()
            guard control.sync(execute: { self.enabled && self.server.viewers.total > 0 }) else {
                await capturer.stop()
                return
            }
            input.bounds = capturer.displayBounds
            control.async { self.needsKeyframe = true }
            print("▶︎ capturing \(capturer.pixelSize.width)x\(capturer.pixelSize.height) @ \(options.fps)fps")
        } catch {
            FileHandle.standardError.write(Data("capture failed: \(error.localizedDescription)\n".utf8))
            Speech.say("Screen capture failed. Check the screen recording permission.")
        }
    }

    private func restartCaptureIfNeeded() {
        control.asyncAfter(deadline: .now() + 1) {
            guard self.enabled, self.server.viewers.total > 0, !self.capturer.isRunning else { return }
            Task { await self.startCapture() }
        }
    }

    // MARK: - Matching the Mac's resolution to the phone

    /// A 16:10 desktop shown on a 19.5:9 phone wastes a third of the screen, and
    /// a full-size desktop is unreadable at phone scale. Both go away if the Mac
    /// simply runs at a shape and size that suits the screen it is being shown on.
    private func matchDisplayToPhone() {
        guard matchPhoneDisplay, enabled, server.viewers.native > 0 else { return }
        let displayID = capturer.displayID != 0 ? capturer.displayID : CGMainDisplayID()
        guard let currentMode = DisplayMode.current(displayID) else { return }
        guard let target = DisplayMode.best(for: displayID,
                                            targetWidth: phoneTargetWidth,
                                            aspect: phoneAspect) else { return }

        // Rotating a 16:9 desktop gives 9:16 — a phone shape — so the mode
        // picker's job does not change, only the framebuffer's orientation.
        let wantedRotation = phonePortrait ? 90 : 0
        let currentRotation = DisplayRotation.current(displayID)

        guard target.width != currentMode.width || target.height != currentMode.height
                || wantedRotation != currentRotation else {
            // Already the right size, but with nothing recorded to go back to —
            // which happens if a previous run was killed while shrunk. Without
            // this the display would be stuck small with no way home.
            if savedDisplayMode == nil, let native = DisplayMode.native(for: displayID),
               native.width != currentMode.width || native.height != currentMode.height {
                savedDisplayMode = native
                savedDisplayID = displayID
                savedRotation = 0
                DisplayMode.remember(native, displayID: displayID, rotation: 0)
                print("⤢ no record of the old resolution; will restore to \(DisplayMode.describe(native))")
            }
            return
        }

        if savedDisplayMode == nil {
            savedDisplayMode = currentMode
            savedDisplayID = displayID
            savedRotation = currentRotation
            DisplayMode.remember(currentMode, displayID: displayID, rotation: currentRotation)
        }

        if wantedRotation != currentRotation {
            if DisplayRotation.set(wantedRotation, on: displayID) {
                print("⤢ display rotated to \(wantedRotation)° for a phone held upright")
                // Rotating reconfigures the display, which invalidates every
                // CGDisplayMode fetched before it. Let that settle, then choose
                // again from the list the display now advertises.
                control.asyncAfter(deadline: .now() + 0.6) {
                    self.applyFittedMode(on: displayID)
                }
                return
            }
            print("⤢ this Mac will not rotate its display")
        }
        applyFittedMode(on: displayID)
    }

    private func applyFittedMode(on displayID: CGDirectDisplayID) {
        guard enabled, matchPhoneDisplay, server.viewers.native > 0 else { return }
        // Once the display is turned on its side, the modes it advertises are
        // portrait too — so the shape being matched has to be inverted, and the
        // target width becomes the short side rather than the long one.
        let rotated = [90, 270].contains(DisplayRotation.current(displayID))
        let wantedAspect = rotated ? 1 / phoneAspect : phoneAspect
        let wantedWidth = rotated ? Int((Double(phoneTargetWidth) / phoneAspect).rounded())
                                  : phoneTargetWidth

        guard let target = DisplayMode.best(for: displayID,
                                            targetWidth: wantedWidth,
                                            aspect: wantedAspect),
              let currentMode = DisplayMode.current(displayID) else { return }
        guard target.width != currentMode.width || target.height != currentMode.height else {
            refreshCaptureGeometry()
            return
        }
        if DisplayMode.apply(target, to: displayID) {
            print("⤢ display set to \(DisplayMode.describe(target)) for the phone")
        } else {
            print("⤢ could not switch display mode")
        }
        refreshCaptureGeometry()
    }

    /// Manual escape hatch: put the display back to its full resolution now,
    /// whatever we do or do not have recorded.
    func resetDisplayNow() {
        control.async {
            if self.savedDisplayMode != nil {
                self.restoreDisplayMode()
                return
            }
            let displayID = self.capturer.displayID != 0 ? self.capturer.displayID : CGMainDisplayID()
            guard let native = DisplayMode.native(for: displayID) else { return }
            DisplayMode.forget()
            DisplayRotation.set(0, on: displayID)
            if DisplayMode.apply(native, to: displayID) {
                print("⤢ display forced back to \(DisplayMode.describe(native))")
            }
            self.refreshCaptureGeometry()
        }
    }

    private func restoreDisplayMode() {
        guard let mode = savedDisplayMode else { return }
        savedDisplayMode = nil
        DisplayMode.forget()
        let displayID = savedDisplayID
        let rotation = savedRotation
        let width = mode.width, height = mode.height

        DisplayRotation.set(rotation, on: displayID)
        control.asyncAfter(deadline: .now() + 0.6) {
            // Same reason as above: re-find the mode after the rotation settles.
            let target = DisplayMode.all(displayID).first {
                $0.width == width && $0.height == height
            } ?? mode
            if DisplayMode.apply(target, to: displayID) {
                print("⤢ display restored to \(DisplayMode.describe(target))")
            } else {
                print("⤢ could not restore the display mode")
            }
            self.refreshCaptureGeometry()
        }
    }

    /// If a previous run was killed mid-session the display is still shrunk.
    private func restoreLeftoverDisplayMode() {
        guard let saved = DisplayMode.takePending() else { return }
        DisplayRotation.set(saved.rotation ?? 0, on: saved.displayID)
        guard let mode = DisplayMode.match(saved) else { return }
        if DisplayMode.apply(mode, to: saved.displayID) {
            print("⤢ display put back to \(DisplayMode.describe(mode)) after an unclean exit")
        }
    }

    /// Changing resolution invalidates the running capture and every coordinate
    /// the phone has been sending, so rebuild both.
    private func refreshCaptureGeometry() {
        control.asyncAfter(deadline: .now() + 0.8) {
            guard self.enabled, self.server.viewers.total > 0, self.capturer.isRunning else { return }
            Task {
                await self.capturer.stop()
                await self.startCapture()
            }
        }
    }

    // MARK: - Audio

    private func audioWantedChanged(_ wanted: Bool) {
        control.async {
            if wanted && !self.audio.isRunning {
                guard self.enabled, self.server.anyClientWantsAudio else { return }
                guard AudioCapture.findDevice() != nil else {
                    print("♪ audio requested but the Mac2Phone output device is not installed")
                    print("  install it with: sudo Scripts/install-audio.sh")
                    self.server.send(status: ["t": "warn",
                                              "m": "The Mac2Phone audio device is not installed on the Mac. Run: sudo Scripts/install-audio.sh"])
                    return
                }
                switch AudioCapture.microphonePermission() {
                case .denied:
                    print("♪ microphone permission denied — macOS will only hand us silence")
                    self.server.send(status: ["t": "warn",
                                              "m": "The Mac needs Microphone permission to read its own audio device: System Settings ▸ Privacy & Security ▸ Microphone ▸ Mac2Phone"])
                    return
                case .pending:
                    print("♪ asking for microphone permission…")
                    AudioCapture.requestMicrophone { granted in
                        print("♪ microphone permission \(granted ? "granted" : "refused")")
                        if granted { self.audioWantedChanged(true) }
                        else {
                            self.server.send(status: ["t": "warn",
                                                      "m": "Microphone permission was refused, so the Mac cannot read its own audio. Enable Mac2Phone under Privacy & Security ▸ Microphone."])
                        }
                    }
                    return
                case .granted:
                    break
                }
                do {
                    try self.audio.start()
                    self.server.sendAudioConfig(sampleRate: Int(self.audio.sampleRate),
                                                channels: self.audio.channels)
                    print("♪ streaming audio at \(Int(self.audio.sampleRate)) Hz")
                    self.scheduleSilenceCheck()
                } catch {
                    print("♪ audio capture failed: \(error.localizedDescription)")
                    self.server.send(status: ["t": "warn", "m": "Audio capture failed: \(error.localizedDescription)"])
                }
            } else if !wanted && self.audio.isRunning {
                self.audio.stop()
                print("♪ audio stopped")
            }
        }
    }

    /// Streaming perfect silence for seconds on end means something is wrong
    /// upstream, not that the Mac happens to be quiet — say so rather than
    /// letting the phone sit there playing nothing.
    private func scheduleSilenceCheck() {
        control.asyncAfter(deadline: .now() + 6) {
            guard self.audio.isRunning, !self.audio.sawSignal else { return }
            print("♪ nothing but silence so far — is Mac2Phone selected as the Mac's output device?")
            self.server.send(status: ["t": "warn",
                                      "m": "No sound is reaching Mac2Phone. Pick Mac2Phone under System Settings ▸ Sound ▸ Output, and allow Mac2Phone under Privacy & Security ▸ Microphone."])
        }
    }

    // MARK: - Frames

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, _ pts: CMTime) {
        let viewers = server.viewers

        // Skipping the encode (not just the send) when the socket is still busy
        // keeps the newest frame moving and costs nothing in quality: the encoder
        // simply predicts from the last frame it actually saw.
        if viewers.native > 0 && !server.nativeBacklog {
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var forceKeyframe = false

            control.sync {
                if encoderSize.width != width || encoderSize.height != height {
                    videoEncoder.prepare(width: width, height: height)
                    encoderSize = (width, height)
                    needsKeyframe = true
                }
                forceKeyframe = needsKeyframe
                needsKeyframe = false
            }
            videoEncoder.encode(pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
        }

        if viewers.desktop > 0, let jpeg = jpegEncoder.encode(pixelBuffer) {
            server.send(jpeg: jpeg)
        }
    }

    private func videoConfigPayload() -> Data? {
        guard let format = videoEncoder.currentFormat else { return nil }
        return VideoEncoder.encodeFormatPayload(format,
                                                displayWidth: Int(capturer.displayBounds.width),
                                                displayHeight: Int(capturer.displayBounds.height))
    }

    // MARK: - Input

    private var lastTrustWarning = Date.distantPast

    private func handleInput(_ message: [String: Any]) {
        // UIKit-style interaction and momentum live on one queue. Network
        // callbacks must not race a delayed scroll or a disconnect cleanup.
        if !Thread.isMainThread {
            DispatchQueue.main.async { self.handleInput(message) }
            return
        }
        guard options.control, enabled else { return }
        input.bounds = capturer.displayBounds
        if message["t"] as? String == "cancel" {
            touch.cancel()
            input.releaseAll()
            return
        }

        // Posting CGEvents without Accessibility silently does nothing, which
        // looks exactly like a broken app. Say so instead.
        if !input.isTrusted {
            if Date().timeIntervalSince(lastTrustWarning) > 5 {
                lastTrustWarning = Date()
                server.send(status: ["t": "warn",
                                     "m": "The Mac needs Accessibility permission before touch can control it: System Settings ▸ Privacy & Security ▸ Accessibility ▸ Mac2Phone"])
                input.requestAccessibility(prompt: true)
            }
            return
        }
        let type = message["t"] as? String ?? ""
        func number(_ key: String) -> Double {
            let value = (message[key] as? NSNumber)?.doubleValue ?? 0
            return value.isFinite ? min(10_000, max(-10_000, value)) : 0
        }
        let button = (message["b"] as? NSNumber)?.intValue ?? 0

        touch.bounds = capturer.displayBounds

        switch type {
        // Window-aware touch: the router decides what a touch means.
        case "tap", "tap2", "dbeg", "dmov", "dend", "pinch", "sw", "win":
            touch.handle(message)
        case "wake":
            power.nudgeDisplayAwake()
        case "resetdisplay":
            resetDisplayNow()

        // Trackpad and desktop clients speak in normalized pointer coordinates.
        case "m":   input.move(nx: number("x"), ny: number("y"))
        case "d":   input.down(button: button)
        case "u":   input.up(button: button)
        case "g":   input.drag(nx: number("x"), ny: number("y"), button: button)
        case "c":   input.click(nx: number("x"), ny: number("y"), button: button,
                                clickState: (message["n"] as? NSNumber)?.intValue ?? 1)
        case "s":   input.scroll(dx: number("dx"), dy: number("dy"))
        case "sb":  input.scrollBegin()
        case "se":  input.scrollEnd(velocityX: number("vx"), velocityY: number("vy"))
        case "z":   input.zoom(delta: number("d"))
        case "rm":  input.moveRelative(dx: number("dx"), dy: number("dy"),
                                       dragging: (message["drag"] as? Bool) ?? false)
        case "ch":  input.clickHere(button: button, clickState: (message["n"] as? NSNumber)?.intValue ?? 1)
        case "txt": input.type(text: message["s"] as? String ?? "")
        case "key": input.key(message["k"] as? String ?? "",
                              modifiers: message["m"] as? [String] ?? [])
        default: break
        }
    }

    // MARK: - Live settings

    private func handleSettings(_ message: [String: Any]) {
        control.async {
            var needsRestart = false
            var describesScreenLater = false

            if let width = (message["width"] as? NSNumber)?.intValue, width != self.capturer.maxWidth {
                self.capturer.maxWidth = width == 0 ? 0 : max(320, min(7680, width))
                needsRestart = true
            }
            if let fps = (message["fps"] as? NSNumber)?.intValue, fps != self.capturer.fps {
                self.capturer.fps = max(1, min(60, fps))
                self.videoEncoder.fps = self.capturer.fps
                needsRestart = true
            }
            if let cursor = message["cursor"] as? Bool, cursor != self.capturer.showsCursor {
                self.capturer.showsCursor = cursor
                needsRestart = true
            }
            if let display = (message["display"] as? NSNumber)?.intValue, display != self.capturer.displayIndex {
                self.capturer.displayIndex = display
                needsRestart = true
            }
            if let bitrate = (message["bitrate"] as? NSNumber)?.intValue {
                self.videoEncoder.updateBitrate(max(1_000_000, min(80_000_000, bitrate)))
            }
            if let lowPower = message["lidLowPower"] as? Bool {
                self.power.lowPowerWhenIdle = lowPower
            }
            if let lidAwake = message["lidAwake"] as? Bool {
                self.setLidAwake(lidAwake)
            }
            if let speed = (message["scrollSpeed"] as? NSNumber)?.doubleValue, speed > 0.05, speed < 5 {
                DispatchQueue.main.async { self.touch.scrollSpeed = speed }
            }
            if let quality = (message["q"] as? NSNumber)?.doubleValue {
                self.jpegEncoder.quality = max(0.1, min(1, quality))
            }
            if let aspect = (message["aspect"] as? NSNumber)?.doubleValue, aspect > 0.2, aspect < 5 {
                self.phoneAspect = aspect < 1 ? 1 / aspect : aspect
            }
            if let target = (message["fitWidth"] as? NSNumber)?.intValue, target >= 480 {
                self.phoneTargetWidth = min(4096, target)
            }
            if let portrait = message["portrait"] as? Bool, portrait != self.phonePortrait {
                self.phonePortrait = portrait
                describesScreenLater = true
            }
            // Re-evaluate whenever the phone describes itself, not only when the
            // toggle flips: on a fresh connection nothing has "changed" yet, and
            // that is exactly the moment the display needs reshaping.
            var describesScreen = false
            if let match = message["fitDisplay"] as? Bool {
                self.matchPhoneDisplay = match
                describesScreen = true
            }
            if message["aspect"] != nil || message["fitWidth"] != nil { describesScreen = true }
            if describesScreen || describesScreenLater {
                if self.matchPhoneDisplay { self.matchDisplayToPhone() } else { self.restoreDisplayMode() }
            }

            guard needsRestart, self.capturer.isRunning else { return }
            Task {
                let geometryChanged = await self.capturer.applySettings()
                self.input.bounds = self.capturer.displayBounds
                self.control.async {
                    if geometryChanged { self.encoderSize = (0, 0) }
                    self.needsKeyframe = true
                }
            }
        }
    }

    // MARK: - Hotkeys

    private func installHotKeys() {
        let mods = HotKeyCenter.Mod.control | HotKeyCenter.Mod.option | HotKeyCenter.Mod.command

        let toggled = HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_M), modifiers: mods) { [weak self] in
            self?.toggleEnabled()
        }
        let announced = HotKeyCenter.shared.register(keyCode: UInt32(kVK_ANSI_I), modifiers: mods) { [weak self] in
            self?.announce(intro: false)
        }
        if !toggled || !announced {
            FileHandle.standardError.write(Data("warning: could not register global hotkeys\n".utf8))
        }
    }

    func shutdown() {
        touch.cancel()
        input.releaseAll()
        server?.disconnectAll()
        restoreDisplayMode()
        power.set(.off)
    }

    private func toggleEnabled() {
        control.async { self.applyEnabled(!self.enabled) }
    }

    private func applyEnabled(_ on: Bool) {
        enabled = on
        if !on {
            DispatchQueue.main.async { self.touch.cancel(); self.input.releaseAll() }
            restoreDisplayMode()
            server.disconnectAll()
            Task { await self.capturer.stop() }
            print("⏸  mirroring disabled")
            Speech.say("Mirroring off")
        } else {
            print("▶︎ mirroring enabled")
            Speech.say("Mirroring on. Open the app on your phone.")
        }
        DispatchQueue.main.async { self.menuBar.refreshIcon() }
    }

    // MARK: - Reporting

    private func printDisplays() async {
        guard let displays = try? await ScreenCapturer.displays() else {
            print("Could not read displays — is Screen Recording permission granted?")
            return
        }
        for (index, d) in displays.enumerated() {
            print("  [\(index)] \(ScreenCapturer.describe(d))")
            let modes = DisplayMode.all(d.displayID)
            let sizes = Set(modes.map { "\($0.width)x\($0.height)" }).sorted()
            print("        modes: \(sizes.joined(separator: ", "))")
            if let best = DisplayMode.best(for: d.displayID, targetWidth: 960, aspect: 19.5 / 9.0) {
                print("        best fit for a 19.5:9 phone at 960 pt: \(DisplayMode.describe(best))")
            }
        }
    }

    private func printBanner() {
        let addresses = NetUtil.localAddresses()
        print("""

        ┌─ Mac2Phone ─────────────────────────────────────────
        │  listening on port \(options.port)
        │  codec: \(videoEncoder.describeMode)   bitrate: \(options.bitrate / 1_000_000) Mbps   fps: \(options.fps)
        │  remote control: \(options.control ? "on" : "off")
        │  audio device: \(AudioCapture.findDevice() != nil ? "installed" : "not installed")
        ├─ copy a private pairing link from the Mac dashboard
        │  and paste it into the iPhone or desktop app. LAN addresses:
        """)
        print("│    \(NetUtil.localHostName())")
        for (iface, ip) in addresses {
            let hint = ip.hasPrefix("172.20.10.") ? "   ← Personal Hotspot" : ""
            print("│    \(ip)   (\(iface))\(hint)")
        }
        print("""
        ├─ paired TLS only · protocol v2 · no browser/UDP listener
        ├─ hotkeys:  ⌃⌥⌘M enable/disable    ⌃⌥⌘I speak address
        └─────────────────────────────────────────────────────

        """)
    }

    private func announce(intro: Bool) {
        guard Date().timeIntervalSince(lastAnnounce) > 1 else { return }
        lastAnnounce = Date()

        let addresses = NetUtil.localAddresses()
        let hotspot = addresses.first { $0.ip.hasPrefix("172.20.10.") }
        let best = hotspot ?? addresses.first

        var text = intro ? "Mac to phone is ready. " : ""
        if let best {
            if hotspot != nil { text += "On hotspot. " }
            text += "Address " + Speech.spell(ip: best.ip) + ". "
        } else {
            text += "No network connection. Turn on your personal hotspot and connect this Mac to it. "
        }
        text += "Port \(Speech.spell(ip: String(options.port)))."
        Speech.say(text)
    }
}
