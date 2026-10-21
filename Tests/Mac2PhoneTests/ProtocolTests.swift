import XCTest
@testable import mac2phone

final class ProtocolTests: XCTestCase {
    func testIntegerRoundTripsAndTruncation() {
        var data = Data()
        data.appendUInt16(0x1234); data.appendUInt32(0x12345678); data.appendInt64(-42)
        XCTAssertEqual(data.readUInt16(at: 0), 0x1234)
        XCTAssertEqual(data.readUInt32(at: 2), 0x12345678)
        XCTAssertEqual(data.readInt64(at: 6), -42)
        XCTAssertNil(data.readUInt32(at: 12))
        XCTAssertNil(data.readUInt64(at: -1))
        XCTAssertNil(data.readUInt16(at: Int.max))
    }

    func testNativeFrameHeader() {
        let data = Proto.frame(Proto.msgInput, Data("hello".utf8))
        XCTAssertEqual(data.first, Proto.msgInput)
        XCTAssertEqual(data.readUInt32(at: 1), 5)
        XCTAssertEqual(data.suffix(5), Data("hello".utf8))
    }

    private func masked(_ text: String, opcode: UInt8 = 1, fin: Bool = true) -> Data {
        let bytes = Array(text.utf8)
        let mask: [UInt8] = [1, 2, 3, 4]
        var result = Data([opcode | (fin ? 0x80 : 0), 0x80 | UInt8(bytes.count)])
        result.append(contentsOf: mask)
        result.append(contentsOf: bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        return result
    }

    private func decode(_ data: Data) throws -> WS.Message? {
        var buffer = data, fragments = Data()
        var opcode: WSOpcode?
        return try WS.decode(from: &buffer, fragmentOpcode: &opcode, fragmentBuffer: &fragments)
    }

    func testMaskedClientText() throws {
        let result = try decode(masked("hello"))
        XCTAssertEqual(result?.opcode, .text)
        XCTAssertEqual(result?.payload, Data("hello".utf8))
    }

    func testPartialFrameWaitsWithoutConsuming() throws {
        var buffer = Data(masked("hello").prefix(4)), fragments = Data()
        var opcode: WSOpcode?
        XCTAssertNil(try WS.decode(from: &buffer, fragmentOpcode: &opcode, fragmentBuffer: &fragments))
        XCTAssertEqual(buffer.count, 4)
    }

    func testFragmentedMessageWithInterleavedPing() throws {
        var buffer = masked("hel", fin: false) + masked("", opcode: 9) + masked("lo", opcode: 0)
        var fragments = Data()
        var opcode: WSOpcode?
        XCTAssertEqual(try WS.decode(from: &buffer, fragmentOpcode: &opcode, fragmentBuffer: &fragments)?.opcode, .ping)
        XCTAssertEqual(try WS.decode(from: &buffer, fragmentOpcode: &opcode, fragmentBuffer: &fragments)?.payload, Data("hello".utf8))
        XCTAssertNil(opcode)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testUnmaskedClientRejected() {
        XCTAssertThrowsError(try decode(WS.frame(Data(), opcode: .text)))
    }
    func testOrphanContinuationRejected() {
        XCTAssertThrowsError(try decode(masked("x", opcode: 0)))
    }
    func testFragmentedControlRejected() {
        XCTAssertThrowsError(try decode(masked("", opcode: 9, fin: false)))
    }
    func testReservedBitsRejected() {
        var data = masked("x"); data[0] |= 0x40
        XCTAssertThrowsError(try decode(data))
    }
    func testHugeLengthRejectedBeforeAllocation() {
        XCTAssertThrowsError(try decode(Data([0x81, 0xFF] + Array(repeating: 0xFF, count: 8))))
    }
    func testInvalidClosePayloadRejected() {
        XCTAssertThrowsError(try decode(masked("x", opcode: 8)))
    }
    func testSecondFragmentStartRejected() {
        XCTAssertThrowsError(try decode(masked("a", fin: false) + masked("b", fin: false)))
    }
}
