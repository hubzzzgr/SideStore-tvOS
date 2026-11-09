import UIKit
import SideSign

enum TVAppIcon {
    static func load(bundleURL: URL) -> UIImage? {
        guard let app = ALTApplication(fileURL: bundleURL) else { return nil }
        if let icon = app.icon { return icon }
        guard let bundle = Bundle(url: bundleURL) else { return nil }
        let info = app.infoPlist
        var names: [String] = []
        if let name = info["CFBundleIconName"] as? String { names.append(name) }
        if let name = info["CFBundleIconFile"] as? String { names.append(name) }
        if let files = info["CFBundleIconFiles"] as? [String] { names += files.reversed() }
        for key in ["CFBundleIcons~tv", "CFBundleIcons", "CFBundleIcons~ipad"] {
            guard let icons = info[key] as? [String: Any] else { continue }
            if let name = icons["CFBundlePrimaryIcon"] as? String { names.append(name) }
            if let primary = icons["CFBundlePrimaryIcon"] as? [String: Any] {
                if let name = primary["CFBundleIconName"] as? String { names.append(name) }
                if let files = primary["CFBundleIconFiles"] as? [String] { names += files.reversed() }
            }
        }
        names += ["App Icon - Small", "App Icon", "AppIcon", "AppIconSmall"]
        let tvTraits = UITraitCollection(traitsFrom: [UITraitCollection(userInterfaceIdiom: .tv), UITraitCollection(displayScale: 2)])
        for name in names {
            // Restrict plist-controlled names to the app bundle.
            guard !name.contains(".."), !name.hasPrefix("/") else { continue }
            if let icon = UIImage(named: name, in: bundle, compatibleWith: tvTraits)
                ?? UIImage(named: name, in: bundle, compatibleWith: nil) { return icon }
            for suffix in ["", ".png", "@2x.png", "@3x.png", ".lcr"] {
                if let icon = UIImage(contentsOfFile: bundleURL.appendingPathComponent(name + suffix).path) { return icon }
            }
        }
        return nil
    }
}
