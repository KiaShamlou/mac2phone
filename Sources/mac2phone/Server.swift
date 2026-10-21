import Foundation
import Network
import CoreMedia

/// Protocol v2: authenticated TLS for every control, video and audio byte.
/// No HTTP listener, plaintext handshake, or unauthenticated UDP side channel.
final class Server {
    enum Mode { case undetermined, native, desktop }
    final class Client {
        let id = UUID()
        let connection: NWConnection
        var mode: Mode = .undetermined
        var approved = false
        var rx = Data()
        var sentConfig = false
        var outstandingFrames = 0
        var outstandingBytes = 0
        var audioPending = 0
        var wantsAudio = false
        let acceptedAt = Date()
        var lastHeard = Date()
        var rateWindow = Date()
        var messageCount = 0
        init(_ connection: NWConnection) { self.connection = connection }
    }
    struct Viewers {
        var native = 0
        var web = 0 // Retained for status-model compatibility; v2 does not serve browsers.
        var desktop = 0
        var total: Int { native + web + desktop }
    }
    private let queue = DispatchQueue(label: "mac2phone.server")
    private var listener: NWListener?
    var requireApproval = false
    var consumeExternalGrant: ((Data) -> Bool)?
    private var grants: [Data: Date] = [:]
    func grant(host: String) throws -> Pairing {
        try queue.sync {
            grants = grants.filter { $0.value > Date() }
            guard grants.count < 8 else { throw Pairing.Failure.invalidLink }
            let token = try Pairing.generate(host: host, port: port).key
            grants[token] = Date().addingTimeInterval(60)
            var result = pairing; result = Pairing(identity: result.identity, key: result.key, host: host, port: port, ticket: token)
            return result
        }
    }
    private var clients: [UUID: Client] = [:]
    private var watchdog: DispatchSourceTimer?
    private var pairing: Pairing
    private let bindHost: String?
    private let nativeVideo: Bool
    let port: UInt16
    var maxQueuedBytes = 160_000
    var onViewersChanged: ((Viewers) -> Void)?
    var onInput: (([String: Any]) -> Void)?
    var onSettings: (([String: Any]) -> Void)?
    var onKeyframeRequest: (() -> Void)?
    var onAudioWantedChanged: ((Bool) -> Void)?
    var currentVideoConfig: (() -> Data?)?
    var currentAudioConfig: (() -> (rate: Int, channels: Int)?)?
    var capabilities: (() -> [String: Any])?
    private let snapshotLock = NSLock()
    private var viewerSnapshot = Viewers()
    private var backlogSnapshot = false
    private var audioWantedSnapshot = false
    var anyClientWantsAudio: Bool { snapshotLock.withLock { audioWantedSnapshot } }
    var viewers: Viewers { snapshotLock.withLock { viewerSnapshot } }
    var nativeBacklog: Bool { snapshotLock.withLock { backlogSnapshot } }
    static func hostMicros() -> UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000)
    }
    init(port: UInt16, pairing: Pairing, bindHost: String? = nil, nativeVideo: Bool = true) {
        self.port = port; self.pairing = pairing; self.bindHost = bindHost; self.nativeVideo = nativeVideo
    }
    func start() throws {
        try listen()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            for client in Array(self.clients.values) {
                let silent = Date().timeIntervalSince(client.lastHeard) > 8
                let incomplete = client.mode == .undetermined && Date().timeIntervalSince(client.acceptedAt) > 8
                if silent || incomplete { self.remove(client) }
            }
        }
        timer.resume(); watchdog = timer
    }
    private func listen(completion: ((Error?) -> Void)? = nil) throws {
        let parameters = pairing.parameters()
        parameters.allowLocalEndpointReuse = true
        let p = NWEndpoint.Port(rawValue: port)!
        let l: NWListener
        if let bindHost {
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(bindHost), port: p)
            l = try NWListener(using: parameters)
        } else {
            l = try NWListener(using: parameters, on: p)
            #if os(macOS)
            let name = Host.current().localizedName ?? "Mac"
            #else
            let name = "Mac2Phone Broadcast"
            #endif
            l.service = NWListener.Service(name: name, type: "_mac2phone._tcp")
        }
        l.newConnectionHandler = { [weak self, weak l] connection in
            guard let self, let l, self.listener === l else { connection.cancel(); return }
            self.accept(connection)
        }
        var reported = false
        l.stateUpdateHandler = { state in
            if case .ready = state, !reported { reported = true; completion?(nil) }
            if case .failed(let error) = state {
                fputs("Secure listener failed: \(error)\n", stderr)
                if !reported { reported = true; completion?(error) }
            }
        }
        listener = l
        l.start(queue: queue)
    }
    func rotatePairing(_ value: Pairing, completion: @escaping (Error?) -> Void) {
        queue.async {
            let old = self.listener
            self.listener = nil // Reject any accept callback racing with revocation.
            for client in Array(self.clients.values) { self.remove(client) }
            self.pairing = value
            self.grants.removeAll()
            let restart = {
                do { try self.listen(completion: completion) } catch { completion(error) }
            }
            if let old {
                // cancel() is asynchronous: rebinding before .cancelled can lose
                // the port. Report success only after the new listener is ready.
                old.stateUpdateHandler = { state in
                    if case .cancelled = state { restart() }
                }
                old.cancel()
            } else { restart() }
        }
    }
    func stop() {
        queue.async {
            self.grants.removeAll()
            self.watchdog?.cancel(); self.watchdog = nil
            self.listener?.stateUpdateHandler = nil
            self.listener?.cancel(); self.listener = nil
            for client in Array(self.clients.values) { self.remove(client) }
        }
    }
    func disconnectAll() {
        queue.async { self.grants.removeAll(); for client in Array(self.clients.values) { self.remove(client) } }
    }
    private func accept(_ connection: NWConnection) {
        guard clients.count < 16 else { connection.cancel(); return }
        let client = Client(connection)
        clients[client.id] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            if case .failed = state { self.remove(client) }
            if case .cancelled = state { self.remove(client) }
        }
        connection.start(queue: queue)
        receive(client)
    }
    private func remove(_ client: Client) {
        guard clients.removeValue(forKey: client.id) != nil else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        if client.mode != .undetermined { onInput?(["t": "cancel"]) }
        updateViewers()
        updateAudioWanted()
    }
    private func updateAudioWanted() {
        let wanted = clients.values.contains { $0.wantsAudio }
        snapshotLock.withLock { audioWantedSnapshot = wanted }
        onAudioWantedChanged?(wanted)
    }
    private func updateViewers() {
        var value = Viewers()
        for client in clients.values {
            if client.mode == .native { value.native += 1 }
            if client.mode == .desktop { value.desktop += 1 }
        }
        let changed = value.total != viewers.total || value.native != viewers.native
        snapshotLock.withLock { viewerSnapshot = value }
        refreshBacklog()
        if changed { onViewersChanged?(value) }
    }
    private func refreshBacklog() {
        let native = clients.values.filter { $0.mode == .native }
        snapshotLock.withLock {
            backlogSnapshot = !native.isEmpty && native.allSatisfy { $0.outstandingFrames >= 4 || $0.outstandingBytes >= maxQueuedBytes }
        }
    }
    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self, self.clients[client.id] === client else { return }
            if let data, !data.isEmpty {
                client.rx.append(data)
                self.process(client)
            }
            if done || error != nil { self.remove(client); return }
            if self.clients[client.id] === client { self.receive(client) }
        }
    }
    private func process(_ client: Client) {
        if client.mode == .undetermined {
            guard client.rx.count >= 4 else { return }
            if client.rx.prefix(4) == Data("M2PG".utf8) {
                guard !client.approved else { remove(client); return }
                guard client.rx.count >= 40 else { return }
                let token = Data(client.rx.dropFirst(4).prefix(32))
                let local = grants.removeValue(forKey: token).map { $0 > Date() } ?? false
                guard local || consumeExternalGrant?(token) == true else { remove(client); return }
                client.approved = true; client.rx.removeFirst(36)
            }
            guard !requireApproval || client.approved else { remove(client); return }
            if client.rx.prefix(4) == Proto.magic { client.mode = .native }
            else if client.rx.prefix(4) == Proto.desktopMagic { client.mode = .desktop }
            else { remove(client); return }
            client.rx.removeFirst(4)
            var hello = capabilities?() ?? [:]
            hello["version"] = 2
            hello["video"] = client.mode == .desktop || !nativeVideo ? "jpeg" : "native"
            hello["audio"] = "pcm-s16le"
            hello["transport"] = "tls-psk"
            if let json = try? JSONSerialization.data(withJSONObject: hello) { send(client, Proto.msgHello, json) }
            updateViewers()
            if client.mode == .native && nativeVideo {
                if let payload = currentVideoConfig?() {
                    client.sentConfig = true; send(client, Proto.msgVideoConfig, payload)
                }
                onKeyframeRequest?()
            }
        }
        while client.rx.count >= 5 {
            let type = client.rx[client.rx.startIndex]
            guard let length = client.rx.readUInt32(at: 1), length <= Proto.maxControlPayload else { remove(client); return }
            let total = 5 + Int(length)
            guard client.rx.count >= total else { return }
            let payload = Data(client.rx.dropFirst(5).prefix(Int(length)))
            client.rx.removeFirst(total)
            client.lastHeard = Date()
            if Date().timeIntervalSince(client.rateWindow) > 1 { client.rateWindow = Date(); client.messageCount = 0 }
            client.messageCount += 1
            guard client.messageCount <= 2000 else { remove(client); return }
            switch type {
            case Proto.msgAck:
                guard payload.isEmpty else { remove(client); return }
                if client.mode == .desktop || !nativeVideo { client.outstandingFrames = max(0, client.outstandingFrames - 1) }
            case Proto.msgPing:
                guard payload.count == 8 else { remove(client); return }
                var pong = payload; pong.appendUInt64(Self.hostMicros()); send(client, Proto.msgPong, pong)
            case Proto.msgAudioOn:
                guard payload.count == 1, payload[0] <= 1 else { remove(client); return }
                client.wantsAudio = payload[0] == 1
                updateAudioWanted()
                if client.wantsAudio, let config = currentAudioConfig?() {
                    send(client, Proto.msgAudioConfig, audioConfig(config.rate, config.channels))
                }
            case Proto.msgKeyframe:
                if client.mode == .native { onKeyframeRequest?() }
            case Proto.msgInput, Proto.msgSettings:
                guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else { remove(client); return }
                if type == Proto.msgInput { onInput?(object) } else { onSettings?(object) }
            default: remove(client); return
            }
        }
    }
    private func send(_ client: Client, _ type: UInt8, _ payload: Data) {
        client.connection.send(content: Proto.frame(type, payload), completion: .contentProcessed { [weak self, weak client] error in
            if error != nil, let self, let client { self.remove(client) }
        })
    }
    func sendVideoConfigToAll(_ payload: Data) {
        queue.async {
            for client in self.clients.values where client.mode == .native {
                client.sentConfig = true; self.send(client, Proto.msgVideoConfig, payload)
            }
        }
    }
    func send(videoSample: Data, isKeyframe: Bool, ptsMicros: Int64) {
        guard videoSample.count + 9 <= Proto.maxVideoPayload else { return }
        queue.async {
            var payload = Data([isKeyframe ? 1 : 0]); payload.appendInt64(ptsMicros); payload.append(videoSample)
            let message = Proto.frame(Proto.msgVideoFrame, payload)
            for client in self.clients.values where client.mode == .native && client.sentConfig {
                guard client.outstandingFrames < 4, client.outstandingBytes < self.maxQueuedBytes else {
                    // Dropping interframes invalidates decoder references. Recover with an IDR.
                    self.onKeyframeRequest?(); continue
                }
                client.outstandingFrames += 1; client.outstandingBytes += message.count
                client.connection.send(content: message, completion: .contentProcessed { error in
                    client.outstandingFrames -= 1; client.outstandingBytes -= message.count
                    if error != nil { self.remove(client) }
                    self.refreshBacklog()
                })
            }
            self.refreshBacklog()
        }
    }
    func send(jpeg: Data) {
        guard jpeg.count <= 4 * 1024 * 1024 else { return }
        queue.async {
            for client in self.clients.values where (client.mode == .desktop || (!self.nativeVideo && client.mode == .native)) && client.outstandingFrames < 2 && client.outstandingBytes < 4 * 1024 * 1024 {
                client.outstandingFrames += 1
                let message = Proto.frame(Proto.msgJPEG, jpeg)
                client.outstandingBytes += message.count
                client.connection.send(content: message, completion: .contentProcessed { error in
                    client.outstandingBytes -= message.count
                    if error != nil { self.remove(client) }
                })
            }
        }
    }
    private func audioConfig(_ rate: Int, _ channels: Int) -> Data {
        var payload = Data(); payload.appendUInt32(UInt32(rate)); payload.append(UInt8(channels)); return payload
    }
    func sendAudioConfig(sampleRate: Int, channels: Int) {
        queue.async {
            for client in self.clients.values where client.mode != .undetermined {
                self.send(client, Proto.msgAudioConfig, self.audioConfig(sampleRate, channels))
            }
        }
    }
    func send(audio: Data, ptsMicros: Int64) {
        guard audio.count <= 65536 else { return }
        queue.async {
            var payload = Data(); payload.appendInt64(ptsMicros); payload.append(audio)
            for client in self.clients.values where client.wantsAudio && client.audioPending < 4 {
                client.audioPending += 1
                client.connection.send(content: Proto.frame(Proto.msgAudioFrame, payload), completion: .contentProcessed { error in
                    client.audioPending -= 1
                    if error != nil { self.remove(client) }
                })
            }
        }
    }
    func send(status: [String: Any]) {
        guard let json = try? JSONSerialization.data(withJSONObject: status) else { return }
        queue.async {
            for client in self.clients.values where client.mode != .undetermined { self.send(client, Proto.msgStatus, json) }
        }
    }
}
