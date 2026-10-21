import SwiftUI
import Network

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var mirror: MirrorController

    init(mirror: MirrorController) {
        self.mirror = mirror
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if model.isConnected {
                MirrorScreen(client: model.client)
            } else {
                ConnectScreen(discovery: model.discovery, client: model.client)
            }
        }
        .background(NearbyInbox(service: model.discovery))
        .sheet(isPresented: $model.showRequestedBroadcast) { BroadcastView() }
        .tint(.teal)
        .preferredColorScheme(model.isConnected ? .dark : nil)
        .statusBarHidden(model.isConnected)
        .persistentSystemOverlays(model.isConnected ? .hidden : .automatic)
        .onAppear { model.onAppear() }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.onAppear()
            case .inactive: model.mirror.cancelInteraction(); WatchRelay.shared.publish()
            case .background: model.suspend()
            @unknown default: break
            }
        }
    }
}

// MARK: - Connect

struct ConnectScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var discovery: Discovery
    @ObservedObject var client: StreamClient
    @State private var showAddress = false
    @State private var showHelp = false
    @State private var showBroadcast = false

    private var connecting: Bool {
        if case .connecting = client.state { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    connectionHero
                    if !model.statusText.isEmpty {
                        HStack(spacing: 12) {
                            if connecting { ProgressView().tint(.teal) }
                            else { Image(systemName: "wifi.exclamationmark").foregroundStyle(.orange) }
                            Text(model.statusText).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if connecting { Button("Cancel") { model.disconnect() }.font(.subheadline.weight(.semibold)) }
                        }
                        .padding(18).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    }
                    if !discovery.notice.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(discovery.notice).font(.callout)
                            if discovery.outgoing != nil { Button("Cancel request") { discovery.cancel() } }
                        }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 22))
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Nearby devices").font(.title3.bold())
                            Spacer()
                            if discovery.probing { ProgressView().controlSize(.small).accessibilityLabel("Searching for nearby devices") }
                        }.padding(.horizontal, 4)
                        VStack(spacing: 0) {
                            if discovery.all.isEmpty {
                                HStack(alignment: .top, spacing: 14) {
                                    SettingsGlyph("antenna.radiowaves.left.and.right", tint: .teal)
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("Looking for devices…").font(.headline)
                                        Text("Open Mac2Phone on both devices and connect them to the same network.")
                                            .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer(minLength: 0)
                                }.padding(20)
                            } else {
                                ForEach(Array(discovery.all.enumerated()), id: \.element.id) { index, mac in
                                    if index > 0 { Divider().padding(.leading, 72) }
                                    Button { model.connect(to: mac) } label: {
                                        HStack(spacing: 14) {
                                            SettingsGlyph("desktopcomputer", tint: .teal)
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(mac.name).font(.headline).foregroundStyle(.primary)
                                                Label("\(mac.platform) · Request connection", systemImage: "circle.fill")
                                                    .font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer(minLength: 8)
                                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                        }.padding(18).contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain).disabled(connecting)
                                    .accessibilityHint("Send a connection request")
                                }
                            }
                        }.background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                    }
                    VStack(spacing: 0) {
                        Button { showAddress = true } label: {
                            connectionRow("Pair a device", subtitle: "Paste a link from the sharing device", symbol: "network", color: .blue)
                        }.buttonStyle(.plain).disabled(connecting)
                        if !model.lastHost.isEmpty {
                            Divider().padding(.leading, 72)
                            Button { model.reconnect() } label: {
                                connectionRow("Connect again", subtitle: "Send a fresh Nearby request", symbol: "arrow.clockwise", color: .indigo)
                            }.buttonStyle(.plain).disabled(connecting)
                        }
                    }.background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                    VStack(spacing: 12) {
                        Button("Share this iPhone / iPad", systemImage: "dot.radiowaves.left.and.right") { showBroadcast = true }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                        Toggle("Apple Watch remote", isOn: Binding(get: { model.allowWatchControl }, set: { model.setWatchControl($0) }))
                        Text("Watch commands work only while this app is open, connected, and Control is enabled.").font(.caption).foregroundStyle(.secondary)
                    }.padding(18).background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 24))
                    VStack(spacing: 8) {
                        Label("Just your devices. No cloud account.", systemImage: "house.and.flag")
                            .font(.footnote.weight(.medium))
                        Text("Development preview · trusted private networks only")
                            .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity).padding(.bottom, 12)
                }
                .frame(maxWidth: 560).padding(.horizontal, 20).padding(.top, 8)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Mac2Phone")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Connection help", systemImage: "questionmark") { showHelp = true }
                }
            }
            .sheet(isPresented: $showAddress) { AddressSheet() }
            .sheet(isPresented: $showHelp) { ConnectionHelp() }
            .sheet(isPresented: $showBroadcast) { BroadcastView() }

        }
    }

    private var connectionHero: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().fill(.teal.opacity(0.08)).frame(width: 132, height: 132)
                Circle().stroke(.teal.opacity(0.12), lineWidth: 1).frame(width: 168, height: 168)
                Image(systemName: "macbook").font(.system(size: 76, weight: .light)).foregroundStyle(.teal).offset(x: -13, y: -3)
                Image(systemName: "iphone").font(.system(size: 54, weight: .regular))
                    .foregroundStyle(.teal)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemGroupedBackground)).frame(width: 28, height: 51))
                    .offset(x: 48, y: 20)
                Image(systemName: "hand.tap.fill").font(.system(size: 19)).foregroundStyle(.teal).offset(x: 47, y: 20)
            }.frame(height: 170).accessibilityHidden(true)
            VStack(spacing: 7) {
                Text("Your Mac. A touch away.").font(.title2.bold()).multilineTextAlignment(.center)
                Text("See your screen. Tap, type, and take control.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 20) {
                Label("Touch", systemImage: "hand.tap")
                Label("Pointer", systemImage: "cursorarrow")
                Label("Trackpad", systemImage: "rectangle.and.hand.point.up.left")
            }.font(.caption.weight(.medium)).foregroundStyle(.teal)
                .minimumScaleFactor(0.8).lineLimit(1)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 24).padding(.horizontal, 18)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 30))
    }

    private func connectionRow(_ title: String, subtitle: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 14) {
            SettingsGlyph(symbol, tint: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }.padding(18).contentShape(Rectangle())
    }
}

private struct SettingsGlyph: View {
    let symbol: String
    let tint: Color
    init(_ symbol: String, tint: Color) { self.symbol = symbol; self.tint = tint }
    var body: some View {
        Image(systemName: symbol).font(.system(size: 19, weight: .medium))
            .foregroundStyle(tint).frame(width: 40, height: 40)
            .background(tint.opacity(0.12), in: .rect(cornerRadius: 12)).accessibilityHidden(true)
    }
}

private struct AddressSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var host = ""
    @FocusState private var focused: Bool
    private var valid: Bool { !host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("mac2phone://… pairing link", text: $host)
                        .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL).submitLabel(.go).focused($focused)
                        .onSubmit { connect() }.accessibilityLabel("mac2phone://… pairing link")
                } header: { Text("Private pairing link") } footer: {
                    Text("Use Copy Pairing Link in the Mac app. Keep both devices on the same Wi-Fi or Personal Hotspot.")
                }
                Section {
                    Button(action: connect) {
                        Label("Connect to Mac", systemImage: "arrow.right.circle.fill")
                            .frame(maxWidth: .infinity, minHeight: 30)
                    }.disabled(!valid)
                }
            }
            .navigationTitle("Pair a Device").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
        .onAppear { host = ""; focused = true }
    }
    private func connect() { guard valid else { return }; model.connect(host: host); dismiss() }
}

private struct ConnectionHelp: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Three small steps") {
                    Label("Open Mac2Phone on your Mac.", systemImage: "desktopcomputer")
                    Label("Join the same Wi-Fi or Personal Hotspot.", systemImage: "wifi")
                    Label("Copy a pairing link from the Mac app.", systemImage: "hand.tap")
                }
                Section("Not seeing your Mac?") {
                    Text("Allow Local Network access on your iPhone. On your Mac, allow Screen Recording for sharing and Accessibility for touch control.")
                    Text("Tap Pair a device and paste the complete pairing link.")
                }
                Section("Development preview") {
                    Text("Connections require a private pairing link and use encrypted TLS. Reset pairing in the Mac app to revoke all shared links.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Let’s Get Connected").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
}

/// Native glass on new systems; legible standard materials on iOS 17–18.
private struct RemoteChrome: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var radius: CGFloat = 30
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        if reduceTransparency {
            content.background(Color(.secondarySystemBackground), in: shape)
        } else {
            #if compiler(>=6.2)
            if #available(iOS 26, *) {
                content.glassEffect(.regular, in: shape)
            } else {
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
            }
            #else
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(.white.opacity(0.14), lineWidth: 0.5))
            #endif
        }
    }
}


// MARK: - Mirror

private struct RemoteControlsHeight: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct MirrorScreen: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var client: StreamClient
    @State private var showControls = true
    @State private var showSettings = false
    @State private var showGuide = false
    @State private var showWindowRow = false
    @State private var hideTask: Task<Void, Never>?
    @State private var controlsHeight: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            MirrorView(client: client, controller: model.mirror,
                       controlsHeight: showControls ? controlsHeight : 56,
                       topOverlayHeight: showControls ? 34 : 0)
                .ignoresSafeArea()

            if showControls {
                VStack(spacing: 6) {
                    if showWindowRow && client.hostTouchMode == "ipad" { windowRow }
                    controlBar
                }
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: RemoteControlsHeight.self, value: proxy.size.height)
                    }
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                Button {
                    reveal()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(.ultraThinMaterial, in: .circle)
                }
                .accessibilityLabel("Show remote controls")
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 14)
                .padding(.bottom, 8)
            }
        }
        .overlay(alignment: .top) {
            if showControls {
                Button { showSettings = true } label: {
                    HStack(spacing: 7) {
                        Circle().fill(.green).frame(width: 5, height: 5)
                        Text("\(style.label) · \(client.stats.fps) fps")
                        Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .padding(.horizontal, 13).padding(.vertical, 8)
                    .modifier(RemoteChrome(radius: 22))
                }.buttonStyle(.plain).accessibilityLabel("Stream status: \(client.stats.fps) frames per second. Open settings")
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .center) {
            if let notice = client.notice {
                Text(notice)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .padding(14)
                    .background(.ultraThinMaterial, in: .rect(cornerRadius: 14))
                    .padding(.horizontal, 28)
                    .onTapGesture { client.notice = nil }
                    .task {
                        try? await Task.sleep(for: .seconds(8))
                        client.notice = nil
                    }
            }
        }
        .overlay(alignment: .top) {
            if showControls && !model.mirror.controlEnabled {
                Text(client.hostControl ? "View only — tap Control to interact" : "View-only broadcast — remote input is not available")
                    .font(.caption2)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: .capsule)
                    .padding(.top, 34)
            }
        }
        .animation(reduceMotion ? nil : .smooth(duration: 0.25), value: showControls)
        .onPreferenceChange(RemoteControlsHeight.self) { controlsHeight = $0 }
        .sheet(isPresented: $showSettings) { SettingsSheet(client: client).presentationDragIndicator(.visible) }
        .sheet(isPresented: $showGuide) { GestureGuide().presentationDragIndicator(.visible) }
        .onAppear { scheduleHide() }
        .onDisappear { hideTask?.cancel(); model.mirror.cancelInteraction() }
        .onChange(of: showSettings) { _, _ in scheduleHide() }
        .onChange(of: showGuide) { _, _ in scheduleHide() }
    }

    private var style: ControlStyle { ControlStyle(rawValue: model.mirror.controlStyle) ?? .ipad }

    /// Window and desktop controls the size of a fingertip, instead of the real
    /// traffic lights which are about twelve points across — and instead of
    /// relying on keyboard shortcuts the Mac may have turned off.
    private var windowRow: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                windowButton("xmark", "close", .red)
                windowButton("minus", "minimise", .yellow)
                windowButton("arrow.up.left.and.arrow.down.right", "zoom", .green)
                windowButton("rectangle.lefthalf.filled", "left", .secondary)
                windowButton("rectangle.righthalf.filled", "right", .secondary)
                windowButton("rectangle.fill", "full", .secondary)
            }
            HStack(spacing: 8) {
                spaceButton("chevron.left.2", "left", .primary)
                spaceButton("square.grid.3x2", "up", .primary)
                spaceButton("rectangle.stack", "down", .primary)
                spaceButton("chevron.right.2", "right", .primary)
                Button {
                    model.setPortrait(!model.portraitMode)
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    scheduleHide()
                } label: {
                    Image(systemName: model.portraitMode ? "iphone" : "macbook")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(model.portraitMode ? Color.white : Color.primary)
                        .background(model.portraitMode ? Color.accentColor : Color.white.opacity(0.08),
                                    in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                Button {
                    model.client.sendInput(["t": "wake"])
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    scheduleHide()
                } label: {
                    Image(systemName: "sun.max.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .foregroundStyle(.orange)
                        .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .modifier(RemoteChrome(radius: 24))
        .frame(maxWidth: 500)
        .padding(.horizontal, 12)
        .disabled(!model.controlEnabled)
    }

    private func spaceButton(_ icon: String, _ direction: String, _ tint: Color) -> some View {
        Button {
            model.client.sendInput(["t": "sw", "d": direction])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            scheduleHide()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(tint)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(["left": "Previous desktop", "right": "Next desktop", "up": "Mission Control", "down": "App windows"][direction] ?? direction)
    }

    private func windowButton(_ icon: String, _ action: String, _ tint: Color) -> some View {
        Button {
            let name = ["close": "close", "minimise": "min", "zoom": "zoom",
                        "left": "left", "right": "right", "full": "full"][action] ?? action
            model.client.sendInput(["t": "win", "a": name])
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            scheduleHide()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .foregroundStyle(tint)
                .background(.white.opacity(0.08), in: .rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Window: \(action)")
    }

    private var controlBar: some View {
        HStack(spacing: 6) {
            barButton("arrow.up.left.and.arrow.down.right", "Fit") { model.mirror.fit(); scheduleHide() }
            barButton(model.mirror.controlEnabled ? "hand.tap.fill" : "eye", "Control", active: model.mirror.controlEnabled) {
                model.setControlEnabled(!model.controlEnabled)
                scheduleHide()
            }.disabled(!client.hostControl)
            Menu {
                ForEach(ControlStyle.allCases, id: \.rawValue) { option in
                    Button {
                        model.setControlStyle(option)
                        scheduleHide()
                    } label: {
                        Label(option.label, systemImage: option == style ? "checkmark" : option.icon)
                    }
                }
                Divider()
                Text(style.hint)
                Button("Gesture guide", systemImage: "questionmark.circle") { showGuide = true }
            } label: {
                barLabel(style.icon, style.label, active: true)
            }
            .accessibilityLabel("Interaction mode: \(style.label)")
            .disabled(client.hostTouchMode != "ipad")
            barButton("keyboard", "Keyboard", active: model.mirror.keyboardVisible) {
                model.setControlEnabled(true)
                model.mirror.toggleKeyboard()
                scheduleHide()
            }.disabled(!client.hostControl)
            Menu {
                Button("Stream settings", systemImage: "slider.horizontal.3") { showSettings = true }.disabled(client.hostTouchMode != "ipad")
                Button("Window controls", systemImage: "macwindow.on.rectangle") {
                    showWindowRow.toggle(); scheduleHide()
                }.disabled(!model.mirror.controlEnabled || client.hostTouchMode != "ipad")
                Button(model.audioEnabled ? "Mute audio" : "Play audio",
                       systemImage: model.audioEnabled ? "speaker.slash" : "speaker.wave.2") {
                    model.audioEnabled.toggle(); client.audioEnabled = model.audioEnabled
                    model.objectWillChange.send(); scheduleHide()
                }.disabled(!client.hostAudio)
                Button("Actual pixels", systemImage: "1.magnifyingglass") { model.mirror.actualSize(); scheduleHide() }
                Button("Gesture guide", systemImage: "questionmark.circle") { showGuide = true }
                Button("Hide controls", systemImage: "chevron.down") { showControls = false }
                Divider()
                Button("Disconnect", systemImage: "xmark.circle", role: .destructive) { model.disconnect() }
            } label: { barLabel("ellipsis", "More") }
            .accessibilityLabel("More remote controls")
        }
        .padding(6)
        .modifier(RemoteChrome())
        .frame(maxWidth: 500)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func barLabel(_ icon: String, _ label: String, active: Bool = false) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 20, weight: .medium))
            if !model.mirror.keyboardVisible {
                Text(label).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: model.mirror.keyboardVisible ? 44 : 50)
        .foregroundStyle(active ? Color.teal : Color.primary)
        .padding(.horizontal, 2)
        .background(active ? Color.teal.opacity(0.16) : Color.clear, in: .rect(cornerRadius: 24))
        .accessibilityLabel(label)
        .contentShape(Rectangle())
    }

    private func barButton(_ systemName: String, _ label: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) { barLabel(systemName, label, active: active) }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(active ? "On" : "Off")
    }

    private func reveal() {
        showControls = true
        scheduleHide()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, !showSettings, !showGuide, !showWindowRow,
                  !model.mirror.keyboardVisible, !UIAccessibility.isVoiceOverRunning else { return }
            await MainActor.run { showControls = false }
        }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @ObservedObject var client: StreamClient
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var width: Double = 2560
    @State private var fps: Double = 30
    @State private var mbps: Double = 20
    @State private var cursor = true
    @State private var fitDisplay = true
    @State private var fitWidth = 960
    @State private var scrollSpeed = 1.0
    @State private var swipeReversed = false

    private let widths: [Double] = [1280, 1600, 1920, 2560, 3200, 0]

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick setup") {
                    preset("Responsive", detail: "1080p · 60 fps", symbol: "bolt.fill", color: .orange, resolution: 1920, rate: 60, bitrate: 16)
                    preset("Balanced", detail: "1440p · 30 fps", symbol: "circle.lefthalf.filled", color: .teal, resolution: 2560, rate: 30, bitrate: 20)
                    preset("Full Detail", detail: "Native resolution · 30 fps", symbol: "sparkle.magnifyingglass", color: .indigo, resolution: 0, rate: 30, bitrate: 30)
                    Text("Presets change this form. Tap Apply to send them to your Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Live connection") {
                    LabeledContent("Transport", value: client.stats.transport)
                    LabeledContent("Round trip", value: "\(client.stats.rttMs) ms")
                    LabeledContent("Received", value: "\(client.stats.fps) fps · \(client.stats.kbps / 1000) Mbps")
                    LabeledContent("Lost frames this interval", value: "\(client.stats.lostFrames)")
                }
                Section("Resolution") {
                    Picker("Width", selection: $width) {
                        ForEach(widths, id: \.self) { value in
                            Text(value == 0 ? "Native (full)" : "\(Int(value)) px").tag(value)
                        }
                    }
                    Text("Higher is sharper when you zoom in, and costs more bandwidth.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Frame rate: \(Int(fps)) fps") {
                    Slider(value: $fps, in: 5...60, step: 5).accessibilityLabel("Frame rate").accessibilityValue("\(Int(fps)) frames per second")
                }
                Section("Bitrate: \(Int(mbps)) Mbps") {
                    Slider(value: $mbps, in: 2...60, step: 2).accessibilityLabel("Bitrate").accessibilityValue("\(Int(mbps)) megabits per second")
                    Text("On Personal Hotspot, 15–25 Mbps is usually the sweet spot.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Mac display") {
                    Toggle("Reshape the Mac to fit this screen", isOn: $fitDisplay)
                    if fitDisplay {
                        Picker("Desktop width", selection: $fitWidth) {
                            ForEach([720, 800, 960, 1024, 1280], id: \.self) { value in
                                Text("\(value) pt").tag(value)
                            }
                        }
                    }
                    Text("The Mac switches to the closest resolution matching this phone's shape while you are connected, and switches back when you disconnect.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Turn the Mac's desktop upright", isOn: Binding(
                        get: { model.portraitMode },
                        set: { model.setPortrait($0) }))
                    Text("Rotates the Mac's display 90°, so holding the phone upright shows a whole desktop — Dock and all — instead of a letterboxed strip.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Restore the Mac's resolution now") {
                        model.client.sendInput(["t": "resetdisplay"])
                    }
                }
                Section("With the lid closed") {
                    Toggle("Keep the Mac awake", isOn: Binding(
                        get: { model.client.lidAwake },
                        set: { model.setLidAwake($0) }))
                    if model.client.lidHelperInstalled {
                        Text("A MacBook sleeps the moment its lid shuts, which drops it off your hotspot. With this on it stays awake and reachable — idling in Low Power Mode until you connect.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Needs a one-off install on the Mac, because only root can stop a lid-close sleep:\n\n    sudo Scripts/install-helper.sh")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section("Touch") {
                    VStack(alignment: .leading) {
                        Text("Scroll speed: \(scrollSpeed, specifier: "%.2f")×")
                        Slider(value: $scrollSpeed, in: 0.25...2.5, step: 0.05).accessibilityLabel("Scroll speed")
                    }
                    Toggle("Reverse three-finger swipes", isOn: $swipeReversed)
                }
                Section {
                    Toggle("Show cursor in Pointer and Trackpad modes", isOn: $cursor)
                    Text("Touch mode hides the Mac cursor while control is enabled. A local touch ring shows where your finger lands.")
                        .font(.caption).foregroundStyle(.secondary)
                    Label("Each new connection needs approval", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .navigationTitle("Stream settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply(); dismiss() }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .onAppear {
            width = Double(model.streamWidth)
            fps = Double(model.streamFPS)
            mbps = Double(model.streamMbps)
            cursor = model.showCursor
            fitDisplay = model.fitDisplay
            fitWidth = model.fitWidth
            scrollSpeed = model.scrollSpeed
            swipeReversed = model.swipeReversed
        }
    }

    private func preset(_ title: String, detail: String, symbol: String, color: Color,
                        resolution: Double, rate: Double, bitrate: Double) -> some View {
        let selected = width == resolution && fps == rate && mbps == bitrate
        return Button { width = resolution; fps = rate; mbps = bitrate } label: {
            HStack(spacing: 13) {
                SettingsGlyph(symbol, tint: color)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.body.weight(.medium)).foregroundStyle(.primary)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(.teal) }
            }.padding(.vertical, 4).contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func apply() {
        model.streamWidth = Int(width)
        model.streamFPS = Int(fps)
        model.streamMbps = Int(mbps)
        model.showCursor = cursor
        model.fitDisplay = fitDisplay
        model.fitWidth = fitWidth
        model.scrollSpeed = scrollSpeed
        model.swipeReversed = swipeReversed
        model.pushSettings()
    }
}

struct GestureGuide: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section("Touch · your Mac, without the cursor") {
                    guide("hand.tap", "Tap", "Click at your fingertip. Double-tap to double-click.")
                    guide("hand.draw", "Swipe", "Scroll the content. Two fingers always scroll, even over a title bar.")
                    guide("hand.point.up.left", "Hold, then move", "Drag a file, select text, or move content. Hold and release for a context menu.")
                    guide("macwindow", "Move a window", "Drag its title bar or resize from an edge. A first touch on a background window only brings it forward.")
                }
                Section("More gestures") {
                    guide("arrow.up.left.and.arrow.down.right", "Pinch", "In control mode, sends Command-scroll to the Mac; support varies by app. In view-only mode, zooms the picture locally.")
                    guide("rectangle.3.group", "Three-finger swipe", "Switch desktops or open Mission Control. Requires the Mac’s Control-arrow shortcuts.")
                    guide("rectangle.and.hand.point.up.left", "Trackpad", "Slide to move the pointer. Hold before dragging. Two-finger tap opens a context menu.")
                }
                Section {
                    Text("Use More for window actions, audio, stream quality, and disconnect. Turning Control off lets you pan and zoom the picture without sending touch or keyboard input.")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Make it feel natural")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func guide(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }.padding(.vertical, 6)
        } icon: { Image(systemName: icon).foregroundStyle(.teal) }
    }
}

private struct NearbyInbox: View {
    @ObservedObject var service: NearbyService
    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .sheet(item: Binding(get: { service.incoming }, set: { if $0 == nil { service.respond(accept: false) } })) { request in
                VStack(alignment: .leading, spacing: 22) {
                    Label("Connection request", systemImage: "person.crop.circle.badge.questionmark").font(.title2.bold())
                    Text("\(request.name) · \(request.platform)").font(.headline)
                    Text(request.code).font(.system(size: 40, weight: .semibold, design: .monospaced))
                    Text("Compare the code on both devices. Accept shares your iPhone screen and supported app sound, in view-only mode. You still approve the system broadcast prompt.").foregroundStyle(.secondary)
                    HStack {
                        Button("Decline", role: .cancel) { service.respond(accept: false) }.buttonStyle(.bordered)
                        Spacer()
                        Button("Accept & share") { service.respond(accept: true) }.buttonStyle(.borderedProminent)
                    }.controlSize(.large)
                }.padding(28).presentationDetents([.medium, .large]).tint(.teal)
            }
    }
}
