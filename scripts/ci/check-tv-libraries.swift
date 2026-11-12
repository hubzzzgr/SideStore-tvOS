import Foundation
import CoreData

func debugLog(_ message: @autoclosure () -> String) { print(message()) }

private class ScopeBase: NSManagedObject, Fetchable {
    class var fetchScopePredicate: NSPredicate? { nil }
}
@objc(LibraryTestInstalledApp) private class LibraryTestInstalledApp: ScopeBase {
    override class var fetchScopePredicate: NSPredicate? { TVLibrary.predicate() }
    @nonobjc class func fetchRequest() -> NSFetchRequest<LibraryTestInstalledApp> {
        NSFetchRequest<LibraryTestInstalledApp>(entityName: "InstalledApp")
    }
}

@main struct LibraryChecks {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw NSError(domain: "LibraryChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func model(_ path: String) throws -> NSManagedObjectModel {
        guard let model = NSManagedObjectModel(contentsOf: URL(fileURLWithPath: path)) else { throw CocoaError(.fileReadCorruptFile) }
        // Check the real model schemas without loading iOS managed-object subclasses on macOS.
        model.entities.forEach { $0.managedObjectClassName = "NSManagedObject" }
        return model
    }
    static func insert(_ name: String, context: NSManagedObjectContext) -> NSManagedObject {
        let object = NSEntityDescription.insertNewObject(forEntityName: name, into: context)
        for (key, attribute) in object.entity.attributesByName where !attribute.isOptional && attribute.defaultValue == nil && !attribute.isTransient {
            switch attribute.attributeType {
            case .stringAttributeType: object.setValue(UUID().uuidString, forKey: key)
            case .dateAttributeType: object.setValue(Date(), forKey: key)
            case .URIAttributeType: object.setValue(URL(string: "https://example.invalid/fixture")! as NSURL, forKey: key)
            case .UUIDAttributeType: object.setValue(UUID(), forKey: key)
            case .decimalAttributeType: object.setValue(NSDecimalNumber.zero, forKey: key)
            case .binaryDataAttributeType: object.setValue(Data(), forKey: key)
            case .transformableAttributeType: object.setValue(NSArray(), forKey: key)
            case .integer16AttributeType, .integer32AttributeType, .integer64AttributeType,
                 .doubleAttributeType, .floatAttributeType, .booleanAttributeType:
                object.setValue(0, forKey: key)
            default: preconditionFailure("Unsupported fixture attribute: \(name).\(key)")
            }
        }
        return object
    }
    static func main() throws {
        let old = try model(CommandLine.arguments[1]), new = try model(CommandLine.arguments[2])
        ValueTransformer.setValueTransformer(NSSecureUnarchiveFromDataTransformer(), forName: NSValueTransformerName("ALTSecureValueTransformer"))
        new.entitiesByName["InstalledApp"]?.managedObjectClassName = NSStringFromClass(LibraryTestInstalledApp.self)
        let folder = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        let original = folder.appendingPathComponent("old.sqlite"), migrated = folder.appendingPathComponent("new.sqlite")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let store = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: original)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let legacy = insert("InstalledApp", context: oldContext)
        legacy.setValue("com.example.app", forKey: "bundleIdentifier")
        legacy.setValue("com.example.app.team", forKey: "resignedBundleIdentifier")
        let catalogApp = insert("StoreApp", context: oldContext), track = insert("ReleaseTrack", context: oldContext)
        legacy.setValue(catalogApp, forKey: "storeApp"); legacy.setValue(track, forKey: "releaseTrack")
        try oldContext.save()
        oldContext.reset(); try oldCoordinator.remove(store)
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: new)
        try NSMigrationManager(sourceModel: old, destinationModel: new).migrateStore(from: original, sourceType: NSSQLiteStoreType,
            options: nil, with: mapping, toDestinationURL: migrated, destinationType: NSSQLiteStoreType, destinationOptions: nil)

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: new)
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: migrated)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); context.persistentStoreCoordinator = coordinator
        let apps = try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "InstalledApp"))
        try require(apps.count == 1, "Migration lost the original app")
        let first = apps[0], tvA = UUID().uuidString, tvB = UUID().uuidString
        try require(first.value(forKey: "usesLegacyStorage") as? Bool == true, "Legacy files must remain in place")
        first.setValue(tvA, forKey: "libraryIdentifier")
        let source = first.value(forKey: "storeApp") as! NSManagedObject
        let release = first.value(forKey: "releaseTrack") as! NSManagedObject
        let second = insert("InstalledApp", context: context)
        for key in ["bundleIdentifier", "resignedBundleIdentifier"] { second.setValue(first.value(forKey: key), forKey: key) }
        second.setValue(tvB, forKey: "libraryIdentifier"); second.setValue(false, forKey: "usesLegacyStorage")
        second.setValue(source, forKey: "storeApp"); second.setValue(release, forKey: "releaseTrack")
        try context.save()
        try require((source.value(forKey: "installedApps") as? NSSet)?.count == 2, "Source relation detached another TV")
        try require((release.value(forKey: "installedApps") as? NSSet)?.count == 2, "Release-track relation detached another TV")
        for id in [tvA, tvB] {
            UserDefaults.standard.set(id, forKey: "AppleTV.selected")
            let request = NSFetchRequest<NSManagedObject>(entityName: "InstalledApp"); request.predicate = TVLibrary.predicate()
            let records = try context.fetch(request)
            try require(records.count == 1 && records[0].value(forKey: "libraryIdentifier") as? String == id, "Library fetch crossed TVs")
            let scoped = LibraryTestInstalledApp.all(in: context)
            try require(scoped.count == 1 && scoped[0].value(forKey: "libraryIdentifier") as? String == id, "Generic fetch helper crossed TVs")
            let match = LibraryTestInstalledApp.first(satisfying: NSPredicate(format: "resignedBundleIdentifier == %@", "com.example.app.team"), in: context)
            try require(match?.value(forKey: "libraryIdentifier") as? String == id, "Registered-object lookup crossed TVs")
        }
        context.delete(second); try context.save()
        let remaining = try context.count(for: NSFetchRequest<NSManagedObject>(entityName: "InstalledApp"))
        try require(remaining == 1, "Removing one TV's app deleted another")
        let root = folder.appendingPathComponent("Apps")
        try require(TVLibrary.directory(in: root, library: tvA, bundleID: "app") != TVLibrary.directory(in: root, library: tvB, bundleID: "app"), "Cache paths collide")
        try require(TVLibrary.directory(in: root, library: nil, bundleID: "app") == root.appendingPathComponent("app"), "Legacy cache path changed")
        print("PASS: legacy migration, duplicate app across TVs, shared catalog/track, scoped fetches, isolated deletion and cache paths")
    }
}
