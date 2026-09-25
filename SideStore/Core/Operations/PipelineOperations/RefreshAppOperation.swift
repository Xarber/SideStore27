//
//  RefreshAppOperation.swift
//  AltStore
//
//  Created by Riley Testut on 2/27/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation
import CoreData
import SideSign

final class RefreshAppOperation: BasePipelineOperation<InstallAppOperationContext, InstalledApp>, @unchecked Sendable {
    
    override func execute(parentProgress: Progress?) async throws -> InstalledApp {
        let startTime = CFAbsoluteTimeGetCurrent()
        debugLog("[RefreshAppOperation] execute() started")
        defer {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            debugLog("[RefreshAppOperation] execute() took: \(String(format: "%.3fs", elapsed))")
        }
        try await super.executePreconditionCheck(parentProgress: parentProgress)
        
        guard let profiles = self.context.provisioningProfiles else {
            throw OperationError.invalidParameters("RefreshAppOperation.execute: self.context.provisioningProfiles is nil")
        }
        
        guard let appBundle = self.context.targetAppBundle else {
            throw OperationError.invalidParameters("RefreshAppOperation: context.targetAppBundle is nil")
        }
        self.setProgress(10)
        
        if self.context.isCellularRefreshGroup {
            debugLog("[RefreshAppOperation] Queueing \(self.context.bundleIdentifier) into batch profile injection (isCellularRefreshGroup = true)")
            self.context.sharedContext.addPendingProfileBatch(PendingProfileBatch(
                bundleID: self.context.bundleIdentifier,
                profiles: profiles.values.map { $0.data },
                app: self.context.installedApp,
                certStatus: self.context.targetCertStatus
            ))
            self.setProgress(85)
            guard let app = self.context.installedApp else {
                throw OperationError.invalidParameters("RefreshAppOperation: context.installedApp is nil")
            }
            return app
        }
        
        do {
            let target = DeviceOperationScope.target
            if target.kind == .local { await CellularRefreshManager.shared.turnOffDataIfNeeded() }
            try await DeviceOperationSession.run(target: target) {
                for profile in profiles.values {
                    try await installProvisioningProfiles(profile.data)
                }
            }
            if target.kind == .local { await CellularRefreshManager.shared.turnOnDataIfNeeded() }
        } catch {
            if DeviceOperationScope.target.kind == .local {
                await CellularRefreshManager.shared.turnOnDataIfNeeded()
            }
            throw error
        }
        
        self.setProgress(80)
        let dbContext = self.context.dbBackgroundContext
        let isLocalTarget = DeviceOperationScope.target.kind == .local
        
        let installedApp = try await dbContext.perform {
            try self.updateInstalledApp(for: appBundle, profiles: profiles,
                                        updateLocalRecord: isLocalTarget, in: dbContext)
        }
        
        self.setProgress(100)
        return installedApp
    }
    
    private func updateInstalledApp(for appBundle: ALTApplication, profiles: [String: ALTProvisioningProfile], updateLocalRecord: Bool, in dbContext: NSManagedObjectContext) throws -> InstalledApp {
        self.setProgress(self.progress.completedUnitCount + 1)
        
        guard let mainApp = self.context.installedApp,
              let installedApp = dbContext.object(with: mainApp.objectID) as? InstalledApp else {
            throw OperationError.invalidParameters("Could not find installed database record for '\(appBundle.name)'")
        }
        // The record belongs to this SideStore installation. Remote expiry and
        // active state are read from the selected device's profiles instead.
        guard updateLocalRecord else { return installedApp }
        installedApp.update(provisioningProfile: profiles.values.first!)
        
        if let certStatus = self.context.targetCertStatus {
            installedApp.certificateStatus = certStatus
        }

        for installedExtension in installedApp.appExtensions {
            guard let provisioningProfile = profiles[installedExtension.bundleIdentifier] else { continue }
            installedExtension.update(provisioningProfile: provisioningProfile)
        }
        return installedApp
    }
}
