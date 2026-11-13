import Foundation
import Network
import Security

/// Network.framework owns TLS 1.3, client authentication, and record encryption.
/// Only an explicitly approved leaf DER fingerprint can pass verification.
public final class TVContainerTransport: ByteTransport, @unchecked Sendable {
    private final class Verification: @unchecked Sendable {
        private let lock = NSLock()
        private var pin: String?
        private var reason: String?
        private var stopped = false
        var fingerprint: String? { lock.withLock { pin } }
        var failure: String? { lock.withLock { reason } }
        func accept(_ fingerprint: String) -> Bool {
            lock.withLock { guard !stopped else { return false }; pin = fingerprint; return true }
        }
        func reject(_ message: String) { lock.withLock { reason = message } }
        func cancel() { lock.withLock { stopped = true } }
    }

    private let stream: TCPTransport
    private let verification: Verification
    private let store: TVContainerIdentityStore
    private let aliases: Set<String>
    private let name: String
    public var peerFingerprint: String? { verification.fingerprint }

    public init(
        endpoint: NWEndpoint,
        aliases: Set<String>,
        name: String,
        identity: TVContainerClientIdentity,
        store: TVContainerIdentityStore = .shared,
        approve: @escaping @Sendable (_ tvFingerprint: String, _ phoneFingerprint: String) async -> Bool
    ) throws {
        guard let local = sec_identity_create(identity.identity) else { throw TVContainerFailure("The transfer identity cannot be used for TLS.") }
        let verification = Verification()
        self.verification = verification; self.store = store; self.aliases = aliases; self.name = name
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_set_local_identity(options, local)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_verify_block(options, { _, trust, complete in
            let value = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let candidate = TVContainerIdentityStore.locallyValidatedPeer(value) else {
                verification.reject("TVContainer's TLS certificate failed local validation.")
                complete(false); return
            }
            Task {
                do {
                    let state = try await store.trust(for: candidate, aliases: aliases)
                    let permitted: Bool
                    switch state {
                    case .approved: permitted = true
                    case .unknown: permitted = await approve(candidate, identity.fingerprint)
                    case .changed:
                        verification.reject("This TVContainer's certificate changed. Check its fingerprint on Apple TV, then use Forget TV / Pair again before reconnecting.")
                        permitted = false
                    }
                    if !permitted, verification.failure == nil { verification.reject("TVContainer pairing was not approved on iPhone.") }
                    complete(permitted && verification.accept(candidate))
                } catch {
                    verification.reject("Unable to read TVContainer trust from Keychain. Unlock the iPhone and retry.")
                    complete(false)
                }
            }
        }, DispatchQueue(label: "SideTVstore.TVContainer.verify"))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        stream = TCPTransport(acceptedConnection: NWConnection(to: endpoint, using: parameters))
    }

    public func connect(timeout: TimeInterval = 90) async throws {
        do {
            try await stream.connect(timeout: timeout)
            try Task.checkCancellation()
            guard let fingerprint = verification.fingerprint else { throw TVPairError.authentication }
            // .ready also requires the TV's approval of the client's identity.
            try await store.approve(fingerprint, aliases: aliases, name: name)
        } catch {
            cancel()
            if let failure = verification.failure { throw TVContainerFailure(failure) }
            throw error
        }
    }
    public func send(_ data: Data, timeout: TimeInterval) async throws { try await stream.send(data, timeout: timeout) }
    public func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await stream.readExactly(count, timeout: timeout) }
    public func cancel() { verification.cancel(); stream.cancel() }
    deinit { cancel() }
}
