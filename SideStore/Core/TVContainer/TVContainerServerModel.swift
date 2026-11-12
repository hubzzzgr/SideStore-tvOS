import Foundation
import SwiftUI
import UniformTypeIdentifiers
import TVPairCore

@MainActor
final class TVContainerServerModel: ObservableObject {
    static let shared = TVContainerServerModel()
    @Published private(set) var enabled = false
    @Published private(set) var starting = false
    @Published private(set) var importing = false
    @Published private(set) var address: String?
    @Published private(set) var discoveryReady = false
    @Published private(set) var discoveryWarning: String?
    @Published private(set) var files: [TVContainerFile] = []
    @Published var error: String?
    private let server = TVContainerFileServer()
    private let advertiser = TVContainerBonjourAdvertiser()
    private var revision = UUID()
    private var backgroundObserver: NSObjectProtocol?
    nonisolated private static var directory: URL {
        FileManager.default.applicationSupportDirectory.appendingPathComponent("TVContainerFiles", isDirectory: true)
    }
    private var manifest: URL { Self.directory.appendingPathComponent("files.json") }

    private init() {
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.complete])
            var directory = Self.directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            if FileManager.default.fileExists(atPath: manifest.path) {
                files = try JSONDecoder().decode([TVContainerFile].self, from: Data(contentsOf: manifest))
                    .filter { FileManager.default.fileExists(atPath: Self.url($0.id).path) }
            }
        } catch { self.error = "Could not load shared files: \(error.localizedDescription)" }
        // The enabled flag is deliberately never persisted or restored.
        backgroundObserver = NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                                                                    object: nil, queue: .main) { _ in
            Task { @MainActor in Self.shared.setEnabled(false) }
        }
    }
    private static func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString) }
    private func save() throws {
        try JSONEncoder().encode(files).write(to: manifest, options: [.atomic, .completeFileProtection])
    }
    private func publishFiles() async { await server.setFiles(files.map { ($0, Self.url($0.id)) }) }
    func downloadURL(for file: TVContainerFile) -> URL? {
        guard let address, let base = URL(string: address) else { return nil }
        return base.appendingPathComponent("v1/files").appendingPathComponent(file.id.uuidString)
    }

    func setEnabled(_ value: Bool) {
        revision = UUID(); let token = revision
        enabled = value; starting = value; address = nil
        advertiser.stop(); discoveryReady = false; discoveryWarning = nil
        Task {
            guard revision == token else { return }
            if !value { await server.stop(); return }
            do {
                await publishFiles()
                guard revision == token, enabled else { return }
                let result = try await server.start { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.revision == token else { return }
                        self.enabled = false; self.starting = false; self.address = nil; self.error = message
                        self.advertiser.stop(); self.discoveryReady = false; self.discoveryWarning = nil
                    }
                }
                guard revision == token, enabled else { return }
                starting = false; address = result
                if let port = URLComponents(string: result)?.port, let servicePort = Int32(exactly: port) {
                    advertiser.start(port: servicePort) { [weak self] warning in
                        guard let self, self.revision == token, self.enabled else { return }
                        self.discoveryReady = warning == nil
                        self.discoveryWarning = warning
                    }
                }
            } catch {
                guard revision == token else { return }
                enabled = false; starting = false; address = nil; self.error = error.localizedDescription
                advertiser.stop(); discoveryReady = false; discoveryWarning = nil
            }
        }
    }
    func add(_ urls: [URL]) {
        guard !importing else { return }
        importing = true
        Task {
            defer { importing = false }
            for source in urls {
                do {
                    guard files.count < 100 else { throw CocoaError(.fileWriteOutOfSpace) }
                    let entry = try await Task.detached(priority: .userInitiated) { () throws -> TVContainerFile in
                        let access = source.startAccessingSecurityScopedResource()
                        defer { if access { source.stopAccessingSecurityScopedResource() } }
                        let id = UUID(), destination = Self.directory.appendingPathComponent(id.uuidString)
                        var coordinationError: NSError?
                        var copyResult: Result<TVContainerFile, Error>?
                        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { local in
                            copyResult = Result {
                                let values = try local.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
                                do {
                                    try FileManager.default.copyItem(at: local, to: destination)
                                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: destination.path)
                                    let size = try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                                    let name = source.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined()
                                    let type = UTType(filenameExtension: source.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                                    return TVContainerFile(id: id, name: String(name.prefix(255)), size: Int64(size), contentType: type)
                                } catch {
                                    try? FileManager.default.removeItem(at: destination)
                                    throw error
                                }
                            }
                        }
                        if let coordinationError { throw coordinationError }
                        guard let copyResult else { throw CocoaError(.fileReadUnknown) }
                        return try copyResult.get()
                    }.value
                    files.append(entry)
                    do { try save() }
                    catch { files.removeAll { $0.id == entry.id }; try? FileManager.default.removeItem(at: Self.url(entry.id)); throw error }
                    await publishFiles()
                } catch { self.error = "Could not add \(source.lastPathComponent): \(error.localizedDescription)" }
            }
        }
    }
    func remove(_ indices: IndexSet) {
        let removed = indices.compactMap { files.indices.contains($0) ? files[$0] : nil }
        let previous = files
        files.removeAll { entry in removed.contains { $0.id == entry.id } }
        do { try save() }
        catch { files = previous; self.error = error.localizedDescription; return }
        Task {
            await publishFiles()
            for entry in removed {
                do { try FileManager.default.removeItem(at: Self.url(entry.id)) }
                catch { self.error = "Could not remove a shared file: \(error.localizedDescription)" }
            }
        }
    }
}
