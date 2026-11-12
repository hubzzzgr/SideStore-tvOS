//
//  DatabaseManager.swift
//  AltStore
//
//  Created by Riley Testut on 5/20/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData

import SideSign

extension CFNotificationName
{
    fileprivate static let willMigrateDatabase = CFNotificationName("com.rileytestut.AltStore.WillMigrateDatabase" as CFString)
}

private let ReceivedWillMigrateDatabaseNotification: @convention(c) (CFNotificationCenter?, UnsafeMutableRawPointer?, CFNotificationName?, UnsafeRawPointer?, CFDictionary?) -> Void = { (center, observer, name, object, userInfo) in
    DatabaseManager.shared.receivedWillMigrateDatabaseNotification()
}

public class DatabaseManager: @unchecked Sendable
{
    public static private(set) var shared = DatabaseManager()
    
    public let persistentContainer: PersistentContainer
    
    private let lock = NSLock()
    private var _isStarted = false
    public var isStarted: Bool {
        self.lock.withLock { self._isStarted }
    }
    
    private var startTask: Task<Void, Error>?
    
    private let coordinator = NSFileCoordinator()
    private let coordinatorQueue = OperationQueue()
    
    private var ignoreWillMigrateDatabaseNotification = false

    private init()
    {
        self.persistentContainer = PersistentContainer(name: AppConstants.Database.name, bundle: Bundle(for: DatabaseManager.self))
        self.persistentContainer.preferredMergePolicy = MergePolicy()
        
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), observer, ReceivedWillMigrateDatabaseNotification, CFNotificationName.willMigrateDatabase.rawValue, nil, .deliverImmediately)
    }
    
    public class func deleteDatabase() -> Bool
    {
        // delete existing database and start fresh if required
        do {
            let container = Self.shared.persistentContainer
            
            var databaseStore = container.persistentStoreCoordinator.persistentStores.first
            let databaseStoreURL = databaseStore?.url ?? PersistentContainer.defaultDirectoryURL().appendingPathComponent(AppConstants.Database.fileName)
            
            // Reset the managed object context
            Self.shared.persistentContainer.viewContext.reset()

            // Remove all existing persistent stores
            for store in Self.shared.persistentContainer.persistentStoreCoordinator.persistentStores {
                try? Self.shared.persistentContainer.persistentStoreCoordinator.remove(store)
            }

            // Now destroy the persistent store
            if FileManager.default.fileExists(atPath: databaseStoreURL.path) {
                try Self.shared.persistentContainer.persistentStoreCoordinator.destroyPersistentStore(
                    at: databaseStoreURL,
                    ofType: NSSQLiteStoreType,
                    options: nil
                )
                try? FileManager.default.removeItem(at: databaseStoreURL)
            }
                
            debugLog("\nDatabase Delete: SUCCEEDED\n")
            return true
        } catch {
            debugLog("\nDatabase Delete request FAILED: \(error)\n")
            return false
        }
    }
    
    public class func recreateDatabase() {
        // Try to perform delete if one exists
        _ = Self.deleteDatabase()
        
        // create new instance and load persistence store
        Self.shared = DatabaseManager()
    }

    public func start() async throws
    {
        if self.isStarted { return }
        
        let task = self.lock.withLock {
            if let startTask { return startTask }
            let task = Task<Void, Error>.detached(priority: .userInitiated) { try await self.performStart() }
            self.startTask = task
            return task
        }
        
        do {
            try await task.value
            self.lock.withLock { self._isStarted = true }
        } catch {
            self.lock.withLock { self.startTask = nil }
            throw error
        }
    }


    private func performStart() async throws
    {
        if self.persistentContainer.isMigrationRequired
        {
            // Quit any other running AltStore processes to prevent concurrent database access during and after migration.
            self.ignoreWillMigrateDatabaseNotification = true
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), .willMigrateDatabase, nil, nil, true)
        }

        try await self.persistentContainer.loadPersistentStores()
        try await self.prepareDatabase()
    }

    public func purgeLoggedErrors(before date: Date? = nil) async throws
    {
        try await self.persistentContainer.performBackgroundTask { context in
            let predicate = date.map { NSPredicate(format: "%K <= %@", #keyPath(LoggedError.date), $0 as NSDate) }
            let loggedErrors = LoggedError.all(satisfying: predicate, in: context, requestProperties: [\.returnsObjectsAsFaults: true])
            loggedErrors.forEach { context.delete($0) }
            try context.save()
        }
    }

    
    public func updateFeaturedSortIDs() async
    {
        let context = DatabaseManager.shared.persistentContainer.newBackgroundContext()
        context.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy // DON'T use our custom merge policy, because that one ignores changes to featuredSortID.
        await context.performAsync {
            do
            {
                // Randomize source order
                let fetchRequest = Source.fetchRequest()
                let sources = try context.fetch(fetchRequest)
                
                for source in sources
                {
                    source.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                debugLog("Failed to update source order. \(error.localizedDescription)")
            }
            
            do
            {
                // Randomize app order
                let fetchRequest = StoreApp.fetchRequest()
                let apps = try context.fetch(fetchRequest)
                
                for app in apps
                {
                    app.featuredSortID = UUID().uuidString
                }
                
                try context.save()
            }
            catch
            {
                debugLog("Failed to update app order. \(error.localizedDescription)")
            }
        }
    }


    public var viewContext: NSManagedObjectContext {
        return self.persistentContainer.viewContext
    }
    
    public func activeAccount(in context: NSManagedObjectContext) -> Account?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Account.isActiveAccount))
        
        let activeAccount = Account.first(satisfying: predicate, in: context)
        return activeAccount
    }
    
    public func activeTeam(in context: NSManagedObjectContext) -> Team?
    {
        let predicate = NSPredicate(format: "%K == YES", #keyPath(Team.isActiveTeam))
        
        let activeTeam = Team.first(satisfying: predicate, in: context)
        return activeTeam
    }

    private func prepareDatabase() async throws
    {
        guard !Bundle.isAppExtension() else { return }
        
        let context = self.persistentContainer.newBackgroundContext()
        try await context.perform {
            // The old library keeps its files in place; only ownership is migrated.
            let legacyOwner = ["AppleTV.managedTarget", "AppleTV.selected"].compactMap {
                UserDefaults.standard.string(forKey: $0).flatMap(UUID.init(uuidString:))?.uuidString
            }.first ?? TVLibrary.unassignedIdentifier
            for app in try InstalledApp.allLibraries(in: context) where app.libraryIdentifier == nil {
                app.libraryIdentifier = legacyOwner
            }
            if UserDefaults.standard.string(forKey: "AppleTV.legacyLibrary") == nil {
                UserDefaults.standard.set(legacyOwner, forKey: "AppleTV.legacyLibrary")
            }
            let source = Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), Source.altStoreIdentifier), in: context)
                ?? Source.first(satisfying: NSPredicate(format: "%K == %@", #keyPath(Source.identifier), "sidestore.io/apps-v2.json"), in: context)
                ?? Source.makeAltStoreSource(in: context)
            try source.setSourceURL(Source.altStoreSourceURL)
            let predicate = NSPredicate(format: "%K == %@", #keyPath(InstalledApp.bundleIdentifier), StoreApp.altstoreAppID)
            for oldController in InstalledApp.all(satisfying: predicate, in: context) { context.delete(oldController) }
            try context.save()
            UserDefaults.standard.removeObject(forKey: "AppleTV.managedTarget")
        }
        
        await self.updateFeaturedSortIDs()
    }
    
    private func reconcileSelfFromSelfBinary(installedApp: InstalledApp, localAppBundle: ALTApplication, serialNumber: String?) {
        debugLog("[DatabaseManager] reconcileSelfFromSelfBinary: Started for '\(localAppBundle.name)' (\(localAppBundle.bundleIdentifier)).")
        var binaryCertSerial: String? = nil
        defer {
            debugLog("""
            [DatabaseManager] reconcileSelfFromSelfBinary: Completed
              • name: '\(installedApp.name)'
              • bundleID: '\(installedApp.bundleIdentifier)'
              • version: '\(installedApp.version)'
              • buildVersion: '\(installedApp.buildVersion)'
              • refreshedDate: \(installedApp.refreshedDate)
              • expirationDate: \(installedApp.expirationDate)
              • installCertSerial: '\(installedApp.certificateSerialNumber ?? "nil")'
              • binaryCertSerial: '\(binaryCertSerial ?? "nil")'
              • binaryCertStatus: \(installedApp.certificateStatus)
            
            """)
        }
        
        installedApp.name = localAppBundle.name
        installedApp.resignedBundleIdentifier = localAppBundle.bundleIdentifier
        installedApp.version = localAppBundle.version
        installedApp.buildVersion = localAppBundle.buildVersion
        
        var status: CertificateStatus = .valid(isCrossSigned: false)
        if let binaryCert = CertificateManager.shared.getSigningCertificate(at: localAppBundle.fileURL) {
            binaryCertSerial = binaryCert.serialNumber
            CertificateManager.shared.saveX509Certificate(binaryCert)
            if binaryCert.expiryDate <= Date() {
                status = .expired
            }
        }
        
        let effectiveSerial = binaryCertSerial ?? serialNumber
        installedApp.certificateSerialNumber = effectiveSerial
        
        let activeKeychainSerial = CertificateManager.shared.activeCertificate?.serialNumber
        let isCross = (activeKeychainSerial != nil && !activeKeychainSerial!.isEmpty && effectiveSerial != nil && effectiveSerial != activeKeychainSerial)
        if case .valid = status {
            status = .valid(isCrossSigned: isCross)
        }
        installedApp.certificateStatus = status
        
        if let provisioningProfile = localAppBundle.provisioningProfile {
            installedApp.refreshedDate = provisioningProfile.creationDate
            installedApp.expirationDate = provisioningProfile.expirationDate
        }
    }
    
    fileprivate func receivedWillMigrateDatabaseNotification()
    {
        defer { self.ignoreWillMigrateDatabaseNotification = false }

        // Ignore notifications sent by the current process.
        guard !self.ignoreWillMigrateDatabaseNotification else { return }

        exit(104)
    }
}
