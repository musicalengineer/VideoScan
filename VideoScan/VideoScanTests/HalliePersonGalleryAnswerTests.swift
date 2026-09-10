// HalliePersonGalleryAnswerTests.swift
// The gallery answer (2026-09-10): counts in the prose, every photo and
// document as an attachment in store order, the 24-photo cap, the folder
// to reveal; the offer after a biography and its "yes" / "no" contract
// through the executor's ordinary continuation; the People-tab profile
// gallery; and the document attachment's outline / JSON / web bytes.
// Fixtures in a temp directory, no real path, no model, no shared center.

import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import VideoScan
import VideoScanCore

private let tree = """
0 HEAD
0 @I1@ INDI
1 NAME Mary /O'Connor/
1 SEX F
1 BIRT
2 DATE 1850
1 DEAT
2 DATE 1931
0 @I2@ INDI
1 NAME Christopher /O'Connor/
1 SEX M
1 BIRT
2 DATE 1880
0 @I3@ INDI
1 NAME David /Latta/
1 SEX M
1 BIRT
2 DATE 1902
0 TRLR
"""

@Suite("Person gallery — answer, offer, profile, attachments", .serialized)
struct HalliePersonGalleryAnswerTests {
    typealias Exec = HallieTurnExecutor
    private let fileManager = FileManager.default
    let graph = GedcomFamilyGraph(gedcomText: tree)

    private struct Fixture {
        let base: URL
        let store: FamilyAssetStore
        let configuration: FamilyAssetConfiguration
        var people: URL { store.peopleDirectory }
    }

    private func fixture() throws -> Fixture {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("test_PersonGalleryAnswer-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let roots = FamilyAssetStore.Roots(
            assets: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            thumbnailCache: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let configuration = FamilyAssetConfiguration(
            roots: roots, access: .readWrite, legacyGEDCOMDirectory: nil)
        return Fixture(base: base, store: configuration.makeStore(), configuration: configuration)
    }

    private func writeImage(to url: URL, type: UTType = .png) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let context = try #require(CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.1, green: 0.5, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }

    private func writeText(_ text: String, to url: URL) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func dependencies(_ fixture: Fixture,
                              profileGallery: ArchivistProfileGallery? = nil) -> Exec.Dependencies {
        let configuration = fixture.configuration
        return Exec.Dependencies(
            executePresence: ArchivistPresenceExecutor.execute,
            executeTemporal: ArchivistTemporalExecutor.execute,
            executeAggregate: ArchivistAggregateExecutor.execute,
            executeGraph: { query, inputs, subject in
                ArchivistGraphExecutor.execute(query, inputs: inputs, subject: subject)
            },
            assetConfiguration: { configuration },
            resolveProfileGallery: { _ in profileGallery })
    }

    private var context: Exec.Context {
        .init(profiles: [], graph: graph,
              speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
    }

    // MARK: Gallery answer

    @Test func threePhotosAndAPDFBecomeFourAttachmentsInOrderWithCountsAndAFolderToReveal() throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        let folder = f.people.appendingPathComponent("Mary_OConnor")
        try writeImage(to: folder.appendingPathComponent("a-portrait.png"))
        try writeImage(to: folder.appendingPathComponent("b-wedding.png"))
        try writeImage(to: folder.appendingPathComponent("c-latta.tif"), type: .tiff)
        try writeText("%PDF-1.4\n%%EOF\n", to: folder.appendingPathComponent("birth_certificate.pdf"))
        let mary = try #require(graph.people["@I1@"])

        let r = HallieLineageAnswer.personPhoto(person: mary, store: f.store)
        #expect(r.route == .graph)
        #expect(r.outcome == .answered)
        #expect(r.prose == "Here are 3 photos and 1 document of Mary O'Connor.")
        #expect(r.basisLine == "Basis: 3 photos and 1 document from the Master Archive’s 40_Family_Tree/People folder for this person.")
        #expect(r.queryDescription == "photo: Mary O'Connor")
        #expect(r.catalogPersonName == "Mary O'Connor")
        #expect(r.attachments.map(\.kind) == ["photo", "photo", "photo", "document"])
        let names = r.attachments.map { a -> String in
            switch a {
            case .photo(let p): return p.fileURL.lastPathComponent
            case .document(let d): return d.fileURL.lastPathComponent
            default: return "?"
            }
        }
        #expect(names == ["a-portrait.png", "b-wedding.png", "c-latta.tif", "birth_certificate.pdf"])
        guard case .document(let d)? = r.attachments.last else { Issue.record("no document"); return }
        #expect(d.title == "birth certificate")
        #expect(d.kind == "pdf")
        #expect(d.personName == "Mary O'Connor")
        #expect(r.offeredActions.count == 2)
        #expect(r.offeredActions.first == .openFamilyTreePerson(personID: "@I1@", personName: "Mary O'Connor"))
        if case .revealFolder(let url, let label)? = r.offeredActions.last {
            #expect(url.standardizedFileURL.resolvingSymlinksInPath().path
                    == folder.standardizedFileURL.resolvingSymlinksInPath().path)
            #expect(label == "Show folder in Finder")
        } else {
            Issue.record("no folder to reveal")
        }
        #expect(Exec.offerLabel(.revealFolder(url: folder, label: "Show folder in Finder")) == "Show folder in Finder")
        // The outline the eval harness reads.
        let outline = HallieAttachmentText.lines(r.attachments)
        #expect(outline.count == 4)
        #expect(outline.last == "[document] Mary O'Connor: \(d.fileURL.path)")
    }

    @Test func onePhotoKeepsTheOldLineAndOnlyDocumentsIsSaidHonestly() throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        try writeImage(to: f.people.appendingPathComponent("Mary_OConnor/portrait.png"))
        let mary = try #require(graph.people["@I1@"])
        let one = HallieLineageAnswer.personPhoto(person: mary, store: f.store)
        #expect(one.prose == "Here’s Mary O'Connor.")
        #expect(one.attachments.count == 1)
        #expect(one.basisLine.hasPrefix("Basis: 1 photo and 0 documents from"))

        try writeText("letter", to: f.people.appendingPathComponent("Christopher_OConnor/CIA_recruitment_letter.txt"))
        let christopher = try #require(graph.people["@I2@"])
        let docs = HallieLineageAnswer.personPhoto(person: christopher, store: f.store)
        #expect(docs.outcome == .answered)
        #expect(docs.prose == "Here is 1 document of Christopher O'Connor.")
        #expect(docs.attachments.map(\.kind) == ["document"])
        guard case .document(let d)? = docs.attachments.first else { Issue.record("no document"); return }
        #expect(d.title == "CIA recruitment letter")

        // Nothing at all: the folder card, as before.
        let david = try #require(graph.people["@I3@"])
        let none = HallieLineageAnswer.personPhoto(person: david, store: f.store)
        #expect(none.outcome == .declined)
        #expect(none.prose == "I don’t have a photo of David Latta yet.")
    }

    @Test func thirtyPhotosAreCappedAtTwentyFourAndTheProseSaysSo() throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        for i in 0..<30 {
            try writeImage(to: f.people.appendingPathComponent(String(format: "Mary_OConnor/photo-%02d.png", i)))
        }
        let mary = try #require(graph.people["@I1@"])
        let r = HallieLineageAnswer.personPhoto(person: mary, store: f.store)
        #expect(r.attachments.count == 24)
        #expect(r.prose == "Here are 30 photos of Mary O'Connor — showing the first 24; the rest are in the folder.")
        #expect(r.basisLine.hasPrefix("Basis: 30 photos and 0 documents from"))
        #expect(r.offeredActions.contains { if case .revealFolder = $0 { return true } else { return false } })
    }

    // MARK: Offer after a biography + continuation

    @Test func aBiographyWithTwoPhotosOffersTheGalleryAndYesResumesIt() async throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        try writeImage(to: f.people.appendingPathComponent("Mary_OConnor/one.png"))
        try writeImage(to: f.people.appendingPathComponent("Mary_OConnor/two.png"))
        let mary = try #require(graph.people["@I1@"])
        let context = self.context
        let biography = Exec.Result(
            route: .graph, outcome: .answered,
            prose: "Mary O'Connor was born in 1850 and died in 1931.",
            basisLine: "Basis: family tree.", queryDescription: "shape=graph",
            citations: [], catalogPersonName: mary.name)

        let offered = HallieGalleryOffer.apply(
            to: biography, subject: .tree(mary), store: f.store, profileGallery: nil, context: context)
        #expect(offered.prose == "Mary O'Connor was born in 1850 and died in 1931. I have 2 photos of her in the archive — want to see them all?")
        #expect(offered.basisLine == biography.basisLine, "the offer is a question, not a fact")
        let pending = try #require(offered.clarification)
        #expect(pending.stage == .galleryOffer)
        #expect(pending.candidates.map(\.id) == [.gedcomPersonID("@I1@")])
        #expect(pending.candidates[0].label == "Mary O'Connor")
        #expect(pending.intent.originalQuestion == "show all photos of Mary O'Connor")
        #expect(pending.intent.ast == .presence(.init(people: ["Mary O'Connor"], mediaKind: .photo)))
        #expect(Exec.ClarificationStage.galleryOffer.accepts(.gedcom))
        #expect(Exec.ClarificationStage.galleryOffer.accepts(.peopleProfile))
        #expect(!Exec.ClarificationStage.galleryOffer.accepts(.cyberBrain))

        // "yes" (and its cousins) select the single candidate.
        for reply in ["yes", "Yes!", "sure", "please", "yes please"] {
            #expect(Exec.clarificationSelection(reply, from: pending.candidates) == .gedcomPersonID("@I1@"), Comment(rawValue: reply))
        }
        // "no" is not a selection; the client's decline table says "Okay."
        #expect(Exec.clarificationSelection("no", from: pending.candidates) == nil)
        for reply in ["no", "No thanks.", "not now", "cancel", "never mind"] {
            #expect(HallieClarificationDecline.matches(reply), Comment(rawValue: reply))
        }
        #expect(!HallieClarificationDecline.matches("show me her mother"))
        #expect(HallieClarificationDecline.reply(for: .galleryOffer) == "Okay.")
        #expect(HallieClarificationDecline.reply(for: .gedcomPerson) == "Okay — I won't guess which person you meant.")

        // The continuation runs the gallery for the chosen person.
        let gallery = try await Exec.continue(
            pending: pending, selecting: .gedcomPersonID("@I1@"),
            context: context, dependencies: dependencies(f))
        #expect(gallery.outcome == .answered)
        #expect(gallery.prose == "Here are 2 photos of Mary O'Connor.")
        #expect(gallery.attachments.map(\.kind) == ["photo", "photo"])
        #expect(gallery.clarification == nil)

        // One photo (already beside the biography) is not worth an offer;
        // a declined biography is never extended.
        try fileManager.removeItem(at: f.people.appendingPathComponent("Mary_OConnor/two.png"))
        let single = HallieGalleryOffer.apply(
            to: biography, subject: .tree(mary), store: f.store, profileGallery: nil, context: context)
        #expect(single == biography)
        let declined = Exec.Result(
            route: .graph, outcome: .declined, prose: "I don’t find her.",
            basisLine: "Basis: none.", queryDescription: nil, citations: [], catalogPersonName: mary.name)
        try writeImage(to: f.people.appendingPathComponent("Mary_OConnor/two.png"))
        #expect(HallieGalleryOffer.apply(to: declined, subject: .tree(mary), store: f.store,
                                         profileGallery: nil, context: context) == declined)
        // Pronoun follows the record's sex; a document counts too.
        try writeText("x", to: f.people.appendingPathComponent("Christopher_OConnor/army.pdf"))
        try writeImage(to: f.people.appendingPathComponent("Christopher_OConnor/pa.png"))
        let christopher = try #require(graph.people["@I2@"])
        let his = HallieGalleryOffer.apply(
            to: Exec.Result(route: .graph, outcome: .answered, prose: "Christopher O'Connor was born in 1880.",
                            basisLine: "Basis: family tree.", queryDescription: nil, citations: [],
                            catalogPersonName: christopher.name),
            subject: .tree(christopher), store: f.store, profileGallery: nil, context: context)
        #expect(his.prose.hasSuffix("I have 1 photo and 1 document of him in the archive — want to see them all?"))
    }

    // MARK: People-tab profile gallery

    @Test func aPeopleTabPersonOutsideTheTreeIsAnsweredFromTheReferenceFolderCoverFirst() async throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        let reference = f.base.appendingPathComponent("POI/Donna", isDirectory: true)
        try writeImage(to: reference.appendingPathComponent("zz-cover.png"))
        try writeImage(to: reference.appendingPathComponent("a-beach.png"))
        try writeImage(to: reference.appendingPathComponent("b-cape.jpg"), type: .jpeg)
        try writeText("not an image", to: reference.appendingPathComponent("c-poison.png"))
        try fileManager.createSymbolicLink(
            at: reference.appendingPathComponent("d-link.png"),
            withDestinationURL: reference.appendingPathComponent("a-beach.png"))
        var profile = POIProfile(name: "Donna", referencePath: reference.path)
        profile.aliases = ["Donna Breen"]
        profile.coverImageFilename = "zz-cover.png"

        let gallery = try #require(ArchivistProfileGallery.resolve(personName: "donna breen", profiles: [profile]))
        #expect(gallery.photoURLs.map(\.lastPathComponent) == ["zz-cover.png", "a-beach.png", "b-cape.jpg"])
        #expect(gallery.folderURL == reference.standardizedFileURL)
        // Two profiles by that name: nobody is chosen.
        #expect(ArchivistProfileGallery.resolve(personName: "Donna", profiles: [profile, profile]) == nil)

        // Through the executor: the tree does not know Donna, the People
        // tab does — presence route, three photos, cover first, plus the
        // archive's name-keyed folder.
        try writeText("recipe", to: f.people.appendingPathComponent("Donna/Recipe_cards.pdf"))
        let context = Exec.Context(
            profiles: [.init(stableID: "donna", canonicalName: "Donna", aliases: ["Donna Breen"], sex: .female)],
            graph: graph,
            speakers: .init(ownerName: "Rick Breen", archivistName: nil, archivistPersonName: nil))
        let intent = Exec.Intent(
            originalQuestion: "show all photos of donna",
            ast: .presence(.init(people: ["Donna"], mediaKind: .photo)))
        let r = try await Exec.execute(.init(intent: intent), context: context,
                                       dependencies: dependencies(f, profileGallery: gallery))
        #expect(r.route == .presence)
        #expect(r.outcome == .answered)
        #expect(r.catalogPersonName == "Donna")
        #expect(r.prose == "Here are 3 photos and 1 document of Donna.")
        #expect(r.attachments.map(\.kind) == ["photo", "photo", "photo", "document"])
        guard case .photo(let first)? = r.attachments.first else { Issue.record("no photo"); return }
        #expect(first.fileURL.lastPathComponent == "zz-cover.png")
        #expect(first.personGedcomID == nil)
        #expect(r.basisLine == "Basis: 3 photos and 1 document from the People-tab reference folder and the Master Archive’s 40_Family_Tree/People folder for this person.")
        #expect(r.offeredActions.count == 2, "the reference folder and the archive folder")

        // The deterministic shape hands this name to the executor instead
        // of the tree's "I don't find" line.
        #expect(HallieLineageAnswer.personPhoto("Donna", context: context) == nil)
        // The offer after a People-tab biography carries the profile.
        let offered = HallieGalleryOffer.apply(
            to: Exec.Result(route: .graph, outcome: .answered, prose: "Donna is in the People tab.",
                            basisLine: "Basis: People tab.", queryDescription: nil, citations: [],
                            catalogPersonName: "Donna"),
            subject: .profile(context.profiles![0]), store: f.store, profileGallery: gallery, context: context)
        #expect(offered.prose.hasSuffix("I have 3 photos and 1 document of her in the archive — want to see them all?"))
        let pending = try #require(offered.clarification)
        #expect(pending.candidates.map(\.id) == [.profileStableID("donna")])
        let resumed = try await Exec.continue(pending: pending, selecting: .profileStableID("donna"),
                                              context: context, dependencies: dependencies(f, profileGallery: gallery))
        #expect(resumed.attachments.count == 4)
        #expect(resumed.route == .presence)
    }

    // MARK: Attachment JSON + web bytes

    @Test @MainActor func aDocumentAttachmentIsServedAsPDFBytesAndImagesStayThumbnails() async throws {
        let f = try fixture()
        defer { try? fileManager.removeItem(at: f.base) }
        let pdf = f.people.appendingPathComponent("Mary_OConnor/birth_certificate.pdf")
        try writeText("%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n", to: pdf)
        let png = f.people.appendingPathComponent("Mary_OConnor/portrait.png")
        try writeImage(to: png)
        let link = f.people.appendingPathComponent("Mary_OConnor/link.pdf")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: pdf)

        let bridge = Self.bridge()
        let json = bridge.attachmentJSON(.document(HallieDocumentAttachment(personName: "Mary O'Connor", fileURL: pdf)))
        #expect(json["kind"] as? String == "document")
        #expect(json["name"] as? String == "Mary O'Connor")
        #expect(json["title"] as? String == "birth certificate")
        #expect(json["ext"] as? String == "pdf")
        let url = try #require(json["url"] as? String)
        #expect(url.hasPrefix("/api/attachment/"))
        #expect(!url.contains("Mary_OConnor"), "the page never sees a path")

        let served = await bridge.attachmentImage(token: String(url.dropFirst("/api/attachment/".count)))
        #expect(served.status == 200)
        #expect(served.headers.contains { $0.0 == "Content-Type" && $0.1 == "application/pdf" })
        if case .data(let bytes) = served.body {
            #expect(bytes == (try Data(contentsOf: pdf)))
        } else {
            Issue.record("document bytes expected")
        }
        let image = await bridge.attachmentImage(token: bridge.attachmentToken(for: png))
        #expect(image.headers.contains { $0.0 == "Content-Type" && $0.1 == "image/jpeg" })
        let linked = await bridge.attachmentImage(token: bridge.attachmentToken(for: link))
        #expect(linked.status == 404)
        #expect(HallieWebBridge.documentContentType(forExtension: "docx")
                == "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
        #expect(HallieWebBridge.documentContentType(forExtension: "exe") == nil)
        #expect(HallieDocumentAttachment.title(for: URL(fileURLWithPath: "/x/CIA_recruitment_letter.PDF")) == "CIA recruitment letter")
    }

    @MainActor
    private static func bridge() -> HallieWebBridge {
        let deps = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in .init(ast: .presence(.init(people: ["Donna"])), responderHost: "fixture") },
            loadProfiles: { [] },
            loadGraph: { nil },
            loadCyberBrain: { nil },
            recordTestimony: { _ in },
            loadSpeakers: { .init(ownerName: "Rick", archivistName: "Hallie Mae") },
            executeRequest: { _, _ in
                HallieTurnExecutor.Result(
                    route: .presence, outcome: .declined, prose: "fixture",
                    basisLine: "Basis: fixture", queryDescription: nil, citations: [], catalogPersonName: nil)
            },
            continueTurn: { pending, id, context in
                try await HallieTurnExecutor.continue(pending: pending, selecting: id, context: context)
            },
            resolveBiographyPhoto: { _ in nil })
        return HallieWebBridge(
            records: { [] },
            record: { _ in nil },
            configuration: {
                .init(passphrase: "", archivistName: "Hallie Mae", archivistPersonName: nil,
                      hosts: ["fixture.invalid"], modelName: "fixture-model", composeWithModel: false)
            },
            dependencies: deps)
    }
}
