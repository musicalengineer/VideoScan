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

    /// One person the editor's tree picker can choose.
    struct TreePersonChoice: Identifiable, Hashable {
        let familySearchID: String
        let name: String
        let birthYear: Int?
        var id: String { familySearchID }
        var label: String { birthYear.map { "\(name) (b. \($0))" } ?? name }
    }

    @Published private(set) var graph: GedcomFamilyGraph?
    @Published private(set) var treePeople: [TreePersonChoice] = []
    private var loadStarted = false

    private var cachedProfiles: [POIProfile] = []
    private var cachedGraphCount = -1
    private var cachedOverlay: FamilyKinshipOverlay?

    private init() {}

    /// Kick off the one-time tree load. Cheap to call repeatedly.
    func loadTreeIfNeeded() {
        guard !loadStarted else { return }
        loadStarted = true
        Task.detached(priority: .utility) {
            let loaded = FamilyAssetConfigurationCenter.shared.snapshot().loadFamilyGraph()
            // Only people with a FamilySearch ID can be anchors — the ID is
            // what survives a re-export. Worst case ~16k entries × ~100 B.
            let choices = (loaded?.people ?? [:]).values
                .compactMap { person -> TreePersonChoice? in
                    guard let fsid = person.familySearchID, !fsid.isEmpty else { return nil }
                    return TreePersonChoice(familySearchID: fsid, name: person.name,
                                            birthYear: person.birthYear)
                }
                .sorted { $0.name == $1.name ? $0.familySearchID < $1.familySearchID : $0.name < $1.name }
            await MainActor.run {
                self.graph = loaded
                self.treePeople = choices
            }
        }
    }

    /// Memoized overlay for the gallery's current profiles.
    func overlay(for profiles: [POIProfile]) -> FamilyKinshipOverlay {
        let graphCount = graph?.people.count ?? -1
        if let cachedOverlay, cachedProfiles == profiles, cachedGraphCount == graphCount {
            return cachedOverlay
        }
        let built = FamilyKinshipOverlay(profiles: profiles, graph: graph)
        cachedProfiles = profiles
        cachedGraphCount = graphCount
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
