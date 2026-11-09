import Foundation
import UIKit
import SwiftUI

public final class AppBootManager: @unchecked Sendable {
    public static let shared = AppBootManager()
    private let lock = NSLock()
    private var pairingPrompt = false
    public var needsPairingPrompt: Bool {
        get { lock.withLock { pairingPrompt } }
        set { lock.withLock { pairingPrompt = newValue } }
    }
    public var needsSideJITPrompt: Bool { get { false } set {} }
    private init() {}
    public func performBootSequence() async {
        do {
            try await AppleTVManager.shared.load()
            if await AppleTVManager.shared.selectedID == nil { needsPairingPrompt = true; return }
            _ = try await AppleTVManager.shared.ready(force: true)
        } catch {
            debugLog("[AppleTV] Startup connection unavailable; saved trust retained.")
        }
    }
    @MainActor public func promptForPairing(on controller: UIViewController) async {
        needsPairingPrompt = false
        let view = NavigationStack { AppleTVSetupView().toolbar {
            ToolbarItem(placement: .confirmationAction) {
                SwiftUI.Button("Done") { controller.dismiss(animated: true) }
            }
        } }
        controller.present(UIHostingController(rootView: view), animated: true)
    }
}
