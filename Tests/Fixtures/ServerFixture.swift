// Synthetic loopback host: no ScreenCaptureKit, CGEvent, microphone, or Keychain calls.
import Foundation
import Network
import Darwin

@main struct ServerFixture {
    static func nativeClient(port: UInt16) {
        let pairing = Pairing(identity: "00000000-0000-4000-8000-000000000001", key: Data(repeating: 65, count: 32), host: "127.0.0.1", port: port)
        let conn = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: pairing.parameters())
        var bytes = Data()
        func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, error in
                if let data { bytes.append(data) }
                if bytes.count >= 5, let length = bytes.readUInt32(at: 1), bytes.count >= 5 + Int(length) {
                    guard bytes[0] == Proto.msgHello,
                          let hello = try? JSONSerialization.jsonObject(with: Data(bytes.dropFirst(5).prefix(Int(length)))) as? [String: Any],
                          hello["version"] as? Int == 2 else { exit(1) }
                    print("PASS Apple Network native client authenticated and received v2 hello")
                    exit(0)
                }
                if done || error != nil { exit(1) }
                receive()
            }
        }
        conn.stateUpdateHandler = { state in
            if case .ready = state { conn.send(content: Proto.magic, completion: .contentProcessed { _ in }); receive() }
            if case .failed = state { exit(1) }
        }
        conn.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { exit(1) }
    }
    static func main() throws {
        setbuf(stdout, nil)
        if CommandLine.arguments[1] == "--native-client" {
            nativeClient(port: UInt16(CommandLine.arguments[2])!)
            dispatchMain()
        }
        let port = UInt16(CommandLine.arguments[1])!
        let pairing = Pairing(identity: "00000000-0000-4000-8000-000000000001",
                              key: Data(repeating: 65, count: 32), host: "127.0.0.1", port: port)
        let server = Server(port: port, pairing: pairing, bindHost: "127.0.0.1", nativeVideo: !CommandLine.arguments.contains("--jpeg-host"))
        server.capabilities = { ["control": true, "screen": true, "audioAvailable": true] }
        server.currentAudioConfig = { (48000, 2) }
        server.onInput = { value in
            if let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), let text = String(data: bytes, encoding: .utf8) { print("INPUT \(text)") }
            if value["t"] as? String == "fixture-rotate" {
                let next = Pairing(identity: "00000000-0000-4000-8000-000000000002", key: Data(repeating: 66, count: 32), host: "127.0.0.1", port: port)
                server.rotatePairing(next) { error in print(error == nil ? "ROTATED" : "ROTATION FAILED") }
            }
        }
        let jpeg = Data(base64Encoded: "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAAYACADASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDh6KKK0PHCiiigAooooAKKKKAP/9k=")!
        server.onViewersChanged = { viewers in
            if viewers.total > 0 { server.send(jpeg: jpeg) }
        }
        server.onAudioWantedChanged = { wanted in
            if wanted {
                server.sendAudioConfig(sampleRate: 48000, channels: 2)
                server.send(audio: Data(repeating: 0, count: 64), ptsMicros: 0)
            }
        }
        try server.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { print("READY") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { exit(2) }
        dispatchMain()
    }
}
