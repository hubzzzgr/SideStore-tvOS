import Foundation
import TVPairCore

/// Foundation publishes on the main run loop. Its lifecycle is independent of
/// the HTTP socket, including when a container host blocks service registration.
@MainActor
final class TVContainerBonjourAdvertiser: NSObject, @preconcurrency NetServiceDelegate {
    private var service: NetService?
    private var report: ((String?) -> Void)?

    func start(port: Int32, report: @escaping (String?) -> Void) {
        stop()
        self.report = report
        let service = NetService(domain: "local.", type: TVContainerHTTP.serviceType + ".", name: "SideTVstore", port: port)
        service.delegate = self
        service.setTXTRecord(NetService.data(fromTXTRecord: [
            "api": "1", "path": "/v1/files", "protocol": "http", "app": "SideTVstore"
        ].mapValues { Data($0.utf8) }))
        self.service = service
        service.publish()
    }
    func stop() {
        service?.delegate = nil
        service?.stop()
        service = nil; report = nil
    }
    func netServiceDidPublish(_ sender: NetService) {
        guard sender === service else { return }
        report?(nil)
    }
    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        guard sender === service else { return }
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        let domain = errorDict[NetService.errorDomain]?.intValue ?? 0
        report?("The file server is running at the address above, but Bonjour discovery could not publish (domain \(domain), code \(code)). In LiveContainer, local-network permission alone may not cover the custom service. Its host must allow _sidetvstore._tcp in NSBonjourServices. Use the LAN address in TVContainer, or update the host's service declarations for automatic discovery.")
    }
}
