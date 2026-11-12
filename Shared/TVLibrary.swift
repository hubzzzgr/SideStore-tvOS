import Foundation
import CoreData

/// A pairing UUID, never a device UDID. Missing selection has its own empty library.
public enum TVLibrary {
    public static let unassignedIdentifier = "00000000-0000-0000-0000-000000000000"
    public static let didChange = Notification.Name("SideTVstore.libraryDidChange")

    public static var currentIdentifier: String {
        UserDefaults.standard.string(forKey: "AppleTV.selected")
            .flatMap(UUID.init(uuidString:))?.uuidString ?? unassignedIdentifier
    }

    public static func predicate(_ additional: NSPredicate? = nil) -> NSPredicate {
        let owner = NSPredicate(format: "libraryIdentifier == %@", currentIdentifier)
        return additional.map { NSCompoundPredicate(andPredicateWithSubpredicates: [owner, $0]) } ?? owner
    }

    public static func directory(in root: URL, library: String?, bundleID: String) -> URL {
        let base = library.flatMap(UUID.init(uuidString:)).map {
            root.appendingPathComponent("Libraries", isDirectory: true).appendingPathComponent($0.uuidString, isDirectory: true)
        } ?? root
        return base.appendingPathComponent(bundleID)
    }
}
