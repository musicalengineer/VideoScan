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

    static func treePerson(for profile: POIProfile, profiles: [POIProfile],
                           graph: GedcomFamilyGraph,
                           fingerprint: () -> String? = { nil }) -> GedcomFamilyGraph.Person? {
        guard let claimed = candidate(for: profile, profiles: profiles, graph: graph, fingerprint: fingerprint)
        else { return nil }
        let claimants = profiles.filter {
            candidate(for: $0, profiles: profiles, graph: graph, fingerprint: fingerprint)?.id == claimed.id
        }
        return claimants.count == 1 ? claimed : nil
    }

    static func profile(for person: GedcomFamilyGraph.Person, profiles: [POIProfile],
                        graph: GedcomFamilyGraph,
                        fingerprint: () -> String? = { nil }) -> POIProfile? {
        let claimants = profiles.filter {
            candidate(for: $0, profiles: profiles, graph: graph, fingerprint: fingerprint)?.id == person.id
        }
        return claimants.count == 1 ? claimants[0] : nil
    }

    /// The profile's own claim, before the uniqueness check.
    private static func candidate(for profile: POIProfile, profiles: [POIProfile],
                                  graph: GedcomFamilyGraph,
                                  fingerprint: () -> String?) -> GedcomFamilyGraph.Person? {
        if let pin = profile.treeIdentity {
            switch pin {
            case .familySearchID(let fsid):
                return graph.person(familySearchID: fsid)
            case .pointer(let pointer, let sourceFingerprint):
                guard let live = fingerprint(), live == sourceFingerprint else { return nil }
                return graph.people[pointer]
            }
        }
        if profile.treeIdentityQuarantined != nil { return nil }   // unreadable pin: fail closed
        if profile.notInFamilyTree { return nil }                   // Rick said: not on the tree
        switch FamilyTreeIdentityResolver(graph: graph, profiles: profiles).resolve(profile.name) {
        case .people(let people) where people.count == 1:
            return people[0]
        default:
            return nil
        }
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
            let data = try Data(contentsOf: cover)
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
    private var cache: [String: PersonPhotoResolution] = [:]

    init() {}

    func invalidate() { revision &+= 1 }

    func peoplePhoto(for profile: POIProfile, among profiles: [POIProfile],
                     kinshipCenter: KinshipDisplayCenter = .shared) -> PersonPhotoResolution? {
        let generation = kinshipCenter.graphGeneration
        if cachedProfiles != profiles || cachedGeneration != generation || cachedRevision != revision {
            cache.removeAll()
            cachedProfiles = profiles
            cachedGeneration = generation
            cachedRevision = revision
        }
        if let hit = cache[profile.id] { return hit }
        let store = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        let person = kinshipCenter.graph.flatMap { graph in
            PersonPhotoBridge.treePerson(for: profile, profiles: profiles, graph: graph,
                                         fingerprint: { kinshipCenter.graphFingerprint })
        }
        let resolved = PersonPhotoResolver(store: store)
            .peoplePhoto(for: profile, treePerson: person.map(FamilyAssetPerson.init))
        if let resolved { cache[profile.id] = resolved }
        return resolved
    }
}
