import Foundation
import Combine
import Network
import UIKit

final class AppModel: ObservableObject {

    let client = StreamClient()
    let discovery = Discovery()
    let mirror = MirrorController()

    /// A Bonjour service name and a hostname look alike but are resolved in
    /// completely different ways — "Kianoosh's MacBook Pro" is meaningless to
    /// DNS. Remember which kind was used, or reconnecting cannot work.
    @AppStorageBacked("lastHost") var lastHost: String = ""
    @AppStorageBacked("lastIsService") var lastIsService: Bool = false
    @AppStorageBacked("port") var port: Int = 8765
    @AppStorageBacked("streamWidth") var streamWidth: Int = 0
    @AppStorageBacked("streamFPS") var streamFPS: Int = 30
    @AppStorageBacked("streamMbps") var streamMbps: Int = 20
    @AppStorageBacked("showCursor") var showCursor: Bool = true
    @AppStorageBacked("autoConnect") var autoConnect: Bool = true
    @AppStorageBacked("fitDisplay") var fitDisplay: Bool = true
    @AppStorageBacked("fitWidth") var fitWidth: Int = 960
    @AppStorageBacked("controlStyle") var controlStyle: Int = 0
    @AppStorageBacked("swipeReversed") var swipeReversed: Bool = false
    @AppStorageBacked("scrollSpeed") var scrollSpeed: Double = 1.0
    @AppStorageBacked("lidAwake") var lidAwake: Bool = false
    @AppStorageBacked("portraitMode") var portraitMode: Bool = false
    @AppStorageBacked("controlEnabled") var controlEnabled: Bool = true
    @AppStorageBacked("audioEnabled") var audioEnabled: Bool = false

    @AppStorageBacked("allowWatchControl") var allowWatchControl = false

    @Published var showRequestedBroadcast = false
    @Published var isConnected = false
    @Published var statusText = ""

    private var cancellables = Set<AnyCancellable>()
    private var didAutoConnect = false

    init() {
        WatchRelay.shared.start(model: self)
        client.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle:                 self.isConnected = false; self.statusText = ""
                case .connecting(let name): self.isConnected = false; self.statusText = "connecting to \(name)…"
                case .connected(let name):
                    self.isConnected = true; self.statusText = name
                    self.pushSettings(); self.client.syncAudio()
                case .failed(let message):  self.isConnected = false; self.statusText = message
                }
                UIApplication.shared.isIdleTimerDisabled = self.isConnected
                WatchRelay.shared.publish()
                if !self.isConnected { self.mirror.cancelInteraction() }
            }
            .store(in: &cancellables)

        discovery.onApproved = { [weak self] link in self?.connect(host: link) }
        discovery.grant = { [weak self] done in
            guard let self else { done(nil); return }
            if let link = try? BroadcastState.grant().link { done(link); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.showRequestedBroadcast = true
                self.waitForBroadcast(until: Date().addingTimeInterval(90), done: done)
            }
        }

        mirror.$viewportSize
            .removeDuplicates()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] size in
                guard let self, self.isConnected, size.width > 0, size.height > 0 else { return }
                self.client.sendSettings(["aspect": self.phoneAspect, "fitDisplay": self.fitDisplay,
                                          "fitWidth": self.fitWidth])
            }
            .store(in: &cancellables)

        mirror.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    private var validatedPort: UInt16 { UInt16(exactly: port).flatMap { $0 > 0 ? $0 : nil } ?? 8765 }

    func onAppear() {
        discovery.start(port: validatedPort)

    }

    private func waitForBroadcast(until deadline: Date, done: @escaping (String?) -> Void) {
        if let link = try? BroadcastState.grant().link { showRequestedBroadcast = false; done(link); return }
        guard Date() < deadline, showRequestedBroadcast else { done(nil); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.waitForBroadcast(until: deadline, done: done) }
    }

    func connect(to mac: Discovery.Found) {
        discovery.request(mac)
    }

    func connect(host: String) {
        do { connect(try Pairing.parse(host)) }
        catch { statusText = error.localizedDescription }
    }

    private func connect(_ pairing: Pairing) {
        didAutoConnect = true
        lastHost = pairing.host
        lastIsService = false
        port = Int(pairing.port)
        client.connect(host: pairing.host, port: pairing.port, pairing: pairing)
    }

    private func autoConnectIfPossible(_ macs: [Discovery.Found]) {
        // A Bonjour name must never replace a stored authenticated endpoint.
    }

    func reconnect() {
        statusText = "Select a device in Nearby devices to send a fresh connection request."
        discovery.start()
    }

    func disconnect() {
        mirror.cancelInteraction()
        didAutoConnect = true
        client.disconnect()
    }

    /// Only ever sent when the person actually flips it — this is the Mac's
    /// setting, and it knows things the phone does not, like whether the
    /// privileged helper is there at all.
    func setLidAwake(_ on: Bool) {
        lidAwake = on
        client.sendSettings(["lidAwake": on])
    }

    /// Turns the Mac's desktop on its side so a phone held upright shows a whole
    /// desktop rather than a letterboxed strip of one.
    func setPortrait(_ on: Bool) {
        portraitMode = on
        client.sendSettings(["portrait": on,
                             "aspect": phoneAspect,
                             "fitWidth": fitWidth,
                             "fitDisplay": fitDisplay])
    }

    var phoneAspect: Double {
        let size = mirror.viewportSize.width > 0 ? mirror.viewportSize : UIScreen.main.bounds.size
        let long = max(size.width, size.height)
        let short = min(size.width, size.height)
        return Double(long / max(short, 1))
    }

    func setControlStyle(_ style: ControlStyle) {
        objectWillChange.send()
        controlStyle = style.rawValue
        mirror.controlStyle = client.hostTouchMode == "ipad" ? style.rawValue : ControlStyle.direct.rawValue
        pushCursorSetting()
    }

    func setWatchControl(_ enabled: Bool) {
        objectWillChange.send(); allowWatchControl = enabled; WatchRelay.shared.publish()
    }

    func setControlEnabled(_ enabled: Bool) {
        objectWillChange.send()
        controlEnabled = enabled
        mirror.controlEnabled = enabled && client.hostControl
        if !enabled { mirror.cancelInteraction() }
        WatchRelay.shared.publish()
        pushCursorSetting()
    }

    private func pushCursorSetting() {
        let style = ControlStyle(rawValue: controlStyle) ?? .ipad
        client.sendSettings(["cursor": style.showsCursor(preference: showCursor, controlling: controlEnabled)])
    }

    func suspend() {
        mirror.cancelInteraction()
        discovery.stop()
        didAutoConnect = !isConnected
        client.disconnect()
    }

    func pushSettings() {
        objectWillChange.send()
        client.sendSettings([
            "width": streamWidth,
            "fps": streamFPS,
            "bitrate": streamMbps * 1_000_000,
            "cursor": (ControlStyle(rawValue: controlStyle) ?? .ipad).showsCursor(preference: showCursor, controlling: controlEnabled),
            // Let the Mac reshape its desktop to this screen.
            "aspect": phoneAspect,
            "fitWidth": fitWidth,
            "fitDisplay": fitDisplay,
            "scrollSpeed": scrollSpeed,
            "portrait": portraitMode
        ])
        mirror.controlStyle = client.hostTouchMode == "ipad" ? controlStyle : ControlStyle.direct.rawValue
        mirror.swipeReversed = swipeReversed
        mirror.controlEnabled = controlEnabled && client.hostControl
        client.audioEnabled = audioEnabled
    }
}

/// Tiny UserDefaults wrapper — @AppStorage cannot live outside a View.
@propertyWrapper
struct AppStorageBacked<Value> {
    let key: String
    let defaultValue: Value

    init(_ key: String, default defaultValue: Value) {
        self.key = key
        self.defaultValue = defaultValue
    }

    var wrappedValue: Value {
        get { UserDefaults.standard.object(forKey: key) as? Value ?? defaultValue }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}

extension AppStorageBacked {
    init(wrappedValue: Value, _ key: String) {
        self.init(key, default: wrappedValue)
    }
}
