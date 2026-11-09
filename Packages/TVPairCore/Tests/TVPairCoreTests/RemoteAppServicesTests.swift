import XCTest
@testable import TVPairCore

final class RemoteAppServicesTests: XCTestCase {
    private func plist(_ value: [String: Any]) throws -> Data {
        let body = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        var size = UInt32(body.count).bigEndian
        return withUnsafeBytes(of: &size) { Data($0) } + body
    }
    func testConsumesBothRSDCheckinRepliesBeforeTheServiceProtocol() async throws {
        let wire = AppWire(try plist(["Request": "RSDCheckin"]) + plist(["Request": "StartService"]) + plist(["Status": "Complete"]))
        let service = RemotePlistService(stream: wire)
        try await service.open()
        try await service.completion()
        XCTAssertEqual(wire.remaining, 0)
        let bytes = wire.sent
        let request = try PropertyListSerialization.propertyList(from: bytes.dropFirst(4), format: nil) as? [String: Any]
        XCTAssertEqual(request?["Request"] as? String, "RSDCheckin")
    }
    func testRejectsStartServiceError() async throws {
        let wire = AppWire(try plist(["Request": "RSDCheckin"]) + plist(["Request": "StartService", "Error": "ServiceProhibited"]))
        do { try await RemotePlistService(stream: wire).open(); XCTFail("Denied services must stop setup") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ServiceProhibited")) }
    }
    func testProgressIsNotInstallationSuccess() async throws {
        let wire = AppWire(try plist(["Status": "Installing", "PercentComplete": 100]))
        do { try await RemotePlistService(stream: wire).completion(); XCTFail("Missing Complete must fail") }
        catch { XCTAssertEqual(error as? TVPairError, .closed) }
    }
    func testInstallationErrorWinsOverComplete() async throws {
        let wire = AppWire(try plist(["Status": "Complete", "Error": "ApplicationVerificationFailed"]))
        do { try await RemotePlistService(stream: wire).completion(); XCTFail("Device error must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("ApplicationVerificationFailed")) }
    }
    func testUntrustedPlistLengthIsBoundedBeforeReadingPayload() async throws {
        let wire = AppWire(Data([0x7f, 0xff, 0xff, 0xff]))
        do { _ = try await RemotePlistService(stream: wire).receive(); XCTFail("Unbounded payload") }
        catch { XCTAssertTrue(error is TVInstallationError) }
    }
    private func afc(_ sequence: UInt64, _ opcode: UInt64, _ body: Data) -> Data {
        Data("CFA6LPAA".utf8) + RemoteAFC.u64(UInt64(40 + body.count)) + RemoteAFC.u64(UInt64(40 + body.count)) + RemoteAFC.u64(sequence) + RemoteAFC.u64(opcode) + body
    }
    func testAFCRejectsWrongPacketNumber() async throws {
        let wire = AppWire(afc(10, 1, RemoteAFC.u64(0)))
        do { _ = try await RemoteAFC(stream: wire).request(11); XCTFail("Mismatched response") }
        catch { XCTAssertTrue(error is TVInstallationError) }
    }
    func testAFCRejectsDeviceWriteError() async throws {
        let wire = AppWire(afc(0, 1, RemoteAFC.u64(18)))
        do { _ = try await RemoteAFC(stream: wire).request(16); XCTFail("No disk space must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("18")) }
    }
    func testExistingStagingDirectoryRequiresDirectoryMetadata() async throws {
        let wire = AppWire(afc(0, 1, RemoteAFC.u64(16)) + afc(1, 2, Data("st_ifmt\0S_IFDIR\0".utf8)))
        try await RemoteAFC(stream: wire).directory("PublicStaging")
        XCTAssertEqual(wire.remaining, 0)
    }
    func testExistingFileCannotBeUsedAsStagingDirectory() async throws {
        let wire = AppWire(afc(0, 1, RemoteAFC.u64(16)) + afc(1, 2, Data("st_ifmt\0S_IFREG\0".utf8)))
        do { try await RemoteAFC(stream: wire).directory("PublicStaging"); XCTFail("A file is not a directory") }
        catch { XCTAssertTrue(error is TVInstallationError) }
    }
    func testDirectoryPermissionFailureIsNotIgnored() async throws {
        let wire = AppWire(afc(0, 1, RemoteAFC.u64(10)))
        do { try await RemoteAFC(stream: wire).directory("PublicStaging"); XCTFail("Permission denial must stop upload") }
        catch TVInstallationError.afcStatus(10) {} // PERM_DENIED
        catch { XCTFail("Unexpected error: \(error)") }
    }
    func testChunkedIPAUploadUsesFileHandleAndCorrectWriteHeader() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 0xa5, count: 70_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var replies = afc(0, 14, RemoteAFC.u64(7))
        for sequence in 1...4 { replies += afc(UInt64(sequence), 1, RemoteAFC.u64(0)) }
        let wire = AppWire(replies)
        let progress = UploadProgressRecorder()
        try await RemoteAFC(stream: wire).upload(file, path: "PublicStaging/test.ipa") { event in await progress.record(event) }
        let completed = await progress.completed
        XCTAssertEqual(completed, [0, 32_768, 65_536, 70_000], "Count only bytes acknowledged by AFC")
        var bytes = wire.sent
        var writes = 0, totalPayload = 0
        while !bytes.isEmpty {
            let total = Int(RemoteAFC.number(bytes, 8)), header = Int(RemoteAFC.number(bytes, 16)), opcode = RemoteAFC.number(bytes, 32)
            if opcode == 16 {
                XCTAssertEqual(header, 48)
                XCTAssertLessThanOrEqual(total - header, 32_768)
                XCTAssertEqual(RemoteAFC.number(bytes, 40), 7)
                writes += 1; totalPayload += total - header
            }
            bytes.removeFirst(total)
        }
        XCTAssertEqual(writes, 3); XCTAssertEqual(totalPayload, 70_000)
        XCTAssertEqual(wire.remaining, 0)
    }
    func testRejectedWriteStopsProgressAndAbortsWithoutWaitingForCleanup() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = AppWire(afc(0, 14, RemoteAFC.u64(7)) + afc(1, 1, RemoteAFC.u64(18)))
        let progress = UploadProgressRecorder()
        do {
            try await RemoteAFC(stream: wire).upload(file, path: "PublicStaging/test.ipa") { event in await progress.record(event) }
            XCTFail("Rejected bytes cannot become a successful upload")
        } catch TVInstallationError.afcStatus(18) {} catch { XCTFail("Unexpected error: \(error)") }
        let completed = await progress.completed
        XCTAssertEqual(completed, [0])
        XCTAssertTrue(wire.cancelled)
        // No response for FILE_CLOSE is supplied; the original error must return.
        XCTAssertEqual(wire.remaining, 0)
    }
    func testUploadDeadlineExpiresWithoutSendingIPABytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(repeating: 1, count: 100).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let wire = AppWire(afc(0, 14, RemoteAFC.u64(7)))
        do {
            try await RemoteAFC(stream: wire).upload(file, path: "PublicStaging/test.ipa", deadline: .distantPast)
            XCTFail("Expired upload must fail")
        } catch { XCTAssertEqual(error as? TVPairError, .timeout) }
        XCTAssertTrue(wire.cancelled)
    }
    func testUploadFailureKeepsStageAndReasonAcrossNSErrorBridge() {
        let error = TVInstallationError.uploadFailed(stage: "transferring the IPA", detail: "The peer closed the connection.") as NSError
        XCTAssertEqual(error.domain, TVInstallationError.errorDomain)
        XCTAssertTrue(error.localizedDescription.contains("transferring the IPA"))
        XCTAssertTrue(error.localizedDescription.contains("The peer closed"))
        XCTAssertTrue(error.localizedDescription.contains("Installation was not requested"))
    }
}

private actor UploadProgressRecorder {
    var completed: [Int64] = []
    func record(_ event: TVUploadProgress) {
        if case let .uploading(bytes, _) = event { completed.append(bytes) }
    }
}

private final class AppWire: ByteTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var input: Data
    private var output = Data()
    private var didCancel = false
    init(_ input: Data) { self.input = input }
    var sent: Data { lock.withLock { output } }
    var remaining: Int { lock.withLock { input.count } }
    var cancelled: Bool { lock.withLock { didCancel } }
    func connect(timeout: TimeInterval) async throws {}
    func send(_ data: Data, timeout: TimeInterval) async throws { lock.withLock { output.append(data) } }
    func readExactly(_ count: Int, timeout: TimeInterval) async throws -> Data {
        try lock.withLock {
            guard count <= input.count else { throw TVPairError.closed }
            let value = Data(input.prefix(count)); input.removeFirst(count); return value
        }
    }
    func cancel() { lock.withLock { didCancel = true } }
}
