//
//  BackgroundRefreshAppsOperation.swift
//  AltStore
//
//  Created by Riley Testut on 7/6/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import CoreData


final class BackgroundRefreshAppsOperation: BaseStandaloneOperation<OperationContext, [String: Result<InstalledApp, Error>]>, @unchecked Sendable {
    let installedApps: [InstalledApp]
    
    var presentsFinishedNotification: Bool = true
    var ignoresServerNotFoundError: Bool = true
    
    private let refreshIdentifier: String = UUID().uuidString
    
    init(installedApps: [InstalledApp], context: OperationContext) throws {
        self.installedApps = installedApps
        try super.init(context: context)
    }
    
    override func execute(parentProgress: Progress?) async throws -> [String: Result<InstalledApp, Error>] {
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        guard !installedApps.isEmpty else { throw OperationError.noInstalledApps }
        // iPhone Darwin notifications cannot describe processes on a remote TV.
        do {
            let results = try await refresh(installedApps)
            scheduleFinishedRefreshingNotification(for: .success(results), delay: 0)
            return results
        } catch {
            scheduleFinishedRefreshingNotification(for: .failure(error), delay: 0)
            throw error
        }
    }

    private func refresh(_ apps: [InstalledApp]) async throws -> [String: Result<InstalledApp, Error>] {
        return try await withCheckedThrowingContinuation { continuation in
            let group = AppManager.shared.refresh(apps, presentingViewController: nil)
            group.completionHandler = { (results) in
                self.setProgress(100)
                continuation.resume(returning: results)
            }
        }
    }
    
    private func scheduleFinishedRefreshingNotification(for result: Result<[String: Result<InstalledApp, Error>], Error>, delay: TimeInterval = 5) {
        func scheduleFinishedRefreshingNotification() {
            #if !os(tvOS)
            self.cancelFinishedRefreshingNotification()
            
            let content = UNMutableNotificationContent()
            
            var shouldPresentAlert = true
            
            do {
                let results = try result.get()
                shouldPresentAlert = !results.isEmpty
                
                for (_, result) in results {
                    guard case let .failure(error) = result else { continue }
                    throw error
                }
                
                content.title = NSLocalizedString("Refreshed Apps", comment: "")
                content.body = NSLocalizedString("All apps have been refreshed.", comment: "")
            } catch let opError as OperationError {
                switch opError {
                case .noConnection, .noInstalledApps:
                    shouldPresentAlert = false
                default:
                    self.debugLog("Failed to refresh apps in background: \(opError)")
                    content.title = NSLocalizedString("Failed to Refresh Apps", comment: "")
                    content.body = opError.localizedDescription
                    shouldPresentAlert = true
                }
            } catch {
                self.debugLog("Failed to refresh apps in background: \(error)")
                content.title = NSLocalizedString("Failed to Refresh Apps", comment: "")
                content.body = error.localizedDescription
                shouldPresentAlert = true
            }

            if shouldPresentAlert {
                // Using nil if delay == 0 fixes race condition where multiple notifications can appear (or none).
                let trigger = delay == 0 ? nil : UNTimeIntervalNotificationTrigger(timeInterval: delay + 1, repeats: false)
                
                let request = UNNotificationRequest(identifier: self.refreshIdentifier, content: content, trigger: trigger)
                UNUserNotificationCenter.current().add(request)
                
                if delay > 0 {
                    Task {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
                        // If app is still running at this point, we schedule another notification with same identifier.
                        // This prevents the currently scheduled notification from displaying, and starts another countdown timer.
                        // First though, make sure there _is_ still a pending request, otherwise it's been cancelled
                        // and we should stop polling.
                        guard requests.contains(where: { $0.identifier == self.refreshIdentifier }) else { return }
                        
                        scheduleFinishedRefreshingNotification()
                    }
                }
            }
            #else
            NotificationCenter.default.post(name: NSNotification.Name("TVTopShelfItemsDidChangeNotification"), object: nil)
            #endif
        }
        
        if self.presentsFinishedNotification {
            scheduleFinishedRefreshingNotification()
        }        
        
        // Perform synchronously to ensure app doesn't quit before we've finishing saving to disk.
        let dbContext = self.context.dbBackgroundContext
        let childContext = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        childContext.parent = dbContext
        childContext.performAndWait {
            self.saveRefreshAttempt(result: result, in: childContext)
        }
        dbContext.performAndWait {
            do { try dbContext.save() }
            catch { debugLog("Failed to save parent context for refresh attempt. \(error.localizedDescription)") }
        }
    }
    
    private func saveRefreshAttempt(result: Result<[String: Result<InstalledApp, Error>], Error>, in context: NSManagedObjectContext) {
        _ = RefreshAttempt(identifier: self.refreshIdentifier, result: result, context: context)
        
        do { try context.save() }
        catch { debugLog("Failed to save refresh attempt. \(error.localizedDescription)") }
    }
    
    private func cancelFinishedRefreshingNotification() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [self.refreshIdentifier])
    }
}
