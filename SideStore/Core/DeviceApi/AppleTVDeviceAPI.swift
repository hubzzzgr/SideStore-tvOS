import Foundation
import Combine
import TVPairCore

// Compatibility entry points keep SideStore's signing and operation pipeline.
// Every device action is routed to the selected, authenticated Apple TV.
public func ensureAppleTVReady() async throws { _ = try await AppleTVManager.shared.ready() }
public func isAppleTVReady() async -> Result<Bool, Error> {
    do { try await ensureAppleTVReady(); return .success(true) }
    catch { return .failure(error) }
}
@MainActor var appleTVStatusPublisher: AnyPublisher<Result<Bool, Error>, Never> {
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
func safeDebugApp(_ bundleID: String) async throws {
    throw OperationError.invalidParameters("Process debugging is not part of the Apple TV sideloading fork.")
}
