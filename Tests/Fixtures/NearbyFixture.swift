import Foundation
import Network
import Combine

/// Synthetic transport fixture. Never captures a screen or dispatches input.
@main struct NearbyFixture {
    static var token: AnyCancellable?
    static func main() throws {
        let nearby = NearbyService()
        let mode = CommandLine.arguments[1]
        if mode == "host" {
            let port = UInt16(CommandLine.arguments[2])!
            let pairing = Pairing(identity: "00000000-0000-4000-8000-000000000002", key: Data(repeating: 66, count: 32), host: "127.0.0.1", port: port)
            let server = Server(port: port, pairing: pairing, bindHost: "127.0.0.1", nativeVideo: false)
            server.requireApproval = true
            server.capabilities = { ["control": false, "screen": true, "platform": "macos"] }
            try server.start()
            nearby.grant = { done in done(try? server.grant(host: "127.0.0.1").link) }
            token = nearby.$incoming.sink { request in
                guard let request else { return }; print("CODE \(request.code)"); fflush(stdout)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { nearby.respond(accept: true) }
            }
            nearby.start(advertise: false)
            Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { timer in
                if let port = nearby.requestPort { print("READY \(port)"); fflush(stdout); timer.invalidate() }
            }
        } else {
            let port = UInt16(CommandLine.arguments[2])!
            nearby.onApproved = { link in print("LINK \(link)"); fflush(stdout); exit(0) }
            token = nearby.$outgoing.sink { if let request = $0 { print("CODE \(request.code)"); fflush(stdout) } }
            nearby.request(NearbyService.Device(id: UUID().uuidString, name: "Node fixture", platform: "linux", endpoint: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { fputs("Fixture timed out\n", stderr); exit(1) }
        withExtendedLifetime(nearby) { RunLoop.main.run() }
    }
}
