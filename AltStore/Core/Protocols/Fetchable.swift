//
//  NSManagedObject+Conveniences.swift
//  AltStore
//
//  Created by Riley Testut on 6/6/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

import CoreData

public typealias FetchRequest = NSFetchRequest<NSFetchRequestResult>

public protocol Fetchable: NSManagedObject
{
    static var fetchScopePredicate: NSPredicate? { get }
}

public extension Fetchable
{
    static var fetchScopePredicate: NSPredicate? { nil }

    private static func scoped(_ predicate: NSPredicate?) -> NSPredicate? {
        guard let scope = Self.fetchScopePredicate else { return predicate }
        return predicate.map { NSCompoundPredicate(andPredicateWithSubpredicates: [scope, $0]) } ?? scope
    }
    static func first(satisfying predicate: NSPredicate? = nil, sortedBy sortDescriptors: [NSSortDescriptor]? = nil, in context: NSManagedObjectContext,
                      requestProperties: [PartialKeyPath<FetchRequest>: Any?] = [:]) -> Self?
    {
        let managedObjects = Self.all(satisfying: predicate, sortedBy: sortDescriptors, in: context, requestProperties: requestProperties, returnFirstResult: true)
        return managedObjects.first
    }
    
    static func all(satisfying predicate: NSPredicate? = nil, sortedBy sortDescriptors: [NSSortDescriptor]? = nil, in context: NSManagedObjectContext,
                    requestProperties: [PartialKeyPath<FetchRequest>: Any?] = [:]) -> [Self]
    {
        let managedObjects = Self.all(satisfying: predicate, sortedBy: sortDescriptors, in: context, requestProperties: requestProperties, returnFirstResult: false)
        return managedObjects
    }
    
    static func fetch(_ fetchRequest: NSFetchRequest<Self>, in context: NSManagedObjectContext) -> [Self]
    {
        fetchRequest.predicate = Self.scoped(fetchRequest.predicate)
        do
        {
            let managedObjects = try context.fetch(fetchRequest)
            return managedObjects
        }
        catch
        {
            debugLog("Failed to fetch managed objects. Fetch Request: \(fetchRequest). Error: \(error).")
            return []
        }
    }
    
    private static func all(satisfying predicate: NSPredicate? = nil, sortedBy sortDescriptors: [NSSortDescriptor]? = nil, in context: NSManagedObjectContext, requestProperties: [PartialKeyPath<FetchRequest>: Any?], returnFirstResult: Bool) -> [Self]
    {
        let predicate = Self.scoped(predicate)
        var result: [Self] = []
        context.performAndWait {
            let registeredObjects = context.registeredObjects.lazy.compactMap({ $0 as? Self }).filter({ predicate?.evaluate(with: $0) != false })
            
            if let managedObject = registeredObjects.first, returnFirstResult
            {
                result = [managedObject]
                return
            }
            
            let fetchRequest = self.fetchRequest() as! NSFetchRequest<Self>
            fetchRequest.predicate = predicate
            fetchRequest.sortDescriptors = sortDescriptors
            fetchRequest.returnsObjectsAsFaults = false
            
            for (keyPath, value) in requestProperties
            {
                // Still no easy way to cast PartialKeyPath back to usable WritableKeyPath :(
                guard let objcKeyString = keyPath._kvcKeyPathString else { continue }
                fetchRequest.setValue(value, forKey: objcKeyString)
            }
            
            let fetchedObjects = self.fetch(fetchRequest, in: context)
            
            if let fetchedObject = fetchedObjects.first, returnFirstResult
            {
                result = [fetchedObject]
            }
            else
            {
                result = fetchedObjects
            }
        }
        return result
    }
}
