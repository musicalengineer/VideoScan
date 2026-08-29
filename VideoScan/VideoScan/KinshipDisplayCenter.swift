// KinshipDisplayCenter.swift
// UI-side owner of the derived "Relationships" strings for the People
// gallery and the profile editor (2026-08-27). Holds a memoized
// FamilyKinshipOverlay for the current profile list. The tree arrives two
// ways (codex #795 C):
//   • the production FamilyTreeLiveModel PUSHES every graph it installs
//     (tree replaced, offline → online, re-pull) through `install(graph:)`,
//     so the memo follows the tree within one session; once pushed, the
//     center follows the live model only;
//   • until then (People tab opened before the Family Tree tab ever
//     loaded) each appearance probes FamilyGraphSharedCache off the main
//     thread — Hallie's one decoded instance of the promoted artifact, so
//     launch never parses a GEDCOM here (codex #792) — and installs only
//     when the cache's load token differs from the one already held.
// Nothing here writes to disk.
//
// `@MainActor` ≈ "this must run on the UI thread"; `ObservableObject` +
// `@Published` ≈ a subject the views subscribe to, so the gallery
// re-renders when the tree finishes loading. The graph is read through
// FamilyAssetConfigurationCenter (same path Hallie uses) — never a raw
// GEDCOM file path of our own.

import Foundation
import Combine
import VideoScanCore

@MainActor
final class KinshipDisplayCenter: ObservableObject {
    static let shared = KinshipDisplayCenter()

    /// One person the editor's tree picker can choose. With a FamilySearch
    /// ID the anchor is durable across re-exports; without one (Ancestry
    /// exports) the anchor is the file-local pointer, valid only for this
    /// export's content fingerprint — shown as "(export-local)".
    struct TreePersonChoice: Identifiable, Hashable {
        let pointer: String
        let familySearchID: String?
        let name: String
        let birthYear: Int?
        var id: String { pointer }
        var label: String {
            (birthYear.map { "\(name) (b. \($0))" } ?? name) + (familySearchID == nil ? " (export-local)" : "")
        }
        var code: String { familySearchID ?? pointer }
    }

    @Published private(set) var graph: GedcomFamilyGraph?
    @Published private(set) var treePeople: [TreePersonChoice] = []
    /// Bumps on every `install(graph:)` — the overlay cache key (codex #778:
    /// a same-count tree replacement must rebuild, so people.count is not
    /// the key).
    @Published private(set) var graphGeneration = 0
    /// Content fingerprint of the installed tree, for `.treePointer` anchors.
    private(set) var graphFingerprint: String?
    /// True once a FamilyTreeLiveModel has pushed a graph: from then on the
    /// live model is the only tree source (it already reloads on repoint /
    /// offline and pushes each install), so the self-load stands down.
    private(set) var followsLiveModel = false
    /// The FamilyGraphSharedCache load token behind the last self-load —
    /// equal tokens mean the cache handed back the same decode, so there is
    /// nothing to rebuild.
    private(set) var sharedCacheToken: UUID?
    private var probeInFlight = false

    private var cachedProfiles: [POIProfile] = []
    private var cachedGeneration = -1
    private var cachedOverlay: FamilyKinshipOverlay?
    private var cachedInference: FamilyKinshipInference?

    /// Internal (not private) so tests can build an isolated center; the
    /// app uses `.shared`.
    init() {}

    /// Replace the tree (or clear it) and invalidate the overlay cache.
    /// Called by FamilyTreeLiveModel on every install (and by tests); a
    /// pushed tree retires the self-load below.
    func install(graph newGraph: GedcomFamilyGraph?) {
        followsLiveModel = true
        apply(graph: newGraph)
    }

    private func apply(graph newGraph: GedcomFamilyGraph?) {
        graph = newGraph
        graphFingerprint = newGraph.map(FamilyKinshipOverlay.fingerprint(of:))
        treePeople = (newGraph?.people ?? [:]).values
            .map { TreePersonChoice(pointer: $0.id, familySearchID: $0.familySearchID.flatMap { $0.isEmpty ? nil : $0 },
                                    name: $0.name, birthYear: $0.birthYear) }
            .sorted { $0.name == $1.name ? $0.pointer < $1.pointer : $0.name < $1.name }
        graphGeneration += 1
    }

    /// Bring the tree in from the shared cache when no live model has
    /// pushed one. Called on every People-tab / editor appearance: the
    /// probe is a pointer read + one directory stat on a utility task; the
    /// artifact is decoded only on a cache miss, and the overlay is rebuilt
    /// only when the load token changed (new pull, repoint, offline →
    /// online, or archive revoked → tree cleared).
    func loadTreeIfNeeded() {
        guard !followsLiveModel, !probeInFlight else { return }
        probeInFlight = true
        let known = sharedCacheToken
        Task.detached(priority: .utility) {
            // Worst case ~16k people × ~100 B for the picker list.
            let loaded = FamilyGraphSharedCache.shared.load(
                for: FamilyAssetConfigurationCenter.shared.snapshot(), store: .app)
            await MainActor.run {
                self.probeInFlight = false
                // A live-model push while we were reading wins outright.
                guard !self.followsLiveModel, loaded?.token != known else { return }
                self.sharedCacheToken = loaded?.token
                self.apply(graph: loaded?.graph)
            }
        }
    }

    /// Memoized overlay for the gallery's current profiles.
    func overlay(for profiles: [POIProfile]) -> FamilyKinshipOverlay {
        if let cachedOverlay, cachedProfiles == profiles, cachedGeneration == graphGeneration {
            return cachedOverlay
        }
        let built = FamilyKinshipOverlay(profiles: profiles, graph: graph)
        cachedProfiles = profiles
        cachedGeneration = graphGeneration
        cachedOverlay = built
        cachedInference = nil
        return built
    }

    /// Memoized derivation engine over the same overlay (design §2: "memoised
    /// per graph generation"). Same key as `overlay(for:)`, so a tree
    /// install or a profile edit rebuilds both; the engine's ancestor-index
    /// memo lives inside it and is dropped with it.
    func inference(for profiles: [POIProfile]) -> FamilyKinshipInference {
        if let cachedInference, cachedProfiles == profiles, cachedGeneration == graphGeneration {
            return cachedInference
        }
        let built = FamilyKinshipInference(overlay: overlay(for: profiles))
        cachedInference = built
        return built
    }

    /// The pinned owner (Hallie's "who is talking to her" settings) when a
    /// profile or tree vertex matches, else the first profile.
    func defaultAnchor(in overlay: FamilyKinshipOverlay, profiles: [POIProfile]) -> FamilyKinshipOverlay.Node? {
        let speakers = HallieTurnExecutor.Speakers.fromDefaults()
        return overlay.defaultAnchor(
            ownerName: speakers.ownerName,
            ownerFamilySearchID: speakers.ownerFamilySearchID,
            firstProfileStableID: profiles.first?.id)
    }

    /// The profile-card / editor line, e.g. "Rick's younger brother".
    func relationshipsLine(for profile: POIProfile, among profiles: [POIProfile]) -> String? {
        guard !profile.kinships.isEmpty else { return nil }
        let overlay = overlay(for: profiles)
        return overlay.relationshipsLine(
            forProfileStableID: profile.id,
            kinships: profile.kinships,
            defaultAnchor: defaultAnchor(in: overlay, profiles: profiles))
    }

    /// Data-hygiene nudge for the card badge: "Alias 'Dad' on Rick looks
    /// relational — use a Relationship row instead". nil when clean.
    func aliasWarning(for profile: POIProfile, among profiles: [POIProfile]) -> String? {
        let lines = overlay(for: profiles).warnings(forProfileNamed: profile.name)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// Tree people whose name contains every typed token; capped so a
    /// one-letter search can't render 16k rows.
    func searchTreePeople(_ typed: String, limit: Int = 25) -> [TreePersonChoice] {
        let tokens = FamilyIdentityText.tokens(typed)
        guard !tokens.isEmpty else { return [] }
        var out: [TreePersonChoice] = []
        for person in treePeople {
            let nameTokens = FamilyIdentityText.tokens(person.name)
            if tokens.allSatisfy({ token in nameTokens.contains { $0.hasPrefix(token) } }) {
                out.append(person)
                if out.count >= limit { break }
            }
        }
        return out
    }
}
