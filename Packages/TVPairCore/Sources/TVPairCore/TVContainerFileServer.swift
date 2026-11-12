#if canImport(Network) && canImport(Darwin)
import Foundation
@preconcurrency import Network
import Darwin

public enum TVContainerServerError: LocalizedError {
    case noLAN, stopped, unavailable
    case listener(String)
    case timeout(String?)
    public var errorDescription: String? {
        switch self {
        case .noLAN: return "Connect the iPhone to Wi-Fi or a local Ethernet network first."
        case .stopped: return "The temporary server was stopped."
        case .unavailable: return "The local server could not start. Check Local Network access and try again."
        case .listener(let detail): return "The TCP server could not start. \(detail)"
        case .timeout(let detail): return "The TCP server did not become ready within 15 seconds.\(detail.map { " " + $0 } ?? "")"
        }
    }
}

private struct LANBinding: Sendable {
    let address: IPv4Address
    let mask: Data
    static func current() -> LANBinding? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        for item in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let record = item.pointee
            guard let addr = record.ifa_addr, let netmask = record.ifa_netmask,
                  addr.pointee.sa_family == UInt8(AF_INET),
                  String(cString: record.ifa_name).hasPrefix("en"),
                  record.ifa_flags & UInt32(IFF_UP | IFF_RUNNING | IFF_LOOPBACK) == UInt32(IFF_UP | IFF_RUNNING) else { continue }
            let ip = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let mask = UnsafeRawPointer(netmask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            var ipBytes = ip, maskBytes = mask
            let bytes = withUnsafeBytes(of: &ipBytes) { Data($0) }
            let subnet = withUnsafeBytes(of: &maskBytes) { Data($0) }
            guard let address = IPv4Address(bytes), address.rawValue.first != 127,
                  address.rawValue != Data(repeating: 0, count: 4), subnet.contains(where: { $0 != 0 }) else { continue }
            return LANBinding(address: address, mask: subnet)
        }
        return nil
    }
    func accepts(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint, case let .ipv4(peer) = host else { return false }
        return zip(zip(address.rawValue, peer.rawValue), mask).allSatisfy { pair, mask in
            pair.0 & mask == pair.1 & mask
        }
    }
}

/// Wi-Fi/Ethernet IPv4 only. No cellular listener, port mapping, background task or keep-alive.
public actor TVContainerFileServer {
    private let queue = DispatchQueue(label: "SideTVstore.TVContainerServer")
    private var listener: NWListener?
    private var binding: LANBinding?
    private var generation = UUID()
    private var pendingStart: CheckedContinuation<UInt16, Error>?
    private var peers: [UUID: NWConnection] = [:]
    private var files: [UUID: (TVContainerFile, URL)] = [:]
    private var failure: (@Sendable (String) -> Void)?
    private var waitingReason: String?

    public init() {}
    public func setFiles(_ values: [(TVContainerFile, URL)]) {
        // Removing a file also ends outstanding downloads; an open descriptor must not keep serving it.
        let removed = Set(files.keys).subtracting(values.map { $0.0.id })
        if !removed.isEmpty { for peer in peers.values { peer.cancel() }; peers.removeAll() }
        files = Dictionary(uniqueKeysWithValues: values.map { ($0.0.id, $0) })
    }
    public func start(onFailure: @escaping @Sendable (String) -> Void) async throws -> String {
        stop()
        guard let lan = LANBinding.current() else { throw TVContainerServerError.noLAN }
        let parameters = NWParameters.tcp
        // Bind to the LAN address and check the peer subnet below. Prohibiting
        // loopback routes here can also reject a hosted app's internal routing.
        parameters.includePeerToPeer = false
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(lan.address), port: .any)
        let service: NWListener
        do { service = try NWListener(using: parameters) }
        catch { throw TVContainerServerError.listener(String(describing: error)) }
        let token = generation
        binding = lan; failure = onFailure; listener = service
        // Bonjour is published separately after the TCP socket is ready. A host
        // missing our service declaration must not take down direct LAN access.
        service.newConnectionHandler = { [weak self] peer in Task { await self?.accept(peer, generation: token) } }
        service.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state, generation: token) } }
        let deadline = Task {
            try await Task.sleep(for: .seconds(15))
            self.startTimedOut(generation: token)
        }
        defer { deadline.cancel() }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            pendingStart = continuation
            service.start(queue: queue)
        }
        return "http://\(lan.address):\(port)"
    }
    public func stop() {
        stop(reason: TVContainerServerError.stopped)
    }
    private func stop(reason: Error) {
        generation = UUID()
        listener?.cancel(); listener = nil; binding = nil
        for peer in peers.values { peer.cancel() }
        peers.removeAll(); failure = nil; waitingReason = nil
        let continuation = pendingStart; pendingStart = nil
        continuation?.resume(throwing: reason)
    }
    private func startTimedOut(generation token: UUID) {
        guard token == generation, pendingStart != nil else { return }
        let report = failure
        let error = TVContainerServerError.timeout(waitingReason)
        stop(reason: error); report?(error.localizedDescription)
    }
    private func changed(_ state: NWListener.State, generation token: UUID) {
        guard token == generation else { return }
        switch state {
        case .ready:
            let continuation = pendingStart; pendingStart = nil
            if let port = listener?.port?.rawValue { continuation?.resume(returning: port) }
            else { continuation?.resume(throwing: TVContainerServerError.unavailable); stop() }
        case .waiting(let error):
            waitingReason = String(describing: error)
        case .failed(let error):
            let report = failure
            let reason = TVContainerServerError.listener(String(describing: error))
            stop(reason: reason); report?(reason.localizedDescription)
        default: break
        }
    }
    private func accept(_ peer: NWConnection, generation token: UUID) {
        guard token == generation, peers.count < 4, let binding,
              LANBinding.current()?.address == binding.address, binding.accepts(peer.endpoint) else { peer.cancel(); return }
        let id = UUID(); peers[id] = peer; peer.start(queue: queue)
        Task { await serve(peer, id: id, generation: token) }
    }
    private func receive(_ peer: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            peer.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, complete, error in
                if let error { continuation.resume(throwing: error) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: TVContainerServerError.stopped) }
            }
        }
    }
    private func send(_ bytes: Data, to peer: NWConnection) async throws {
        let deadline = Task { try await Task.sleep(for: .seconds(30)); peer.cancel() }
        defer { deadline.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.send(content: bytes, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
    private func header(_ code: Int, _ reason: String, length: Int64, type: String, extra: String = "") -> Data {
        Data("HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(length)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n\(extra)\r\n".utf8)
    }
    private func serve(_ peer: NWConnection, id: UUID, generation token: UUID) async {
        defer { peer.cancel(); peers.removeValue(forKey: id) }
        let headerDeadline = Task { try await Task.sleep(for: .seconds(15)); peer.cancel() }
        defer { headerDeadline.cancel() }
        do {
            var bytes = Data()
            while bytes.range(of: Data("\r\n\r\n".utf8)) == nil {
                bytes.append(try await receive(peer))
                guard bytes.count <= TVContainerHTTP.maximumHeaderBytes else { throw TVContainerHTTP.Failure.invalidRequest }
            }
            headerDeadline.cancel()
            let request = try TVContainerHTTP.request(bytes)
            guard token == generation, peers[id] != nil else { return }
            if request.path == "/v1/files" {
                let data = try TVContainerHTTP.catalog(files.values.map { $0.0 }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
                try await send(header(200, "OK", length: Int64(data.count), type: "application/json; charset=utf-8"), to: peer)
                if request.method != "HEAD" { try await send(data, to: peer) }
                return
            }
            let components = request.path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.count == 4, components[1] == "v1", components[2] == "files",
                  let fileID = UUID(uuidString: String(components[3])), let (entry, url) = files[fileID] else {
                try await send(header(404, "Not Found", length: 0, type: "text/plain"), to: peer); return
            }
            let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
            let size = Int64(try file.seekToEnd())
            let range: Range<Int64>
            do { range = try TVContainerHTTP.byteRange(request.range, size: size) }
            catch {
                try await send(header(416, "Range Not Satisfiable", length: 0, type: "text/plain", extra: "Content-Range: bytes */\(size)\r\n"), to: peer); return
            }
            var extra = "Accept-Ranges: bytes\r\nContent-Disposition: attachment\r\n"
            if request.range != nil { extra += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(size)\r\n" }
            let safeType = entry.contentType.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/!#$&^_.+-").contains($0)
            } && !entry.contentType.isEmpty ? entry.contentType : "application/octet-stream"
            try await send(header(request.range == nil ? 200 : 206, request.range == nil ? "OK" : "Partial Content",
                                  length: range.upperBound - range.lowerBound, type: safeType, extra: extra), to: peer)
            if request.method == "HEAD" { return }
            try file.seek(toOffset: UInt64(range.lowerBound))
            var remaining = range.upperBound - range.lowerBound
            while remaining > 0 {
                guard token == generation, peers[id] != nil, files[fileID] != nil else { return }
                guard let data = try file.read(upToCount: Int(min(65_536, remaining))), !data.isEmpty else { return }
                try await send(data, to: peer)
                remaining -= Int64(data.count)
            }
        } catch let error as TVContainerHTTP.Failure {
            let unsupported = { if case .unsupportedMethod = error { return true }; return false }()
            try? await send(header(unsupported ? 405 : 400, unsupported ? "Method Not Allowed" : "Bad Request", length: 0, type: "text/plain", extra: unsupported ? "Allow: GET, HEAD\r\n" : ""), to: peer)
        } catch { /* A stopped connection must not retry or keep the app alive. */ }
    }
}
#endif
