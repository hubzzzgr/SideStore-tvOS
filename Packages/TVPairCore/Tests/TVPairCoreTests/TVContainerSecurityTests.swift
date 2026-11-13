import Foundation
import XCTest
import Network
import Security
@testable import TVPairCore

final class TVContainerSecurityTests: XCTestCase {
    private func identity() throws -> TVContainerClientIdentity {
        let password = UUID().uuidString
        return try TVContainerIdentityStore.importIdentity(
            TVContainerIdentityStore.makeIdentityContainer(password: password), password: password)
    }
    private func deleteStore(_ service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
    }

    func testAppleImportsGeneratedIdentityAndRejectsWrongWrappingPassword() throws {
        let password = UUID().uuidString
        let data = try TVContainerIdentityStore.makeIdentityContainer(password: password)
        let imported = try TVContainerIdentityStore.importIdentity(data, password: password)
        XCTAssertEqual(imported.fingerprint.count, 64)
        XCTAssertTrue(imported.fingerprint.allSatisfy { "0123456789ABCDEF".contains($0) })
        XCTAssertThrowsError(try TVContainerIdentityStore.importIdentity(data, password: "incorrect"))
        var key: SecKey?
        XCTAssertEqual(SecIdentityCopyPrivateKey(imported.identity, &key), errSecSuccess)
        let attributes = try XCTUnwrap(SecKeyCopyAttributes(try XCTUnwrap(key)) as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrKeySizeInBits as String] as? Int, 2048)
        XCTAssertEqual(attributes[kSecAttrKeyType as String] as? String, kSecAttrKeyTypeRSA as String)
    }

    func testIdentityAndPinsSurviveNewStoreInstanceWithoutRotation() async throws {
        let service = "TVContainerTests.\(UUID().uuidString)"
        defer { deleteStore(service) }
        let store = TVContainerIdentityStore(service: service)
        let original = try await store.identity()
        try await store.approve(original.fingerprint, aliases: ["old-service"], name: "TV")
        let reopened = TVContainerIdentityStore(service: service)
        let restored = try await reopened.identity()
        XCTAssertEqual(restored.fingerprint, original.fingerprint)
        let renamedTrust = try await reopened.trust(for: original.fingerprint, aliases: ["renamed-service"])
        if case .approved = renamedTrust {} else { XCTFail("Renaming must not change cryptographic trust") }
        let changedTrust = try await reopened.trust(for: String(repeating: "A", count: 64), aliases: ["old-service"])
        if case .changed = changedTrust {} else { XCTFail("A new certificate must not inherit a service's trust") }
        try await reopened.forget(original.fingerprint)
        let afterForget = try await reopened.trust(for: original.fingerprint, aliases: ["old-service"])
        if case .unknown = afterForget {} else { XCTFail("Forget must remove trust") }
        let afterForgetIdentity = try await reopened.identity()
        XCTAssertEqual(afterForgetIdentity.fingerprint, original.fingerprint)
    }

    func testRealMutualTLSStreamsPayloadReadsFragmentedResultAndReconnectsByPin() async throws {
        let phone = try identity(), tv = try identity()
        let service = "TVContainerTests.\(UUID().uuidString)"
        defer { deleteStore(service) }
        let store = TVContainerIdentityStore(service: service)
        let server = try ContainerTLSFixture(identity: tv, acceptedPhone: phone.fingerprint)
        defer { server.cancel() }
        let port = try await server.start()
        let calls = ContainerApprovalRecorder()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 42, count: 180_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for alias in ["original-service", "renamed-service"] {
            let transport = try TVContainerTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
                aliases: [alias], name: "Test TV", identity: phone, store: store) { candidate, client in
                    await calls.record(candidate: candidate, phone: client)
                    return candidate == tv.fingerprint && client == phone.fingerprint
                }
            try await transport.connect(timeout: 10)
            let response = try await TVContainerWire.upload(file: file, filename: "Épisode.ipa", action: .uploadIPA, over: transport, responseTimeout: 10)
            XCTAssertEqual(response, TVContainerWire.Response(ok: true, message: "App installed in TVContainer."))
        }
        let approvals = await calls.count
        XCTAssertEqual(approvals, 1, "A known leaf pin must reconnect without another phone prompt")
        XCTAssertEqual(server.completedPayloads, [180_000, 180_000])
    }

    func testDecliningPhoneFingerprintPreventsPairingAndPinPersistence() async throws {
        let phone = try identity(), tv = try identity()
        let service = "TVContainerTests.\(UUID().uuidString)"
        defer { deleteStore(service) }
        let store = TVContainerIdentityStore(service: service)
        let server = try ContainerTLSFixture(identity: tv, acceptedPhone: phone.fingerprint)
        defer { server.cancel() }
        let port = try await server.start()
        let transport = try TVContainerTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
            aliases: ["test-service"], name: "TV", identity: phone, store: store) { _, _ in false }
        do { try await transport.connect(timeout: 5); XCTFail("Rejected fingerprint connected") } catch {}
        let pins = try await store.pins()
        XCTAssertTrue(pins.isEmpty)
        XCTAssertTrue(server.completedPayloads.isEmpty)
    }

    func testChangedPinNeverPromptsOrConnectsUntilExplicitForget() async throws {
        let phone = try identity(), tv = try identity()
        let service = "TVContainerTests.\(UUID().uuidString)"
        defer { deleteStore(service) }
        let store = TVContainerIdentityStore(service: service)
        try await store.approve(String(repeating: "B", count: 64), aliases: ["test-service"], name: "TV")
        let server = try ContainerTLSFixture(identity: tv, acceptedPhone: phone.fingerprint)
        defer { server.cancel() }
        let port = try await server.start()
        let calls = ContainerApprovalRecorder()
        let transport = try TVContainerTransport(endpoint: .hostPort(host: "127.0.0.1", port: port),
            aliases: ["test-service"], name: "TV", identity: phone, store: store) { candidate, client in
                await calls.record(candidate: candidate, phone: client); return true
            }
        do { try await transport.connect(timeout: 5); XCTFail("Changed certificate connected") } catch {}
        let count = await calls.count
        XCTAssertEqual(count, 0)
        XCTAssertTrue(server.completedPayloads.isEmpty)
    }
}

private actor ContainerApprovalRecorder {
    var count = 0
    func record(candidate: String, phone: String) { count += 1 }
}

/// Disposable loopback peer: real TLS requires the exact client leaf fingerprint.
/// This validates the sender's transport, not TVContainer's native install UI.
private final class ContainerTLSFixture: @unchecked Sendable {
    private let listener: NWListener
    private let lock = NSLock()
    private var connections: [TCPTransport] = []
    private var payloads: [Int] = []
    var completedPayloads: [Int] { lock.withLock { payloads } }
    init(identity: TVContainerClientIdentity, acceptedPhone: String) throws {
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv13)
        sec_protocol_options_set_local_identity(tls.securityProtocolOptions, try XCTUnwrap(sec_identity_create(identity.identity)))
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, complete in
            complete(TVContainerIdentityStore.locallyValidatedPeer(sec_trust_copy_ref(trust).takeRetainedValue()) == acceptedPhone)
        }, DispatchQueue(label: "TVContainerTests.verify"))
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let stream = TCPTransport(acceptedConnection: connection)
            self.lock.withLock { self.connections.append(stream) }
            Task {
                defer { stream.cancel() }
                do {
                    try await stream.connect(timeout: 10)
                    let prefix = try await stream.readExactly(4, timeout: 10)
                    let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                    guard (1...16_384).contains(length) else { throw TVPairError.malformed("test header") }
                    let header = try await stream.readExactly(length, timeout: 10)
                    let json = try JSONSerialization.jsonObject(with: header) as? [String: Any]
                    guard let size = json?["size"] as? Int, size > 0 else { throw TVPairError.malformed("test size") }
                    var count = 0
                    while count < size { count += try await stream.readExactly(min(4096, size - count), timeout: 10).count }
                    self.lock.withLock { self.payloads.append(count) }
                    let frame = try TVContainerWire.frame(TVContainerWire.Response(ok: true, message: "App installed in TVContainer."))
                    for range in [0..<1, 1..<3, 3..<6, 6..<frame.count] {
                        try await stream.send(frame.subdata(in: range), timeout: 5)
                    }
                } catch { /* Expected for rejection/cancellation tests; no credentials are logged. */ }
            }
        }
    }
    func start() async throws -> NWEndpoint.Port {
        let gate = OperationGate<NWEndpoint.Port>()
        return try await withCheckedThrowingContinuation { continuation in
            gate.install(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port { gate.finish(.success(port)) }
                    else { gate.finish(.failure(TVPairError.closed)) }
                case let .failed(error): gate.finish(.failure(error))
                case .cancelled: gate.finish(.failure(CancellationError()))
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "TVContainerTests.listener"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) { gate.finish(.failure(TVPairError.timeout)) }
        }
    }
    func cancel() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }
}
