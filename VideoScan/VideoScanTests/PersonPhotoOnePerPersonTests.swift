// PersonPhotoOnePerPersonTests.swift
// Rick 2026-08-29: "every time I go to Donna Hudson it shows a picture of
// the whole family; I set a new photo using right-click and it keeps
// reverting." One photo per person across the Family Tree card and the
// People tab: explicit choice (latest) › bridged profile cover › derived.
//
// Everything runs against injected temp roots — never the real archive or
// the real POI store. The fixture mirrors the real layout that produced
// the bug: tree name "Donna Hudson" (FSID G2CL-86B), a People folder
// "Donna_Elaine_Hudson" (no name match), and the group folder
// "RickDonnaBreenFamily" attributed to her by married surname.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoScan
import VideoScanCore

@Suite("One photo per person — tree card ↔ People tab", .serialized)
struct PersonPhotoOnePerPersonTests {
    private let fileManager = FileManager.default

    // MARK: Fixture

    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 BIRT
    2 DATE 4 MAR 1959
    1 _FSFTID GVQV-NW3
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMC @F3@
    1 FAMS @F2@
    0 @I3@ INDI
    1 NAME Donna /Hudson/
    1 SEX F
    1 BIRT
    2 DATE 4 AUG 1959
    1 _FSFTID G2CL-86B
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Timothy /Breen/
    1 SEX M
    1 FAMC @F1@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    1 CHIL @I5@
    0 @F2@ FAM
    1 HUSB @I2@
    1 WIFE @I4@
    1 CHIL @I1@
    0 @F3@ FAM
    1 CHIL @I2@
    0 TRLR
    """
    static let graph = GedcomFamilyGraph(gedcomText: tree)
    static var donna: GedcomFamilyGraph.Person { graph.people["@I3@"]! }
    static var rick: GedcomFamilyGraph.Person { graph.people["@I1@"]! }
    static var richardSr: GedcomFamilyGraph.Person { graph.people["@I2@"]! }

    struct Sandbox {
        let base: URL
        let store: FamilyAssetStore
        let groupPhoto: URL
        let ownFolderPhoto: URL
        let poiFolder: URL
        let cover: URL
        var profiles: [POIProfile]
        var donnaProfile: POIProfile { profiles[0] }
        var peopleDirectory: URL { store.peopleDirectory }
        /// A second store over the same root = "after relaunch".
        func relaunched() -> FamilyAssetStore {
            var fresh = FamilyAssetStore(root: store.root, cacheRoot: store.cacheRoot)
            fresh.identity = store.identity
            return fresh
        }
    }

    private func png(_ url: URL, width: Int = 4, height: Int = 4, shade: CGFloat = 0.5) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: shade, green: 0.3, blue: 0.6, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    /// The real on-disk shape, in a temp dir: group folder + a folder whose
    /// name does NOT match the tree spelling + a People-tab profile "Donna"
    /// (aliases mom/mommy, no pin) with a cover in its own reference folder.
    private func sandbox(withProfileCover: Bool = true) throws -> Sandbox {
        // Canonical (/private/var, not /var): the store canonicalizes its
        // root, and the expectations compare URLs.
        let base = fileManager.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("OnePhotoPerPerson-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true)
        var store = FamilyAssetStore(root: root, cacheRoot: base.appendingPathComponent("support/thumbs"))
        store.identity = FamilyAssetIdentityDirectory(
            graph: Self.graph, aliases: ["@I1@": ["Rick Breen"]],
            ownerGedcomID: "@I1@", ownerName: "Rick Breen")
        let people = root.appendingPathComponent("People", isDirectory: true)
        let group = people.appendingPathComponent("RickDonnaBreenFamily/SouthEastMontana1995.png")
        try png(group, width: 8, height: 8, shade: 0.1)
        let own = people.appendingPathComponent("Donna_Elaine_Hudson/DonnaOrangeShorts1990.png")
        try png(own, width: 6, height: 6, shade: 0.9)
        let poi = base.appendingPathComponent("POI/donna", isDirectory: true)
        let cover = poi.appendingPathComponent("DSCN3603.png")
        try png(cover, width: 5, height: 5, shade: 0.4)
        var donna = POIProfile(name: "Donna", referencePath: poi.path)
        donna.aliases = ["mom", "mommy"]
        if withProfileCover { donna.coverImageFilename = cover.lastPathComponent }
        var rick = POIProfile(name: "Rick", referencePath: base.appendingPathComponent("POI/rick").path)
        rick.aliases = ["Richard Breen"]
        return Sandbox(base: base, store: store, groupPhoto: group.standardizedFileURL,
                       ownFolderPhoto: own.standardizedFileURL, poiFolder: poi,
                       cover: cover.standardizedFileURL, profiles: [donna, rick])
    }

    private func jpegBytes(shade: CGFloat) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 3, height: 3, bitsPerComponent: 8, bytesPerRow: 12,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: shade, green: shade, blue: shade, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 3, height: 3))
        let image = try #require(context.makeImage())
        return try #require(CropRenderer.jpegData(image, quality: 0.9))
    }

    private var donnaAsset: FamilyAssetPerson { FamilyAssetPerson(Self.donna) }

    // MARK: Reproduction

    @Test func reproduction_providerGroupPhotoIsWhatTheCardShowedAndAnExplicitChoiceNowWinsInBothViews() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let store = box.store

        // The bug, exactly: no own folder resolves for "Donna Hudson"
        // (folder says Donna_Elaine_Hudson), no card crop, and the FIRST
        // photo the provider hands back is the whole-family group shot.
        #expect(store.cardPhotoURL(for: donnaAsset) == nil)
        #expect(store.originalPhotoURL(for: donnaAsset) == nil)
        #expect(store.photoURLs(for: donnaAsset).first == box.groupPhoto,
                "the group folder is attributed to Donna by her married surname")
        let resolver = PersonPhotoResolver(store: store)
        let before = try #require(resolver.treePhoto(for: donnaAsset, bridgedProfile: nil))
        #expect(before.source == .folder)
        #expect(before.url == box.groupPhoto)

        // Right-click → Pick a photo (the tree side) is now THE choice.
        let chosen = try store.choosePhoto(
            try jpegBytes(shade: 0.7), fileExtension: "jpg", for: donnaAsset,
            source: PersonPhotoChoiceSource.treePick, chosenAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(chosen.deletingLastPathComponent() == box.peopleDirectory.appendingPathComponent("G2CL-86B"),
                "canonical asset lives under People/<FSID>/")

        let tree = try #require(resolver.treePhoto(for: donnaAsset, bridgedProfile: box.donnaProfile))
        #expect(tree.source == .chosen)
        #expect(tree.url == chosen)
        #expect(store.cardPhotoURL(for: donnaAsset) == chosen, "a provider never overrides a choice")
        #expect(store.photoURLs(for: donnaAsset).first == chosen)

        let people = try #require(resolver.peoplePhoto(for: box.donnaProfile, treePerson: donnaAsset))
        #expect(people.source == .chosen)
        #expect(people.url == chosen, "the People tab shows the SAME asset")
    }

    // MARK: Bridge

    @Test func bridgeFindsDonnaProfileByIdentityAndPinWinsAndCollisionsFailClosed() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let graph = Self.graph

        // No pin: "Donna" (+ aliases mom/mommy) reaches exactly one record.
        #expect(PersonPhotoBridge.profile(for: Self.donna, profiles: box.profiles, graph: graph)?.name == "Donna")
        #expect(PersonPhotoBridge.treePerson(for: box.donnaProfile, profiles: box.profiles, graph: graph)?.id == "@I3@")
        // Rick bridges to Jr through his "Richard Breen" alias? Two Richards
        // — the resolver is ambiguous, so no bridge. Sr has no profile.
        #expect(PersonPhotoBridge.profile(for: Self.richardSr, profiles: box.profiles, graph: graph) == nil)

        // A pin wins over the name, and a pin to a record the tree lacks
        // bridges nobody.
        var pinned = box.donnaProfile
        pinned.treeIdentity = .familySearchID("G2CL-86B")
        #expect(PersonPhotoBridge.treePerson(for: pinned, profiles: [pinned], graph: graph)?.id == "@I3@")
        pinned.treeIdentity = .familySearchID("XXXX-000")
        #expect(PersonPhotoBridge.treePerson(for: pinned, profiles: [pinned], graph: graph) == nil)

        // Two profiles pinned to Donna: neither is her (fail closed).
        var a = box.donnaProfile; a.treeIdentity = .familySearchID("G2CL-86B")
        var b = POIProfile(name: "Donna B", referencePath: box.poiFolder.path); b.treeIdentity = .familySearchID("G2CL-86B")
        #expect(PersonPhotoBridge.profile(for: Self.donna, profiles: [a, b], graph: graph) == nil)
        #expect(PersonPhotoBridge.treePerson(for: a, profiles: [a, b], graph: graph) == nil)
    }

    // MARK: Cross-view

    @Test func profileCoverBeatsDerivedPhotosUntilATreeChoiceIsMade() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let resolver = PersonPhotoResolver(store: box.store)

        let card = try #require(resolver.treePhoto(for: donnaAsset, bridgedProfile: box.donnaProfile))
        #expect(card.source == .profileCover)
        #expect(card.url == box.cover, "with no choice, the tree shows the People-tab cover, not the group shot")

        let chosen = try box.store.choosePhoto(
            try jpegBytes(shade: 0.2), fileExtension: "jpg", for: donnaAsset,
            source: PersonPhotoChoiceSource.treeApplePhotos)
        #expect(resolver.treePhoto(for: donnaAsset, bridgedProfile: box.donnaProfile)?.url == chosen)
        #expect(resolver.peoplePhoto(for: box.donnaProfile, treePerson: donnaAsset)?.url == chosen,
                "set from the tree → the People tab shows it")
    }

    @Test func setFromPeopleTabCopiesTheCoverIntoTheArchiveAndTheTreeShowsIt() throws {
        var box = try sandbox(withProfileCover: false)
        defer { try? fileManager.removeItem(at: box.base) }
        let store = box.store
        // An older tree choice exists.
        let older = try store.choosePhoto(
            try jpegBytes(shade: 0.3), fileExtension: "jpg", for: donnaAsset,
            source: PersonPhotoChoiceSource.treePick, chosenAt: Date(timeIntervalSince1970: 1_700_000_000))

        var edited = box.donnaProfile
        edited.coverImageFilename = box.cover.lastPathComponent
        let now = Date(timeIntervalSince1970: 1_700_000_500)
        let copied = PersonPhotoSync.applyCoverChoice(
            to: &edited, previous: box.donnaProfile, profiles: box.profiles,
            graph: Self.graph, store: store, now: now)
        let copiedURL = try #require(copied)
        #expect(copiedURL.deletingLastPathComponent().lastPathComponent == "G2CL-86B")
        #expect(edited.photoChosenAt == now)
        #expect(try Data(contentsOf: copiedURL) == (try Data(contentsOf: box.cover)), "same bytes, one asset")
        box.profiles[0] = edited

        let resolver = PersonPhotoResolver(store: store)
        let tree = try #require(resolver.treePhoto(for: donnaAsset, bridgedProfile: edited))
        #expect(tree.source == .chosen)
        #expect(tree.url == copiedURL)
        #expect(tree.url != older, "the most recent explicit choice wins")
        let people = try #require(resolver.peoplePhoto(for: edited, treePerson: donnaAsset))
        #expect(people.url == copiedURL)
        #expect(store.chosenPhoto(for: donnaAsset)?.choice.source == PersonPhotoChoiceSource.peopleCover)
    }

    @Test func laterPeopleTabCoverBeatsAnOlderTreeChoiceByTimestampInBothViews() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let store = box.store
        try store.choosePhoto(
            try jpegBytes(shade: 0.3), fileExtension: "jpg", for: donnaAsset,
            source: PersonPhotoChoiceSource.treePick, chosenAt: Date(timeIntervalSince1970: 1_700_000_000))
        // The archive was offline when the cover was picked: no copy, but
        // the profile is stamped later than the tree choice.
        var profile = box.donnaProfile
        profile.photoChosenAt = Date(timeIntervalSince1970: 1_700_000_900)
        let resolver = PersonPhotoResolver(store: store)
        #expect(resolver.treePhoto(for: donnaAsset, bridgedProfile: profile)?.url == box.cover)
        #expect(resolver.treePhoto(for: donnaAsset, bridgedProfile: profile)?.source == .profileCover)
        #expect(resolver.peoplePhoto(for: profile, treePerson: donnaAsset)?.url == box.cover)
        // Unchanged cover on a later edit: no new claim, no copy.
        var again = profile
        #expect(PersonPhotoSync.applyCoverChoice(
            to: &again, previous: profile, profiles: box.profiles, graph: Self.graph, store: store) == nil)
        #expect(again.photoChosenAt == profile.photoChosenAt)
    }

    // MARK: Persistence

    @Test func choiceSurvivesRelaunchAndAdjustCropIsRecordedWhereverItLands() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let chosen = try box.store.choosePhoto(
            try jpegBytes(shade: 0.5), fileExtension: "jpg", for: donnaAsset,
            source: PersonPhotoChoiceSource.treePick)
        // Relaunch = a brand-new store over the same root, and a person
        // re-derived from a re-pulled tree with a NEW pointer but the same FSID.
        let fresh = box.relaunched()
        let repulled = FamilyAssetPerson(gedcomID: "@I999@", name: "Donna Hudson", birthYear: 1959,
                                         familySearchID: "G2CL-86B")
        let read = try #require(fresh.chosenPhoto(for: repulled))
        #expect(read.url == chosen)
        #expect(read.choice.source == PersonPhotoChoiceSource.treePick)
        #expect(PersonPhotoResolver(store: fresh).treePhoto(for: repulled, bridgedProfile: nil)?.url == chosen)

        // Adjust: the crop is saved beside its original (another People/
        // folder) and recorded as the choice by relative path.
        let crop = try fresh.saveCardPhoto(try jpegBytes(shade: 0.6), for: donnaAsset, nextTo: box.ownFolderPhoto)
        #expect(crop.deletingLastPathComponent().lastPathComponent == "Donna_Elaine_Hudson")
        try fresh.recordPhotoChoice(crop, for: donnaAsset, source: PersonPhotoChoiceSource.treeAdjust)
        #expect(box.relaunched().chosenPhoto(for: donnaAsset)?.url == crop)
        #expect(box.relaunched().chosenPhoto(for: donnaAsset)?.choice.file == "Donna_Elaine_Hudson/\(crop.lastPathComponent)")
        #expect(fresh.cardPhotoURL(for: donnaAsset) == crop)
    }

    @Test func personWithoutFamilySearchIDUsesTheOrdinaryRequestFolder() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let sr = FamilyAssetPerson(Self.richardSr)
        #expect(sr.familySearchID == nil)
        let chosen = try box.store.choosePhoto(
            try jpegBytes(shade: 0.5), fileExtension: "jpg", for: sr, source: PersonPhotoChoiceSource.treePick)
        #expect(chosen.deletingLastPathComponent().lastPathComponent.hasPrefix("Richard_Harding_Breen_Sr"))
        #expect(box.relaunched().chosenPhoto(for: sr)?.url == chosen)
    }

    // MARK: Isolation

    @Test func unbridgedTreePersonIsUnaffectedByDonnasChoice() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        try box.store.choosePhoto(
            try jpegBytes(shade: 0.5), fileExtension: "jpg", for: donnaAsset, source: PersonPhotoChoiceSource.treePick)
        let resolver = PersonPhotoResolver(store: box.store)
        let sr = FamilyAssetPerson(Self.richardSr)
        #expect(box.store.chosenPhoto(for: sr) == nil)
        #expect(resolver.treePhoto(for: sr, bridgedProfile: nil) == nil, "Sr has no photo of any kind")
        // Rick (Jr) still gets the group shot through his own attribution.
        let rick = FamilyAssetPerson(Self.rick)
        #expect(resolver.treePhoto(for: rick, bridgedProfile: nil)?.url == box.groupPhoto)
        // A tree without Donna: nobody bridges, no crash.
        let other = GedcomFamilyGraph(gedcomText: "0 @X@ INDI\n1 NAME Only /One/")
        #expect(PersonPhotoBridge.profile(for: other.people["@X@"]!, profiles: box.profiles, graph: other) == nil)
    }

    @Test func poisonedSidecarsAreIgnoredNotFollowed() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let folder = box.peopleDirectory.appendingPathComponent("G2CL-86B", isDirectory: true)
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let sidecar = folder.appendingPathComponent(FamilyAssetStore.chosenPhotoSidecarName)
        let outside = box.base.appendingPathComponent("outside.png")
        try png(outside)
        func write(_ json: String) throws { try json.data(using: .utf8)!.write(to: sidecar) }
        let stamp = "2026-08-29T20:00:00Z"

        // Traversal out of People/.
        try write(#"{"file":"../../outside.png","chosenAt":"\#(stamp)","source":"tree.pick"}"#)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // Absolute path.
        try write(#"{"file":"\#(outside.path)","chosenAt":"\#(stamp)","source":"tree.pick"}"#)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // Deeper than one folder.
        try write(#"{"file":"a/b/c.png","chosenAt":"\#(stamp)","source":"tree.pick"}"#)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // Names a file that vanished.
        try write(#"{"file":"G2CL-86B/gone.png","chosenAt":"\#(stamp)","source":"tree.pick"}"#)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // Names a symlink to an outside image.
        let link = folder.appendingPathComponent("link.png")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        try write(#"{"file":"G2CL-86B/link.png","chosenAt":"\#(stamp)","source":"tree.pick"}"#)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // Corrupt JSON.
        try write("{not json")
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        // The sidecar itself is a symlink.
        try fileManager.removeItem(at: sidecar)
        let realSidecar = box.base.appendingPathComponent("real.json")
        try #"{"file":"RickDonnaBreenFamily/SouthEastMontana1995.png","chosenAt":"\#(stamp)","source":"tree.pick"}"#
            .data(using: .utf8)!.write(to: realSidecar)
        try fileManager.createSymbolicLink(at: sidecar, withDestinationURL: realSidecar)
        #expect(box.store.chosenPhoto(for: donnaAsset) == nil)
        try fileManager.removeItem(at: sidecar)

        // Every poisoned form falls back to the ordinary precedence.
        let resolver = PersonPhotoResolver(store: box.store)
        #expect(resolver.treePhoto(for: donnaAsset, bridgedProfile: box.donnaProfile)?.source == .profileCover)
        #expect(resolver.treePhoto(for: donnaAsset, bridgedProfile: nil)?.url == box.groupPhoto)

        // A poisoned profile cover (not one component) never resolves either.
        var bad = box.donnaProfile
        bad.coverImageFilename = "../outside.png"
        #expect(PersonPhotoResolver.coverURL(bad) == nil)
        bad.coverImageFilename = "G2CL-86B"
        #expect(PersonPhotoResolver.coverURL(bad) == nil)

        // A bad FSID is not a folder name.
        #expect(FamilyAssetStore.safeFamilySearchIDComponent("../x") == nil)
        #expect(FamilyAssetStore.safeFamilySearchIDComponent("") == nil)
        #expect(FamilyAssetStore.safeFamilySearchIDComponent(" g2cl-86b ") == "G2CL-86B")
    }

    @Test func readOnlyAndUnavailableStoresNeverWriteButStillRead() throws {
        let box = try sandbox()
        defer { try? fileManager.removeItem(at: box.base) }
        let chosen = try box.store.choosePhoto(
            try jpegBytes(shade: 0.5), fileExtension: "jpg", for: donnaAsset, source: PersonPhotoChoiceSource.treePick)
        var readOnly = FamilyAssetStore(root: box.store.root, cacheRoot: box.store.cacheRoot, access: .readOnly)
        readOnly.identity = box.store.identity
        #expect(readOnly.chosenPhoto(for: donnaAsset)?.url == chosen)
        #expect(throws: FamilyAssetStore.StoreError.readOnly) {
            try readOnly.choosePhoto(try jpegBytes(shade: 0.1), fileExtension: "jpg", for: donnaAsset,
                                     source: PersonPhotoChoiceSource.treePick)
        }
        #expect(throws: FamilyAssetStore.StoreError.readOnly) {
            try readOnly.recordPhotoChoice(chosen, for: donnaAsset, source: PersonPhotoChoiceSource.treeAdjust)
        }
        let unavailable = FamilyAssetStore(root: box.store.root, cacheRoot: box.store.cacheRoot, access: .unavailable)
        #expect(unavailable.chosenPhoto(for: donnaAsset) == nil)
        #expect(PersonPhotoResolver(store: unavailable).treePhoto(for: donnaAsset, bridgedProfile: box.donnaProfile)?.source == .profileCover,
                "offline archive: the People-tab cover still shows")
        // A profile edit while the archive is unavailable stamps the
        // profile (People tab wins by date) and copies nothing.
        var edited = box.donnaProfile
        edited.coverCropScale = 1.5
        #expect(PersonPhotoSync.applyCoverChoice(
            to: &edited, previous: box.donnaProfile, profiles: box.profiles, graph: Self.graph, store: unavailable) == nil)
        #expect(edited.photoChosenAt != nil)
    }

    @Test func profilePhotoChosenAtRoundTripsAndOlderJSONStillLoads() throws {
        var profile = POIProfile(name: "Donna", referencePath: "/tmp/x")
        profile.photoChosenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(POIProfile.self, from: data).photoChosenAt == profile.photoChosenAt)
        let legacy = #"{"name":"Donna","referencePath":"/tmp/x"}"#.data(using: .utf8)!
        #expect(try JSONDecoder().decode(POIProfile.self, from: legacy).photoChosenAt == nil)
    }
}
