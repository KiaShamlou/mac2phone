import Foundation

enum WSOpcode: UInt8 {
    case continuation = 0x0
    case text         = 0x1
    case binary       = 0x2
    case close        = 0x8
    case ping         = 0x9
    case pong         = 0xA
}

enum WS {

    /// Server -> client frame. Server frames are never masked.
    static func frame(_ payload: Data, opcode: WSOpcode) -> Data {
        var out = Data()
        out.reserveCapacity(payload.count + 10)
        out.append(0x80 | opcode.rawValue)

        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out.append(126)
            out.append(UInt8((n >> 8) & 0xFF))
            out.append(UInt8(n & 0xFF))
        } else {
            out.append(127)
            let v = UInt64(n)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((v >> UInt64(shift)) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }

    struct Message {
        let opcode: WSOpcode
        let payload: Data
    }

    enum DecodeError: Error { case invalidFrame, messageTooLarge }
    static let maxMessageBytes = 64 * 1024

    /// Pulls one complete (possibly de-fragmented) message off `buffer`.
    /// Returns nil when more bytes are needed.
    static func decode(from buffer: inout Data,
                       fragmentOpcode: inout WSOpcode?,
                       fragmentBuffer: inout Data) throws -> Message? {
        while true {
            guard buffer.count >= 2 else { return nil }

            let b0 = buffer[buffer.startIndex]
            let b1 = buffer[buffer.startIndex + 1]
            let fin = (b0 & 0x80) != 0
            guard b0 & 0x70 == 0, let opcode = WSOpcode(rawValue: b0 & 0x0F) else {
                throw DecodeError.invalidFrame
            }
            let masked = (b1 & 0x80) != 0
            guard masked else { throw DecodeError.invalidFrame }
            let control = opcode.rawValue >= 8
            if control && (!fin || b1 & 0x7F > 125) { throw DecodeError.invalidFrame }
            var len = Int(b1 & 0x7F)
            var offset = 2

            if len == 126 {
                guard buffer.count >= offset + 2 else { return nil }
                len = Int(buffer[buffer.startIndex + 2]) << 8 | Int(buffer[buffer.startIndex + 3])
                guard len >= 126 else { throw DecodeError.invalidFrame }
                offset += 2
            } else if len == 127 {
                guard buffer.count >= offset + 8 else { return nil }
                var v: UInt64 = 0
                for k in 0..<8 { v = v << 8 | UInt64(buffer[buffer.startIndex + offset + k]) }
                guard v >= 65536, v <= UInt64(maxMessageBytes) else { throw DecodeError.messageTooLarge }
                len = Int(v)
                offset += 8
            }

            guard len <= maxMessageBytes,
                  control || fragmentBuffer.count <= maxMessageBytes - len else { throw DecodeError.messageTooLarge }
            if !control {
                if opcode == .continuation && fragmentOpcode == nil { throw DecodeError.invalidFrame }
                if opcode != .continuation && fragmentOpcode != nil { throw DecodeError.invalidFrame }
            }
            var mask = [UInt8](repeating: 0, count: 4)
            if masked {
                guard buffer.count >= offset + 4 else { return nil }
                for k in 0..<4 { mask[k] = buffer[buffer.startIndex + offset + k] }
                offset += 4
            }

            guard buffer.count >= offset + len else { return nil }

            var payload = Data(buffer[(buffer.startIndex + offset)..<(buffer.startIndex + offset + len)])
            if masked {
                for k in 0..<payload.count { payload[k] ^= mask[k % 4] }
            }
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + offset + len))

            if opcode == .close && payload.count == 1 { throw DecodeError.invalidFrame }
            // Control frames are never fragmented.
            if opcode == .close || opcode == .ping || opcode == .pong {
                return Message(opcode: opcode, payload: payload)
            }

            if !fin {
                if fragmentOpcode == nil { fragmentOpcode = opcode }
                fragmentBuffer.append(payload)
                continue
            }

            if opcode == .continuation {
                fragmentBuffer.append(payload)
                let full = fragmentBuffer
                let op = fragmentOpcode ?? .binary
                fragmentBuffer.removeAll(keepingCapacity: true)
                fragmentOpcode = nil
                return Message(opcode: op, payload: full)
            }

            return Message(opcode: opcode, payload: payload)
        }
    }
}
