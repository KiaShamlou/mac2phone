import SwiftUI
import WatchConnectivity

@main struct Mac2PhoneWatchApp: App {
    @StateObject private var remote = WatchRemote()
    var body: some Scene { WindowGroup { RemoteView().environmentObject(remote) } }
}
final class WatchRemote: NSObject, ObservableObject, WCSessionDelegate {
    @Published var ready = false
    @Published var status = "Open Mac2Phone on iPhone."
    override init() {
        super.init()
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func send(_ command: [String: Any]) {
        guard WCSession.default.isReachable else { ready = false; status = "Keep Mac2Phone open on iPhone."; return }
        WCSession.default.sendMessage(command, replyHandler: { [weak self] in self?.receive($0) }, errorHandler: { [weak self] _ in
            DispatchQueue.main.async { self?.ready = false; self?.status = "iPhone is not reachable." }
        })
    }
    private func receive(_ value: [String: Any]) {
        DispatchQueue.main.async { self.ready = value["ready"] as? Bool ?? false; self.status = value["host"] as? String ?? "Connect on iPhone." }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        receive(session.receivedApplicationContext)
    }
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { receive(applicationContext) }
    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.send(["t": "status"]) }
    }
}
private struct RemoteView: View {
    @EnvironmentObject var remote: WatchRemote
    @Environment(\.scenePhase) var phase
    @State private var text = ""
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Label("Mac2Phone", systemImage: "display").foregroundStyle(.mint).font(.headline)
                Text(remote.status).font(.caption2).foregroundStyle(.secondary)
                VStack(spacing: 6) {
                    key("Up", icon: "chevron.up", value: "up")
                    HStack { key("Left", icon: "chevron.left", value: "left"); key("Right", icon: "chevron.right", value: "right") }
                    key("Down", icon: "chevron.down", value: "down")
                    HStack { key("Escape", icon: "escape", value: "escape"); key("Return", icon: "return", value: "return") }
                    HStack {
                        Button { remote.send(["t": "s", "dy": -80.0]) } label: { Image(systemName: "arrow.up.to.line") }.accessibilityLabel("Scroll up")
                        Button { remote.send(["t": "s", "dy": 80.0]) } label: { Image(systemName: "arrow.down.to.line") }.accessibilityLabel("Scroll down")
                    }
                    TextField("Type or dictate", text: $text)
                    Button("Send text") { remote.send(["t": "txt", "s": text]); text = "" }.disabled(text.isEmpty)
                }.disabled(!remote.ready)
                Button("Refresh connection") { remote.send(["t": "status"]) }.font(.caption)
            }
        }.tint(.mint)
        .onAppear { remote.send(["t": "status"]) }
        .onChange(of: phase) { _, value in if value == .active { remote.send(["t": "status"]) } }
    }
    private func key(_ title: String, icon: String, value: String) -> some View {
        Button { remote.send(["t": "key", "k": value]) } label: { Image(systemName: icon) }.accessibilityLabel(title)
    }
}
