import Foundation

/// A selected developer-paired TV supplies only an address hint. The transfer
/// port is supplied for this session; separate TLS pins authenticate TVContainer.
struct TVContainerDevice: Identifiable {
    let pairingID: UUID
    let name: String
    let port: UInt16
    var id: String { "TVContainer.paired:\(pairingID.uuidString)" }
    var aliases: Set<String> { [id] }
}
