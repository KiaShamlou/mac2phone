import AppKit
import AVFoundation
import ApplicationServices
import CoreGraphics
import SwiftUI

/// Lightweight menu-bar controls, with an optional dashboard for setup and recovery.
final class MenuBarController: NSObject, NSMenuDelegate {

    private weak var controller: AppController?
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var dashboard: DashboardWindowController?
    private let popover = NSPopover()

    init(controller: AppController) {
        self.controller = controller
        super.init()
    }

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "macbook.and.iphone",
                                     accessibilityDescription: "Mac2Phone")
        item.button?.image?.isTemplate = true
        menu.delegate = self
        item.button?.target = self
        item.button?.action = #selector(statusClicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item.button?.toolTip = "Mac2Phone — click for controls, right-click for the classic menu"
        statusItem = item
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        refreshIcon()
        if !UserDefaults.standard.bool(forKey: "hasShownWorkspaceV3") {
            UserDefaults.standard.set(true, forKey: "hasShownWorkspaceV3")
            DispatchQueue.main.async { [weak self] in self?.openDashboard() }
        }
    }

    func refreshIcon() {
        guard let controller else { return }
        let connected = controller.status.viewers.total > 0
        let name = connected ? "macbook.and.iphone" : "macbook"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Mac2Phone")
        statusItem?.button?.image?.isTemplate = true
    }

    // MARK: - Menu

    private var actions: DesktopActions {
        DesktopActions(
            setEnabled: { [weak self] in self?.controller?.setEnabled($0) },
            setMatchDisplay: { [weak self] in self?.controller?.setMatchDisplay($0) },
            setLidAwake: { [weak self] in self?.controller?.setLidAwake($0) },
            restoreDisplay: { [weak self] in self?.resetDisplay() },
            speakAddress: { [weak self] in self?.speak() },
            requestMicrophone: { [weak self] in self?.askMicrophone() },
            showAudioSetup: { [weak self] in self?.showAudioInstructions() },
            showHelperSetup: { [weak self] in self?.showHelperInstructions() },
            openLog: { [weak self] in self?.openLog() },
            quit: { [weak self] in self?.quit() },
            copyPairingLink: { [weak self] in self?.controller?.copyPairingLink() },
            resetPairing: { [weak self] in self?.controller?.resetPairing() }, nearby: controller?.nearby)
    }

    @objc private func statusClicked() {
        guard let button = statusItem?.button, let controller else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.close()
            rebuild()
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 4), in: button)
            return
        }
        if popover.isShown { popover.performClose(nil); return }
        let host = NSHostingController(rootView: MenuPopoverView(
            statusProvider: { controller.status }, actions: actions,
            openDashboard: { [weak self] in self?.openDashboard() }))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild()
    }

    private func rebuild() {
        menu.removeAllItems()
        guard let controller else { return }
        let status = controller.status

        let open = NSMenuItem(title: "Open Mac2Phone…", action: #selector(openDashboard), keyEquivalent: ",")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(header(status.headline))
        if let detail = status.detail {
            menu.addItem(header(detail, small: true))
        }
        menu.addItem(.separator())

        for address in status.addresses.prefix(3) {
            let item = NSMenuItem(title: address, action: #selector(copyAddress(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = address
            item.toolTip = "Copy"
            menu.addItem(item)
        }
        let speak = NSMenuItem(title: "Speak the address", action: #selector(speak), keyEquivalent: "i")
        speak.keyEquivalentModifierMask = [.control, .option, .command]
        speak.target = self
        menu.addItem(speak)

        menu.addItem(.separator())

        let mirroring = NSMenuItem(title: "Mirroring", action: #selector(toggleMirroring), keyEquivalent: "m")
        mirroring.keyEquivalentModifierMask = [.control, .option, .command]
        mirroring.target = self
        mirroring.state = status.enabled ? .on : .off
        menu.addItem(mirroring)

        let fit = NSMenuItem(title: "Reshape display for the phone", action: #selector(toggleFit), keyEquivalent: "")
        fit.target = self
        fit.state = status.matchesDisplay ? .on : .off
        menu.addItem(fit)

        let lid = NSMenuItem(title: "Stay awake with the lid closed",
                             action: #selector(toggleLidAwake), keyEquivalent: "")
        lid.target = self
        lid.state = status.lidAwake ? .on : .off
        menu.addItem(lid)
        if status.lidAwake {
            let detail = status.powerState == "active" ? "full speed — a phone is watching"
                                                       : "idling to save power"
            menu.addItem(header("  \(detail)\(status.onBattery ? " · on battery" : "")", small: true))
        }
        if status.lidAwake && !status.lidHelperInstalled {
            let warn = NSMenuItem(title: "  needs the helper — how…",
                                  action: #selector(showHelperInstructions), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        if let mode = status.displayMode {
            menu.addItem(header("Display: \(mode)", small: true))
        }
        let reset = NSMenuItem(title: "Restore display resolution",
                               action: #selector(resetDisplay), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

        menu.addItem(.separator())
        menu.addItem(header("Permissions", small: true))
        menu.addItem(permissionItem("Screen Recording", status.screenRecording,
                                    pane: "Privacy_ScreenCapture"))
        menu.addItem(permissionItem("Accessibility", status.accessibility,
                                    pane: "Privacy_Accessibility"))
        if status.microphone {
            menu.addItem(permissionItem("Microphone", true, pane: "Privacy_Microphone"))
        } else {
            // Microphone is the one pane with no "+" button, so the app has
            // to ask for itself before it can even be listed there.
            let ask = NSMenuItem(title: "Microphone — ask for access…",
                                 action: #selector(askMicrophone), keyEquivalent: "")
            ask.target = self
            menu.addItem(ask)
        }

        let audioDevice = NSMenuItem(
            title: status.audioDeviceInstalled ? "Audio device installed ✓" : "Audio device not installed",
            action: status.audioDeviceInstalled ? nil : #selector(showAudioInstructions),
            keyEquivalent: "")
        audioDevice.target = self
        menu.addItem(audioDevice)

        menu.addItem(.separator())
        let log = NSMenuItem(title: "Open log", action: #selector(openLog), keyEquivalent: "")
        log.target = self
        menu.addItem(log)

        let quit = NSMenuItem(title: "Quit Mac2Phone", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func header(_ text: String, small: Bool = false) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        let font = small ? NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
                         : NSFont.menuBarFont(ofSize: 0)
        item.attributedTitle = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: small ? NSColor.secondaryLabelColor : NSColor.labelColor
        ])
        return item
    }

    private func permissionItem(_ name: String, _ granted: Bool, pane: String) -> NSMenuItem {
        let item = NSMenuItem(title: granted ? "\(name) ✓" : "\(name) — grant…",
                              action: granted ? nil : #selector(openPane(_:)),
                              keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        return item
    }

    // MARK: - Actions

    @objc private func openDashboard() {
        guard let controller else { return }
        popover.close()
        if dashboard == nil { dashboard = DashboardWindowController(statusProvider: { controller.status }, actions: actions) }
        dashboard?.present()
    }

    @objc private func copyAddress(_ sender: NSMenuItem) {
        guard let address = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
    }

    @objc private func speak() { controller?.speakAddress() }
    @objc private func toggleMirroring() { controller?.setEnabled(!(controller?.status.enabled ?? true)) }
    @objc private func toggleFit() { controller?.setMatchDisplay(!(controller?.status.matchesDisplay ?? true)) }

    @objc private func openPane(_ sender: NSMenuItem) {
        guard let pane = sender.representedObject as? String,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func resetDisplay() { controller?.resetDisplayNow() }

    @objc private func toggleLidAwake() {
        guard let controller else { return }
        controller.setLidAwake(!controller.lidAwake)
    }

    @objc private func showHelperInstructions() {
        let alert = NSAlert()
        alert.messageText = "One more step to survive a closed lid"
        alert.informativeText = "Closing the lid is not idle sleep — it sleeps the Mac immediately, and no ordinary app can stop that. A small helper daemon can, and installing it needs your password once.\n\nIn Terminal, from the project folder:\n\n    sudo Scripts/install-helper.sh"
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func askMicrophone() {
        AudioCapture.requestMicrophone { granted in
            guard !granted else { return }
            let alert = NSAlert()
            alert.messageText = "Microphone access was not granted"
            alert.informativeText = "Mac2Phone reads the audio your apps play into its own virtual output device. macOS files that under Microphone, even though no microphone is involved.\n\nTurn on Mac2Phone under System Settings \u{25B8} Privacy & Security \u{25B8} Microphone."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Later")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    @objc private func showAudioInstructions() {
        let alert = NSAlert()
        alert.messageText = "Install the Mac2Phone audio device"
        alert.informativeText = """
        The virtual output device lives in a system folder, so installing it needs your password.

        In Terminal, from the project folder:

            Scripts/build-audio.sh
            sudo Scripts/install-audio.sh

        Then pick Mac2Phone under Sound ▸ Output.
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func openLog() {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/mac2phone.log")
        NSWorkspace.shared.open(url)
    }

    @objc private func quit() {
        controller?.shutdown()
        NSApp.terminate(nil)
    }
}
