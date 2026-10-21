import Foundation
import Network
import Security

/// A host-wide, random 256-bit bearer key. Never log or advertise the key.
struct Pairing: Codable, Equatable {
    let identity: String
    let key: Data
    let host: String
    let port: UInt16
    var ticket: Data? = nil

    enum Failure: Error, LocalizedError {
        case invalidLink, keychain(OSStatus)
        var errorDescription: String? {
            switch self {
            case .invalidLink: return "Paste a complete pairing link copied from the Mac app."
            case .keychain: return "The pairing key could not be read or saved in Keychain."
            }
        }
    }

    static func generate(host: String, port: UInt16) throws -> Pairing {
        var bytes = [UInt8](repeating: 0, count: 32)
        let result = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard result == errSecSuccess else { throw Failure.keychain(result) }
        return Pairing(identity: UUID().uuidString.lowercased(), key: Data(bytes), host: host, port: port)
    }

    var link: String {
        var url = URLComponents()
        url.scheme = "mac2phone"
        url.host = host
        url.port = Int(port)
        url.fragment = "\(ticket == nil ? "v2" : "v3").\(identity).\(key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))"
        if let ticket { url.fragment! += "." + ticket.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
        return url.string ?? ""
    }

    static func parse(_ raw: String) throws -> Pairing {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 1024, !text.contains(where: { $0.isWhitespace }),
              let url = URLComponents(string: text), url.scheme == "mac2phone",
              let host = url.host, !host.isEmpty, host.utf8.allSatisfy({ $0 < 128 }),
              url.user == nil, url.password == nil, url.query == nil,
              url.path.isEmpty, let number = url.port, let port = UInt16(exactly: number), port > 0,
              let fragment = url.percentEncodedFragment, !fragment.contains("%") else { throw Failure.invalidLink }
        let parts = fragment.split(separator: ".", omittingEmptySubsequences: false)
        guard ((parts.count == 3 && parts[0] == "v2") || (parts.count == 4 && parts[0] == "v3")), UUID(uuidString: String(parts[1])) != nil,
              parts[1] == parts[1].lowercased(), parts[2].count == 43,
              parts[2].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              let key = Data(base64Encoded: parts[2].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), key.count == 32 else { throw Failure.invalidLink }
        var value = Pairing(identity: String(parts[1]), key: key, host: host, port: port)
        if parts.count == 4 {
            guard parts[3].count == 43, let ticket = Data(base64Encoded: parts[3].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), ticket.count == 32 else { throw Failure.invalidLink }
            value.ticket = ticket
        }
        guard value.link == text else { throw Failure.invalidLink }
        return value
    }

    func parameters() -> NWParameters {
        let tls = NWProtocolTLS.Options()
        key.withUnsafeBytes { bytes in
            Data(identity.utf8).withUnsafeBytes { name in
                sec_protocol_options_add_pre_shared_key(tls.securityProtocolOptions,
                    DispatchData(bytes: bytes) as __DispatchData, DispatchData(bytes: name) as __DispatchData)
            }
        }
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        // The typed tls_ciphersuite_t SDK enum omits ECDHE-PSK; this public API accepts it.
        sec_protocol_options_add_tls_ciphersuite(tls.securityProtocolOptions,
            UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256))
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 8
        return NWParameters(tls: tls, tcp: tcp)
    }
}

enum PairingStore {
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "Mac2Phone.Pairing.v2",
         kSecAttrAccount as String: account]
    }
    static func load(_ account: String) throws -> Pairing? {
        var q = query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw Pairing.Failure.keychain(status) }
        let pairing = try JSONDecoder().decode(Pairing.self, from: data)
        return try Pairing.parse(pairing.link)
    }
    static func save(_ pairing: Pairing, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(pairing),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(q.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Pairing.Failure.keychain(status) }
    }
}
