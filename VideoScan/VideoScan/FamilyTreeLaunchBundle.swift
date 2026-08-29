// FamilyTreeLaunchBundle.swift
// Everything the Family Tree tab installs, built OFF the main actor from
// one decoded graph (2026-08-29, launch-to-tree work on the 39k merged
// tree). The main-actor install then only assigns: no O(people) loop
// runs on the UI thread.
//
// The three parts are independent pure functions of (graph, speaker
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

    /// Build every part, in parallel. Pure; safe on any thread.
    nonisolated static func build(graph: GedcomFamilyGraph, settings: Settings) -> FamilyTreeLaunchBundle {
        var rows: [FamilyTreePersonSummary] = []
        var identity: FamilyAssetIdentityDirectory?
        var anchors: [FamilyTreeAnchor] = []
        var caption: String?
        var indexes: [String: GedcomFamilyGraph.AncestorIndex] = [:]
        // Three independent jobs; each writes its own variable only.
        withUnsafeMutablePointer(to: &rows) { rowsOut in
            withUnsafeMutablePointer(to: &identity) { identityOut in
                withUnsafeMutablePointer(to: &anchors) { anchorsOut in
                    withUnsafeMutablePointer(to: &caption) { captionOut in
                        withUnsafeMutablePointer(to: &indexes) { indexesOut in
                            DispatchQueue.concurrentPerform(iterations: 3) { job in
                                switch job {
                                case 0:
                                    rowsOut.pointee = FamilyTreeLiveModel.sidebarRows(of: graph)
                                case 1:
                                    identityOut.pointee = FamilyAssetIdentityDirectory(graph: graph, speakers: settings.speakers)
                                default:
                                    let owner = settings.ownerFamilySearchID
                                    let found = FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: owner)
                                    anchorsOut.pointee = found
                                    captionOut.pointee = FamilyTreeLiveModel.staleOwnerPinCaption(in: graph, ownerFamilySearchID: owner)
                                    // One BFS per anchor, themselves in parallel (2–4 anchors).
                                    var built = [GedcomFamilyGraph.AncestorIndex?](repeating: nil, count: found.count)
                                    built.withUnsafeMutableBufferPointer { slots in
                                        DispatchQueue.concurrentPerform(iterations: found.count) { i in
                                            slots[i] = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: found[i].id)
                                        }
                                    }
                                    indexesOut.pointee = Dictionary(uniqueKeysWithValues: zip(found.map(\.id), built.map { $0! }))
                                }
                            }
                        }
                    }
                }
            }
        }
        return FamilyTreeLaunchBundle(graph: graph, rows: rows, identity: identity!,
                                      ownerFamilySearchID: settings.ownerFamilySearchID,
                                      anchors: anchors, anchorsCaption: caption, anchorIndexes: indexes)
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
    static func prewarm(log: @escaping (String) -> Void = { appLog.write($0) }) {
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
