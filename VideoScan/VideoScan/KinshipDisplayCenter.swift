// KinshipDisplayCenter.swift
// UI-side owner of the derived "Relationships" strings for the People
// gallery and the profile editor (2026-08-27). Holds a memoized
// FamilyKinshipOverlay for the current profile list and loads the family
// tree ONCE in the background so tree-anchored rows can show a name
// instead of a bare FamilySearch ID. Nothing here writes to disk.
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
    private var loadStarted = false

    private var cachedProfiles: [POIProfile] = []
    private var cachedGeneration = -1
    private var cachedOverlay: FamilyKinshipOverlay?

    /// Internal (not private) so tests can build an isolated center; the
    /// app uses `.shared`.
    init() {}

    /// Replace the tree (or clear it) and invalidate the overlay cache.
    func install(graph newGraph: GedcomFamilyGraph?) {
        graph = newGraph
        graphFingerprint = newGraph.map(FamilyKinshipOverlay.fingerprint(of:))
        treePeople = (newGraph?.people ?? [:]).values
            .map { TreePersonChoice(pointer: $0.id, familySearchID: $0.familySearchID.flatMap { $0.isEmpty ? nil : $0 },
                                    name: $0.name, birthYear: $0.birthYear) }
            .sorted { $0.name == $1.name ? $0.pointer < $1.pointer : $0.name < $1.name }
        graphGeneration += 1
    }

    /// Kick off the one-time tree load. Cheap to call repeatedly.
    func loadTreeIfNeeded() {
        guard !loadStarted else { return }
        loadStarted = true
        Task.detached(priority: .utility) {
            // Worst case ~16k people × ~100 B for the picker list.
            let loaded = FamilyAssetConfigurationCenter.shared.snapshot().loadFamilyGraph()
            await MainActor.run { self.install(graph: loaded) }
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
