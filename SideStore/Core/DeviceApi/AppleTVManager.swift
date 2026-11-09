import Foundation
import SwiftUI
import Combine
import SideSign
import TVPairCore

struct AppleTVIconRequest: Sendable {
    let bundleIdentifier: String
    let destination: URL
}

/// The selected TV, never the iPhone hosting SideStore, owns device operations.
@MainActor
final class AppleTVManager: ObservableObject {
    static let shared = AppleTVManager()
    static let iconsDidChange = Notification.Name("SideTVstore.iconsDidChange")
    static let operationsDidFinish = Notification.Name("SideTVstore.operationsDidFinish")
    private var iconRefresh: Task<Void, Never>?
    let discovery = BonjourDiscovery()
    private let vault = CredentialVault()
    @Published private(set) var saved: [SavedDevice] = []
    @Published private(set) var information: DeviceInformation?
    @Published private(set) var status = "Choose an Apple TV to begin."
    @Published private(set) var busy = false
    @Published private(set) var needsPIN = false
    @Published var pin = ""
    @Published private(set) var selectedID: UUID?
    @Published private(set) var installedApps: [String: String] = [:]
    @Published private(set) var transferStatus: String?
    private var lastTransferLog = Date.distantPast
    private var developer: DeveloperConnection?
    private var transport: (any ByteTransport)?
    private var pinContinuation: CheckedContinuation<String, Error>?
    private var pinRequestID: UUID?
    private var operation: Task<Void, Never>?
    private var connecting: Task<DeveloperConnection, Error>?
    private var leases = 0
    private var staged: [String: String] = [:]
    private var readyAt = Date.distantPast
    let readiness = CurrentValueSubject<Result<Bool, Error>, Never>(.success(false))

    private init() {
        selectedID = UserDefaults.standard.string(forKey: "AppleTV.selected").flatMap(UUID.init(uuidString:))
    }
    func load() async throws { saved = try await vault.load() }
    func importPairing(_ data: Data) async throws {
        await stopIconRefresh()
        guard leases == 0, !busy, connecting == nil else { throw TVInstallationError.busy }
        var record = try PairingRecord.importPlist(data)
        guard record.peerPublicKey != nil, record.peerIdentifier != nil else {
            throw TVPairError.invalidRecord("This file lacks the TV's peer-verification keys. Export a saved pairing from SideTVstore or TVPair, or pair with the TV again.")
        }
        if let product = record.productType, !product.hasPrefix("AppleTV") {
            throw TVPairError.invalidRecord("This pairing belongs to a different device type.")
        }
        // Reimporting our own export preserves the selected TV/library binding.
        for device in saved {
            let existing = try await vault.record(id: device.id)
            if existing.publicKey == record.publicKey, existing.peerPublicKey == record.peerPublicKey,
               existing.peerIdentifier == record.peerIdentifier {
                record.id = existing.id; break
            }
        }
        saved = try await vault.save(record)
        let bound = UserDefaults.standard.string(forKey: "AppleTV.managedTarget")
        if bound == nil || bound == record.id.uuidString { try select(record.id) }
        status = "Pairing imported. Connect to verify this Apple TV."
    }
    func exportPairing(_ id: UUID) async throws -> Data {
        return try await vault.record(id: id).exportPlist()
    }
    func startDiscovery() { discovery.start() }
    func select(_ id: UUID) throws {
        guard leases == 0, !busy, connecting == nil else { throw TVInstallationError.busy }
        if let bound = UserDefaults.standard.string(forKey: "AppleTV.managedTarget"), bound != id.uuidString {
            throw OperationError.invalidParameters("This library belongs to another Apple TV. Remove its tracked apps before switching the managed TV.")
        }
        developer?.cancel(); developer = nil; information = nil; installedApps = [:]; readyAt = .distantPast
        status = "Connecting to the selected Apple TV…"
        UserDefaults.standard.removeObject(forKey: "AppleTV.osVersion")
        selectedID = id
        UserDefaults.standard.set(id.uuidString, forKey: "AppleTV.selected")
        UserDefaults.standard.isDeviceRegistered = false
        readiness.send(.success(false))
    }
    func delete(_ id: UUID) async throws {
        guard leases == 0, !busy, connecting == nil else { throw TVInstallationError.busy }
        guard UserDefaults.standard.string(forKey: "AppleTV.managedTarget") != id.uuidString else {
            throw OperationError.invalidParameters("Remove this TV's tracked apps before forgetting its pairing.")
        }
        saved = try await vault.delete(id: id)
        if selectedID == id {
            developer?.cancel(); developer = nil; selectedID = nil; information = nil
            installedApps = [:]; status = "Choose an Apple TV to begin."
            UserDefaults.standard.removeObject(forKey: "AppleTV.selected")
            UserDefaults.standard.removeObject(forKey: "AppleTV.osVersion")
            readiness.send(.success(false))
        }
    }
    func setup(host: String) {
        guard !busy, leases == 0, connecting == nil else { return }
        busy = true; status = "Finding the TV's developer pairing service…"
        discovery.start()
        operation = Task {
            defer { busy = false; operation = nil; transport?.cancel(); transport = nil }
            do {
                // POC's computer-host bootstrap procedure is automatic in setup.
                let endpoint = try await DirectPairingProbe(host: host).resolve(.manualPairing)
                let tcp = TCPTransport(endpoint: endpoint); transport = tcp
                let client = RemotePairingClient(transport: tcp)
                let record = try await client.authenticate(endpoint: endpoint, requestPIN: { [weak self] in
                    guard let self else { throw CancellationError() }
                    return try await self.requestPIN()
                }, report: reporter)
                // Persist before the handoff so a service timeout never loses trust.
                saved = try await vault.save(record)
                tcp.cancel(); transport = nil
                busy = false
                try select(record.id)
                busy = true
                _ = try await ready(force: true)
            } catch {
                status = error.localizedDescription
                readiness.send(.failure(error))
            }
        }
    }
    private var reporter: PairingReporter {
        { [weak self] _, _, _, message in await self?.setStatus(message) }
    }
    private func setStatus(_ value: String) { status = value }
    private func requestPIN() async throws -> String {
        needsPIN = true; pin = ""
        defer { needsPIN = false; pin = "" }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let requestID = UUID(); pinRequestID = requestID
                pinContinuation = continuation
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(90))
                    guard self?.pinRequestID == requestID else { return }
                    self?.finishPIN(.failure(TVPairError.timeout))
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.finishPIN(.failure(CancellationError())) } }
    }
    private func finishPIN(_ result: Result<String, Error>) {
        let continuation = pinContinuation; pinContinuation = nil; pinRequestID = nil
        continuation?.resume(with: result)
    }
    func submitPIN() {
        guard pin.count == 6, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else { return }
        finishPIN(.success(pin))
    }
    func cancelSetup() {
        operation?.cancel(); connecting?.cancel(); transport?.cancel(); finishPIN(.failure(CancellationError()))
    }
    private func endpoint(for record: PairingRecord) async throws -> ConnectionEndpoint {
        if !discovery.scanning { discovery.start() }
        let deadline = Date().addingTimeInterval(20)
        repeat {
            try Task.checkCancellation()
            if let match = discovery.devices.first(where: {
                $0.service == .remotePairing && $0.endpoint != nil && AdvertisementIdentity.matches(record: record, identifier: $0.advertisedIdentifier, authTag: $0.authenticationTag)
            })?.endpoint { return match }
            if let host = record.lastEndpoint?.host,
               let result = try? await DirectPairingProbe(host: host).resolve(.remotePairing, timeout: min(4, max(0.01, deadline.timeIntervalSinceNow))) { return result }
            try await Task.sleep(for: .milliseconds(500))
        } while deadline > Date()
        throw OperationError.notReachable(reason: "The paired TV's trusted endpoint was not discovered. Keep it awake on the same Wi-Fi and retry with the saved pairing.")
    }
    func ready(force: Bool = false) async throws -> DeveloperConnection {
        if let connecting { return try await connecting.value }
        if !force, let developer, leases > 0 || Date().timeIntervalSince(readyAt) < 15 { return developer }
        let task = Task<DeveloperConnection, Error> {
            guard let id = selectedID else { throw OperationError.noDevice(reason: "Pair and select an Apple TV in Settings.") }
            let record = try await vault.record(id: id)
            developer?.cancel(); developer = nil; information = nil
            let resolved = try await endpoint(for: record)
            let tcp = TCPTransport(endpoint: resolved)
            let client = RemotePairingClient(transport: tcp)
            do {
                let verified = try await client.authenticate(endpoint: resolved, service: .remotePairing, existingRecord: record, requestPIN: { throw TVPairError.authentication }, report: reporter)
                saved = try await vault.save(verified)
                let tunnel = try await TrustedTunnel.establish(endpoint: resolved, session: client, report: reporter)
                let connection = DeveloperConnection(tunnel: tunnel, hostIdentifier: verified.hostIdentifier, savedName: verified.deviceName)
                let info = try await connection.inspect(report: reporter)
                guard info.productType?.hasPrefix("AppleTV") == true, let udid = info.identifier, !udid.isEmpty,
                      info.osVersion != nil else {
                    connection.cancel()
                    throw OperationError.invalidParameters("Authenticated RSD must identify an Apple TV, its UDID, and tvOS version before provisioning.")
                }
                guard info.instrumentsServiceResponded || info.deviceInfoServiceResponded else {
                    connection.cancel(); throw TVInstallationError.missingService("a responding developer service")
                }
                information = info
                UserDefaults.standard.set(info.osVersion, forKey: "AppleTV.osVersion")
                try await connection.verifyInstallationServices()
                developer = connection; readyAt = Date()
                status = "Developer access and installation services verified."
                readiness.send(.success(true))
                return connection
            } catch { tcp.cancel(); throw error }
        }
        connecting = task
        defer { connecting = nil }
        do { return try await task.value }
        catch { readiness.send(.failure(error)); status = error.localizedDescription; throw error }
    }
    func beginOperations() async throws {
        // App mutations take priority over optional, read-only icon retrieval.
        await stopIconRefresh()
        guard leases == 0, !busy else { throw TVInstallationError.busy }
        leases = 1
        do { _ = try await ready(force: true) }
        catch { leases = 0; throw error }
    }
    func endOperations() async {
        if let developer {
            for path in staged.values { try? await developer.removeStagedIPA(path) }
            developer.cancel()
        }
        staged.removeAll(); developer = nil; readyAt = .distantPast; leases = 0
        readiness.send(.success(false))
        NotificationCenter.default.post(name: Self.operationsDidFinish, object: nil)
    }
    private func stopIconRefresh() async {
        if let iconRefresh {
            iconRefresh.cancel(); connecting?.cancel(); developer?.cancel()
            await iconRefresh.value
        }
    }
    func refreshIcons(_ requests: [AppleTVIconRequest]) {
        guard !requests.isEmpty, leases == 0, !busy, connecting == nil, iconRefresh == nil else { return }
        if let bound = UserDefaults.standard.string(forKey: "AppleTV.managedTarget"), bound != selectedID?.uuidString { return }
        leases = 1
        iconRefresh = Task {
            var changed = false
            defer {
                leases = 0; iconRefresh = nil
                if changed { NotificationCenter.default.post(name: Self.iconsDidChange, object: nil) }
            }
            do {
                let connection = try await ready()
                guard await connection.supportsAppIcons else { return }
                for request in requests {
                    try Task.checkCancellation()
                    let png = try await connection.appIconPNG(bundleIdentifier: request.bundleIdentifier)
                    guard UIImage(data: png) != nil else { continue }
                    try FileManager.default.createDirectory(at: request.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try png.write(to: request.destination, options: .atomic)
                    changed = true
                }
            } catch {
                if !Task.isCancelled { debugLog("[AppleTVIcons] Optional icon retrieval unavailable; using cached bundle or source artwork.") }
            }
        }
    }
    func deviceUDID() async throws -> String {
        _ = try await ready()
        guard let value = information?.identifier else { throw OperationError.unknownUDID(reason: "Apple TV did not return its UDID.") }
        return value
    }
    func validate(_ app: ALTApplication) async throws {
        _ = try await ready()
        let platforms = app.infoPlist["CFBundleSupportedPlatforms"] as? [String] ?? []
        guard app.supportedDeviceTypes.contains(.appleTV), platforms == ["AppleTVOS"] else {
            throw OperationError.invalidApp(reason: "Choose a physical-device tvOS IPA (AppleTVOS, device family 3). iPhone and simulator apps cannot run on Apple TV.")
        }
        try validateExecutable(app)
        guard let os = information?.osVersion else { throw OperationError.invalidParameters("tvOS version is unavailable.") }
        let parts = os.split(separator: ".").map { Int($0) ?? 0 }
        guard !parts.isEmpty else { throw OperationError.invalidParameters("Invalid tvOS version.") }
        let actual = OperatingSystemVersion(majorVersion: parts[0], minorVersion: parts.count > 1 ? parts[1] : 0, patchVersion: parts.count > 2 ? parts[2] : 0)
        let required = app.minimumiOSVersion
        guard actual >= required else { throw OperationError.invalidApp(reason: "This IPA requires a newer tvOS version than the selected Apple TV.") }
        for ext in app.appExtensions {
            let platforms = ext.infoPlist["CFBundleSupportedPlatforms"] as? [String] ?? []
            guard platforms == ["AppleTVOS"] else { throw OperationError.invalidApp(reason: "The IPA contains a non-tvOS extension.") }
            try validateExecutable(ext)
        }
    }
    private func validateExecutable(_ app: ALTApplication) throws {
        guard let name = app.infoPlist["CFBundleExecutable"] as? String, !name.isEmpty,
              !name.contains("/"), !name.contains("\\"), name != ".", name != ".." else {
            throw OperationError.invalidApp(reason: "The IPA executable name is invalid.")
        }
        try TVOSExecutable.validate(url: app.fileURL.appendingPathComponent(name))
    }
    func validateProfile(_ profile: ALTProvisioningProfile) async throws {
        let udid = try await deviceUDID()
        // SideSign decodes the profile. Inspect its platform before signing;
        // the TV separately enforces the Apple CMS signature during installation.
        guard let start = profile.data.range(of: Data("<?xml".utf8)),
              let end = profile.data.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.data.endIndex),
              let dictionary = try PropertyListSerialization.propertyList(from: profile.data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any] else {
            throw OperationError.invalidParameters("Cannot inspect the provisioning profile's platform.")
        }
        guard (dictionary["Platform"] as? [String])?.contains("tvOS") == true,
              profile.deviceIDs.contains(where: { $0.caseInsensitiveCompare(udid) == .orderedSame }),
              profile.expirationDate > Date() else {
            throw OperationError.invalidParameters("A valid tvOS development profile containing the selected Apple TV's UDID is required. Apple may restrict tvOS provisioning for this account.")
        }
    }
    func stage(bundleID: String, url: URL, progress: @escaping @Sendable (TVUploadProgress) async throws -> Void = { _ in }) async throws {
        transferStatus = "Connecting to Apple TV for upload…"
        debugLog("[AppleTVUpload] Preparing the signed IPA for transfer.")
        lastTransferLog = .distantPast
        do {
            let connection = try await ready()
            staged[bundleID] = try await connection.stageIPA(url) { event in
                await self.reportTransfer(event)
                try await progress(event)
            }
        } catch {
            developer?.cancel(); developer = nil; readyAt = .distantPast
            readiness.send(.failure(error))
            status = error.localizedDescription; transferStatus = "Apple TV upload failed."
            debugLog("[AppleTVUpload] FAILED: \(error.localizedDescription)")
            throw error
        }
    }
    private func reportTransfer(_ event: TVUploadProgress) {
        let message: String
        var logNow = true
        switch event {
        case .openingService: message = "Opening Apple TV file service…"
        case .preparingDirectory: message = "Preparing Apple TV upload folder…"
        case .openingFile: message = "Opening the IPA on Apple TV…"
        case let .uploading(completed, total):
            let sent = ByteCountFormatter.string(fromByteCount: completed, countStyle: .file)
            let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            message = "Uploading \(sent) of \(size)…"
            logNow = completed == 0 || completed == total || Date().timeIntervalSince(lastTransferLog) >= 2
        case .closingFile: message = "Finishing the Apple TV upload…"
        case .complete: message = "Upload complete. Preparing installation…"
        }
        transferStatus = message
        if logNow { debugLog("[AppleTVUpload] \(message)"); lastTransferLog = Date() }
    }
    func install(bundleID: String, expectedBundleID: String? = nil, version: String? = nil, build: String? = nil) async throws {
        guard let path = staged.removeValue(forKey: bundleID), let developer else { throw OperationError.invalidParameters("No package has been staged on the selected Apple TV.") }
        transferStatus = "Installing on Apple TV…"
        do {
            try await developer.install(stagedPath: path, bundleIdentifier: expectedBundleID ?? bundleID, version: version, build: build)
            let icon = InstalledApp.appsDirectoryURL.appendingPathComponent(expectedBundleID ?? bundleID).appendingPathComponent("AppleTVIcon.png")
            try? FileManager.default.removeItem(at: icon)
            try? await developer.removeStagedIPA(path)
            transferStatus = nil
        } catch {
            transferStatus = "Apple TV installation failed."
            try? await developer.removeStagedIPA(path)
            throw error
        }
    }
    func inventory() async throws {
        guard leases == 0, !busy else { throw TVInstallationError.busy }
        leases = 1
        defer { leases = 0 }
        installedApps = try await ready(force: true).lookupApps()
    }
}
