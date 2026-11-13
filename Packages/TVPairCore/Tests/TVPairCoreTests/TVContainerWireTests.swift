import Foundation
import XCTest
@testable import TVPairCore

final class TVContainerWireTests: XCTestCase {
    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try data.write(to: url)
        return url
    }

    func testStreamsExactPayloadWithOriginalFilenameAndBigEndianHeader() async throws {
        let payload = Data((0..<150_000).map { UInt8($0 % 251) })
        let file = try temporaryFile(payload)
        defer { try? FileManager.default.removeItem(at: file) }
        let reply = TVContainerWire.Response(ok: true, message: "Installed")
        let wire = ContainerTestWire(try TVContainerWire.frame(reply))
        let progress = ContainerProgress()
        let result = try await TVContainerWire.upload(file: file, filename: "An app.ipa", action: .uploadIPA, over: wire, progress: {
            await progress.record($0, $1)
        })
        XCTAssertEqual(result, reply)
        let bytes = wire.sent
        let headerSize = bytes.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        let header = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes.subdata(in: 4..<(headerSize + 4))) as? [String: Any])
        XCTAssertEqual(header["version"] as? Int, 1)
        XCTAssertEqual(header["action"] as? String, "uploadIPA")
        XCTAssertEqual(header["filename"] as? String, "An app.ipa")
        XCTAssertEqual(header["size"] as? Int, payload.count)
        XCTAssertEqual(Set(header.keys), ["version", "action", "filename", "size"])
        XCTAssertEqual(Data(bytes.dropFirst(4 + headerSize)), payload)
        XCTAssertLessThanOrEqual(wire.largestSend, TVContainerWire.chunkSize)
        let events = await progress.events
        XCTAssertEqual(events.map(\.0), [0, 65_536, 131_072, 150_000])
        XCTAssertTrue(events.allSatisfy { $0.1 == UInt64(payload.count) })
        XCTAssertEqual(wire.remaining, 0)
    }

    func testRejectedInstallationRemainsAnExplicitFailureResponse() async throws {
        let file = try temporaryFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: file) }
        let reply = TVContainerWire.Response(ok: false, message: "Signature rejected")
        let wire = ContainerTestWire(try TVContainerWire.frame(reply))
        let result = try await TVContainerWire.upload(file: file, filename: "cert.p12", action: .uploadP12, over: wire)
        XCTAssertEqual(result, reply)
    }

    func testOversizedAndEmptyFramesAreRejectedBeforeReadingBody() async throws {
        for prefix in [Data([0, 0, 64, 1]), Data([0, 0, 0, 0]), Data([255, 255, 255, 255])] {
            let wire = ContainerTestWire(prefix + Data([123]))
            do {
                _ = try await TVContainerWire.receiveResponse(from: wire)
                XCTFail("Unsafe frame accepted")
            } catch { XCTAssertEqual(error as? TVContainerWire.WireError, .invalidFrame) }
            XCTAssertEqual(wire.remaining, 1)
        }
    }

    func testMalformedResponseDoesNotBecomeSuccess() async throws {
        for body in ["{}", "{\"ok\":\"true\",\"message\":\"Installed\"}", "not JSON"] {
            let data = Data(body.utf8)
            let wire = ContainerTestWire(Data([0, 0, 0, UInt8(data.count)]) + data)
            do {
                _ = try await TVContainerWire.receiveResponse(from: wire)
                XCTFail("Malformed response accepted")
            } catch { XCTAssertEqual(error as? TVContainerWire.WireError, .invalidFrame) }
        }
    }

    func testUnsafeFilenameSendsNothingAndClosesStream() async throws {
        let file = try temporaryFile(Data([1]))
        defer { try? FileManager.default.removeItem(at: file) }
        for name in ["../app.ipa", "folder\\cert.p12", "bad\nname.ipa", "", ".", ".."] {
            let wire = ContainerTestWire(Data())
            do {
                _ = try await TVContainerWire.upload(file: file, filename: name, action: .uploadIPA, over: wire)
                XCTFail("Unsafe name accepted")
            } catch { XCTAssertEqual(error as? TVContainerWire.WireError, .invalidFilename) }
            XCTAssertTrue(wire.sent.isEmpty)
            XCTAssertTrue(wire.cancelled)
        }
    }

    func testTransportFailureAbortsWithoutReadingSuccessOrAdvancingProgress() async throws {
        let file = try temporaryFile(Data(repeating: 7, count: 100))
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = ContainerTestWire(try TVContainerWire.frame(TVContainerWire.Response(ok: true, message: "Installed")), failSend: 2)
        let progress = ContainerProgress()
        do {
            _ = try await TVContainerWire.upload(file: file, action: .uploadIPA, over: wire, progress: { await progress.record($0, $1) })
            XCTFail("Failed upload accepted")
        } catch { XCTAssertEqual(error as? TVPairError, .closed) }
        XCTAssertTrue(wire.cancelled)
        let events = await progress.events
        XCTAssertEqual(events.map(\.0), [0])
    }

    func testExpiredDeadlineSendsNothing() async throws {
        let file = try temporaryFile(Data([1]))
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = ContainerTestWire(Data())
        do {
            _ = try await TVContainerWire.upload(file: file, action: .uploadIPA, over: wire, timeout: -1)
            XCTFail("Expired transfer accepted")
        } catch { XCTAssertEqual(error as? TVPairError, .timeout) }
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(wire.cancelled)
    }

    func testCancelledTaskSendsNothing() async throws {
        let file = try temporaryFile(Data([1]))
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = ContainerTestWire(Data())
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await TVContainerWire.upload(file: file, action: .uploadP12, over: wire)
        }
        do {
            _ = try await task.value
            XCTFail("Cancelled transfer accepted")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(wire.sent.isEmpty)
        XCTAssertTrue(wire.cancelled)
    }

    func testGrowingFileDoesNotSendMoreThanAdvertisedSize() async throws {
        let file = try temporaryFile(Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = ContainerTestWire(try TVContainerWire.frame(TVContainerWire.Response(ok: true, message: "Installed")))
        do {
            _ = try await TVContainerWire.upload(file: file, action: .uploadIPA, over: wire, progress: { completed, _ in
                if completed == 0 {
                    let handle = try? FileHandle(forWritingTo: file)
                    _ = try? handle?.seekToEnd()
                    try? handle?.write(contentsOf: Data([4]))
                    try? handle?.close()
                }
            })
            XCTFail("Growing file accepted")
        } catch { XCTAssertEqual(error as? TVContainerWire.WireError, .fileChanged) }
        XCTAssertTrue(wire.cancelled)
        let sent = wire.sent
        let headerSize = sent.prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        XCTAssertEqual(Data(sent.dropFirst(4 + headerSize)), Data([1, 2, 3]))
    }

    func testTruncatedFileClosesStreamBeforeReadingResponse() async throws {
        let file = try temporaryFile(Data(repeating: 9, count: 100))
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = ContainerTestWire(try TVContainerWire.frame(TVContainerWire.Response(ok: true, message: "Installed")))
        do {
            _ = try await TVContainerWire.upload(file: file, action: .uploadIPA, over: wire, progress: { completed, _ in
                if completed == 0 {
                    let handle = try? FileHandle(forWritingTo: file)
                    try? handle?.truncate(atOffset: 0)
                    try? handle?.close()
                }
            })
            XCTFail("Changed file accepted")
        } catch { XCTAssertEqual(error as? TVContainerWire.WireError, .fileChanged) }
        XCTAssertTrue(wire.cancelled)
    }

    func testStrictSizeAndUTF8FilenameLimitsBeforeSending() throws {
        let file = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertThrowsError(try TVContainerWire.validate(file: file, action: .uploadIPA))
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 4_194_305)
        XCTAssertThrowsError(try TVContainerWire.validate(file: file, action: .uploadP12))
        XCTAssertEqual(try TVContainerWire.validate(file: file, action: .uploadIPA), 4_194_305)
        XCTAssertThrowsError(try TVContainerWire.validate(file: file, filename: String(repeating: "é", count: 101), action: .uploadIPA))
        XCTAssertNoThrow(try TVContainerWire.validate(file: file, filename: String(repeating: "é", count: 98) + ".ipa", action: .uploadIPA))
        try handle.truncate(atOffset: 2_147_483_649)
        XCTAssertThrowsError(try TVContainerWire.validate(file: file, action: .uploadIPA))
    }

    func testEarlyLocalizedFailureSurvivesConcurrentWriterError() async throws {
        let file = try temporaryFile(Data(repeating: 5, count: 5_000_000))
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = TVContainerWire.Response(ok: false, message: "Un certificat est déjà installé.")
        let wire = EarlyContainerRejection(try TVContainerWire.frame(expected))
        let response = try await TVContainerWire.upload(file: file, action: .uploadIPA, over: wire)
        XCTAssertEqual(response, expected)
        XCTAssertTrue(wire.cancelled)
    }

    func testEOFInResponseCannotBecomeSuccess() async throws {
        for input in [Data([0, 0]), Data([0, 0, 0, 40]) + Data("{\"ok\":true".utf8)] {
            let wire = ContainerTestWire(input)
            do {
                _ = try await TVContainerWire.receiveResponse(from: wire)
                XCTFail("Truncated response accepted")
            } catch { XCTAssertEqual(error as? TVPairError, .closed) }
        }
    }
}

private final class EarlyContainerRejection: ByteTransport, @unchecked Sendable {
    private let headerArrived = OperationGate<Void>()
    private let lock = NSLock()
    private var response: Data
    private var sends = 0
    private var stopped = false
    init(_ response: Data) { self.response = response }
    var cancelled: Bool { lock.withLock { stopped } }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ data: Data, timeout: TimeInterval) async throws {
        let count = lock.withLock { sends += 1; return sends }
        if count == 1 { headerArrived.finish(.success(())) }
        else { throw TVPairError.closed }
    }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { headerArrived.install($0) }
        return try lock.withLock {
            guard response.count >= count else { throw TVPairError.closed }
            let data = Data(response.prefix(count)); response.removeFirst(count); return data
        }
    }
    func cancel() { lock.withLock { stopped = true }; headerArrived.finish(.failure(CancellationError())) }
}

private actor ContainerProgress {
    var events: [(UInt64, UInt64)] = []
    func record(_ completed: UInt64, _ total: UInt64) { events.append((completed, total)) }
}

private final class ContainerTestWire: ByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var input: Data
    private var output = Data()
    private var sendCount = 0
    private var maximumSend = 0
    private var didCancel = false
    private let failSend: Int?

    init(_ input: Data, failSend: Int? = nil) { self.input = input; self.failSend = failSend }
    var sent: Data { lock.withLock { output } }
    var largestSend: Int { lock.withLock { maximumSend } }
    var remaining: Int { lock.withLock { input.count } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ data: Data, timeout: TimeInterval) async throws {
        try lock.withLock {
            sendCount += 1
            if failSend == sendCount { throw TVPairError.closed }
            maximumSend = max(maximumSend, data.count)
            output.append(data)
        }
    }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        try lock.withLock {
            guard count <= input.count else { throw TVPairError.closed }
            let value = Data(input.prefix(count)); input.removeFirst(count); return value
        }
    }
    func cancel() { lock.withLock { didCancel = true } }
}
