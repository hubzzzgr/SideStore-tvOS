//
//  SendAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 6/7/19.
//  Copyright © 2019 Riley Testut. All rights reserved.
//

@preconcurrency import UIKit
import Foundation
import Network
import SideSign
import TVPairCore

final class SendAppOperation: BasePipelineOperation<InstallAppOperationContext, ALTApplication>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> ALTApplication {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[SendAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[SendAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        self.setProgress(10)

        guard let resignedAppBundle = self.context.resignedAppBundle else {
            throw OperationError.invalidParameters("SendAppOperation.main: self.resignedAppBundle is nil")
        }

        let bundleIdentifier = self.context.targetBundleIdentifier
        guard let ipaURL = self.context.ipaURL else {
            throw OperationError.invalidParameters("The signed tvOS IPA has not been packaged.")
        }
        try await AppleTVManager.shared.stage(bundleID: bundleIdentifier, url: ipaURL) { event in
            if self.isCancelled || Task.isCancelled { throw CancellationError() }
            switch event {
            case let .uploading(completed, total):
                self.setProgress(10 + Int64(Double(completed) / Double(max(total, 1)) * 80))
            case .closingFile: self.setProgress(95)
            default: break
            }
        }
        self.setProgress(100)
        return resignedAppBundle
    }
}
