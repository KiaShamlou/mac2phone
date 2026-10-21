import Foundation
import Network
import CryptoKit
import Combine
#if os(iOS)
import UIKit
#endif

/// DNS-SD is an availability hint, never authorization. A human compares the
/// transcript-bound code before a one-use stream grant is sent with AES-GCM.
final class NearbyService: ObservableObject {
    struct Device: Identifiable, Equatable {
        let id: String, name: String, platform: String
        let endpoint: NWEndpoint
    }
    struct Request: Identifiable {
        let id = UUID()
        let name: String, platform: String, code: String
    }
    @Published private(set) var devices: [Device] = []
    @Published private(set) var incoming: Request?
    @Published private(set) var outgoing: Request?
    @Published var notice = ""
    var onApproved: ((String) -> Void)?
    var grant: ((@escaping (String?) -> Void) -> Void)?
    private let id = UUID().uuidString.lowercased()
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var channels: [UUID: NearbyChannel] = [:]
    private var pending: (NearbyChannel, SymmetricKey)?
    private var sending: NearbyChannel?
    private var recent: [String: Date] = [:]
    private var generation = UUID()
    static let type = "_m2p-nearby._tcp"
    static let info = Data("Mac2Phone Nearby v1".utf8)
    #if os(macOS)
    let name = String((Host.current().localizedName ?? "Mac").prefix(32))
    let platform = "macos"
    #else
    let name = String(UIDevice.current.name.prefix(32))
    let platform = "ios"
    #endif

    var requestPort: UInt16? { listener?.port?.rawValue }
    func start(advertise: Bool = true) {
        guard listener == nil else { return }
        generation = UUID()
        do {
            let l = try NWListener(using: .tcp, on: .any)
            if advertise { l.service = NWListener.Service(name: "\(name.prefix(24)) \(id.prefix(8))", type: Self.type,
                txtRecord: NWTXTRecord(["v": "1", "id": id, "name": name, "platform": platform])) }
            l.newConnectionHandler = { [weak self] in self?.accept($0) }
            l.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.stop(); self?.notice = "Nearby discovery needs local-network access. Reopen the app after granting access." }
            }
            listener = l; l.start(queue: .main)
            guard advertise else { return }
            let b = NWBrowser(for: .bonjourWithTXTRecord(type: Self.type, domain: nil), using: .tcp)
            b.browseResultsChangedHandler = { [weak self] results, _ in
                guard let self else { return }
                let found: [Device] = results.prefix(128).compactMap { result in
                    guard case .bonjour(let txt) = result.metadata else { return nil }
                    func text(_ key: String) -> String? { if case .string(let v) = txt.getEntry(for: key) { return v }; return nil }
                    guard text("v") == "1", let peerID = text("id"), UUID(uuidString: peerID) != nil, peerID != self.id,
                          let label = text("name"), Self.validName(label), let platform = text("platform"), Self.platforms.contains(platform) else { return nil }
                    return Device(id: peerID, name: label, platform: platform, endpoint: result.endpoint)
                }
                self.devices = Dictionary(grouping: found, by: \.id).values.compactMap { $0.first }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
            b.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.stop(); self?.notice = "Nearby discovery needs local-network access. Reopen the app after granting access." }
            }
            browser = b; b.start(queue: .main)
        } catch { notice = "Nearby discovery did not start." }
    }
    func stop() {
        generation = UUID(); listener?.cancel(); listener = nil; browser?.cancel(); browser = nil
        cancel(); pending = nil; incoming = nil
        let all = Array(channels.values); channels.removeAll(); all.forEach { $0.close() }
        devices = []; recent.removeAll()
    }
    private static let platforms: Set<String> = ["macos", "darwin", "win32", "linux", "android", "ios"]
    static func validName(_ s: String) -> Bool {
        !s.trimmingCharacters(in: .whitespaces).isEmpty && s.utf8.count <= 128 && !s.unicodeScalars.contains {
            switch $0.properties.generalCategory { case .control, .format, .surrogate, .privateUse, .unassigned: return true; default: return false }
        }
    }
    static func decode(_ s: Any?, count: Int? = nil) throws -> Data {
        guard let s = s as? String, s.count <= 6000, let d = Data(base64Encoded: s), d.base64EncodedString() == s,
              count == nil || d.count == count else { throw NearbyError.invalid }; return d
    }
    static func agree(_ privateKey: Curve25519.KeyAgreement.PrivateKey, request: [String: Any], hostKey: String) throws -> (SymmetricKey, String) {
        guard request["v"] as? Int == 1, let name = request["name"] as? String, validName(name),
              let platform = request["platform"] as? String, platforms.contains(platform) else { throw NearbyError.invalid }
        let client = try decode(request["key"], count: 32), server = try decode(hostKey, count: 32)
        let peer = privateKey.publicKey.rawRepresentation == client ? server : client
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
        let transcript = Data("\(name)\n\(platform)\n".utf8) + client + server
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(repeating: 0, count: 32), sharedInfo: info + transcript, outputByteCount: 32)
        let digest = Array(SHA256.hash(data: key.withUnsafeBytes { Data($0) } + transcript))
        let code = (Int(digest[0]) << 16 | Int(digest[1]) << 8 | Int(digest[2])) % 1_000_000
        return (key, String(format: "%06d", code))
    }
    private func accept(_ connection: NWConnection) {
        let address: String
        if case .hostPort(let host, _) = connection.endpoint { address = "\(host)" } else { address = "\(connection.endpoint)" }
        recent = recent.filter { Date().timeIntervalSince($0.value) < 10 }
        guard listener != nil, pending == nil, channels.count < 4, recent[address] == nil, recent.count < 128 else { connection.cancel(); return }
        recent[address] = Date()
        let channel = NearbyChannel(connection); let channelID = UUID(); channels[channelID] = channel
        channel.onClose = { [weak self, weak channel] in
            guard let self else { return }; self.channels.removeValue(forKey: channelID)
            if self.pending?.0 === channel { self.pending = nil; self.incoming = nil }
        }
        channel.start(); channel.deadline(8)
        channel.read { [weak self, weak channel] result in
            guard let self, let channel, self.pending == nil, self.listener != nil else { channel?.close(); return }
            do {
                var request = try result.get()
                guard request["v"] as? Int == 1, let label = request["name"] as? String, Self.validName(label),
                      let platform = request["platform"] as? String, Self.platforms.contains(platform) else { throw NearbyError.invalid }
                let commitment = try Self.decode(request["commit"], count: 32)
                let privateKey = Curve25519.KeyAgreement.PrivateKey()
                let publicKey = privateKey.publicKey.rawRepresentation.base64EncodedString()
                channel.send(["v": 1, "key": publicKey])
                channel.read { [weak self, weak channel] result in
                    guard let self, let channel, self.pending == nil, self.listener != nil else { channel?.close(); return }
                    do {
                        let reveal = try result.get(), client = try Self.decode(reveal["key"], count: 32), nonce = try Self.decode(reveal["nonce"], count: 32)
                        guard Data(SHA256.hash(data: client + nonce)) == commitment else { throw NearbyError.invalid }
                        request["key"] = reveal["key"]
                        let (key, code) = try Self.agree(privateKey, request: request, hostKey: publicKey)
                        channel.deadline(120); self.pending = (channel, key)
                        self.incoming = Request(name: label, platform: platform, code: code)
                        channel.read { _ in channel.close() }
                    } catch { channel.close() }
                }
            } catch { channel.close() }
        }
    }
    func respond(accept: Bool) {
        guard let request = incoming, let (channel, key) = pending else { return }
        incoming = nil // Single tap; leave channel pending until capture is approved.
        let finish: (String?) -> Void = { [weak self, weak channel] link in
            guard let self, let channel, self.pending?.0 === channel, !channel.closed else { return }
            do {
                var result: [String: Any] = ["status": "declined"]
                if let link { _ = try Pairing.parse(link); result = ["status": "accepted", "link": link] }
                let box = try AES.GCM.seal(JSONSerialization.data(withJSONObject: result), using: key, authenticating: Self.info)
                self.pending = nil
                channel.send(["box": box.combined!.base64EncodedString()], closeAfter: true)
                self.notice = link == nil ? "Request declined." : "Approved \(request.name) for one connection."
            } catch { channel.close() }
        }
        if accept, let grant { grant(finish) } else { finish(nil) }
    }
    func request(_ device: Device) {
        guard sending == nil else { return }
        let channel = NearbyChannel(NWConnection(to: device.endpoint, using: .tcp)); sending = channel
        let privateKey = Curve25519.KeyAgreement.PrivateKey()
        let request: [String: Any] = ["v": 1, "name": name, "platform": platform, "key": privateKey.publicKey.rawRepresentation.base64EncodedString()]
        notice = "Sending a connection request to \(device.name)…"
        channel.onClose = { [weak self, weak channel] in
            if self?.sending === channel { self?.sending = nil; self?.outgoing = nil; self?.notice = "Request ended. Try again when the device is ready." }
        }
        let nonce = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        var publicRequest = request; publicRequest.removeValue(forKey: "key")
        publicRequest["commit"] = Data(SHA256.hash(data: privateKey.publicKey.rawRepresentation + nonce)).base64EncodedString()
        channel.start(); channel.deadline(120); channel.send(publicRequest)
        channel.read { [weak self, weak channel] result in
            guard let self, let channel, self.sending === channel else { return }
            do {
                let reply = try result.get()
                guard reply["v"] as? Int == 1, let publicKey = reply["key"] as? String else { throw NearbyError.invalid }
                let (key, code) = try Self.agree(privateKey, request: request, hostKey: publicKey)
                channel.send(["key": privateKey.publicKey.rawRepresentation.base64EncodedString(), "nonce": nonce.base64EncodedString()])
                self.outgoing = Request(name: device.name, platform: device.platform, code: code)
                self.notice = "Waiting for approval. Compare \(code) on both devices."
                channel.read { [weak self, weak channel] result in
                    guard let self, let channel, self.sending === channel else { return }
                    do {
                        let envelope = try result.get(), bytes = try Self.decode(envelope["box"])
                        let plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: bytes), using: key, authenticating: Self.info)
                        guard let object = try JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else { throw NearbyError.invalid }
                        let remote = channel.connection.currentPath?.remoteEndpoint
                        self.sending = nil; self.outgoing = nil; channel.close()
                        if object["status"] as? String == "accepted", let link = object["link"] as? String {
                            var pairing = try Pairing.parse(link)
                            if case .hostPort(let host, _) = remote {
                                pairing = Pairing(identity: pairing.identity, key: pairing.key, host: "\(host)", port: pairing.port, ticket: pairing.ticket)
                            }
                            _ = try Pairing.parse(pairing.link)
                            self.notice = "Request accepted. Connecting…"; self.onApproved?(pairing.link)
                        } else { self.notice = "Request declined." }
                    } catch { channel.close() }
                }
            } catch { channel.close() }
        }
    }
    func cancel() { let old = sending; sending = nil; outgoing = nil; old?.close(); notice = "Request cancelled." }
}
private enum NearbyError: Error { case invalid }
private final class NearbyChannel {
    let connection: NWConnection
    private var timeout: DispatchWorkItem?
    var closed = false
    var onClose: (() -> Void)?
    init(_ connection: NWConnection) { self.connection = connection }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }; if case .cancelled = state { self?.close() }
        }
        connection.start(queue: .main)
    }
    func deadline(_ seconds: Double) { timeout?.cancel(); let task = DispatchWorkItem { [weak self] in self?.close() }; timeout = task; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: task) }
    func exact(_ n: Int, _ data: Data = Data(), completion: @escaping (Result<Data, Error>) -> Void) {
        guard !closed else { completion(.failure(NearbyError.invalid)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: n - data.count) { [weak self] bytes, _, done, error in
            guard let self else { return }; let next = data + (bytes ?? Data())
            if next.count == n { completion(.success(next)) }
            else if done || error != nil { self.close(); completion(.failure(NearbyError.invalid)) }
            else { self.exact(n, next, completion: completion) }
        }
    }
    func read(_ completion: @escaping (Result<[String: Any], Error>) -> Void) {
        exact(4) { [weak self] result in
            guard let self else { return }
            do {
                let bytes = try result.get(); let n = bytes.reduce(0) { ($0 << 8) | Int($1) }
                guard n >= 2, n <= 4096 else { throw NearbyError.invalid }
                self.exact(n) { result in
                    do {
                        guard let object = try JSONSerialization.jsonObject(with: result.get()) as? [String: Any] else { throw NearbyError.invalid }
                        completion(.success(object))
                    } catch { self.close(); completion(.failure(error)) }
                }
            } catch { self.close(); completion(.failure(error)) }
        }
    }
    func send(_ value: [String: Any], closeAfter: Bool = false) {
        guard !closed, let bytes = try? JSONSerialization.data(withJSONObject: value), bytes.count <= 4096 else { close(); return }
        var n = UInt32(bytes.count).bigEndian
        connection.send(content: withUnsafeBytes(of: &n) { Data($0) } + bytes, completion: .contentProcessed { [weak self] error in
            if error != nil || closeAfter { self?.close() }
        })
    }
    func close() { guard !closed else { return }; closed = true; timeout?.cancel(); connection.stateUpdateHandler = nil; connection.cancel(); onClose?(); onClose = nil }
}
