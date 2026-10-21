import WatchConnectivity
import Combine
import UIKit

/// Live commands only: no queued background commands or pairing secrets on the watch.
final class WatchRelay: NSObject, WCSessionDelegate {
    static let shared = WatchRelay()
    weak var model: AppModel?
    private var lastCommand = Date.distantPast
    private let keys: Set<String> = ["left", "right", "up", "down", "return", "escape", "space"]
    func start(model: AppModel) {
        self.model = model
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self; WCSession.default.activate()
    }
    func publish() {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        try? WCSession.default.updateApplicationContext(status)
    }
    private var status: [String: Any] {
        let ready = model?.isConnected == true && model?.client.hostControl == true && model?.controlEnabled == true
            && model?.allowWatchControl == true && UIApplication.shared.applicationState == .active
        return ["ready": ready, "host": ready ? (model?.statusText ?? "Device") : "Open Mac2Phone on iPhone, connect and enable Watch control."]
    }
    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            if message["t"] as? String != "status", self.status["ready"] as? Bool == true,
               Date().timeIntervalSince(self.lastCommand) >= 0.04 {
                var input: [String: Any]?
                switch message["t"] as? String {
                case "key":
                    if let key = message["k"] as? String, self.keys.contains(key) { input = ["t": "key", "k": key, "m": []] }
                case "txt":
                    if let text = message["s"] as? String, !text.isEmpty, text.utf8.count <= 4096 { input = ["t": "txt", "s": text] }
                case "s":
                    if let delta = message["dy"] as? Double, delta.isFinite { input = ["t": "s", "dx": 0, "dy": min(120, max(-120, delta))] }
                default: break
                }
                if let input { self.lastCommand = Date(); self.model?.client.sendInput(input) }
            }
            replyHandler(self.status)
        }
    }
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async { self.publish() }
    }
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
}
