import Foundation
import TVPairCore
import Combine
import Network

struct TVContainerStagedFile: Sendable {
    let url: URL
    let name: String
    let size: UInt64
}

private actor TVContainerStaging {
    static let shared = TVContainerStaging()
    private init() {
        // Once per process, clear any protected export left by a terminated run.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("TVContainerTransfers", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
    }
    private func destination(name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TVContainerTransfers", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        var excluded = directory
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try excluded.setResourceValues(values)
        return directory.appendingPathComponent(name)
    }
    func copy(_ source: URL) throws -> TVContainerStagedFile {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        // Validate before copying, then validate the stable copy before connecting.
        try TVContainerWire.validate(file: source, action: .uploadIPA)
        let url = try destination(name: source.lastPathComponent)
        do {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: url) } catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
            let size = try TVContainerWire.validate(file: url, action: .uploadIPA)
            return TVContainerStagedFile(url: url, name: source.lastPathComponent, size: size)
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
    }
    func certificate(_ active: ActiveSigningCertificate) throws -> TVContainerStagedFile {
        let url = try destination(name: "SideTVStore-Signing.p12")
        do {
            // Existing exporter, without a payload password. Only approved mTLS
            // carries it; the user chooses an empty password in the TV importer.
            let data = try CertificateManager.convert(active.certificate, password: nil)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            let size = try TVContainerWire.validate(file: url, action: .uploadP12)
            return TVContainerStagedFile(url: url, name: url.lastPathComponent, size: size)
        } catch {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw error
        }
    }
}

@MainActor
final class TVContainerTransferModel: ObservableObject {
    struct PairingPrompt: Identifiable {
        let id = UUID()
        let tvFingerprint: String
        let phoneFingerprint: String
    }
    @Published var selectedID: String?
    @Published private(set) var status = "Choose a paired Apple TV and enter TVContainer's current port."
    @Published private(set) var busy = false
    @Published private(set) var completed: UInt64 = 0
    @Published private(set) var total: UInt64 = 0
    @Published private(set) var result: TVContainerWire.Response?
    @Published private(set) var error: String?
    @Published private(set) var pairingPrompt: PairingPrompt?
    @Published private(set) var phoneFingerprint: String?
    @Published private(set) var pins: [TVContainerIdentityStore.Pin] = []
    @Published private(set) var staged: TVContainerStagedFile?
    @Published private(set) var certificateSentPins: Set<String> = []
    @Published private(set) var selectedPin: String?
    @Published private(set) var connectionActive = false
    private let staging = TVContainerStaging.shared
    private var operation: Task<Void, Never>?
    private var connection: TVContainerTransport?
    private var responseTask: Task<TVContainerWire.Response, Error>?
    private var idleMonitor: Task<Void, Never>?
    private var connectionDeviceID: String?
    private var approval: CheckedContinuation<Bool, Never>?
    private var uploadStarted = false
    private var generation = UUID()
    private var opened = false

    var certificateAlreadySent: Bool { selectedPin.map { certificateSentPins.contains($0) } ?? false }

    func open(initialIPA: URL?) {
        guard !opened else { return }; opened = true
        Task {
            do {
                let identity = try await TVContainerIdentityStore.shared.identity()
                phoneFingerprint = identity.fingerprint
                pins = try await TVContainerIdentityStore.shared.pins()
            } catch { self.error = error.localizedDescription }
        }
        if let initialIPA { stage(initialIPA) }
    }

    private func begin(_ message: String) -> UUID {
        let token = UUID(); generation = token
        busy = true; status = message; result = nil; error = nil
        completed = 0; total = 0; uploadStarted = false
        return token
    }

    func stage(_ source: URL) {
        guard !busy else { return }
        clearStaged()
        let token = begin("Preparing IPA…")
        operation = Task {
            do {
                let copy = try await staging.copy(source)
                guard !Task.isCancelled, generation == token else { remove(copy); return }
                staged = copy
                status = "IPA ready. Choose a TV, then tap Send and install IPA."
            } catch { if generation == token { self.error = error.localizedDescription; status = "Unable to prepare IPA." } }
            finish(token)
        }
    }

    func connect(_ device: TVContainerDevice) {
        guard !busy else { return }
        disconnectSession()
        selectedID = device.id; selectedPin = nil
        let token = begin("Connecting securely… Approve pairing on both devices if asked.")
        operation = Task {
            do {
                let stream = try await session(device, token: token)
                guard generation == token else { return }
                selectedPin = stream.peerFingerprint
                pins = try await TVContainerIdentityStore.shared.pins()
                status = "Ready to send."
            } catch { if generation == token { disconnectSession(); self.error = connectionError(error); status = "Not connected." } }
            finish(token)
        }
    }

    func sendIPA(to device: TVContainerDevice) {
        guard let staged, !busy else { return }
        transfer(staged, action: .uploadIPA, to: device)
    }

    func sendCertificate(to device: TVContainerDevice) {
        guard !busy, !certificateAlreadySent else { return }
        let token = begin("Preparing signing certificate…")
        operation = Task {
            do {
                guard let active = try CertificateManager.shared.loadActiveCertificate() else {
                    throw TVContainerFailure("No active SideTVStore signing certificate is available. Sign in or import a certificate in Settings first.")
                }
                let file = try await staging.certificate(active)
                guard !Task.isCancelled, generation == token else { remove(file); return }
                await runTransfer(file, action: .uploadP12, to: device, token: token)
                await reconnectAfterResult(device, token: token)
            } catch { if generation == token { self.error = error.localizedDescription; status = "Certificate not sent." } }
            finish(token)
        }
    }

    private func transfer(_ file: TVContainerStagedFile, action: TVContainerWire.Action, to device: TVContainerDevice) {
        let token = begin("Connecting securely…")
        operation = Task {
            await runTransfer(file, action: action, to: device, token: token)
            await reconnectAfterResult(device, token: token)
            finish(token)
        }
    }

    private func runTransfer(_ file: TVContainerStagedFile, action: TVContainerWire.Action, to device: TVContainerDevice, token: UUID) async {
        defer {
            if generation == token { connectionActive = false }
            remove(file)
            if staged?.url == file.url { staged = nil }
        }
        do {
            try TVContainerWire.validate(file: file.url, filename: file.name, action: action)
            let stream = try await session(device, token: token)
            defer { if connection === stream { disconnectSession() } else { stream.cancel() } }
            try Task.checkCancellation()
            guard generation == token else { return }
            selectedPin = stream.peerFingerprint
            pins = try await TVContainerIdentityStore.shared.pins()
            uploadStarted = true; total = file.size; status = "Uploading \(file.name)…"
            let response = try await TVContainerWire.upload(file: file.url, filename: file.name, action: action, over: stream,
                responseTask: responseTask,
                progress: { [weak self] bytes, size in
                    await self?.updateProgress(bytes, total: size, token: token)
                }, waiting: { [weak self] in
                    await self?.waitingForTV(token)
                })
            guard generation == token else { return }
            result = response
            uploadStarted = false
            status = response.ok ? (action == .uploadIPA ? "Installation confirmed by TVContainer." : "Certificate import confirmed by TVContainer.") : "TVContainer declined the transfer."
            if response.ok, action == .uploadP12, let pin = stream.peerFingerprint { certificateSentPins.insert(pin) }
        } catch {
            guard generation == token else { return }
            if uploadStarted {
                status = "Outcome unknown — check TVContainer on Apple TV."
                self.error = "\(connectionError(error))\n\nThe TV may have completed the operation. Check it before selecting the file and retrying manually."
            } else {
                status = "Transfer not started."
                self.error = connectionError(error)
            }
        }
    }

    private func session(_ device: TVContainerDevice, token: UUID) async throws -> TVContainerTransport {
        if connectionActive, connectionDeviceID == device.id, let connection { return connection }
        disconnectSession()
        let stream = try await authenticatedConnection(device, token: token)
        connectionDeviceID = device.id
        // One reader owns the stream from idle through the final upload result.
        // A graceful peer close is detected even before a file is selected.
        let reader = Task { try await TVContainerWire.receiveResponse(from: stream, timeout: 7200) }
        responseTask = reader
        idleMonitor = Task { [weak self] in
            let outcome = await reader.result
            guard let self, self.connection === stream, !self.uploadStarted else { return }
            self.disconnectSession()
            switch outcome {
            case let .success(reply): self.error = reply.ok ? "Unexpected response before an upload." : reply.message
            case .failure: self.error = "TVContainer closed the connection. Reconnect to retry. Its receiver must allow idle authenticated connections to stay connected before sending a file."
            }
            if !self.busy { self.status = "Disconnected from TVContainer." }
        }
        return stream
    }

    private func reconnectAfterResult(_ device: TVContainerDevice, token: UUID) async {
        // Reconnect only after a complete result, never retry an unknown upload.
        guard generation == token, result != nil, !Task.isCancelled else { return }
        do { _ = try await session(device, token: token) }
        catch {
            guard generation == token else { return }
            disconnectSession()
            self.error = "The transfer result above is final. The idle connection could not be restored: \(connectionError(error))"
        }
    }

    private func disconnectSession() {
        let stream = connection
        connection = nil; connectionDeviceID = nil; connectionActive = false
        stream?.cancel(); responseTask?.cancel(); responseTask = nil
        idleMonitor?.cancel(); idleMonitor = nil
    }

    private func updateProgress(_ bytes: UInt64, total: UInt64, token: UUID) {
        guard generation == token else { return }
        completed = bytes; self.total = total
    }
    private func waitingForTV(_ token: UUID) {
        guard generation == token else { return }
        status = "Waiting for confirmation on Apple TV"
    }
    private func authenticatedConnection(_ device: TVContainerDevice, token: UUID) async throws -> TVContainerTransport {
        let host = try await AppleTVManager.shared.tvContainerHost(for: device.pairingID)
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        let identity = try await TVContainerIdentityStore.shared.identity()
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        phoneFingerprint = identity.fingerprint
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: device.port)!)
        let stream = try TVContainerTransport(endpoint: endpoint, aliases: device.aliases, name: device.name,
            identity: identity, approve: { [weak self] tv, phone in
                guard let self else { return false }
                return await self.requestApproval(tv: tv, phone: phone, token: token)
            })
        connection = stream
        try await stream.connect(timeout: 90)
        try Task.checkCancellation()
        guard generation == token else { stream.cancel(); throw CancellationError() }
        connectionActive = true
        return stream
    }
    private func requestApproval(tv: String, phone: String, token: UUID) async -> Bool {
        guard busy, generation == token, !Task.isCancelled else { return false }
        answerPairing(false)
        return await withCheckedContinuation { continuation in
            approval = continuation
            pairingPrompt = PairingPrompt(tvFingerprint: tv, phoneFingerprint: phone)
        }
    }
    func answerPairing(_ matches: Bool) {
        let continuation = approval; approval = nil; pairingPrompt = nil
        continuation?.resume(returning: matches)
        if matches { status = "Approve this iPhone on Apple TV. Compare the phone fingerprint below." }
    }
    func forget(_ pin: TVContainerIdentityStore.Pin) {
        guard !busy else { return }
        Task {
            do {
                try await TVContainerIdentityStore.shared.forget(pin.fingerprint)
                pins = try await TVContainerIdentityStore.shared.pins()
                certificateSentPins.remove(pin.fingerprint); selectedPin = nil
                status = "TV forgotten. Select it again to compare fingerprints and pair."
            } catch { self.error = error.localizedDescription }
        }
    }
    func cancel() {
        let unknown = uploadStarted
        generation = UUID()
        operation?.cancel(); disconnectSession()
        answerPairing(false)
        busy = false; operation = nil; connectionActive = false
        if result != nil { status = "Disconnected. The completed transfer result is shown below." }
        else { status = unknown ? "Outcome unknown — check TVContainer on Apple TV before retrying." : "Cancelled / disconnected." }
    }
    func resetDestination() {
        guard !busy else { return }
        generation = UUID(); disconnectSession()
        selectedID = nil; selectedPin = nil; result = nil; error = nil; connectionActive = false
        status = "Choose a paired Apple TV and enter TVContainer's current port."
    }
    func close() { cancel(); clearStaged() }
    private func finish(_ token: UUID) {
        guard generation == token else { return }
        answerPairing(false); busy = false; operation = nil
    }
    private func clearStaged() { if let staged { remove(staged) }; staged = nil }
    private func remove(_ file: TVContainerStagedFile) { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
    private func connectionError(_ error: Error) -> String {
        if error is CancellationError { return "The connection was cancelled." }
        return "\(error.localizedDescription) Keep TVContainer's launcher open with its TCP Server enabled. If pairing expired, restart the connection and approve on both devices."
    }
}
