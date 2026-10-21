import Foundation

/// Binary protocol spoken between the Mac server and the native iPhone app.
///
///   client -> "M2P2" (native) or "M2PJ" (desktop), inside paired TLS;                                    (4 byte magic, once)
///   both   -> [u8 type][u32be length][payload ...]      (framed messages)
///
enum Proto {
    static let maxControlPayload = 64 * 1024
    static let maxVideoPayload = 16 * 1024 * 1024
    static let maxUDPFragments = 4096

    static let magic = Data("M2P2".utf8)
    static let desktopMagic = Data("M2PJ".utf8)
    static let msgHello: UInt8 = 0x08
    static let msgJPEG: UInt8 = 0x09

    // Server -> client
    static let msgVideoConfig: UInt8 = 0x01
    static let msgVideoFrame:  UInt8 = 0x02
    static let msgStatus:      UInt8 = 0x03   // JSON

    // Client -> server
    static let msgInput:       UInt8 = 0x10   // JSON
    static let msgSettings:    UInt8 = 0x11   // JSON
    static let msgAck:         UInt8 = 0x12   // empty
    static let msgKeyframe:    UInt8 = 0x13   // empty, "resend a keyframe"
    static let msgPing:        UInt8 = 0x14   // client -> server, u64 client micros
    static let msgPong:        UInt8 = 0x04   // server -> client, u64 client micros + u64 server micros
    static let msgSession:     UInt8 = 0x05   // server -> client: u32 token, u16 udp port
    static let msgUdpOk:       UInt8 = 0x15   // client -> server: UDP video is arriving

    /// UDP video datagram header, laid out ahead of each fragment.
    ///   u32 token | u32 frameSeq | u16 fragIndex | u16 fragCount | u8 flags | i64 ptsMicros
    static let msgAudioConfig: UInt8 = 0x06   // server -> client: u32 rate, u8 channels
    static let msgAudioFrame:  UInt8 = 0x07   // server -> client: i64 pts + Int16 PCM (TCP fallback)
    static let msgAudioOn:     UInt8 = 0x16   // client -> server: 1 byte, want audio or not

    /// Datagram flag bits (byte 12 of the UDP header).
    static let udpFlagKeyframe: UInt8 = 1 << 0
    static let udpFlagAudio:    UInt8 = 1 << 1

    /// Client -> server datagrams: 4-byte token alone is a hello; anything
    /// longer carries a kind byte.
    static let udpKindNack: UInt8 = 1

    static let udpHeaderSize = 21
    /// Conservative payload size: 1500 MTU minus IP/UDP overhead, minus our header,
    /// with room to spare for any tunnel that shaves a few bytes off the path.
    static let udpMaxPayload = 1200

    static let codecH264: UInt8 = 0
    static let codecHEVC: UInt8 = 1

    static func frame(_ type: UInt8, _ payload: Data) -> Data {
        var out = Data(capacity: payload.count + 5)
        out.append(type)
        out.append(UInt8((payload.count >> 24) & 0xFF))
        out.append(UInt8((payload.count >> 16) & 0xFF))
        out.append(UInt8((payload.count >> 8) & 0xFF))
        out.append(UInt8(payload.count & 0xFF))
        out.append(payload)
        return out
    }
}

extension Data {
    mutating func appendUInt32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    mutating func appendInt64(_ v: Int64) {
        let u = UInt64(bitPattern: v)
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((u >> UInt64(shift)) & 0xFF))
        }
    }

    func readUInt32(at offset: Int) -> UInt32? {
        guard offset >= 0, offset <= count, count - offset >= 4 else { return nil }
        let i = startIndex + offset
        return UInt32(self[i]) << 24 | UInt32(self[i + 1]) << 16 | UInt32(self[i + 2]) << 8 | UInt32(self[i + 3])
    }

    mutating func appendUInt16(_ v: UInt16) {
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8(v & 0xFF))
    }

    func readUInt16(at offset: Int) -> UInt16? {
        guard offset >= 0, offset <= count, count - offset >= 2 else { return nil }
        let i = startIndex + offset
        return UInt16(self[i]) << 8 | UInt16(self[i + 1])
    }

    mutating func appendUInt64(_ v: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((v >> UInt64(shift)) & 0xFF))
        }
    }

    func readUInt64(at offset: Int) -> UInt64? {
        guard offset >= 0, offset <= count, count - offset >= 8 else { return nil }
        var u: UInt64 = 0
        for k in 0..<8 { u = u << 8 | UInt64(self[startIndex + offset + k]) }
        return u
    }

    func readInt64(at offset: Int) -> Int64? {
        guard offset >= 0, offset <= count, count - offset >= 8 else { return nil }
        var u: UInt64 = 0
        for k in 0..<8 { u = u << 8 | UInt64(self[startIndex + offset + k]) }
        return Int64(bitPattern: u)
    }
}
