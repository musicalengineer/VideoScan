// FamilyGraphCompiledStore+App.swift
// The app's production store: VideoScanCore's layout + the app log.
//
// Remote viewer (docs/remote_use_design.md Phase 1): on a viewer the
// generation under family-tree/compiled/ was compiled on the master and
// arrived by verified sync, so the store trusts the synced manifest
// instead of re-hashing raw sources that live on the master's disk, and
// refuses every write (ingest / rollback / repoint). Read at each use, so
// the role installed at launch is what the tree loads with.
import Foundation
import VideoScanCore

extension FamilyGraphCompiledStore {
    static var app: FamilyGraphCompiledStore {
        var store = production
        store.log = { appLog.write($0) }
        let isViewer = ViewerModeCenter.shared.isViewer
        store.trustsManifestSources = isViewer
        store.refusesWrites = isViewer
        return store
    }
}
