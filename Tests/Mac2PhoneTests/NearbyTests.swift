import XCTest
import CryptoKit
@testable import mac2phone

final class NearbyTests: XCTestCase {
    func testApprovalLinkRoundTrip() throws {
        var value = try Pairing.generate(host: "127.0.0.1", port: 8765)
        value.ticket = Data(repeating: 7, count: 32)
        XCTAssertEqual(try Pairing.parse(value.link), value)
        XCTAssertTrue(value.link.contains("#v3."))
        XCTAssertThrowsError(try Pairing.parse(String(value.link.dropLast())))
        XCTAssertThrowsError(try Pairing.parse(value.link.replacingOccurrences(of: "#v3.", with: "#v2.")))
    }
    func testNodeCryptoVectorAndAuthenticatedEnvelope() throws {
        let client = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
        let host = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Data(repeating: 2, count: 32))
        let request: [String: Any] = ["v": 1, "name": "Fixture iPhone", "platform": "ios", "key": client.publicKey.rawRepresentation.base64EncodedString()]
        let (key, code) = try NearbyService.agree(client, request: request, hostKey: host.publicKey.rawRepresentation.base64EncodedString())
        let (other, otherCode) = try NearbyService.agree(host, request: request, hostKey: host.publicKey.rawRepresentation.base64EncodedString())
        XCTAssertEqual(code, "950711"); XCTAssertEqual(otherCode, code)
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }, other.withUnsafeBytes { Data($0) })
        XCTAssertEqual(key.withUnsafeBytes { Data($0) }.map { String(format: "%02x", $0) }.joined(), "6c443cd6cd571664597b4d6420b13b30851bd5da8cf380461950827c37d110a9")
        let nodeEnvelope = Data(base64Encoded: "gXQ/mvPXUTnjBSK2VTlPNtko/VzXvm1l3Q+R5+s+lK5bSl/I23xvPwAKwr8tGMhh6A==")!
        let opened = try AES.GCM.open(AES.GCM.SealedBox(combined: nodeEnvelope), using: key, authenticating: NearbyService.info)
        XCTAssertEqual(String(data: opened, encoding: .utf8), "{\"status\":\"declined\"}")
        var corrupted = nodeEnvelope; corrupted[15] ^= 1
        XCTAssertThrowsError(try AES.GCM.open(AES.GCM.SealedBox(combined: corrupted), using: key, authenticating: NearbyService.info))
    }
    func testNamesAndMalformedKeys() throws {
        XCTAssertTrue(NearbyService.validName("My iPhone"))
        XCTAssertFalse(NearbyService.validName("bad\u{202e}name"))
        XCTAssertFalse(NearbyService.validName("  "))
        XCTAssertFalse(NearbyService.validName(String(repeating: "a", count: 129)))
        XCTAssertThrowsError(try NearbyService.decode("not-base64", count: 32))
    }
    func testGrantCapacityAndStopRevocation() throws {
        let pairing = try Pairing.generate(host: "127.0.0.1", port: 8765)
        let server = Server(port: 8765, pairing: pairing)
        let one = try server.grant(host: "127.0.0.1")
        XCTAssertEqual(one.identity, pairing.identity)
        XCTAssertEqual(one.ticket?.count, 32)
        for _ in 0..<7 { _ = try server.grant(host: "127.0.0.1") }
        XCTAssertThrowsError(try server.grant(host: "127.0.0.1"))
        server.disconnectAll() // Queue-ordered revocation is observed by the next synchronous grant.
        XCTAssertNoThrow(try server.grant(host: "127.0.0.1"))
    }
}
