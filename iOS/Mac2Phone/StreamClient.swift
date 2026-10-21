import Foundation
import Network
import AVFoundation
import CoreMedia
import Combine
import UIKit
import dnssd
import ImageIO

/// Talks the Mac2Phone protocol and feeds decoded video to a display layer.
///
/// Protocol v2 keeps control, video and audio inside the same paired TLS session.
final class StreamClient: ObservableObject {

    enum State: Equatable {
        case idle
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    struct Stats {
        var fps = 0
        var kbps = 0
        var frames = 0
        var latencyMs = 0
        var rttMs = 0
        var lostFrames = 0
        var transport = "TLS"
    }

    @Published private(set) var hostControl = false
    @Published private(set) var hostAudio = false
    @Published private(set) var hostTouchMode = "pointer"
    private var allowsInput = false
    private var jpegSession = false
    private var mapsCommandToControl = false
    @Published private(set) var state: State = .idle
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var stats = Stats()
    /// A message from the Mac worth putting in front of the user, such as a
    /// permission it still needs.
    @Published var notice: String?
    @Published private(set) var interactionRole = ""
    /// What the Mac says about its own lid behaviour.
    @Published var lidAwake = false
    @Published var lidHelperInstalled = false
    @Published var powerState = ""

    private(set) var desktopSize: CGSize = .zero
    let displayLayer = AVSampleBufferDisplayLayer()
    let audioPlayer = AudioPlayer()

    /// Ask the Mac to start or stop sending what it is playing.
    @Published var audioEnabled = false {
        didSet {
            guard audioEnabled != oldValue else { return }
            if audioEnabled { audioPlayer.start() } else { audioPlayer.stop() }
            send(Proto.msgAudioOn, Data([audioEnabled ? 1 : 0]))
        }
    }

    private let queue = DispatchQueue(label: "mac2phone.client", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    private var connection: NWConnection?
    private var sessionLabel = ""
    private var acceptedHello = false
    private var sessionPairing: Pairing?
    private var lastReceived = CFAbsoluteTimeGetCurrent()
    private var totalFrames = 0
    private var rx = Data()
    private var formatDescription: CMFormatDescription?
    private var awaitingKeyframe = true

    // Stats
    private var lastStatsTime = CFAbsoluteTimeGetCurrent()
    private var bytesSinceStats = 0
    private var framesSinceStats = 0
    private var lostSinceStats = 0
    private var latencySum = 0.0
    private var rttMillis = 0.0
    private var clockOffset: Double?
    private var pingTimer: DispatchSourceTimer?

    // UDP video
    private var token: UInt32 = 0
    private var udp: NWConnection?
    private var udpTimer: DispatchSourceTimer?
    private var udpConfirmed = false
    private var assemblies: [UInt32: Assembly] = [:]
    private var nextSequence: UInt32 = 0
    private var headSince: CFAbsoluteTime = 0
    private var repairTimer: DispatchSourceTimer?
    private var lastKeyframeRequest = CFAbsoluteTimeGetCurrent()

    private struct Assembly {
        var fragments: [Data?]
        var received = 0
        let count: Int
        let isKeyframe: Bool
        let ptsMicros: Int64
        let firstSeen: CFAbsoluteTime
        var byteCount = 0
        var nackCount = 0
        var lastNack: CFAbsoluteTime = 0
    }

    private static func hostMicros() -> UInt64 {
        UInt64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 1_000_000)
    }

    init() {
        queue.setSpecific(key: queueKey, value: true)
        displayLayer.videoGravity = .resize
        displayLayer.preventsDisplaySleepDuringVideoPlayback = true
    }

    // MARK: - Connection

    func connect(to endpoint: NWEndpoint, label: String, pairing: Pairing) {
        guard DispatchQueue.getSpecific(key: queueKey) == true else {
            queue.async { self.connect(to: endpoint, label: label, pairing: pairing) }
            return
        }
        closeConnection()
        sessionPairing = pairing
        sessionLabel = label
        lastReceived = CFAbsoluteTimeGetCurrent()
        publish(.connecting(label))

        let params = pairing.parameters()
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
            tcp.connectionTimeout = 8
        }

        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] newState in
            guard let self, self.connection === conn else { return }
            switch newState {
            case .ready:
                self.rx.removeAll()
                self.formatDescription = nil
                self.awaitingKeyframe = true
                conn.send(content: (pairing.ticket.map { Data("M2PG".utf8) + $0 } ?? Data()) + Proto.magic, completion: .contentProcessed { _ in })
                self.startPinging()
                self.receive()

            case .failed(let error):
                self.closeConnection()
                self.publish(.failed(StreamClient.explain(error, label: label)))
            case .cancelled:
                self.publish(.idle)
            case .waiting(let error):
                self.publish(.connecting("\(label) — \(StreamClient.explain(error, label: label))"))
            default:
                break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { [weak self, weak conn] in
            guard let self, let conn, self.connection === conn else { return }
            if self.acceptedHello { return }
            self.closeConnection()
            self.publish(.failed("Connection timed out. Check the Mac address and Wi-Fi."))
        }
    }

    func connect(host: String, port: UInt16, pairing: Pairing) {
        connect(to: .hostPort(host: NWEndpoint.Host(host),
                              port: NWEndpoint.Port(rawValue: port) ?? 8765),
                label: host, pairing: pairing)
    }

    func disconnect() {
        queue.async {
            self.closeConnection()
            self.publish(.idle)
        }
    }

    /// Queue-confined teardown. Old TCP/UDP callbacks must never touch a new session.
    private func closeConnection() {
        pingTimer?.cancel(); pingTimer = nil
        udpTimer?.cancel(); udpTimer = nil
        repairTimer?.cancel(); repairTimer = nil
        udp?.stateUpdateHandler = nil
        udp?.cancel(); udp = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        acceptedHello = false
        allowsInput = false
        jpegSession = false
        sessionPairing = nil
        rx.removeAll()
        formatDescription = nil
        assemblies.removeAll()
        udpConfirmed = false
        nextSequence = 0
        token = 0
        clockOffset = nil
        rttMillis = 0
        totalFrames = 0
        framesSinceStats = 0
        bytesSinceStats = 0
        lostSinceStats = 0
        latencySum = 0
        lastStatsTime = CFAbsoluteTimeGetCurrent()
        DispatchQueue.main.async {
            self.audioPlayer.stop()
            self.displayLayer.flushAndRemoveImage()
            self.videoSize = .zero
            self.stats = Stats()
            self.interactionRole = ""
            self.hostControl = false; self.hostAudio = false
            self.notice = nil
        }
    }

    func syncAudio() {
        if audioEnabled { audioPlayer.start() }
        send(Proto.msgAudioOn, Data([audioEnabled ? 1 : 0]))
    }

    /// NWError text is written for developers; say what the person can do.
    static func explain(_ error: NWError, label: String) -> String {
        switch error {
        case .dns(let code) where code == kDNSServiceErr_NoSuchRecord:
            return "couldn’t look up “\(label)” — pick your Mac from the list below, or type its IP address"
        case .posix(.ECONNREFUSED):
            return "\(label) refused the connection — is Mac2Phone running on it?"
        case .posix(.ETIMEDOUT), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return "can’t reach \(label) — put both on the same Wi-Fi, or turn on Personal Hotspot"
        case .tls:
            return "Pairing failed. Copy a fresh pairing link from the Mac and update both apps."
        default:
            return error.localizedDescription
        }
    }

    private func publish(_ newState: State) {
        DispatchQueue.main.async { self.state = newState }
    }

    // MARK: - Keepalive and clock sync

    private func startPinging() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(1000))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard CFAbsoluteTimeGetCurrent() - self.lastReceived < 8 else {
                self.closeConnection()
                self.publish(.failed("Connection lost. Check Wi-Fi, then reconnect."))
                return
            }
            var payload = Data()
            payload.appendUInt64(Self.hostMicros())
            self.send(Proto.msgPing, payload)
        }
        timer.resume()
        pingTimer = timer
    }

    private func handlePong(_ payload: Data) {
        guard let sentAt = payload.readUInt64(at: 0),
              let serverMicros = payload.readUInt64(at: 8) else { return }
        let now = Double(Self.hostMicros())
        let rtt = now - Double(sentAt)
        guard rtt >= 0, rtt < 5_000_000 else { return }
        rttMillis = rtt / 1000
        clockOffset = Double(serverMicros) - (Double(sentAt) + rtt / 2)
    }

    // MARK: - Receiving control

    private func receive() {
        guard let connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 18) { [weak self] data, _, isComplete, error in
            guard let self, self.connection === connection else { return }
            if let data, !data.isEmpty {
                self.lastReceived = CFAbsoluteTimeGetCurrent()
                self.bytesSinceStats += data.count
                self.rx.append(data)
                self.drain()
            }
            if isComplete || error != nil {
                self.closeConnection()
                self.publish(.failed(error?.localizedDescription ?? "The Mac disconnected. Tap Reconnect to try again."))
                return
            }
            if self.connection === connection { self.receive() }
        }
    }

    private func drain() {
        while rx.count >= 5 {
            let type = rx[rx.startIndex]
            guard let length = rx.readUInt32(at: 1) else { return }
            guard length <= Proto.maxVideoPayload else {
                closeConnection()
                publish(.failed("The Mac sent an oversized message. Update both apps and reconnect."))
                return
            }
            let total = 5 + Int(length)
            guard rx.count >= total else { return }
            let payload = Data(rx[(rx.startIndex + 5)..<(rx.startIndex + total)])
            rx.removeFirst(total)

            guard acceptedHello || type == Proto.msgHello else {
                closeConnection(); publish(.failed("Pairing protocol mismatch. Update both apps.")); return
            }
            switch type {
            case Proto.msgHello:
                guard !acceptedHello,
                      let hello = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
                      hello["version"] as? Int == 2, ["native", "jpeg"].contains(hello["video"] as? String ?? ""),
                      hello["transport"] as? String == "tls-psk" else {
                    closeConnection(); publish(.failed("Incompatible host protocol.")); return
                }
                acceptedHello = true
                jpegSession = hello["video"] as? String == "jpeg"
                allowsInput = hello["control"] as? Bool ?? false
                mapsCommandToControl = ["win32", "linux", "android"].contains(hello["platform"] as? String ?? "")
                let control = allowsInput
                let sound = hello["audioAvailable"] as? Bool ?? false
                let touch = hello["touchMode"] as? String ?? (jpegSession ? "pointer" : "ipad")
                DispatchQueue.main.async {
                    self.hostControl = control; self.hostTouchMode = touch; self.hostAudio = sound
                    if !control { self.notice = "This device is sharing its screen in view-only mode." }
                }
                if let pairing = sessionPairing, pairing.ticket == nil {
                    do { try PairingStore.save(pairing, account: "last-peer") }
                    catch {
                        DispatchQueue.main.async { self.notice = "Connected, but the pairing key was not saved. Re-pair on the next launch." }
                    }
                }
                publish(.connected(sessionLabel))
            case Proto.msgJPEG: if jpegSession { presentJPEG(payload) }
            case Proto.msgVideoConfig: if !jpegSession { handleConfig(payload) }
            case Proto.msgVideoFrame: if !jpegSession { handleTCPFrame(payload) }
            case Proto.msgSession:
                closeConnection(); publish(.failed("Unencrypted media is disabled in protocol v2.")); return
            case Proto.msgPong:        handlePong(payload)
            case Proto.msgStatus:
                if let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] {
                    switch object["t"] as? String {
                    case "role":
                        let role = object["r"] as? String ?? ""
                        DispatchQueue.main.async { self.interactionRole = role }
                    case "warn":
                        if let text = object["m"] as? String {
                            DispatchQueue.main.async { self.notice = text }
                        }
                    case "lid":
                        DispatchQueue.main.async {
                            self.lidAwake = object["awake"] as? Bool ?? false
                            self.lidHelperInstalled = object["helper"] as? Bool ?? false
                            self.powerState = object["power"] as? String ?? ""
                        }
                    default:
                        break
                    }
                }
            case Proto.msgAudioConfig:
                if let rate = payload.readUInt32(at: 0), payload.count > 4 {
                    let channels = Int(payload[payload.startIndex + 4])
                    guard (8_000...192_000).contains(rate), (1...2).contains(channels) else { continue }
                    DispatchQueue.main.async {
                        self.audioPlayer.configure(sampleRate: Double(rate), channels: channels)
                    }
                }
            case Proto.msgAudioFrame:
                if payload.count > 8 {
                    audioPlayer.enqueue(Data(payload[(payload.startIndex + 8)...]))
                }
            default: break
            }
        }
    }

    // MARK: - UDP setup

    private func handleSession(_ payload: Data) {
        guard let token = payload.readUInt32(at: 0),
              let udpPort = payload.readUInt16(at: 4),
              let port = NWEndpoint.Port(rawValue: udpPort) else { return }

        // The Mac names the address it wants datagrams sent to; fall back to
        // whatever this TCP connection resolved to if it could not work one out.
        var host: NWEndpoint.Host?
        if payload.count > 6 {
            let length = Int(payload[payload.startIndex + 6])
            if length > 0, payload.count >= 7 + length,
               let text = String(data: payload[(payload.startIndex + 7)..<(payload.startIndex + 7 + length)],
                                 encoding: .utf8), !text.isEmpty {
                host = NWEndpoint.Host(text)
            }
        }
        if host == nil, let remote = connection?.currentPath?.remoteEndpoint,
           case let .hostPort(resolved, _) = remote {
            host = resolved
        }
        guard let host else { return }

        self.token = token
        udp?.cancel()

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true
        let conn = NWConnection(host: host, port: port, using: params)
        conn.stateUpdateHandler = { [weak self] state in
            guard let self, self.udp === conn else { return }
            if case .ready = state { self.sendUDPHello() }
        }
        conn.start(queue: queue)
        udp = conn

        // The hello both tells the Mac where to send and keeps the flow open.
        udpTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(1000))
        timer.setEventHandler { [weak self] in self?.sendUDPHello() }
        timer.resume()
        udpTimer = timer

        receiveUDP()

        repairTimer?.cancel()
        let repair = DispatchSource.makeTimerSource(queue: queue)
        repair.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(6))
        repair.setEventHandler { [weak self] in self?.repairTick() }
        repair.resume()
        repairTimer = repair
    }

    private func sendUDPHello() {
        var hello = Data()
        hello.appendUInt32(token)
        udp?.send(content: hello, completion: .contentProcessed { _ in })
    }

    private func receiveUDP() {
        guard let udp else { return }
        udp.receiveMessage { [weak self] data, _, _, error in
            guard let self, self.udp === udp else { return }
            if let data, data.count > Proto.udpHeaderSize {
                self.bytesSinceStats += data.count
                self.handleDatagram(data)
            }
            if error == nil { self.receiveUDP() }
        }
    }

    private func handleDatagram(_ packet: Data) {
        guard let packetToken = packet.readUInt32(at: 0), packetToken == token,
              let sequence = packet.readUInt32(at: 4),
              let index = packet.readUInt16(at: 8),
              let count = packet.readUInt16(at: 10),
              let pts = packet.readInt64(at: 13),
              count > 0, count <= Proto.maxUDPFragments, index < count,
              packet.count <= Proto.udpHeaderSize + Proto.udpMaxPayload else { return }

        let flags = packet[packet.startIndex + 12]
        let body = Data(packet[(packet.startIndex + Proto.udpHeaderSize)...])

        if !udpConfirmed {
            udpConfirmed = true
            send(Proto.msgUdpOk, Data())
        }

        if flags & Proto.udpFlagAudio != 0 {
            audioPlayer.enqueue(body)
            return
        }

        // Already shown, or given up on.
        if nextSequence != 0 && sequence < nextSequence { return }

        if assemblies[sequence] == nil && assemblies.count >= 12 {
            assemblies.removeAll()
            nextSequence = 0
            awaitingKeyframe = true
            requestKeyframe()
        }
        var assembly = assemblies[sequence] ?? Assembly(fragments: Array(repeating: nil, count: Int(count)),
                                                        count: Int(count),
                                                        isKeyframe: flags & Proto.udpFlagKeyframe != 0,
                                                        ptsMicros: pts,
                                                        firstSeen: CFAbsoluteTimeGetCurrent())
        guard assembly.count == Int(count), assembly.ptsMicros == pts,
              assembly.isKeyframe == (flags & Proto.udpFlagKeyframe != 0) else { return }
        if assembly.fragments[Int(index)] == nil {
            assembly.fragments[Int(index)] = body
            assembly.received += 1
            assembly.byteCount += body.count
        }
        assemblies[sequence] = assembly

        drainFrames()
    }

    /// Frames must reach the decoder in order — every frame but a keyframe is
    /// predicted from the one before it — so a completed frame waits for its
    /// predecessors rather than jumping the queue.
    private func drainFrames() {
        if nextSequence == 0 {
            guard let first = assemblies.filter({ $0.value.isKeyframe && $0.value.received == $0.value.count })
                .keys.min() else { return }
            nextSequence = first
            headSince = CFAbsoluteTimeGetCurrent()
        }

        while let assembly = assemblies[nextSequence], assembly.received == assembly.count {
            var sample = Data(capacity: assembly.byteCount)
            for fragment in assembly.fragments { sample.append(fragment ?? Data()) }
            assemblies.removeValue(forKey: nextSequence)
            present(sample, isKeyframe: assembly.isKeyframe, micros: assembly.ptsMicros)
            nextSequence &+= 1
            headSince = CFAbsoluteTimeGetCurrent()
        }

        for key in assemblies.keys where key < nextSequence {
            assemblies.removeValue(forKey: key)
        }
    }

    /// Runs often and cheaply: ask for the handful of packets that did not turn
    /// up, and only fall back to demanding a whole keyframe once that has
    /// clearly failed. On a local link a retransmit arrives in a few
    /// milliseconds, where a keyframe is large enough to cause the next round
    /// of loss by itself.
    private func repairTick() {
        guard udpConfirmed else { return }
        let now = CFAbsoluteTimeGetCurrent()
        if nextSequence == 0 {
            assemblies = assemblies.filter { now - $0.value.firstSeen < 0.25 }
            if now - lastKeyframeRequest > 0.5 {
                lastKeyframeRequest = now
                send(Proto.msgKeyframe, Data())
            }
            return
        }

        if let head = assemblies[nextSequence], head.received < head.count {
            requestMissing(sequence: nextSequence, from: head, now: now)
        } else if assemblies[nextSequence] == nil, !assemblies.isEmpty,
                  now - headSince > 0.012 {
            // Nothing at all arrived for this frame; ask for all of it.
            sendNack(sequence: nextSequence, indices: [])
        }

        // A frame that is still missing long after the fact is never coming.
        if now - headSince > 0.09 {
            lostSinceStats += 1
            assemblies.removeAll()
            nextSequence = 0
            awaitingKeyframe = true
            if now - lastKeyframeRequest > 0.12 {
                lastKeyframeRequest = now
                send(Proto.msgKeyframe, Data())
            }
        }
    }

    private func requestMissing(sequence: UInt32, from assembly: Assembly, now: CFAbsoluteTime) {
        guard now - assembly.firstSeen > 0.008,
              now - assembly.lastNack > 0.012,
              assembly.nackCount < 5 else { return }

        var missing: [UInt16] = []
        for (index, fragment) in assembly.fragments.enumerated() where fragment == nil {
            missing.append(UInt16(index))
            if missing.count >= 64 { break }
        }
        guard !missing.isEmpty else { return }

        var updated = assembly
        updated.nackCount += 1
        updated.lastNack = now
        assemblies[sequence] = updated
        sendNack(sequence: sequence, indices: missing)
    }

    /// An empty index list means "resend the whole frame".
    private func sendNack(sequence: UInt32, indices: [UInt16]) {
        var packet = Data()
        packet.appendUInt32(token)
        packet.append(Proto.udpKindNack)
        packet.appendUInt32(sequence)
        packet.appendUInt16(UInt16(indices.count))
        for index in indices { packet.appendUInt16(index) }
        udp?.send(content: packet, completion: .contentProcessed { _ in })
    }

    // MARK: - Video

    /// JPEG is the interoperable path for desktop, Android and ReplayKit hosts.
    /// Decode on the serial receive queue, acknowledge only after enqueueing.
    private func presentJPEG(_ data: Data) {
        defer { send(Proto.msgAck, Data()) }
        guard data.count <= 4 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int,
              width > 0, height > 0, width <= 8192, height <= 8192, width * height <= 8_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
              [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
              &buffer) == kCVReturnSuccess, let buffer else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
              bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
              bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else {
            CVPixelBufferUnlockBaseAddress(buffer, []); return
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
              formatDescriptionOut: &format) == noErr, let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
              formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sample) }
        let size = CGSize(width: width, height: height)
        desktopSize = size
        DispatchQueue.main.async { if self.videoSize != size { self.videoSize = size } }
        framesSinceStats += 1; updateStats()
    }

    private func handleConfig(_ payload: Data) {
        var offset = 0
        func u8() -> UInt8? {
            guard payload.count > offset else { return nil }
            defer { offset += 1 }
            return payload[payload.startIndex + offset]
        }
        func u32() -> Int? {
            guard let v = payload.readUInt32(at: offset) else { return nil }
            offset += 4
            return Int(v)
        }

        guard let codec = u8(),
              let width = u32(), let height = u32(),
              let desktopW = u32(), let desktopH = u32(),
              let nalLength = u8(), let setCount = u8() else { return }

        guard [Proto.codecH264, Proto.codecHEVC].contains(codec),
              (1...16384).contains(width), (1...16384).contains(height),
              desktopW > 0, desktopH > 0, [1, 2, 4].contains(nalLength),
              (1...3).contains(setCount) else { return }
        var sets: [Data] = []
        for _ in 0..<Int(setCount) {
            guard let size = u32(), payload.count >= offset + size else { return }
            sets.append(Data(payload[(payload.startIndex + offset)..<(payload.startIndex + offset + size)]))
            offset += size
        }
        guard !sets.isEmpty else { return }

        var pointers: [UnsafePointer<UInt8>] = []
        var sizes: [Int] = []
        var buffers: [UnsafeMutablePointer<UInt8>] = []
        for set in sets {
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.copyBytes(to: buffer, count: set.count)
            buffers.append(buffer)
            pointers.append(UnsafePointer(buffer))
            sizes.append(set.count)
        }
        defer { buffers.forEach { $0.deallocate() } }

        var format: CMFormatDescription?
        let status: OSStatus = codec == Proto.codecHEVC
            ? CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault,
                                                                  parameterSetCount: pointers.count,
                                                                  parameterSetPointers: &pointers,
                                                                  parameterSetSizes: &sizes,
                                                                  nalUnitHeaderLength: Int32(nalLength),
                                                                  extensions: nil,
                                                                  formatDescriptionOut: &format)
            : CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                                                                  parameterSetCount: pointers.count,
                                                                  parameterSetPointers: &pointers,
                                                                  parameterSetSizes: &sizes,
                                                                  nalUnitHeaderLength: Int32(nalLength),
                                                                  formatDescriptionOut: &format)

        guard status == noErr, let format else { return }
        formatDescription = format
        awaitingKeyframe = true
        assemblies.removeAll()
        nextSequence = 0
        desktopSize = CGSize(width: desktopW, height: desktopH)

        DispatchQueue.main.async {
            self.displayLayer.sampleBufferRenderer.flush()
            self.videoSize = CGSize(width: width, height: height)
        }
        send(Proto.msgKeyframe, Data())
    }

    private func handleTCPFrame(_ payload: Data) {
        guard payload.count > 9 else { return }
        let isKeyframe = payload[payload.startIndex] == 1
        let micros = payload.readInt64(at: 1) ?? 0
        present(Data(payload[(payload.startIndex + 9)...]), isKeyframe: isKeyframe, micros: micros)
        if !udpConfirmed { send(Proto.msgAck, Data()) }
    }

    private func present(_ sample: Data, isKeyframe: Bool, micros: Int64) {
        guard let format = formatDescription else { return }

        if awaitingKeyframe {
            guard isKeyframe else { return }
            awaitingKeyframe = false
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
            awaitingKeyframe = true
            send(Proto.msgKeyframe, Data())
            return
        }

        guard let sampleBuffer = makeSampleBuffer(sample, format: format, micros: micros) else { return }
        renderer.enqueue(sampleBuffer)

        if let offset = clockOffset {
            let age = (Double(Self.hostMicros()) - (Double(micros) - offset)) / 1000
            if age > 0, age < 5000 { latencySum += age }
        }
        framesSinceStats += 1
        updateStats()
    }

    private func makeSampleBuffer(_ data: Data, format: CMFormatDescription, micros: Int64) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault,
                                                 memoryBlock: nil,
                                                 blockLength: data.count,
                                                 blockAllocator: kCFAllocatorDefault,
                                                 customBlockSource: nil,
                                                 offsetToData: 0,
                                                 dataLength: data.count,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &blockBuffer) == kCMBlockBufferNoErr,
              let blockBuffer else { return nil }

        let copied = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: blockBuffer,
                                                 offsetIntoDestination: 0, dataLength: data.count)
        }
        guard copied == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: micros, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var sizes = [data.count]
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault,
                                        dataBuffer: blockBuffer,
                                        formatDescription: format,
                                        sampleCount: 1,
                                        sampleTimingEntryCount: 1,
                                        sampleTimingArray: &timing,
                                        sampleSizeEntryCount: 1,
                                        sampleSizeArray: &sizes,
                                        sampleBufferOut: &sampleBuffer) == noErr,
              let sampleBuffer else { return nil }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sampleBuffer
    }

    private func updateStats() {
        let now = CFAbsoluteTimeGetCurrent()
        let elapsed = now - lastStatsTime
        guard elapsed >= 1 else { return }
        let fps = Int((Double(framesSinceStats) / elapsed).rounded())
        let kbps = Int(Double(bytesSinceStats) * 8 / 1000 / elapsed)
        totalFrames += framesSinceStats
        let total = totalFrames
        let latency = framesSinceStats > 0 ? Int((latencySum / Double(framesSinceStats)).rounded()) : 0
        let rtt = Int(rttMillis.rounded())
        let lost = lostSinceStats
        let transport = "TLS"
        lastStatsTime = now
        framesSinceStats = 0
        bytesSinceStats = 0
        lostSinceStats = 0
        latencySum = 0
        DispatchQueue.main.async {
            self.stats = Stats(fps: fps, kbps: kbps, frames: total, latencyMs: latency,
                               rttMs: rtt, lostFrames: lost, transport: transport)
        }
    }

    // MARK: - Sending

    private func send(_ type: UInt8, _ payload: Data) {
        guard DispatchQueue.getSpecific(key: queueKey) == true else {
            queue.async { self.send(type, payload) }
            return
        }
        connection?.send(content: Proto.frame(type, payload), completion: .contentProcessed { _ in })
    }

    func requestKeyframe() { send(Proto.msgKeyframe, Data()) }

    func sendInput(_ object: [String: Any]) {
        guard DispatchQueue.getSpecific(key: queueKey) == true else {
            queue.async { self.sendInput(object) }; return
        }
        guard allowsInput else { return }
        var value = object
        if mapsCommandToControl, let modifiers = value["m"] as? [String] {
            value["m"] = Array(Set(modifiers.map { $0 == "cmd" ? "ctrl" : $0 }))
        }
        guard let data = try? JSONSerialization.data(withJSONObject: value) else { return }
        send(Proto.msgInput, data)
    }

    func sendSettings(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        send(Proto.msgSettings, data)
    }
}
