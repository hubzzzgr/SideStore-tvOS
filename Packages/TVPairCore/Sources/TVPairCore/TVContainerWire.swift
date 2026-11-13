import Foundation

/// The upload framing shared with TVContainer protocol 1.
/// This layer does not establish trust: callers must supply an encrypted transport
/// authenticated by the receiver's Apple TV pairing approval before uploading.
public enum TVContainerWire {
    public enum Action: String, Codable, Sendable {
        case uploadIPA
        case uploadP12
    }

    public struct Response: Codable, Equatable, Sendable {
        public let ok: Bool
        public let message: String

        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    public enum WireError: LocalizedError, Equatable {
        case invalidFile
        case invalidFilename
        case invalidFrame
        case fileChanged
        case invalidSize

        public var errorDescription: String? {
            switch self {
            case .invalidFile: return "Select a regular file to send to TVContainer."
            case .invalidFilename: return "The file name cannot be sent to TVContainer. Rename the file and try again."
            case .invalidFrame: return "TVContainer sent an invalid protocol response."
            case .fileChanged: return "The selected file changed during transfer. Select it again and retry."
            case .invalidSize: return "Select a nonempty IPA up to 2 GiB or a P12 up to 4 MiB."
            }
        }
    }

    private struct UploadHeader: Encodable {
        let version = 1
        let action: Action
        let filename: String
        let size: UInt64
    }

    static let maximumHeaderSize = 16_384
    static let chunkSize = 65_536

    static func frame<T: Encodable>(_ header: T) throws -> Data {
        let data = try JSONEncoder().encode(header)
        guard !data.isEmpty, data.count <= maximumHeaderSize else { throw WireError.invalidFrame }
        let length = UInt32(data.count)
        return Data([
            UInt8((length >> 24) & 255), UInt8((length >> 16) & 255),
            UInt8((length >> 8) & 255), UInt8(length & 255)
        ]) + data
    }

    public static func receiveResponse(from transport: any ByteTransport, timeout: TimeInterval = 3600) async throws -> Response {
        let deadline = Date().addingTimeInterval(timeout)
        let prefix = Array(try await transport.readExactly(4, timeout: timeout))
        guard prefix.count == 4 else { throw WireError.invalidFrame }
        let length = prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumHeaderSize) else { throw WireError.invalidFrame }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw TVPairError.timeout }
        let body = try await transport.readExactly(Int(length), timeout: remaining)
        guard let response = try? JSONDecoder().decode(Response.self, from: body) else { throw WireError.invalidFrame }
        return response
    }

    /// Validate the stable staged file before opening a connection.
    @discardableResult
    public static func validate(file: URL, filename: String? = nil, action: Action) throws -> UInt64 {
        let name = filename ?? file.lastPathComponent
        guard !name.isEmpty, name != ".", name != "..", name.utf8.count <= 200,
              !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw WireError.invalidFilename
        }
        var fresh = file
        fresh.removeAllCachedResourceValues()
        let values = try fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw WireError.invalidFile }
        let maximum: UInt64 = action == .uploadIPA ? 2_147_483_648 : 4_194_304
        guard let length = values.fileSize, length > 0, UInt64(length) <= maximum else { throw WireError.invalidSize }
        return UInt64(length)
    }

    private enum Event: Sendable {
        case response(Result<Response, Error>)
        case writer(Result<Void, Error>)
        case writerGraceExpired
    }

    /// One upload per authenticated TLS connection. Read concurrently because the
    /// receiver can reject the request without consuming its binary payload.
    public static func upload(
        file: URL,
        filename: String? = nil,
        action: Action,
        over transport: any ByteTransport,
        timeout: TimeInterval = 1800,
        responseTimeout: TimeInterval = 3600,
        progress: @escaping @Sendable (UInt64, UInt64) async -> Void = { _, _ in },
        waiting: @escaping @Sendable () async -> Void = {}
    ) async throws -> Response {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let name = filename ?? file.lastPathComponent
                let size = try validate(file: file, filename: name, action: action)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                guard try handle.seekToEnd() == size else { throw WireError.fileChanged }
                try handle.seek(toOffset: 0)
                let deadline = Date().addingTimeInterval(timeout)
                func send(_ data: Data) async throws {
                    try Task.checkCancellation()
                    let remaining = deadline.timeIntervalSinceNow
                    guard remaining > 0 else { throw TVPairError.timeout }
                    try await transport.send(data, timeout: min(30, remaining))
                }
                defer { transport.cancel() }
                return try await withThrowingTaskGroup(of: Event.self) { group in
                    group.addTask {
                        do { return .response(.success(try await receiveResponse(from: transport, timeout: responseTimeout))) }
                        catch { return .response(.failure(error)) }
                    }
                    group.addTask {
                        do {
                            try await send(frame(UploadHeader(action: action, filename: name, size: size)))
                            var sent: UInt64 = 0
                            await progress(sent, size)
                            while sent < size {
                                try Task.checkCancellation()
                                let count = Int(min(UInt64(chunkSize), size - sent))
                                guard let data = try handle.read(upToCount: count), !data.isEmpty else { throw WireError.fileChanged }
                                try await send(data)
                                sent += UInt64(data.count)
                                await progress(sent, size)
                            }
                            guard (try handle.read(upToCount: 1))?.isEmpty != false else { throw WireError.fileChanged }
                            try Task.checkCancellation()
                            await waiting()
                            return .writer(.success(()))
                        } catch { return .writer(.failure(error)) }
                    }
                    defer { group.cancelAll(); transport.cancel() }
                    var writerFinished = false
                    var response: Response?
                    var writerError: Error?
                    while let event = try await group.next() {
                        switch event {
                        case let .response(.success(value)):
                            // A complete TV failure wins over a secondary write error.
                            if !value.ok { return value }
                            response = value
                        case let .response(.failure(error)):
                            throw writerError ?? error
                        case .writer(.success): writerFinished = true
                        case let .writer(.failure(error)):
                            writerError = error
                            if response != nil { throw error }
                            // A peer may reject and close while a send is outstanding.
                            // Give its already-in-flight result a bounded chance to win.
                            group.addTask {
                                try? await Task.sleep(nanoseconds: 2_000_000_000)
                                return .writerGraceExpired
                            }
                        case .writerGraceExpired: throw writerError ?? TVPairError.closed
                        }
                        if writerFinished, let response { return response }
                    }
                    throw TVPairError.closed
                }
            } catch {
                // An interrupted payload leaves the stream out of frame; never reuse it.
                transport.cancel()
                throw error
            }
        } onCancel: {
            transport.cancel()
        }
    }
}
