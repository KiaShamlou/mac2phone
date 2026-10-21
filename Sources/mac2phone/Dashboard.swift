import AppKit
import SwiftUI

struct DesktopActions {
    var setEnabled: (Bool) -> Void = { _ in }
    var setMatchDisplay: (Bool) -> Void = { _ in }
    var setLidAwake: (Bool) -> Void = { _ in }
    var restoreDisplay: () -> Void = {}
    var speakAddress: () -> Void = {}
    var requestMicrophone: () -> Void = {}
    var showAudioSetup: () -> Void = {}
    var showHelperSetup: () -> Void = {}
    var openLog: () -> Void = {}
    var quit: () -> Void = {}
    var copyPairingLink: () -> Void = {}
    var resetPairing: () -> Void = {}
    var nearby: NearbyService?
}

enum DesktopSection: String, CaseIterable, Identifiable {
    case overview = "Overview", display = "Display & power", permissions = "Permissions"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .display: return "display"
        case .permissions: return "checkmark.shield"
        }
    }
}

struct DesktopStatusPresentation {
    let status: AppController.Status
    var title: String {
        if !status.enabled { return "Taking a break." }
        if status.viewers.total > 0 { return "Your Mac is within reach." }
        return "Ready when you are."
    }
    var badge: String {
        if !status.enabled { return "PAUSED" }
        if !status.screenRecording { return "SETUP NEEDED" }
        return status.viewers.total > 0 ? "CONNECTED" : "READY TO CONNECT"
    }
    var stateLabel: String {
        if !status.enabled { return "Sharing paused" }
        if !status.screenRecording { return "Let’s finish setup" }
        return status.viewers.total > 0 ? "Your Mac is connected" : "Ready to connect"
    }
    var requiredPermissions: Int { (status.screenRecording ? 1 : 0) + (status.accessibility ? 1 : 0) }
    var connectionDetail: String {
        if !status.enabled { return "Resume sharing to make your Mac available again." }
        if !status.screenRecording { return "Allow Screen Recording in Permissions to share your Mac’s display." }
        if !status.accessibility { return "Screen sharing is ready. Allow Accessibility in Permissions to enable touch and keyboard control." }
        if status.viewers.total > 0 { return status.detail ?? "Connected over your local network." }
        return "Copy a pairing link, then paste it into Mac2Phone on your other device."
    }
}

private enum DesktopStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor.systemMint : NSColor(red: 0.0, green: 0.43, blue: 0.40, alpha: 1)
    })
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.15 : 1, alpha: 1)
    })
    static let canvas = Color(nsColor: NSColor(name: nil) { appearance in
        NSColor(calibratedWhite: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.10 : 0.95, alpha: 1)
    })
}

struct BrandMark: View {
    var size: CGFloat = 40
    private static let image = NSImage(data: IconMaker.makePNG(size: 180))
    var body: some View {
        Group {
            if let image = Self.image { Image(nsImage: image).resizable().interpolation(.high) }
            else { Image(systemName: "macbook.and.iphone").resizable().scaledToFit().padding(8) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
        .accessibilityHidden(true)
    }
}

final class DashboardWindowController: NSWindowController {
    init(statusProvider: @escaping () -> AppController.Status, actions: DesktopActions) {
        let host = NSHostingController(rootView: DashboardView(statusProvider: statusProvider, actions: actions))
        let window = NSWindow(contentViewController: host)
        window.title = "Mac2Phone"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 940, height: 760))
        window.minSize = NSSize(width: 780, height: 610)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Mac2PhoneWorkspace")
        window.center()
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("Use init(statusProvider:actions:)") }
    func present() {
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct DesktopGlyph: View {
    var symbol: String
    var color: Color = .teal
    var body: some View {
        Image(systemName: symbol).font(.system(size: 16, weight: .medium))
            .foregroundStyle(.white).frame(width: 30, height: 30)
            .background(color.gradient, in: .rect(cornerRadius: 8))
            .accessibilityHidden(true)
    }
}

private struct DesktopCard: ViewModifier {
    var radius: CGFloat = 20
    func body(content: Content) -> some View {
        content.background(DesktopStyle.surface, in: .rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(.primary.opacity(0.035), lineWidth: 1))
    }
}

struct DashboardView: View {
    let statusProvider: () -> AppController.Status
    let actions: DesktopActions
    @State private var section: DesktopSection = .overview
    @State private var copiedAddress: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(statusProvider: @escaping () -> AppController.Status, actions: DesktopActions, initialSection: DesktopSection = .overview) {
        self.statusProvider = statusProvider
        self.actions = actions
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = statusProvider()
            HStack(spacing: 0) {
                sidebar(status)
                Divider().opacity(0.5)
                VStack(spacing: 0) {
                    HStack {
                        Label("Mac2Phone", systemImage: "macbook.and.iphone").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        Spacer()
                        Button(action: actions.openLog) { Image(systemName: "doc.text.magnifyingglass").frame(width: 28, height: 28) }
                            .buttonStyle(.plain).help("Open diagnostic log").accessibilityLabel("Open diagnostic log")
                    }.padding(.horizontal, 30).padding(.top, 18).padding(.bottom, 8)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch section {
                            case .overview:
                                overview(status)
                                if let service = actions.nearby { NearbyMacDevices(service: service) }
                            case .display: display(status)
                            case .permissions: permissions(status)
                            }
                        }.padding(.horizontal, 30).padding(.top, 15).padding(.bottom, 30)
                            .frame(maxWidth: 790, alignment: .leading).frame(maxWidth: .infinity)
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(DesktopStyle.canvas)
            }
        }
        .tint(DesktopStyle.accent).frame(minWidth: 780, minHeight: 610).ignoresSafeArea()
    }

    private func sidebar(_ status: AppController.Status) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Workspace").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.top, 57)
            VStack(spacing: 5) {
                ForEach(DesktopSection.allCases) { item in
                    Button { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { section = item } } label: {
                        HStack(spacing: 10) {
                            DesktopGlyph(symbol: item.symbol, color: item == .overview ? .teal : (item == .display ? .blue : .indigo))
                            Text(item.rawValue).font(.system(size: 13, weight: section == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                            if item == .permissions && (!status.screenRecording || !status.accessibility) {
                                Circle().fill(.orange).frame(width: 6, height: 6)
                            }
                        }.padding(8).background(section == item ? Color.teal.opacity(0.12) : .clear, in: .rect(cornerRadius: 12))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(section == item ? .isSelected : [])
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 10) {
                    BrandMark(size: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac2Phone").font(.system(size: 13, weight: .semibold))
                        Text("Development preview").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                }
                Divider()
                Link(destination: URL(string: "https://github.com/KiaShamlou/mac2phone")!) {
                    Label("Project on GitHub", systemImage: "arrow.up.right.square").font(.system(size: 12))
                }.foregroundStyle(.secondary)
                Button("Quit Mac2Phone", action: actions.quit).buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }.padding(.horizontal, 12)
        }.padding(.horizontal, 12).padding(.bottom, 24).frame(width: 205).background(.thinMaterial)
    }

    @ViewBuilder private func overview(_ status: AppController.Status) -> some View {
        let presentation = DesktopStatusPresentation(status: status)
        heading("Your Mac", subtitle: "A familiar desktop. A whole new way to use it.")
        VStack(spacing: 22) {
            HStack(spacing: 20) {
                Image(systemName: status.enabled ? "macbook.and.iphone" : "pause.fill")
                    .font(.system(size: 36, weight: .light)).foregroundStyle(status.enabled ? Color.teal : .secondary)
                    .frame(width: 84, height: 84).background(.teal.opacity(0.08), in: .rect(cornerRadius: 25))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(presentation.stateLabel).font(.system(size: 23, weight: .semibold)).tracking(-0.5)
                    Text(presentation.connectionDetail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true).lineSpacing(3)
                    Label(status.enabled ? "Local network" : "Not sharing", systemImage: status.enabled ? "wifi" : "pause.circle")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopStyle.accent)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Screen Sharing").font(.system(size: 13, weight: .medium))
                    Text(status.enabled ? "Your devices can connect to this Mac." : "Turn on when you’re ready to connect.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Screen Sharing", isOn: Binding(get: { status.enabled }, set: actions.setEnabled))
                    .labelsHidden().toggleStyle(.switch)
            }
        }.padding(24).modifier(DesktopCard(radius: 26))
        HStack(spacing: 12) {
            summary("Devices", value: "\(status.viewers.total) connected", icon: "iphone", color: .teal)
            summary("Permissions", value: "\(presentation.requiredPermissions) of 2 ready", icon: "checkmark.shield", color: .indigo) { section = .permissions }
            summary("Display", value: status.matchesDisplay ? "Automatic fit" : "Original size", icon: "display", color: .blue) { section = .display }
        }
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button("Copy Pairing Link", systemImage: "link", action: actions.copyPairingLink).buttonStyle(.borderedProminent)
                Button("Reset Pairing", action: actions.resetPairing).buttonStyle(.bordered)
            }
            Text("Connect your devices").font(.system(size: 15, weight: .semibold)).padding(.horizontal, 4)
            VStack(spacing: 0) {
                ForEach(Array(status.addresses.enumerated()), id: \.element) { index, address in
                    if index > 0 { Divider().padding(.leading, 56) }
                    Button { copy(address) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: index == 0 ? "desktopcomputer" : "network").font(.system(size: 17)).foregroundStyle(DesktopStyle.accent).frame(width: 24)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(index == 0 ? "Mac address" : "Network address").font(.system(size: 11)).foregroundStyle(.secondary)
                                Text(address).font(.system(size: 12, design: .monospaced)).textSelection(.disabled)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                            }
                            Spacer(minLength: 8)
                            Label(copiedAddress == address ? "Copied" : "Copy", systemImage: copiedAddress == address ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopStyle.accent)
                        }.padding(18).contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("Copy \(address)")
                }
                if status.addresses.isEmpty { Label("Waiting for a network connection", systemImage: "wifi.slash").foregroundStyle(.secondary).padding(20) }
            }.modifier(DesktopCard())
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "iphone.gen3.radiowaves.left.and.right").foregroundStyle(DesktopStyle.accent)
                Text("Copy a pairing link and paste it into the iPhone or desktop app. Keep the link private: it grants access to this Mac.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(action: actions.speakAddress) { Image(systemName: "speaker.wave.2").frame(width: 28, height: 28) }
                    .buttonStyle(.plain).help("Speak the address").accessibilityLabel("Speak the address")
            }.padding(.horizontal, 4).padding(.top, 2)
        }
        Label("Paired connections use encrypted TLS. Reset pairing to revoke all shared links.", systemImage: "info.circle")
            .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func display(_ status: AppController.Status) -> some View {
        heading("Display & Power", subtitle: "Make your Mac feel at home on a smaller screen.")
        groupTitle("Display", symbol: "display", color: .blue)
        VStack(spacing: 0) {
            settingToggle("Fit to Your Device", detail: "Temporarily match the Mac display to your iPhone or iPad. Disconnecting restores the original mode.", value: status.matchesDisplay, set: actions.setMatchDisplay)
            Divider().padding(.leading, 20)
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Current Resolution").font(.system(size: 13, weight: .medium))
                    Text(status.displayMode ?? "System default").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restore Original", action: actions.restoreDisplay).controlSize(.large)
            }.padding(20)
        }.modifier(DesktopCard())
        groupTitle("Power", symbol: "bolt.fill", color: .orange)
        VStack(spacing: 0) {
            settingToggle("Keep Awake with Lid Closed", detail: "Optional. Requires the helper and may increase battery use.", value: status.lidAwake, set: actions.setLidAwake)
            Divider().padding(.leading, 20)
            HStack {
                Label(status.lidHelperInstalled ? "Helper installed" : "Helper setup needed", systemImage: status.lidHelperInstalled ? "checkmark.circle.fill" : "info.circle")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if !status.lidHelperInstalled { Button("Set Up…", action: actions.showHelperSetup).controlSize(.large) }
            }.padding(20)
            if status.lidAwake {
                Divider().padding(.leading, 20)
                LabeledContent("Power mode", value: "\(status.powerState)\(status.onBattery ? " · on battery" : "")")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(20)
            }
        }.modifier(DesktopCard())
        Label("Press ⌃⌥⌘M anytime to pause sharing.", systemImage: "keyboard").font(.system(size: 12)).foregroundStyle(.secondary)
    }

    @ViewBuilder private func permissions(_ status: AppController.Status) -> some View {
        heading("Permissions", subtitle: "A little setup, and you’re ready to go.")
        groupTitle("Screen & Control", symbol: "checkmark.shield.fill", color: .indigo)
        VStack(spacing: 0) {
            permissionRow("Screen Recording", detail: "Share your desktop with your devices.", symbol: "rectangle.inset.filled", color: .blue, granted: status.screenRecording) { openPrivacy("Privacy_ScreenCapture") }
            Divider().padding(.leading, 66)
            permissionRow("Accessibility", detail: "Use touch, scrolling, and the keyboard.", symbol: "hand.tap.fill", color: .teal, granted: status.accessibility) { openPrivacy("Privacy_Accessibility") }
        }.modifier(DesktopCard())
        groupTitle("Audio · Optional", symbol: "speaker.wave.2.fill", color: .pink)
        VStack(spacing: 0) {
            permissionRow("Microphone Permission", detail: "Read the virtual audio output, not a microphone.", symbol: "waveform", color: .pink, granted: status.microphone, action: actions.requestMicrophone)
            Divider().padding(.leading, 66)
            permissionRow("Virtual Audio Device", detail: "Route Mac audio to your iPhone or iPad.", symbol: "hifispeaker.fill", color: .purple, granted: status.audioDeviceInstalled, action: actions.showAudioSetup)
        }.modifier(DesktopCard())
        VStack(alignment: .leading, spacing: 8) {
            Label("Keep it on your network", systemImage: "network").font(.system(size: 13, weight: .semibold))
            Text("Connections require a private pairing link and use encrypted TLS. Reset pairing to revoke all devices. This development preview is intended for your LAN.")
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
        }.padding(20).background(.orange.opacity(0.07), in: .rect(cornerRadius: 20))
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 32, weight: .bold)).tracking(-0.8)
            Text(subtitle).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
    private func groupTitle(_ title: String, symbol: String, color: Color) -> some View {
        Label(title, systemImage: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(color).padding(.horizontal, 4)
    }
    @ViewBuilder private func summary(_ title: String, value: String, icon: String, color: Color,
                                      action: (() -> Void)? = nil) -> some View {
        let card = VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(value).font(.system(size: 12, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(16).modifier(DesktopCard(radius: 18)).contentShape(Rectangle())
        if let action { Button(action: action) { card }.buttonStyle(.plain) }
        else { card.accessibilityElement(children: .combine) }
    }
    private func settingToggle(_ title: String, detail: String, value: Bool, set: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Toggle(title, isOn: Binding(get: { value }, set: set)).labelsHidden().toggleStyle(.switch)
        }.padding(20)
    }
    private func permissionRow(_ title: String, detail: String, symbol: String, color: Color, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: 14) {
            DesktopGlyph(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if granted { Label("Ready", systemImage: "checkmark.circle.fill").font(.system(size: 11, weight: .medium)).foregroundStyle(DesktopStyle.accent) }
            else { Button("Set Up…", action: action).controlSize(.large) }
        }.padding(20)
    }
    private func copy(_ address: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string)
        copiedAddress = address
    }
}

struct MenuPopoverView: View {
    let statusProvider: () -> AppController.Status
    let actions: DesktopActions
    let openDashboard: () -> Void
    @State private var copied = false
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let status = statusProvider()
            let presentation = DesktopStatusPresentation(status: status)
            VStack(spacing: 18) {
                HStack(spacing: 11) {
                    BrandMark(size: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mac2Phone").font(.system(size: 16, weight: .semibold))
                        Text(presentation.stateLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: actions.quit) { Image(systemName: "power").font(.system(size: 13)).frame(width: 30, height: 30).background(.primary.opacity(0.05), in: .circle) }
                        .buttonStyle(.plain).help("Quit Mac2Phone").accessibilityLabel("Quit Mac2Phone")
                }
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        DesktopGlyph(symbol: "rectangle.on.rectangle", color: .teal)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Screen Sharing").font(.system(size: 13, weight: .medium))
                            Text(status.enabled ? "\(status.viewers.total) devices connected" : "Paused")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 6)
                        Toggle("Screen Sharing", isOn: Binding(get: { status.enabled }, set: actions.setEnabled))
                            .labelsHidden().toggleStyle(.switch)
                    }.padding(16)
                    if let address = status.addresses.first {
                        Divider().padding(.leading, 16)
                        Button {
                            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(address, forType: .string); copied = true
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "network").foregroundStyle(DesktopStyle.accent)
                                Text(address).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 4)
                                Image(systemName: copied ? "checkmark" : "doc.on.doc").foregroundStyle(DesktopStyle.accent)
                            }.padding(16).contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(copied ? "Address copied" : "Copy \(address)")
                    }
                }.modifier(DesktopCard(radius: 18))
                if presentation.requiredPermissions < 2 {
                    Button(action: openDashboard) {
                        HStack(spacing: 9) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text("Finish setup").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(presentation.requiredPermissions) of 2 ready").font(.system(size: 11)).foregroundStyle(.secondary)
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                Button("Copy Pairing Link", systemImage: "link", action: actions.copyPairingLink).buttonStyle(.bordered)
                Button(action: openDashboard) {
                    HStack { Text("Open Mac2Phone"); Spacer(); Image(systemName: "arrow.up.right") }
                        .font(.system(size: 13, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 12)
                        .foregroundStyle(.white).background(Color(red: 0.0, green: 0.43, blue: 0.40).gradient, in: .capsule)
                }.buttonStyle(.plain).keyboardShortcut(",", modifiers: .command)
                Text("Protocol v2 · paired and encrypted").font(.system(size: 10)).foregroundStyle(.secondary)
            }.padding(18).frame(width: 360).tint(DesktopStyle.accent).background(DesktopStyle.canvas)
        }
    }
}

private func openPrivacy(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

struct NearbyMacDevices: View {
    @ObservedObject var service: NearbyService
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nearby devices", systemImage: "antenna.radiowaves.left.and.right").font(.headline)
            Text("Select this Mac on another device to request its screen. Every new connection needs approval.").foregroundStyle(.secondary)
            if service.devices.isEmpty { Text("Looking for devices with Mac2Phone open…").font(.callout).foregroundStyle(.secondary) }
            ForEach(service.devices) { device in
                HStack { Image(systemName: "network"); Text(device.name); Spacer(); Text(device.platform).foregroundStyle(.secondary) }.padding(.vertical, 5)
            }
            if !service.notice.isEmpty { Text(service.notice).font(.caption).foregroundStyle(.secondary) }
        }.padding(20).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 20))
    }
}
struct NearbyMacApproval: View {
    @ObservedObject var service: NearbyService
    let allowsControl: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let request = service.incoming {
                Label("Connection request", systemImage: "person.crop.circle.badge.questionmark").font(.title2.bold())
                Text("\(request.name) · \(request.platform)").font(.headline)
                Text(request.code).font(.system(size: 38, weight: .semibold, design: .monospaced)).textSelection(.enabled)
                Text("Accept only if this code matches the other screen. You will share your screen and supported sound\(allowsControl ? ", with mouse and keyboard control." : " in view-only mode.")").foregroundStyle(.secondary)
                HStack {
                    Button("Decline") { service.respond(accept: false) }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Accept & share") { service.respond(accept: true) }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(26).frame(width: 440).tint(.teal)
    }
}
