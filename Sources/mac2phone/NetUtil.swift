import Foundation

enum NetUtil {

    /// Non-loopback IPv4 addresses of active interfaces, best candidate first.
    static func localAddresses() -> [(iface: String, ip: String)] {
        var out: [(iface: String, ip: String)] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return out }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard flags & IFF_UP == IFF_UP, flags & IFF_LOOPBACK == 0 else { continue }
            guard let sa = ptr.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if ip.hasPrefix("169.254.") { continue }
            out.append((iface: String(cString: ptr.pointee.ifa_name), ip: ip))
        }

        // 172.20.10.x is the iPhone Personal Hotspot subnet — always the best guess here.
        return out.sorted { (a: (iface: String, ip: String), b: (iface: String, ip: String)) -> Bool in
            rank(a.ip, a.iface) < rank(b.ip, b.iface)
        }
    }

    private static func rank(_ ip: String, _ iface: String) -> Int {
        if ip.hasPrefix("172.20.10.") { return 0 }
        if iface.hasPrefix("en") { return 1 }
        if iface.hasPrefix("bridge") { return 3 }
        return 2
    }

    /// The mDNS name of this Mac, e.g. "Kias-MacBook-Pro.local".
    static func localHostName() -> String {
        let raw = ProcessInfo.processInfo.hostName
        if raw.hasSuffix(".local") { return raw }
        if raw.contains(".") { return raw }
        return raw + ".local"
    }
}
