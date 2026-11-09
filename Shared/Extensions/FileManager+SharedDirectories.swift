//
//  FileManager+SharedDirectories.swift
//  AltStore
//
//  Created by Riley Testut on 5/14/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation

public extension FileManager
{
    var altstoreSharedDirectory: URL? {
        #if os(tvOS)
        return self.cachesDirectory
        #else
        // This fork has one iPhone controller and no helper/widget targets.
        // Keep its library in the sandbox without requiring an App Group.
        let directory = self.applicationSupportDirectory.appendingPathComponent("SideStoreTV", isDirectory: true)
        do {
            try self.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
        #endif
    }
    
    var appBackupsDirectory: URL? {
        let appBackupsDirectory = self.altstoreSharedDirectory?.appendingPathComponent("Backups", isDirectory: true)
        return appBackupsDirectory
    }
    
    func backupDirectoryURL(forBundleIdentifier bundleIdentifier: String) -> URL?
    {
        let backupDirectoryURL = self.appBackupsDirectory?.appendingPathComponent(bundleIdentifier, isDirectory: true)
        return backupDirectoryURL
    }
    
    func deleteBackup(forBundleIdentifier bundleIdentifier: String) throws
    {
        debugLog("[FileManager] deleteBackup() started for \(bundleIdentifier)")
        defer { debugLog("[FileManager] deleteBackup() completed for \(bundleIdentifier)") }
        
        guard let backupDirectoryURL = self.backupDirectoryURL(forBundleIdentifier: bundleIdentifier) else {
            debugLog("[FileManager] deleteBackup: Failed to construct backup directory URL for \(bundleIdentifier)")
            return
        }
        
        guard self.fileExists(atPath: backupDirectoryURL.path) else {
            debugLog("[FileManager] deleteBackup: No backup directory exists at \(backupDirectoryURL.path)")
            return
        }
        
        try self.removeItem(at: backupDirectoryURL)
        debugLog("[FileManager] Successfully deleted backup directory for \(bundleIdentifier) at \(backupDirectoryURL.path)")
    }
}
