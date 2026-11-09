import Foundation
import Combine
import TVPairCore

// Compatibility entry points keep SideStore's signing and operation pipeline.
// Every device action is routed to the selected, authenticated Apple TV.
public func ensureMinimuxerReady() async throws { _ = try await AppleTVManager.shared.ready() }
public func isMinimuxerReady() async -> Result<Bool, Error> {
    do { try await ensureMinimuxerReady(); return .success(true) }
    catch { return .failure(error) }
}
@MainActor var minimuxerStatusPublisher: AnyPublisher<Result<Bool, Error>, Never> {
    AppleTVManager.shared.readiness.eraseToAnyPublisher()
}
func fetchUDID(forceLive: Bool = false) async throws -> String {
    if forceLive { _ = try await AppleTVManager.shared.ready(force: true) }
    return try await AppleTVManager.shared.deviceUDID()
}
func safeFetchUDID(forceLive: Bool = false) async throws -> String { try await fetchUDID(forceLive: forceLive) }
func installProvisioningProfiles(_ data: Data) async throws {
    let connection = try await AppleTVManager.shared.ready()
    try await connection.installProfile(data)
}
func removeProvisioningProfile(_ id: String) async throws {
    let connection = try await AppleTVManager.shared.ready()
    try await connection.removeProfile(id)
}
func removeApp(_ bundleID: String) async throws {
    let connection = try await AppleTVManager.shared.ready()
    try await connection.uninstall(bundleIdentifier: bundleID)
}
func sendIpaAfc(_ bundleID: String, _ bytes: Data) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ipa")
    try bytes.write(to: url, options: [.atomic, .completeFileProtection])
    defer { try? FileManager.default.removeItem(at: url) }
    try await AppleTVManager.shared.stage(bundleID: bundleID, url: url)
}
func sendAppBundleAfc(_ bundleID: String, at url: URL) async throws {
    throw OperationError.invalidParameters("Apple TV installation requires a packaged tvOS IPA.")
}
func installIPA(_ bundleID: String) async throws { try await AppleTVManager.shared.install(bundleID: bundleID) }
func installAppBundle(_ bundleID: String, appName: String) async throws { try await installIPA(bundleID) }
func safeDebugApp(_ bundleID: String) async throws {
    throw OperationError.invalidParameters("Process debugging is not part of the Apple TV sideloading fork.")
}
