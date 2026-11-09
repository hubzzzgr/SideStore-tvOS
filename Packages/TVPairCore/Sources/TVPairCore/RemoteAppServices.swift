import Foundation

public enum TVInstallationError: Error, LocalizedError, CustomNSError {
    case missingService(String), protocolFailure(String), deviceRejected(String), afcStatus(UInt64), busy
    case uploadFailed(stage: String, detail: String)
    public static var errorDomain: String { "SideTVstore.TVInstallation" }
    public var errorCode: Int { if case .uploadFailed = self { return 2 }; return 1 }
    public var errorUserInfo: [String: Any] { [NSLocalizedDescriptionKey: errorDescription ?? "Apple TV operation failed."] }
    public var errorDescription: String? {
        switch self {
        case let .missingService(name): return "The Apple TV does not advertise \(name). Pairing alone does not permit installation. Its developer services or developer image may be unavailable on this tvOS version."
        case let .protocolFailure(stage): return "Apple TV returned an invalid response during \(stage)."
        case let .deviceRejected(code): return "Apple TV rejected the operation: \(code)."
        case let .afcStatus(code): return "Apple TV AFC returned status \(code)."
        case .busy: return "Another Apple TV operation is in progress."
        case let .uploadFailed(stage, detail): return "Apple TV upload failed while \(stage). \(detail) Installation was not requested. Keep both devices awake on the same Wi-Fi and retry."
        }
    }
}

public enum TVUploadProgress: Sendable {
    case openingService, preparingDirectory, openingFile, uploading(completed: Int64, total: Int64), closingFile, complete
}

/// Lockdown-style plists on an authenticated RSD service. The two check-in
/// replies must be consumed before speaking AFC, installation_proxy or misagent.
actor RemotePlistService {
    let stream: any ByteTransport
    init(stream: any ByteTransport) { self.stream = stream }
    func close() async { if let tunnelStream = stream as? TunnelTCPTransport { await tunnelStream.finish() } }
    func open() async throws {
        try await stream.connect(timeout: 10)
        try await send(["Label": "SideStoreTV", "ProtocolVersion": "2", "Request": "RSDCheckin"])
        let checkin = try await receive(timeout: 15)
        guard checkin["Request"] as? String == "RSDCheckin", checkin["Error"] == nil else {
            throw TVInstallationError.protocolFailure("RSD check-in")
        }
        let start = try await receive(timeout: 15)
        try Self.checkError(start)
        guard start["Request"] as? String == "StartService" else {
            throw TVInstallationError.protocolFailure("RSD StartService")
        }
    }
    func send(_ value: [String: Any]) async throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
        guard bytes.count <= 16_777_216 else { throw TVInstallationError.protocolFailure("plist size") }
        var length = UInt32(bytes.count).bigEndian
        try await write(withUnsafeBytes(of: &length) { Data($0) } + bytes)
    }
    private func write(_ data: Data) async throws {
        for offset in stride(from: 0, to: data.count, by: 32_768) {
            try Task.checkCancellation()
            try await stream.send(data.subdata(in: offset..<min(offset + 32_768, data.count)), timeout: 30)
        }
    }
    func receive(timeout: TimeInterval = 120) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        let header = try await stream.readExactly(4, timeout: timeout)
        let length = header.reduce(0) { ($0 << 8) | Int($1) }
        guard (1...16_777_216).contains(length) else { throw TVInstallationError.protocolFailure("plist length") }
        var data = Data()
        while data.count < length {
            guard deadline > Date() else { throw TVPairError.timeout }
            data += try await stream.readExactly(min(65_536, length - data.count), timeout: deadline.timeIntervalSinceNow)
        }
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw TVInstallationError.protocolFailure("plist dictionary")
        }
        return value
    }
    static func checkError(_ response: [String: Any]) throws {
        if let error = response["Error"] as? String {
            // Keep symbolic errors useful; do not expose arbitrary peer payloads.
            let code = String(error.prefix(160)).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }
            throw TVInstallationError.deviceRejected(code.isEmpty ? "service error" : code)
        }
    }
    func completion() async throws {
        let deadline = Date().addingTimeInterval(600)
        for _ in 0..<4096 {
            try Task.checkCancellation()
            guard deadline > Date() else { throw TVPairError.timeout }
            let response = try await receive()
            try Self.checkError(response)
            if response["Status"] as? String == "Complete" { return }
            guard response["Status"] is String || response["PercentComplete"] is NSNumber else {
                throw TVInstallationError.protocolFailure("installation progress")
            }
        }
        throw TVPairError.timeout
    }
}

/// Sequential, bounded AFC client. Uploads use 32 KiB chunks, below the POC's
/// tunnel write limit; no whole-app read or local VPN interface is needed.
actor RemoteAFC {
    let stream: any ByteTransport
    var sequence: UInt64 = 0
    init(stream: any ByteTransport) { self.stream = stream }
    static func u64(_ value: UInt64) -> Data { XPCCodec.le(value, count: 8) }
    static func number(_ data: Data, _ offset: Int = 0) -> UInt64 { XPCCodec.number(data, offset, count: 8) }
    func request(_ operation: UInt64, header: Data = Data(), payload: Data = Data(), accepting: Set<UInt64> = [1], timeout: TimeInterval = 30) async throws -> Data {
        try Task.checkCancellation()
        let deadline = Date().addingTimeInterval(timeout)
        let id = sequence; sequence &+= 1
        let bytes = Data("CFA6LPAA".utf8) + Self.u64(UInt64(40 + header.count + payload.count)) + Self.u64(UInt64(40 + header.count)) + Self.u64(id) + Self.u64(operation) + header + payload
        guard bytes.count <= 65_535 else { throw TVInstallationError.protocolFailure("AFC request size") }
        try await stream.send(bytes, timeout: timeout)
        guard deadline > Date() else { throw TVPairError.timeout }
        let response = try await stream.readExactly(40, timeout: deadline.timeIntervalSinceNow)
        guard response.prefix(8) == Data("CFA6LPAA".utf8), Self.number(response, 24) == id else {
            throw TVInstallationError.protocolFailure("AFC sequence")
        }
        let total = Self.number(response, 8), current = Self.number(response, 16), opcode = Self.number(response, 32)
        guard total >= 40, total <= 1_048_576, current >= 40, current <= total else {
            throw TVInstallationError.protocolFailure("AFC response length")
        }
        guard deadline > Date() else { throw TVPairError.timeout }
        let body = try await stream.readExactly(Int(total - 40), timeout: deadline.timeIntervalSinceNow)
        if opcode == 1 {
            guard body.count == 8 else { throw TVInstallationError.protocolFailure("AFC status") }
            let status = Self.number(body)
            guard status == 0 else { throw TVInstallationError.afcStatus(status) }
        }
        guard accepting.contains(opcode) else { throw TVInstallationError.protocolFailure("AFC opcode") }
        return body
    }
    func directory(_ path: String) async throws {
        let name = Data(path.utf8) + Data([0])
        do { _ = try await request(9, header: name) }
        catch TVInstallationError.afcStatus(16) { // OBJECT_EXISTS
            let info = try await request(10, header: name, accepting: [2])
            let fields = info.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count % 2 == 0,
                  stride(from: 0, to: fields.count, by: 2).contains(where: { fields[$0] == "st_ifmt" && fields[$0 + 1] == "S_IFDIR" }) else {
                throw TVInstallationError.protocolFailure("AFC staging directory type")
            }
        }
    }
    func remove(_ path: String) async throws { _ = try await request(8, header: Data(path.utf8) + Data([0])) }
    func upload(_ url: URL, path: String, deadline: Date = Date().addingTimeInterval(900), progress: @Sendable (TVUploadProgress) async throws -> Void = { _ in }) async throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length > 0, length <= UInt64(Int64.max) else { throw TVInstallationError.protocolFailure("IPA file size") }
        try file.seek(toOffset: 0)
        try await progress(.openingFile)
        let opened = try await request(13, header: Self.u64(3) + Data(path.utf8) + Data([0]), accepting: [14])
        guard opened.count == 8 else { throw TVInstallationError.protocolFailure("AFC file handle") }
        do {
            var completed: Int64 = 0
            try await progress(.uploading(completed: 0, total: Int64(length)))
            while let bytes = try file.read(upToCount: 32_768), !bytes.isEmpty {
                guard deadline > Date() else { throw TVPairError.timeout }
                _ = try await request(16, header: opened, payload: bytes, timeout: min(30, deadline.timeIntervalSinceNow))
                completed += Int64(bytes.count)
                try await progress(.uploading(completed: completed, total: Int64(length)))
            }
            guard completed == Int64(length) else { throw TVInstallationError.protocolFailure("IPA size changed during upload") }
            try await progress(.closingFile)
            _ = try await request(20, header: opened)
        } catch {
            // Never spend further read timeouts cleaning up a failed stream.
            // A transport failure invalidates this carrier; do not replay writes.
            stream.cancel()
            throw error
        }
    }
}

extension DeveloperConnection {
    func appService(_ name: String) async throws -> RemotePlistService {
        guard let port = Self.port(availableServices[name]) else { throw TVInstallationError.missingService(name) }
        guard availableServices[name]?.dictionary?["Properties"]?.dictionary?["UsesRemoteXPC"] != .bool(true) else {
            throw TVInstallationError.protocolFailure("unsupported RemoteXPC transport for \(name)")
        }
        let stream = try TunnelTCPTransport(tunnel: tunnel, port: port)
        let client = RemotePlistService(stream: stream)
        do { try await client.open() }
        catch { await client.close(); throw error }
        return client
    }
    private func usingService<T>(_ name: String, _ body: (RemotePlistService) async throws -> T) async throws -> T {
        let client = try await appService(name)
        do { let result = try await body(client); await client.close(); return result }
        catch { await client.close(); throw error }
    }
    // Needs proper testing on physical tvOS; shim availability varies by firmware.
    public func verifyInstallationServices() async throws {
        try beginAppOperation(); defer { operating = false }
        // Actual protocol probes, not just advertised ports.
        _ = try await lookup()
        try await usingService("com.apple.afc.shim.remote") { afc in
            _ = try await RemoteAFC(stream: afc.stream).request(11, accepting: [2])
        }
    }
    private func beginAppOperation() throws {
        guard !operating else { throw TVInstallationError.busy }
        guard developerVerified else { throw TVInstallationError.missingService("a responding developer service") }
        operating = true
    }
    public func stageIPA(_ url: URL, progress: @Sendable (TVUploadProgress) async throws -> Void = { _ in }) async throws -> String {
        try beginAppOperation(); defer { operating = false }
        let directory = "PublicStaging/SideStoreTV-" + UUID().uuidString
        let path = directory + "/Application.ipa"
        var stage = "opening the file service"
        do {
            try await progress(.openingService)
            let result = try await usingService("com.apple.afc.shim.remote") { service in
                let afc = RemoteAFC(stream: service.stream)
                stage = "creating the staging directory"
                try await progress(.preparingDirectory)
                try await afc.directory("PublicStaging")
                try await afc.directory(directory)
                stage = "transferring or closing the IPA"
                try await afc.upload(url, path: path, progress: progress)
                return path
            }
            try await progress(.complete)
            return result
        } catch {
            tunnel.transport.cancel()
            if error is CancellationError { throw error }
            throw TVInstallationError.uploadFailed(stage: stage, detail: error.localizedDescription)
        }
    }
    public func removeStagedIPA(_ path: String) async throws {
        guard path.hasPrefix("PublicStaging/SideStoreTV-"), path.hasSuffix("/Application.ipa"), !path.contains("..") else {
            throw TVInstallationError.protocolFailure("staging path")
        }
        try beginAppOperation(); defer { operating = false }
        try await usingService("com.apple.afc.shim.remote") { service in
            let afc = RemoteAFC(stream: service.stream)
            try await afc.remove(path)
            try await afc.remove(String(path.dropLast("/Application.ipa".count)))
        }
    }
    public func lookupApps() async throws -> [String: String] {
        try beginAppOperation(); defer { operating = false }
        return try await lookup()
    }
    private func lookup() async throws -> [String: String] {
        try await usingService("com.apple.mobile.installation_proxy.shim.remote") { client in
            try await client.send(["Command": "Lookup", "ClientOptions": ["ApplicationType": "User", "ReturnAttributes": ["CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString"]]])
            let response = try await client.receive()
            try RemotePlistService.checkError(response)
            guard let apps = response["LookupResult"] as? [String: [String: Any]] else { throw TVInstallationError.protocolFailure("application inventory") }
            return apps.mapValues { ($0["CFBundleDisplayName"] ?? $0["CFBundleName"]) as? String ?? "App" }
        }
    }
    public func install(stagedPath: String, bundleIdentifier: String, version: String? = nil, build: String? = nil) async throws {
        try beginAppOperation(); defer { operating = false }
        guard stagedPath.hasPrefix("PublicStaging/SideStoreTV-"), !stagedPath.contains("..") else { throw TVInstallationError.protocolFailure("package path") }
        let existing = try await lookup()
        try await usingService("com.apple.mobile.installation_proxy.shim.remote") { client in
            try await client.send(["Command": existing[bundleIdentifier] == nil ? "Install" : "Upgrade", "PackagePath": stagedPath, "ClientOptions": ["PackageType": "Developer"]])
            // A lost connection here is an uncertain result. Never replay mutations.
            try await client.completion()
        }
        try await usingService("com.apple.mobile.installation_proxy.shim.remote") { client in
            try await client.send(["Command": "Lookup", "ClientOptions": ["BundleIDs": [bundleIdentifier], "ReturnAttributes": ["CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion"]]])
            let response = try await client.receive()
            try RemotePlistService.checkError(response)
            guard let apps = response["LookupResult"] as? [String: [String: Any]], let app = apps[bundleIdentifier],
                  version == nil || app["CFBundleShortVersionString"] as? String == version,
                  build == nil || app["CFBundleVersion"] as? String == build else {
                throw TVInstallationError.protocolFailure("post-install bundle/version inventory")
            }
        }
    }
    public func uninstall(bundleIdentifier: String) async throws {
        try beginAppOperation(); defer { operating = false }
        try await usingService("com.apple.mobile.installation_proxy.shim.remote") { client in
            try await client.send(["Command": "Uninstall", "ApplicationIdentifier": bundleIdentifier, "ClientOptions": [:]])
            try await client.completion()
        }
        guard try await lookup()[bundleIdentifier] == nil else { throw TVInstallationError.protocolFailure("post-uninstall inventory") }
    }
    public func installProfile(_ data: Data) async throws {
        try beginAppOperation(); defer { operating = false }
        try await profileRequest(["MessageType": "Install", "Profile": data, "ProfileType": "Provisioning"])
    }
    public func removeProfile(_ identifier: String) async throws {
        try beginAppOperation(); defer { operating = false }
        try await profileRequest(["MessageType": "Remove", "ProfileID": identifier, "ProfileType": "Provisioning"])
    }
    private func profileRequest(_ request: [String: Any]) async throws {
        try await usingService("com.apple.misagent.shim.remote") { client in
            try await client.send(request)
            let response = try await client.receive()
            try RemotePlistService.checkError(response)
            guard let status = response["Status"] as? NSNumber else { throw TVInstallationError.protocolFailure("misagent status") }
            guard status.intValue == 0 else { throw TVInstallationError.deviceRejected("misagent status \(status.intValue)") }
            if let expected = request["Profile"] as? Data {
                try await client.send(["MessageType": "CopyAll", "ProfileType": "Provisioning"])
                let installed = try await client.receive()
                try RemotePlistService.checkError(installed)
                guard (installed["Status"] as? NSNumber)?.intValue == 0,
                      let profiles = installed["Payload"] as? [Data], profiles.contains(expected) else {
                    throw TVInstallationError.protocolFailure("post-refresh profile inventory")
                }
            }
        }
    }
}
