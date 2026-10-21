import Foundation
import Darwin

/// Shared only with our ReplayKit extension, protected on disk and excluded from backup.
enum BroadcastState {
    static var file: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "Mac2PhoneAppGroup") as? String,
              let folder = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return folder.appendingPathComponent("broadcast-pairing.json")
    }
    static func load() throws -> Pairing {
        guard let file else { throw Failure.group }
        return try JSONDecoder().decode(Pairing.self, from: Data(contentsOf: file))
    }
    static func prepare() throws -> Pairing {
        guard var file else { throw Failure.group }
        guard let address = addresses().first else { throw Failure.network }
        let value = try Pairing.generate(host: address, port: 8765)
        try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true
        try file.setResourceValues(resources)
        return value
    }
    static func revoke() {
        if let file {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent().appendingPathComponent("connection-grants"))
        }
        if let activeFile { try? FileManager.default.removeItem(at: activeFile) }
    }
    private static var activeFile: URL? { file?.deletingLastPathComponent().appendingPathComponent("broadcast-active.json") }
    static func markActive(identity: String) {
        guard let activeFile else { return }
        let value: [String: Any] = ["identity": identity, "time": Date().timeIntervalSince1970]
        if let bytes = try? JSONSerialization.data(withJSONObject: value) { try? bytes.write(to: activeFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    }
    static func grant() throws -> Pairing {
        var pairing = try load()
        guard let activeFile, let bytes = try? Data(contentsOf: activeFile),
              let active = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              active["identity"] as? String == pairing.identity, let time = active["time"] as? Double,
              Date().timeIntervalSince1970 - time < 2,
              let folder = file?.deletingLastPathComponent().appendingPathComponent("connection-grants", isDirectory: true) else { throw Failure.network }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in files {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 60 { try? FileManager.default.removeItem(at: url) }
        }
        guard try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).count < 8 else { throw Failure.network }
        let token = try Pairing.generate(host: pairing.host, port: pairing.port).key
        let name = token.map { String(format: "%02x", $0) }.joined()
        let value: [String: Any] = ["identity": pairing.identity, "expires": Date().addingTimeInterval(60).timeIntervalSince1970]
        var url = folder.appendingPathComponent(name)
        try JSONSerialization.data(withJSONObject: value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var resources = URLResourceValues(); resources.isExcludedFromBackup = true; try url.setResourceValues(resources)
        pairing.ticket = token; return pairing
    }
    static func consume(_ token: Data, identity: String) -> Bool {
        guard token.count == 32, let folder = file?.deletingLastPathComponent().appendingPathComponent("connection-grants", isDirectory: true) else { return false }
        let url = folder.appendingPathComponent(token.map { String(format: "%02x", $0) }.joined())
        do {
            let bytes = try Data(contentsOf: url)
            try FileManager.default.removeItem(at: url) // The extension consumes on its serial server queue.
            guard let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  value["identity"] as? String == identity, let expires = value["expires"] as? Double else { return false }
            return expires > Date().timeIntervalSince1970
        } catch { return false }
    }
    enum Failure: LocalizedError {
        case group, network
        var errorDescription: String? {
            switch self {
            case .group: return "Enable the same App Group for the app and Broadcast extension in Xcode Signing & Capabilities."
            case .network: return "Connect to Wi-Fi before preparing a broadcast."
            }
        }
    }
    static func addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var result: [String] = []; var item = head
        while let entry = item {
            defer { item = entry.pointee.ifa_next }
            let value = entry.pointee
            guard let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: value.ifa_name).hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}
