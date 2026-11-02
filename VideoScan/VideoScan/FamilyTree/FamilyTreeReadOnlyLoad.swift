// FamilyTreeReadOnlyLoad.swift
// How the Family Tree loads in its read-only state (DECISIONS 2026-11-01):
// pure functions over the compiled store, called off the main actor by
// FamilyTreeLiveModel. They read only under the store's root and the
// person-refresh overlay file, and write nothing (FamilyTreeWriteGate.swift
// has the access matrix; the isolation tests prove the bytes).

import Foundation
import VideoScanCore

enum FamilyTreeReadOnlyLoad {
    /// Pure apart from reads under the compiled store's root and the
    /// overlay file. Nil graph = the only refusal left (no compiled tree,
    /// a corrupt one, or one built by another version).
    static func outcome(store: FamilyGraphCompiledStore?,
                        overlay: PersonFactOverlayStore?,
                        log: @escaping (String) -> Void) -> FamilyGraphFileLoader.Outcome {
        guard var store else {
            return FamilyGraphFileLoader.Outcome(graph: nil, selectedURL: nil, rejectedURLs: [], candidateCount: 0)
        }
        // The sources live on the absent archive: trust the manifest the
        // ingest verified (as a viewer does), and refuse every write.
        store.trustsManifestSources = true
        store.refusesWrites = true
        // `originalsDirectory` is never opened in promoted-only mode; it is
        // set to the store root so that stays true even if that changes.
        var loader = FamilyGraphFileLoader(originalsDirectory: store.root)
        loader.compiledStore = store
        loader.readOnly = true
        let outcome = loader.loadNewestOutcome()
        guard let graph = outcome.graph else { return outcome }
        let newestPull = store.loadCurrentManifest()?.sources.compactMap(\.modifiedAt).max()
        return outcome.replacingGraph(PersonRefreshOverlayReader.apply(
            to: graph, store: overlay, newestPullAt: newestPull, canWrite: false, log: log))
    }

    /// The viewer's copy of a store: trusts the synced manifest, refuses
    /// every write (the same flags `FamilyGraphCompiledStore.app` sets).
    static func refusingWrites(_ store: FamilyGraphCompiledStore?) -> FamilyGraphCompiledStore? {
        guard var store else { return nil }
        store.trustsManifestSources = true
        store.refusesWrites = true
        return store
    }
}
