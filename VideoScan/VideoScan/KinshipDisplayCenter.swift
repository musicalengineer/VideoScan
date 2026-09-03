// KinshipDisplayCenter.swift
// UI-side owner of the derived "Relationships" strings for the People
// gallery and the profile editor (2026-08-27). Holds a memoized
// FamilyKinshipOverlay and a memoized FamilyKinshipInference for the
// current profile list. The tree arrives two ways (codex #795 C):
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
// Main-thread discipline (codex #845): `install(graph:)` only swaps the
// reference and bumps the generation. The picker's people list (a 39k
// projection + sort) is built lazily on first picker use; the tree's
// content fingerprint (a SHA over 39k names) is computed lazily the first
// time an export-local pointer needs it. The inference engine is cached by
// (graph generation, kinship-relevant profile signature) so a notes edit or
// a Hallie turn never rebuilds it.
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
    /// The editor's tree-picker choices, built LAZILY on first use
    /// (2026-08-29): the sort of 39k names ran on the main actor at every
    /// install although only the picker reads it. Reset per install.
    var treePeople: [TreePersonChoice] {
        if let treePeopleCache { return treePeopleCache }
        var built: [TreePersonChoice] = []
        if let graph {
            built.reserveCapacity(graph.people.count)
            for person in graph.people.values {
                let fsid: String? = person.familySearchID.flatMap { $0.isEmpty ? nil : $0 }
                built.append(TreePersonChoice(pointer: person.id, familySearchID: fsid,
                                              name: person.name, birthYear: person.birthYear))
            }
            built.sort { $0.name == $1.name ? $0.pointer < $1.pointer : $0.name < $1.name }
        }
        treePeopleCache = built
        return built
    }
    private var treePeopleCache: [TreePersonChoice]?
    /// Bumps on every `install(graph:)` — the overlay cache key (codex #778:
    /// a same-count tree replacement must rebuild, so people.count is not
    /// the key).
    @Published private(set) var graphGeneration = 0
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
    private var inferenceSignature: Int?
    private var inferenceGeneration = -1
    /// Bumps each time the engine is (re)built — tests pin invalidation on
    /// tree replacement and kinship-relevant profile edits, and that a
    /// notes edit or a repeated Hallie turn does NOT rebuild.
    private(set) var inferenceBuildCount = 0

    /// Lazily computed content fingerprint for the installed generation.
    private var fingerprintCache: (generation: Int, value: String?)?

    /// Internal (not private) so tests can build an isolated center; the
    /// app uses `.shared`.
    init() {}

    /// Replace the tree (or clear it) and invalidate the caches.
    /// Called by FamilyTreeLiveModel on every install (and by tests); a
    /// pushed tree retires the self-load below.
    func install(graph newGraph: GedcomFamilyGraph?) {
        followsLiveModel = true
        apply(graph: newGraph)
    }

    private func apply(graph newGraph: GedcomFamilyGraph?) {
        graph = newGraph
        graphGeneration += 1
        fingerprintCache = nil
        treePeopleCache = nil
    }

    /// Content fingerprint of the installed tree, for `.treePointer`
    /// anchors. Computed on first use (a SHA over every name) and cached
    /// per generation — the picker is user-driven, so this never runs on
    /// a tree install or a gallery render.
    var graphFingerprint: String? {
        if let fingerprintCache, fingerprintCache.generation == graphGeneration { return fingerprintCache.value }
        let value = graph.map(FamilyKinshipOverlay.fingerprint(of:))
        fingerprintCache = (graphGeneration, value)
        return value
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
        return built
    }

    /// Memoized derivation engine (design §2: "memoised per graph
    /// generation"). Keyed by the graph generation and the KINSHIP-RELEVANT
    /// profile signature (`kinshipSignature(of:)`), so unrelated edits and
    /// repeated calls with equal inputs reuse the engine and its memo.
    func inference(for profiles: [POIProfile]) -> FamilyKinshipInference {
        let signature = Self.kinshipSignature(of: profiles)
        if let cachedInference, inferenceSignature == signature, inferenceGeneration == graphGeneration {
            return cachedInference
        }
        let built = FamilyKinshipInference(profiles: profiles, graph: graph)
        inferenceBuildCount += 1
        inferenceSignature = signature
        inferenceGeneration = graphGeneration
        cachedInference = built
        return built
    }

    /// Hash of every field the engine reads — name, uuid, aliases, sex,
    /// birthdate, kinships, pin — and nothing else (notes, thresholds and
    /// photos never invalidate).
    static func kinshipSignature(of profiles: [POIProfile]) -> Int {
        var hasher = Hasher()
        hasher.combine(profiles.count)
        for p in profiles {
            hasher.combine(p.name)
            hasher.combine(p.uuid)
            hasher.combine(p.aliases)
            hasher.combine(p.sex)
            hasher.combine(p.birthdate)
            hasher.combine(p.kinships)
            hasher.combine(p.treeIdentity)
            hasher.combine(p.treeIdentityQuarantined != nil)
        }
        return hasher.finalize()
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
    /// relational — use a Relationship row instead", plus any derivation
    /// conflict this profile's sibling set is part of (codex #984: the
    /// same line Hallie's basis carries). nil when clean.
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
