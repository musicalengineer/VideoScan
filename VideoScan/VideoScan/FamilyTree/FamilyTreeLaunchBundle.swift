// FamilyTreeLaunchBundle.swift
// Everything the Family Tree tab installs, built OFF the main actor from
// one decoded graph (2026-08-29, launch-to-tree work on the 39k merged
// tree). The main-actor install then only assigns: no O(people) loop
// runs on the UI thread.
//
// The four parts are independent pure functions of (graph, speaker
// settings), so they build in parallel (`DispatchQueue.concurrentPerform`)
// and each is itself chunked over ordinals where it iterates people.
// A process-wide memo keyed by the shared cache's load token means the
// tab's second appearance — or a launch that was prewarmed — installs
// without rebuilding anything.
//
// C++ analogy: a struct of precomputed views over an immutable graph,
// plus a mutex-guarded single-entry memo keyed by (graph identity,
// settings).

import Foundation
import os
import VideoScanCore

struct FamilyTreeLaunchBundle: Sendable {
    let graph: GedcomFamilyGraph
    /// Everyone's sidebar summary in sidebar order.
    let rows: [FamilyTreePersonSummary]
    /// Group-photo attribution directory (tree + speaker settings).
    let identity: FamilyAssetIdentityDirectory
    /// The owner pin the anchors were computed with.
    let ownerFamilySearchID: String?
    let anchors: [FamilyTreeAnchor]
    let anchorsCaption: String?
    /// One upward BFS per anchor so a selection change is O(path).
    let anchorIndexes: [String: GedcomFamilyGraph.AncestorIndex]
    /// The sidebar's token / fuzzy name search over the same rows
    /// (2026-09-26). Built here so a keystroke never tokenizes a name.
    let search: FamilyTreeNameSearch

    /// Settings the bundle depends on besides the graph.
    struct Settings: Equatable, Sendable {
        let speakers: HallieTurnExecutor.Speakers
        let ownerFamilySearchID: String?

        /// Production: the archivist settings + the owner pin, both from
        /// UserDefaults.standard (thread-safe to read off the main actor).
        static func fromDefaults() -> Settings {
            Settings(speakers: .fromDefaults(),
                     ownerFamilySearchID: UserDefaults.standard.string(
                        forKey: HallieTurnExecutor.Speakers.ownerFamilySearchIDDefaultsKey))
        }
    }

    /// The four jobs' results while they build. Each job computes its part
    /// on its own thread and assigns it under the lock once (four lock
    /// acquisitions per build; the arrays are copy-on-write, so no part is
    /// deep-copied — memory is the same one bundle as before).
    private struct Partial: Sendable {
        var rows: [FamilyTreePersonSummary] = []
        var identity: FamilyAssetIdentityDirectory?
        var anchors: [FamilyTreeAnchor] = []
        var caption: String?
        var indexes: [String: GedcomFamilyGraph.AncestorIndex] = [:]
        var search: FamilyTreeNameSearch?
    }

    /// Build every part, in parallel. Pure; safe on any thread.
    ///
    /// Swift 6: the lock owns the partial result (C++: a mutex-guarded
    /// struct the worker threads fill), replacing the six nested
    /// `withUnsafeMutablePointer` slots a `@Sendable` closure may not capture.
    nonisolated static func build(graph: GedcomFamilyGraph, settings: Settings) -> FamilyTreeLaunchBundle {
        let partial = OSAllocatedUnfairLock(initialState: Partial())
        // Four independent jobs; each writes its own field only.
        DispatchQueue.concurrentPerform(iterations: 4) { job in
            switch job {
            case 0:
                let rows = FamilyTreeLiveModel.sidebarRows(of: graph)
                partial.withLock { $0.rows = rows }
            case 1:
                let identity = FamilyAssetIdentityDirectory(graph: graph, speakers: settings.speakers)
                partial.withLock { $0.identity = identity }
            case 2:
                let search = FamilyTreeNameSearch(graph: graph)
                partial.withLock { $0.search = search }
            default:
                let owner = settings.ownerFamilySearchID
                let found = FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: owner)
                let caption = FamilyTreeLiveModel.staleOwnerPinCaption(in: graph, ownerFamilySearchID: owner)
                // One BFS per anchor, themselves in parallel (2–4 anchors);
                // each lands in the dictionary under its own lock take.
                let built = OSAllocatedUnfairLock(initialState: [String: GedcomFamilyGraph.AncestorIndex]())
                DispatchQueue.concurrentPerform(iterations: found.count) { i in
                    let index = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: found[i].id)
                    built.withLock {
                        // Same fail-fast as the Dictionary(uniqueKeysWithValues:) this replaced.
                        precondition($0[found[i].id] == nil, "duplicate anchor id \(found[i].id)")
                        $0[found[i].id] = index
                    }
                }
                let indexes = built.withLock { $0 }
                partial.withLock {
                    $0.anchors = found
                    $0.caption = caption
                    $0.indexes = indexes
                }
            }
        }
        let parts = partial.withLock { $0 }
        return FamilyTreeLaunchBundle(graph: graph, rows: parts.rows, identity: parts.identity!,
                                      ownerFamilySearchID: settings.ownerFamilySearchID,
                                      anchors: parts.anchors, anchorsCaption: parts.caption,
                                      anchorIndexes: parts.indexes, search: parts.search!)
    }

    // MARK: Process-wide memo

    /// One bundle per (shared-cache load token, settings). The Family
    /// Tree tab and the launch prewarm share it; a new generation (new
    /// token) or changed settings rebuild. Never holds more than one.
    final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private let lock = NSLock()
        private var entry: (token: UUID, settings: Settings, bundle: FamilyTreeLaunchBundle)?
        private var buildCount = 0

        /// How many bundles were built (tests: prove the memo hit).
        var builds: Int { lock.withLock { buildCount } }

        /// The memoized bundle for `loaded`, building it when the token or
        /// settings differ. The lock is held across the build on purpose
        /// so two concurrent callers (prewarm + tab) build once.
        func bundle(for loaded: FamilyGraphSharedCache.Loaded, settings: Settings) -> FamilyTreeLaunchBundle {
            lock.withLock {
                if let entry, entry.token == loaded.token, entry.settings == settings { return entry.bundle }
                buildCount += 1
                let built = FamilyTreeLaunchBundle.build(graph: loaded.graph, settings: settings)
                entry = (loaded.token, settings, built)
                return built
            }
        }

        /// The bundle only if it is already built for this token + settings.
        func cached(token: UUID, settings: Settings) -> FamilyTreeLaunchBundle? {
            lock.withLock { entry.flatMap { $0.token == token && $0.settings == settings ? $0.bundle : nil } }
        }

        func invalidate() { lock.withLock { entry = nil } }
    }

    // MARK: Launch prewarm

    /// Decode the promoted artifact and build the bundle on a utility
    /// task right after launch, so the first Family Tree tab appearance
    /// (and Hallie's first question) find everything warm. Logs one line.
    /// Any later configuration change is a cache-key miss and reloads;
    /// nothing here is authoritative.
    static func prewarm(log: @escaping @Sendable (String) -> Void = { appLog.write($0) }) {
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let start = clock.now
            let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
            guard let loaded = FamilyGraphSharedCache.shared.load(for: configuration, store: .app) else {
                log("[family-tree] prewarm: no tree to load (\(configuration.access))")
                return
            }
            let decoded = clock.now
            let bundle = Cache.shared.bundle(for: loaded, settings: .fromDefaults())
            let ms = { (d: Duration) in Int((d / .milliseconds(1)).rounded()) }
            log("[family-tree] prewarm: graph \(loaded.reused ? "reused" : "loaded") in \(ms(decoded - start)) ms, "
                + "bundle in \(ms(clock.now - decoded)) ms (\(bundle.rows.count) people, \(bundle.anchors.count) anchors)")
        }
    }
}
