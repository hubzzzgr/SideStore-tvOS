import UIKit
@MainActor public enum ExportPairingFileHandler {
    public static func handle(urlname: String) {
        // Never export private pairing keys in callback URLs or logs.
        guard let controller = UIApplication.shared.topViewController() else { return }
        Task { await AppBootManager.shared.promptForPairing(on: controller) }
    }
}
