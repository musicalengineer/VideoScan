// PersonPhotoResolver.swift
// One photo per person across the Family Tree card and the People tab
// (Rick 2026-08-29: "every time I go to Donna Hudson it shows a picture of
// the whole family … I set a new photo and it keeps reverting").
//
// What was wrong: the tree card had NO persistent choice. Pick a photo /
// Apple Photos were in-memory overrides on a FamilyTreeLiveModel that the
// tab rebuilds on every tab switch; the persistent fallback was
// `photoURLs(for:).first`, and for Donna Hudson (tree name "Donna Hudson",
// folder "Donna_Elaine_Hudson" — no name match) the first photo was the
// group folder RickDonnaBreenFamily/SouthEastMontana1995.jpg, attributed to
// her through her married surname. The People tab, separately, showed the
// profile cover.
//
// Now: FamilyAssetStore keeps ONE explicit choice per person
// (`People/<FSID>/chosen-photo.json`); both views resolve through
// `PersonPhotoResolver`, whose precedence is
//     explicit choice (latest `chosenAt` — tree or People tab)
//   > the bridged People-tab profile's cover photo
//   > derived (a `-card` crop, the person's own folder, a group folder).
// A provider/derived photo can never overwrite a choice.
//
// C++ analogy: the store is the repository, this file is a pure
// "policy" object plus a tiny main-thread memo (`PersonPhotoCenter`).

import AppKit
import Combine
import Foundation
import os
import VideoScanCore

private let photoLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "photo")

/// Choice sources, as written into the sidecar.
enum PersonPhotoChoiceSource {
    static let treePick = "tree.pick"
    static let treeApplePhotos = "tree.applePhotos"
    static let treeAdjust = "tree.adjust"
    static let peopleCover = "people.cover"
}

enum PersonPhotoLog {
    /// One line per choice. The name is private (codex #861: no full names
    /// at public level); videoscan.log gets the tree key instead.
    static func chose(person: FamilyAssetPerson, source: String, chosenAt: Date) {
        let when = ISO8601DateFormatter().string(from: chosenAt)
        photoLog.debug("[photo] \(person.name, privacy: .private) ← \(source, privacy: .public) (chosen \(when, privacy: .public))")
        let key = person.familySearchID ?? person.gedcomID ?? "?"
        appLog.write("[photo] \(key) ← \(source) (chosen \(when))")
    }
}

/// Where a resolved portrait came from.
enum PersonPhotoSource: String, Sendable {
    case chosen, profileCover, card, folder
}

struct PersonPhotoResolution: Equatable, Sendable {
    let url: URL
    let source: PersonPhotoSource
    let chosenAt: Date?
    /// People-tab crop, applied only when the profile cover is what shows
    /// (a chosen asset is shown whole).
    let cropScale: Double
    let cropOffset: CGSize

    static func plain(_ url: URL, _ source: PersonPhotoSource, chosenAt: Date? = nil) -> PersonPhotoResolution {
        PersonPhotoResolution(url: url, source: source, chosenAt: chosenAt, cropScale: 1, cropOffset: .zero)
    }
}

// MARK: - Bridge (profile ↔ tree person)

/// Which People-tab profile IS a tree person, and vice versa. A
/// `treeIdentity` pin wins and fails closed (two profiles on one record
/// bridge nobody); with no pin, the identity bridge Hallie and the tree
/// focus use (`FamilyTreeIdentityResolver`) — accepted only when the
/// profile's spellings reach exactly one record and no other profile
/// reaches the same one. Never a bare surname.
enum PersonPhotoBridge {

    /// One fail-closed identity pass for a complete People snapshot.
    ///
    /// The old per-profile bridge filtered `profiles` once to find every
    /// claimant, and each filtered candidate built another full-profile
    /// `FamilyTreeIdentityResolver`. Asking for all cards therefore grew at
    /// least quadratically. This snapshot builds the spelling index once,
    /// resolves each profile once, counts claims once, then retains only
    /// collision-free pairs. Build work is O(profiles + identity lookups).
    struct Snapshot {
        private enum CanonicalClaim {
            case one(String)
            case ambiguous
        }

        private let personByProfileID: [String: GedcomFamilyGraph.Person]
        private let profileByPersonID: [String: POIProfile]
        /// Regression sensor: exactly one candidate evaluation per profile.
        let candidateEvaluationCount: Int

        init(profiles: [POIProfile], graph: GedcomFamilyGraph,
             fingerprint: () -> String? = { nil }) {
            var canonicalBySpelling: [String: CanonicalClaim] = [:]
            var aliasesByCanonicalName: [String: [String]] = [:]
            var profileIDCounts: [String: Int] = [:]
            canonicalBySpelling.reserveCapacity(profiles.count)
            profileIDCounts.reserveCapacity(profiles.count)
            for profile in profiles {
                Self.recordCanonicalClaim(
                    spelling: profile.name, canonicalName: profile.name,
                    in: &canonicalBySpelling)
                for alias in profile.aliases {
                    Self.recordCanonicalClaim(
                        spelling: alias, canonicalName: profile.name,
                        in: &canonicalBySpelling)
                }
                if !profile.aliases.isEmpty {
                    aliasesByCanonicalName[PersonResolver.normalize(profile.name), default: []]
                        .append(contentsOf: profile.aliases)
                }
                profileIDCounts[profile.id, default: 0] += 1
            }

            var candidates: [(profileIndex: Int, person: GedcomFamilyGraph.Person)] = []
            var claimCounts: [String: Int] = [:]
            candidates.reserveCapacity(profiles.count)
            for (profileIndex, profile) in profiles.enumerated() {
                guard let person = Self.candidate(
                    for: profile, graph: graph,
                    canonicalBySpelling: canonicalBySpelling,
                    aliasesByCanonicalName: aliasesByCanonicalName,
                    fingerprint: fingerprint)
                else { continue }
                candidates.append((profileIndex, person))
                claimCounts[person.id, default: 0] += 1
            }

            var byProfile: [String: GedcomFamilyGraph.Person] = [:]
            var byPerson: [String: POIProfile] = [:]
            for pair in candidates {
                let profile = profiles[pair.profileIndex]
                guard claimCounts[pair.person.id] == 1,
                      profileIDCounts[profile.id] == 1 else { continue }
                byProfile[profile.id] = pair.person
                byPerson[pair.person.id] = profile
            }
            personByProfileID = byProfile
            profileByPersonID = byPerson
            candidateEvaluationCount = profiles.count
        }

        func treePerson(for profile: POIProfile) -> GedcomFamilyGraph.Person? {
            personByProfileID[profile.id]
        }

        func profile(for person: GedcomFamilyGraph.Person) -> POIProfile? {
            profileByPersonID[person.id]
        }

        private static func recordCanonicalClaim(
            spelling: String,
            canonicalName: String,
            in claims: inout [String: CanonicalClaim]
        ) {
            let key = PersonResolver.normalize(spelling)
            guard !key.isEmpty else { return }
            switch claims[key] {
            case .none:
                claims[key] = .one(canonicalName)
            case .some(.one(let existing)) where existing != canonicalName:
                claims[key] = .ambiguous
            case .some(.one(_)), .some(.ambiguous):
                break
            }
        }

        private static func candidate(
            for profile: POIProfile,
            graph: GedcomFamilyGraph,
            canonicalBySpelling: [String: CanonicalClaim],
            aliasesByCanonicalName: [String: [String]],
            fingerprint: () -> String?
        ) -> GedcomFamilyGraph.Person? {
            if let pin = profile.treeIdentity {
                switch pin {
                case .familySearchID(let fsid):
                    return graph.person(familySearchID: fsid)
                case .pointer(let pointer, let sourceFingerprint):
                    guard fingerprint() == sourceFingerprint else { return nil }
                    return graph.people[pointer]
                }
            }
            guard profile.treeIdentityQuarantined == nil,
                  !profile.notInFamilyTree else { return nil }

            // A profile always has an exact PersonResolver entry unless its
            // name is empty. Avoid fuzzy recovery for that invalid case: it
            // cannot establish identity and would scan the whole profile set.
            guard !PersonResolver.normalize(profile.name).isEmpty else { return nil }
            let normalizedName = PersonResolver.normalize(profile.name)
            let canonicalName: String
            switch canonicalBySpelling[normalizedName] {
            case .some(.one(let resolved)):
                canonicalName = resolved
            case .some(.ambiguous), .none:
                return nil
            }

            let normalizedCanonical = PersonResolver.normalize(canonicalName)
            let terms = [canonicalName]
                + (aliasesByCanonicalName[normalizedCanonical] ?? [])
                + [profile.name]
            var seen = Set<String>()
            let ordered = terms.filter {
                seen.insert(PersonResolver.normalize($0)).inserted
            }
            .enumerated()
            .sorted { lhs, rhs in
                let lhsWords = lhs.element.split(whereSeparator: \Character.isWhitespace).count
                let rhsWords = rhs.element.split(whereSeparator: \Character.isWhitespace).count
                if lhsWords != rhsWords { return lhsWords > rhsWords }
                if lhs.element.count != rhs.element.count {
                    return lhs.element.count > rhs.element.count
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            for term in ordered {
                let matches = graph.people(matching: term)
                if matches.count == 1 { return matches[0] }
                if !matches.isEmpty { return nil }
            }
            return nil
        }
    }

    static func treePerson(for profile: POIProfile, profiles: [POIProfile],
                           graph: GedcomFamilyGraph,
                           fingerprint: () -> String? = { nil }) -> GedcomFamilyGraph.Person? {
        Snapshot(profiles: profiles, graph: graph, fingerprint: fingerprint)
            .treePerson(for: profile)
    }

    static func profile(for person: GedcomFamilyGraph.Person, profiles: [POIProfile],
                        graph: GedcomFamilyGraph,
                        fingerprint: () -> String? = { nil }) -> POIProfile? {
        Snapshot(profiles: profiles, graph: graph, fingerprint: fingerprint)
            .profile(for: person)
    }
}

// MARK: - Precedence

struct PersonPhotoResolver {
    let store: FamilyAssetStore

    /// The Family Tree card's photo.
    func treePhoto(for person: FamilyAssetPerson, bridgedProfile: POIProfile?) -> PersonPhotoResolution? {
        let chosen = store.chosenPhoto(for: person)
        let cover = bridgedProfile.flatMap(Self.coverResolution)
        if let chosen {
            // A People-tab cover set AFTER the choice (e.g. while the archive
            // was offline) is the more recent explicit choice.
            if let cover, let coverAt = bridgedProfile?.photoChosenAt, coverAt > chosen.choice.chosenAt {
                return cover
            }
            return .plain(chosen.url, .chosen, chosenAt: chosen.choice.chosenAt)
        }
        if let cover { return cover }
        if let card = store.cardPhotoURL(for: person) { return .plain(card, .card) }
        if let first = store.photoURLs(for: person).first { return .plain(first, .folder) }
        return nil
    }

    /// The People-tab card's photo.
    func peoplePhoto(for profile: POIProfile, treePerson: FamilyAssetPerson?) -> PersonPhotoResolution? {
        let cover = Self.coverResolution(profile)
        guard let treePerson, let chosen = store.chosenPhoto(for: treePerson) else { return cover }
        if let cover, let coverAt = profile.photoChosenAt, coverAt > chosen.choice.chosenAt {
            return cover
        }
        return .plain(chosen.url, .chosen, chosenAt: chosen.choice.chosenAt)
    }

    /// The profile's cover as a resolution: one path component, a regular
    /// non-link file directly in the reference folder.
    static func coverResolution(_ profile: POIProfile) -> PersonPhotoResolution? {
        guard let url = coverURL(profile) else { return nil }
        return PersonPhotoResolution(
            url: url, source: .profileCover, chosenAt: profile.photoChosenAt,
            cropScale: profile.coverCropScale,
            cropOffset: CGSize(width: profile.coverCropOffsetX, height: profile.coverCropOffsetY))
    }

    static func coverURL(_ profile: POIProfile) -> URL? {
        guard let filename = profile.coverImageFilename, !filename.isEmpty,
              filename == URL(fileURLWithPath: filename).lastPathComponent else { return nil }
        let folder = URL(fileURLWithPath: profile.referencePath, isDirectory: true).standardizedFileURL
        let file = folder.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard file.deletingLastPathComponent() == folder,
              let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return file
    }
}

// MARK: - People-tab write (cover → canonical asset)

enum PersonPhotoSync {
    /// File-size preflight plus a bounded read. The second size guard closes
    /// the grow-between-stat-and-read race without ever allocating more than
    /// `maxImportBytes + 1` bytes.
    static func boundedCoverData(
        at url: URL,
        maxBytes: Int = FamilyAssetStore.maxImportBytes
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw FamilyAssetStore.StoreError.sourceIsNotARegularImage(url)
        }
        let advertisedSize = values.fileSize ?? (maxBytes + 1)
        guard advertisedSize <= maxBytes else {
            throw FamilyAssetStore.StoreError.imageTooLarge(bytes: advertisedSize)
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var data = Data()
        data.reserveCapacity(advertisedSize)
        while data.count <= maxBytes {
            let remaining = maxBytes + 1 - data.count
            let chunkSize = min(1 << 20, remaining)
            guard let chunk = try handle.read(upToCount: chunkSize),
                  !chunk.isEmpty else { break }
            data.append(chunk)
        }
        guard data.count <= maxBytes else {
            throw FamilyAssetStore.StoreError.imageTooLarge(bytes: data.count)
        }
        return data
    }

    /// A People-tab cover edit is an explicit choice: stamp the profile and,
    /// when the profile is bridged to a tree person, copy the cover into
    /// that person's choice folder so the Family Tree shows the same photo.
    /// Returns the copied URL (nil when unbridged / unchanged / the archive
    /// refused; the profile still stamps so the People tab wins by date).
    @discardableResult
    static func applyCoverChoice(to updated: inout POIProfile, previous: POIProfile?,
                                 profiles: [POIProfile], graph: GedcomFamilyGraph?,
                                 store: FamilyAssetStore, now: Date = Date(),
                                 fingerprint: () -> String? = { nil }) -> URL? {
        let changed = previous == nil
            || previous?.coverImageFilename != updated.coverImageFilename
            || previous?.coverCropScale != updated.coverCropScale
            || previous?.coverCropOffsetX != updated.coverCropOffsetX
            || previous?.coverCropOffsetY != updated.coverCropOffsetY
        guard changed, let cover = PersonPhotoResolver.coverURL(updated) else { return nil }
        updated.photoChosenAt = now
        guard let graph,
              let person = PersonPhotoBridge.treePerson(for: updated, profiles: profiles,
                                                        graph: graph, fingerprint: fingerprint)
        else { return nil }
        do {
            let data = try boundedCoverData(at: cover)
            return try store.choosePhoto(data, fileExtension: cover.pathExtension,
                                         for: FamilyAssetPerson(person),
                                         source: PersonPhotoChoiceSource.peopleCover, chosenAt: now)
        } catch {
            appLog.write("[photo] People-tab cover not copied to the family archive: \(error.localizedDescription)")
            return nil
        }
    }
}

// MARK: - Main-thread memo for the People gallery

/// Resolves each People-tab card's portrait once per (profiles, tree
/// generation, revision) instead of per render — the gallery body must
/// not do O(profiles²) resolver work. `revision` bumps on every write from
/// either view so a change sticks immediately.
@MainActor
final class PersonPhotoCenter: ObservableObject {
    static let shared = PersonPhotoCenter()

    @Published private(set) var revision = 0
    private var cachedProfiles: [POIProfile] = []
    private var cachedGeneration = -1
    private var cachedRevision = -1
    private enum CacheEntry {
        case photo(PersonPhotoResolution)
        case missing
    }

    private let storeProvider: () -> FamilyAssetStore
    private var cache: [String: CacheEntry] = [:]
    private var resolvedPhotos: [String: PersonPhotoResolution] = [:]
    /// Sensors pin one whole-profile build per revision, including misses.
    private(set) var resolutionBuildCount = 0
    var cachedEntryCount: Int { cache.count }

    init(storeProvider: @escaping () -> FamilyAssetStore = {
        FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
    }) {
        self.storeProvider = storeProvider
    }

    func invalidate() { revision &+= 1 }

    /// Complete portrait map for one gallery evaluation. Call this once
    /// before `ForEach`; every card then performs one dictionary lookup.
    /// Missing resolutions are retained in `cache` just like hits, so a
    /// subsequent render does not repeat bridge or filesystem work.
    func peoplePhotos(for profiles: [POIProfile],
                      kinshipCenter: KinshipDisplayCenter = .shared)
        -> [String: PersonPhotoResolution] {
        let generation = kinshipCenter.graphGeneration
        if cachedProfiles != profiles || cachedGeneration != generation || cachedRevision != revision {
            cache.removeAll()
            resolvedPhotos.removeAll()
            cachedProfiles = profiles
            cachedGeneration = generation
            cachedRevision = revision
            cache.reserveCapacity(profiles.count)
            let bridge = kinshipCenter.graph.map {
                PersonPhotoBridge.Snapshot(
                    profiles: profiles, graph: $0,
                    fingerprint: { kinshipCenter.graphFingerprint })
            }
            let resolver = PersonPhotoResolver(store: storeProvider())
            for profile in profiles {
                let person = bridge?.treePerson(for: profile).map(FamilyAssetPerson.init)
                if let photo = resolver.peoplePhoto(for: profile, treePerson: person) {
                    cache[profile.id] = .photo(photo)
                    resolvedPhotos[profile.id] = photo
                } else {
                    cache[profile.id] = .missing
                }
            }
            resolutionBuildCount += 1
        }
        return resolvedPhotos
    }

    /// Compatibility for non-gallery callers. The gallery itself must use
    /// `peoplePhotos` once, or the O(profiles) revision comparison would be
    /// repeated by every card.
    func peoplePhoto(for profile: POIProfile, among profiles: [POIProfile],
                     kinshipCenter: KinshipDisplayCenter = .shared) -> PersonPhotoResolution? {
        peoplePhotos(for: profiles, kinshipCenter: kinshipCenter)[profile.id]
    }
}
