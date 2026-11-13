import Foundation
import Network
import Combine

struct TVContainerDevice: Identifiable {
    let id: String
    let endpoint: NWEndpoint
    let name: String
    let appVersion: String
    let protocolVersion: String
    var supported: Bool { protocolVersion == "1" }
    var aliases: Set<String> { [id] }
}

@MainActor
final class TVContainerDiscovery: ObservableObject {
    @Published private(set) var devices: [TVContainerDevice] = []
    @Published private(set) var issue: String?
    private var browser: NWBrowser?
    private var generation = UUID()

    func start() {
        stop()
        issue = nil
        let generation = UUID(); self.generation = generation
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        parameters.prohibitedInterfaceTypes = [.cellular]
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_tvcontainer._tcp", domain: "local."), using: parameters)
        self.browser = browser
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.devices = results.map { result in
                    func text(_ key: String) -> String {
                        guard case let .bonjour(record) = result.metadata else { return "" }
                        let value: String
                        switch record.getEntry(for: key) {
                        case let .string(string): value = string
                        default: value = ""
                        }
                        // Protocol acceptance must be exact; display sanitization
                        // must not turn malformed "1\n" metadata into version 1.
                        if key == "protocol" { return value }
                        return String(String.UnicodeScalarView(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(200)))
                    }
                    let fallback: String
                    if case let .service(name, _, _, _) = result.endpoint { fallback = name } else { fallback = "Apple TV" }
                    let advertised = text("deviceName")
                    return TVContainerDevice(id: String(describing: result.endpoint), endpoint: result.endpoint,
                        name: advertised.isEmpty ? fallback : advertised, appVersion: text("appVersion"), protocolVersion: text("protocol"))
                }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch state {
                case let .failed(error), let .waiting(error):
                    self.devices = []
                    self.issue = "Discovery is unavailable (\(error)). Allow Local Network access in iPhone Settings. In LiveContainer, the host must also declare _tvcontainer._tcp in NSBonjourServices; the guest's settings alone cannot grant this access."
                case .ready: self.issue = nil
                default: break
                }
            }
        }
        browser.start(queue: .main)
    }

    func stop() {
        generation = UUID()
        browser?.cancel(); browser = nil
        devices = []
    }
}
