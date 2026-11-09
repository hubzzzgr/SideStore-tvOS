import XCTest
@testable import TVPairCore

final class TunnelTests: XCTestCase {
    func testBulkUploadDoesNotWaitForAnAckAfterEachSegment() async throws {
        let carrier = BulkTunnelPeer()
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let stream = try TunnelTCPTransport(tunnel: tunnel)
        try await stream.connect(timeout: 1)
        let data = Data(repeating: 0x5a, count: 65_535)
        try await stream.send(data, timeout: 1)
        let received = await carrier.received
        XCTAssertEqual(received, data, "A peer delaying ACKs until two segments must accept the full upload")
        let bursts = await carrier.bursts
        XCTAssertTrue(bursts.contains(where: { $0 > 1024 }))
    }
    func testBulkUploadRespectsSmallWindowAndIgnoresStaleAcks() async throws {
        let carrier = BulkTunnelPeer(window: 2048, staleAcks: true)
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let stream = try TunnelTCPTransport(tunnel: tunnel)
        try await stream.connect(timeout: 1)
        try await stream.send(Data(repeating: 1, count: 7_000), timeout: 1)
        try await stream.send(Data(repeating: 2, count: 3_000), timeout: 1)
        let received = await carrier.received
        XCTAssertEqual(received, Data(repeating: 1, count: 7_000) + Data(repeating: 2, count: 3_000))
        let bursts = await carrier.bursts
        XCTAssertTrue(bursts.allSatisfy { $0 <= 2048 })
    }
    func testMissingBulkAcknowledgementFailsInsteadOfReportingSuccess() async throws {
        let carrier = BulkTunnelPeer(dropAcks: true)
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let stream = try TunnelTCPTransport(tunnel: tunnel)
        try await stream.connect(timeout: 1)
        do { try await stream.send(Data(repeating: 1, count: 32_768), timeout: 0.1); XCTFail("Missing ACK must fail") }
        catch { XCTAssertEqual(error as? TVPairError, .timeout) }
    }
    func testInterleavedRSDDataIsBufferedWhileOpeningDeveloperStream() async throws {
        let carrier = TunnelPeerTransport()
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let rsd = try TunnelTCPTransport(tunnel: tunnel)
        try await rsd.connect(timeout: 1)
        await carrier.interleaveOldPayload()
        let developer = try TunnelTCPTransport(tunnel: tunnel, port: 4321)
        try await developer.connect(timeout: 1)
        let old = try await rsd.readExactly(5, timeout: 1)
        XCTAssertEqual(old, Data("later".utf8), "Opening another port must not discard RSD data")
    }
    func testUserspaceHandshakeDataAcknowledgementsAndRead() async throws {
        let carrier = TunnelPeerTransport()
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        let stream = try TunnelTCPTransport(tunnel: tunnel)
        try await stream.connect(timeout: 1)
        try await stream.send(Data("hello".utf8), timeout: 1)
        let response = try await stream.readExactly(5, timeout: 1)
        XCTAssertEqual(response, Data("world".utf8))
        let payload = await carrier.received()
        XCTAssertEqual(payload, Data("hello".utf8))
    }
    func testUserspaceRejectsCorruptedEncapsulatedPacket() async throws {
        let carrier = TunnelPeerTransport(corrupt: true)
        let tunnel = TrustedTunnel(transport: carrier, configuration: TunnelConfiguration(clientAddress: "fd00::1", serverAddress: "fd00::2", rsdPort: 1234, mtu: 16000))
        do { try await TunnelTCPTransport(tunnel: tunnel).connect(timeout: 1); XCTFail("Invalid packet must fail") }
        catch { XCTAssertEqual(error as? TVPairError, .malformed("TCP length or checksum")) }
    }
}

/// A delayed-ACK receiver: no response for the first data segment. Reads on
/// an empty carrier model its bounded read deadline expiring.
private actor BulkTunnelPeer: ByteTransport {
    let window: UInt16
    let staleAcks: Bool
    let dropAcks: Bool
    var received = Data(), output = Data()
    var bursts: [Int] = []
    private var burst = 0, segments = 0
    private var expected: UInt32 = 0
    init(window: UInt16 = 65535, staleAcks: Bool = false, dropAcks: Bool = false) {
        self.window = window; self.staleAcks = staleAcks; self.dropAcks = dropAcks
    }
    func connect(timeout: TimeInterval) async throws {}
    nonisolated func cancel() {}
    func send(_ data: Data, timeout: TimeInterval) async throws {
        let segment = try IPv6TCPPacket.parse(data)
        func reply(_ acknowledgement: UInt32, flags: UInt8) -> Data {
            var packet = IPv6TCPPacket.make(source: data.subdata(in: 24..<40), destination: data.subdata(in: 8..<24), sourcePort: segment.destinationPort, destinationPort: segment.sourcePort, sequence: flags == 0x12 ? 100 : 101, acknowledgement: acknowledgement, flags: flags, payload: Data())
            packet[54] = UInt8(window >> 8); packet[55] = UInt8(window & 255)
            packet[56] = 0; packet[57] = 0
            let tcp = packet.subdata(in: 40..<packet.count)
            let checksum = IPv6TCPPacket.checksum(packet.subdata(in: 8..<40) + IPv6TCPPacket.be(UInt32(tcp.count)) + Data([0, 0, 0, 6]) + tcp)
            packet[56] = UInt8(checksum >> 8); packet[57] = UInt8(checksum & 255)
            return packet
        }
        if segment.flags & 2 != 0 {
            expected = segment.sequence &+ 1; output += reply(expected, flags: 0x12); return
        }
        guard !segment.payload.isEmpty else { return }
        guard segment.sequence == expected else { throw TVPairError.malformed("test peer sequence") }
        received += segment.payload; expected &+= UInt32(segment.payload.count)
        burst += segment.payload.count; segments += 1
        guard burst <= Int(window) else { throw TVPairError.malformed("sender exceeded advertised window") }
        if !dropAcks, segments % 2 == 0 || segment.flags & 8 != 0 {
            if staleAcks { output += reply(expected &- UInt32(burst) &- 1, flags: 0x10) }
            output += reply(expected, flags: 0x10)
        }
        if segment.flags & 8 != 0 { bursts.append(burst); burst = 0; segments = 0 }
    }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        guard timeout > 0, output.count >= count else { throw TVPairError.timeout }
        let data = Data(output.prefix(count)); output.removeFirst(count); return data
    }
}

private final class TunnelPeerTransport: ByteTransport, @unchecked Sendable {
    let peer: TunnelPeer
    init(corrupt: Bool = false) { peer = TunnelPeer(corrupt: corrupt) }
    func received() async -> Data { await peer.received }
    func interleaveOldPayload() async { await peer.armInterleaving() }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ data: Data, timeout: TimeInterval) async throws { try await peer.respond(data) }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data { try await peer.take(count) }
    func cancel() {}
}
private actor TunnelPeer {
    let corrupt: Bool
    var output = Data(), received = Data()
    var sequence: UInt32 = 101
    var firstSYN: Data?
    var interleave = false
    func armInterleaving() { interleave = true }
    init(corrupt: Bool) { self.corrupt = corrupt }
    func take(_ count: Int) throws -> Data {
        guard output.count >= count else { throw TVPairError.closed }
        let data = Data(output.prefix(count)); output.removeFirst(count); return data
    }
    func respond(_ packet: Data) throws {
        let segment = try IPv6TCPPacket.parse(packet)
        let syn = segment.flags & 2 != 0
        if syn && interleave, let firstSYN {
            let first = try IPv6TCPPacket.parse(firstSYN)
            output += IPv6TCPPacket.make(source: firstSYN.subdata(in: 24..<40), destination: firstSYN.subdata(in: 8..<24), sourcePort: first.destinationPort, destinationPort: first.sourcePort, sequence: 101, acknowledgement: first.sequence &+ 1, flags: 0x18, payload: Data("later".utf8))
            interleave = false
        }
        if syn && firstSYN == nil { firstSYN = packet.zeroBased }
        guard syn || !segment.payload.isEmpty else { return }
        received.append(segment.payload)
        let payload = syn ? Data() : Data("world".utf8)
        var response = IPv6TCPPacket.make(source: packet.subdata(in: 24..<40), destination: packet.subdata(in: 8..<24), sourcePort: segment.destinationPort, destinationPort: segment.sourcePort, sequence: syn ? 100 : sequence, acknowledgement: segment.sequence &+ UInt32(syn ? 1 : segment.payload.count), flags: syn ? 0x12 : 0x18, payload: payload)
        if corrupt { response[56] ^= 1 }
        output.append(response); sequence &+= UInt32(payload.count)
    }
}
