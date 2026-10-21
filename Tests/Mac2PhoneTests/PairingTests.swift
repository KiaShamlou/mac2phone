import XCTest
@testable import mac2phone

final class PairingTests: XCTestCase {
    private let sample = Pairing(identity: "00000000-0000-4000-8000-000000000001", key: Data(repeating: 0x41, count: 32), host: "192.168.1.20", port: 8765)
    func testPairingRoundTrip() throws {
        XCTAssertEqual(try Pairing.parse(sample.link), sample)
        XCTAssertTrue(sample.link.contains("#v2."))
        XCTAssertFalse(sample.link.contains("?"))
    }
    func testInvalidLinksFailClosed() {
        for text in ["", "http://192.168.1.20:8765", sample.link.replacingOccurrences(of: ":8765", with: ":0"),
                     sample.link.replacingOccurrences(of: ":8765", with: ":65536"),
                     sample.link.replacingOccurrences(of: "#", with: "?key="),
                     sample.link.replacingOccurrences(of: "#", with: "/#"), sample.link + "=",
                     sample.link.replacingOccurrences(of: "//", with: "//user@"),
                     sample.link.replacingOccurrences(of: "v2.", with: "v1."), String(sample.link.dropLast())] {
            XCTAssertThrowsError(try Pairing.parse(text), text)
        }
    }
    func testFreshPairingsHaveIndependentKeys() throws {
        let first = try Pairing.generate(host: "mac.local", port: 8765)
        let second = try Pairing.generate(host: "mac.local", port: 8765)
        XCTAssertEqual(first.key.count, 32)
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertNotEqual(first.identity, second.identity)
    }
    func testDesktopViewersCount() {
        var viewers = Server.Viewers(); viewers.native = 1; viewers.desktop = 2
        XCTAssertEqual(viewers.total, 3)
    }
    func testProtocolV2ModesAreDistinct() {
        XCTAssertEqual(String(decoding: Proto.magic, as: UTF8.self), "M2P2")
        XCTAssertEqual(String(decoding: Proto.desktopMagic, as: UTF8.self), "M2PJ")
    }
}
