import Foundation
import Security
import CryptoKit
import TVPairTLS

public struct TVContainerFailure: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public struct TVContainerClientIdentity: @unchecked Sendable {
    public let identity: SecIdentity
    public let fingerprint: String
}

/// A separate namespace from Apple developer-device pairing and signing keys.
public actor TVContainerIdentityStore {
    public static let shared = TVContainerIdentityStore()
    private struct StoredIdentity: Codable { let pkcs12: Data; let password: String }
    public struct Pin: Codable, Identifiable, Sendable {
        public var id: String { fingerprint }
        public let fingerprint: String
        public var aliases: Set<String>
        public var name: String
    }
    public enum Trust: Sendable { case approved, unknown, changed }
    private let service: String
    private var cachedIdentity: TVContainerClientIdentity?

    public init(service: String = "SideTVstore.TVContainer.transfer.v1") { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
    private func read(_ account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw TVPairError.keychain(status) }
        return data
    }
    private func write(_ account: String, data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(account)
            item.merge(attributes) { _, new in new }
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TVPairError.keychain(status) }
    }

    public func identity() throws -> TVContainerClientIdentity {
        if let cachedIdentity { return cachedIdentity }
        let value: TVContainerClientIdentity
        if let data = try read("client-identity") {
            // Never rotate an unreadable established identity as error recovery.
            let saved = try JSONDecoder().decode(StoredIdentity.self, from: data)
            value = try Self.importIdentity(saved.pkcs12, password: saved.password)
        } else {
            guard try pins().isEmpty else { throw TVContainerFailure("The saved transfer identity is missing. Restore Keychain access before pairing again.") }
            var random = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else { throw TVPairError.storage }
            let password = random.map { String(format: "%02X", $0) }.joined()
            let p12 = try Self.makeIdentityContainer(password: password)
            value = try Self.importIdentity(p12, password: password)
            try write("client-identity", data: JSONEncoder().encode(StoredIdentity(pkcs12: p12, password: password)))
        }
        cachedIdentity = value
        return value
    }

    static func makeIdentityContainer(password: String) throws -> Data {
        var bytes: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard password.withCString({ tvp_container_identity($0, &bytes, &length) }) == 1,
              let bytes, length > 0 else { throw TVContainerFailure("Unable to create the private transfer identity.") }
        defer { tvp_container_identity_free(bytes, length) }
        return Data(bytes: bytes, count: length)
    }

    static func importIdentity(_ data: Data, password: String) throws -> TVContainerClientIdentity {
        var items: CFArray?
        var options: [String: Any] = [kSecImportExportPassphrase as String: password]
        #if os(macOS)
        if #available(macOS 15.0, *) { options[kSecImportToMemoryOnly as String] = true }
        #endif
        let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
        guard status == errSecSuccess, let first = (items as? [[String: Any]])?.first,
              let item = first[kSecImportItemIdentity as String], CFGetTypeID(item as CFTypeRef) == SecIdentityGetTypeID() else {
            throw TVContainerFailure("Unable to open the saved transfer identity (\(status)). It has not been replaced.")
        }
        let identity = item as! SecIdentity
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { throw TVPairError.storage }
        return TVContainerClientIdentity(identity: identity, fingerprint: fingerprint(certificate))
    }

    public static func fingerprint(_ certificate: SecCertificate) -> String {
        SHA256.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
    }

    public static func displayFingerprint(_ value: String) -> String {
        stride(from: 0, to: value.count, by: 8).map { offset in
            let start = value.index(value.startIndex, offsetBy: offset)
            let end = value.index(start, offsetBy: min(8, value.count - offset))
            return String(value[start..<end])
        }.joined(separator: " ")
    }

    static func locallyValidatedPeer(_ trust: SecTrust) -> String? {
        guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateBasicX509()) == errSecSuccess,
              let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return nil }
        return fingerprint(leaf)
    }

    public func pins() throws -> [Pin] {
        guard let data = try read("approved-tvs") else { return [] }
        return try JSONDecoder().decode([Pin].self, from: data)
    }
    public func trust(for fingerprint: String, aliases: Set<String>) throws -> Trust {
        let saved = try pins()
        if saved.contains(where: { $0.fingerprint == fingerprint }) { return .approved }
        if saved.contains(where: { !$0.aliases.isDisjoint(with: aliases) }) { return .changed }
        return .unknown
    }
    public func approve(_ fingerprint: String, aliases: Set<String>, name: String) throws {
        var saved = try pins()
        if let index = saved.firstIndex(where: { $0.fingerprint == fingerprint }) {
            saved[index].aliases.formUnion(aliases); saved[index].name = name
        } else {
            guard saved.count < 64 else { throw TVContainerFailure("Forget an unused TVContainer pairing before adding another TV.") }
            saved.append(Pin(fingerprint: fingerprint, aliases: aliases, name: name))
        }
        try write("approved-tvs", data: JSONEncoder().encode(saved))
    }
    public func forget(_ fingerprint: String) throws {
        try write("approved-tvs", data: JSONEncoder().encode(try pins().filter { $0.fingerprint != fingerprint }))
    }
}
