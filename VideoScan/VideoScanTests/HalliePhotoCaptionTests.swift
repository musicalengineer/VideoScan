// HalliePhotoCaptionTests.swift
// Live miss 2026-08-26 23:36Z: after Hallie showed the wrong photo for
// Richard Sr, "this photo is a photo of me and my family with donna and
// the boys." was routed as a catalog search. It is a caption + correction.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

struct HalliePhotoCaptionTests {
    typealias C = HalliePhotoCaption

    // MARK: Intent detection

    @Test func theLiveSentenceIsACaptionNamingEveryone() throws {
        let s = try #require(C.detect("this photo is a photo of me and my family with donna and the boys."))
        #expect(s.caption == "me and my family with donna and the boys")
        #expect(s.mentionsSpeaker)
        #expect(s.names == ["Donna"])
        #expect(s.childrenPhrase == "the boys")
        #expect(!s.mentionsSpouse)
        #expect(s.year == nil && s.place == nil)
    }

    @Test func manyCaptionPhrasingsAreRecognised() throws {
        let cases: [(String, [String])] = [
            ("That's a photo of Donna and me at the lake in 1995", ["Donna"]),
            ("this picture shows Dad and Muriel", ["Muriel"]),
            ("That picture is Donna, Tim and Matt", ["Donna", "Tim", "Matt"]),
            ("This is a picture of my wife Donna", ["Donna"]),
            ("this photo is from our wedding", []),
        ]
        for (text, names) in cases {
            let s = C.detect(text)
            #expect(s != nil, Comment(rawValue: text))
            #expect(s?.names == names, Comment(rawValue: text))
        }
        let lake = try #require(C.detect("That's a photo of Donna and me at the lake in 1995"))
        #expect(lake.year == 1995)
        #expect(lake.place == "The Lake")
        #expect(lake.mentionsSpeaker)
        #expect(C.detect("This is a picture of my wife")?.mentionsSpouse == true)
        #expect(C.detect("this picture shows Dad and Muriel")?.mentionsFather == true)
        #expect(C.detect("that's a photo of my mother and me")?.mentionsMother == true)
    }

    @Test func searchesAndQuestionsAreNotCaptions() {
        for text in [
            "find photos of me and donna",
            "show me photos of donna",
            "who is in this photo?",
            "this photo is of whom",
            "is this a photo of donna",
            "tell me about richard harding breen sr",
            "what year is this photo from?",
        ] {
            #expect(C.detect(text) == nil, Comment(rawValue: text))
        }
    }

    // MARK: Reply and file-name hint

    @Test func theReplyReadsAsSpecified() {
        #expect(C.reply(shows: ["you", "Donna", "the boys"], place: "Montana", year: 1995,
                        excludedName: "Richard Harding Breen Sr", problems: [])
            == "Got it — I've noted this photo shows you, Donna and the boys (Montana, 1995), and I won't show it for Richard Harding Breen Sr again.")
        #expect(C.reply(shows: ["you"], place: nil, year: nil, excludedName: nil, problems: [])
            == "Got it — I've noted this photo shows you.")
        let hint = C.filenameHint(URL(fileURLWithPath: "/People/RickDonnaBreenFamily/SouthEastMontana1995.jpg"))
        #expect(hint.place == "South East Montana")
        #expect(hint.year == 1995)
    }

    // MARK: Conversation memory remembers the last photo

    @Test func memoryKeepsTheLastShownPhotoUntilAnAnswerWithoutOne() {
        var memory = HallieTurnExecutor.ConversationMemory()
        let photo = HalliePhotoAttachment(
            personName: "Richard Harding Breen Sr",
            fileURL: URL(fileURLWithPath: "/x/People/RickDonnaBreenFamily/SouthEastMontana1995.jpg"),
            personGedcomID: "@I2@")
        func result(_ route: HallieTurnExecutor.Route, attachments: [HallieAttachment] = []) -> HallieTurnExecutor.Result {
            .init(route: route, outcome: .answered, prose: "x", basisLine: "b",
                  queryDescription: nil, citations: [], catalogPersonName: nil, attachments: attachments)
        }
        memory.record(intent: nil, result: result(.graph, attachments: [.photo(photo)]))
        #expect(memory.lastPhotoAttachment == photo)
        memory.record(intent: nil, result: result(.telling))
        #expect(memory.lastPhotoAttachment == photo, "a telling (or caption) keeps it")
        memory.record(intent: nil, result: result(.followUp))
        #expect(memory.lastPhotoAttachment == photo)
        memory.record(intent: nil, result: result(.graph))
        #expect(memory.lastPhotoAttachment == nil, "a new answer with no photo clears it")
        memory.record(intent: nil, result: result(.graph, attachments: [.photo(photo)]))
        memory.record(intent: nil, result: result(.reset))
        #expect(memory.lastPhotoAttachment == nil)
    }

    // MARK: Through the coordinator: caption round-trip + exclusion + reply

    private final class Recorder: @unchecked Sendable {
        var captions: [CyberBrainWriter.PhotoCaption] = []
        var exclusions: [(URL, String, String?, String?)] = []
        var translated: [String] = []
        var failExclusion = false
    }

    private func dependencies(_ recorder: Recorder, graph: GedcomFamilyGraph?) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { question, _, _ in
                recorder.translated.append(question)
                throw CancellationError()
            },
            loadProfiles: { [] },
            loadGraph: { graph },
            loadCyberBrain: { nil },
            recordPhotoCaption: { recorder.captions.append($0) },
            excludePhoto: { url, id, by, caption in
                if recorder.failExclusion { throw FamilyAssetStore.StoreError.readOnly }
                recorder.exclusions.append((url, id, by, caption))
            },
            loadSpeakers: {
                .init(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                      ownerFamilySearchID: "GVQV-NW3")
            },
            executeRequest: { _, _ in throw CancellationError() },
            continueTurn: { _, _, _ in throw CancellationError() },
            resolveBiographyPhoto: { _ in nil })
    }

    private static let photo = HalliePhotoAttachment(
        personName: "Richard Harding Breen Sr",
        fileURL: URL(fileURLWithPath: "/Volumes/Archive/40_Family_Tree/People/RickDonnaBreenFamily/SouthEastMontana1995.jpg"),
        personGedcomID: "@I2@")

    private static func memoryShowing(_ photo: HalliePhotoAttachment) -> HallieTurnExecutor.ConversationMemory {
        var memory = HallieTurnExecutor.ConversationMemory()
        memory.record(intent: nil, result: .init(
            route: .graph, outcome: .answered, prose: "He was…", basisLine: "b",
            queryDescription: nil, citations: [], catalogPersonName: photo.personName,
            attachments: [.photo(photo)]))
        return memory
    }

    @Test @MainActor func theLiveTurnCaptionsExcludesAndReplies() async throws {
        let recorder = Recorder()
        let graph = FamilyAssetIdentityDirectoryTests.graph
        let response = try await HallieAppTurnCoordinator.execute(
            question: "this photo is a photo of me and my family with donna and the boys.",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture",
            memory: Self.memoryShowing(Self.photo),
            dependencies: dependencies(recorder, graph: graph))
        #expect(response.result.route == .telling)
        #expect(response.result.prose
            == "Got it — I've noted this photo shows you, Donna and the boys (South East Montana, 1995), and I won't show it for Richard Harding Breen Sr again.")
        #expect(recorder.translated.isEmpty, "never a search")
        #expect(response.executedIntent == nil)

        let caption = try #require(recorder.captions.first)
        #expect(caption.subjects.map(\.gedcomPersonID) == ["@I1@", "@I3@", "@I7@", "@I8@"],
                "me → owner by FamilySearch ID; Donna → his wife; the boys → his children")
        #expect(caption.text == "me and my family with donna and the boys")
        #expect(caption.photoPath == Self.photo.fileURL.path)
        #expect(caption.speakerName == "Rick Breen")

        #expect(recorder.exclusions.count == 1)
        #expect(recorder.exclusions.first?.1 == "@I2@")
        #expect(recorder.exclusions.first?.0 == Self.photo.fileURL)
        #expect(recorder.exclusions.first?.2 == "Rick Breen")

        // Round trip through the real writer: one shared note, cited to the photo.
        let receipt = try CyberBrainWriter.appending(caption: caption, to: nil)
        let index = try CyberBrainIndex(archive: receipt.archive)
        let item = try #require(index.allActiveItems(for: receipt.personID).first)
        #expect(item.kind == .note)
        #expect(item.subjectPersonIDs.count == 4)
        #expect(item.sourceIDs.contains(receipt.sourceID))
        #expect(index.source(id: receipt.sourceID)?.locator == "People/RickDonnaBreenFamily/SouthEastMontana1995.jpg")
        #expect(index.source(id: receipt.sourceID)?.notes?.contains(Self.photo.fileURL.path) == true)
        #expect(index.source(id: receipt.sourceID)?.type == .mediaEvidence)
        for id in item.subjectPersonIDs {
            #expect(index.allActiveItems(for: id).map(\.id) == [item.id], "findable from every subject")
        }
        #expect(index.people(gedcomPersonID: "@I3@").first?.canonicalName == "Donna Elaine Hudson")
    }

    @Test @MainActor func aCaptionNamingTheShownPersonExcludesNobody() async throws {
        let recorder = Recorder()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "that's a photo of Dad and Muriel in 1938",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: [], modelName: "fixture",
            memory: Self.memoryShowing(Self.photo),
            dependencies: dependencies(recorder, graph: FamilyAssetIdentityDirectoryTests.graph))
        #expect(recorder.exclusions.isEmpty, "Dad = the owner's father = the person it was shown for")
        #expect(recorder.captions.first?.subjects.map(\.gedcomPersonID) == ["@I2@", "@I5@"])
        #expect(response.result.prose == "Got it — I've noted this photo shows your dad and Muriel (1938).",
                "a year said in the caption is used alone — never mixed with the file-name place")
    }

    @Test @MainActor func aFailedExclusionIsSaidNotHidden() async throws {
        let recorder = Recorder()
        recorder.failExclusion = true
        let response = try await HallieAppTurnCoordinator.execute(
            question: "this photo is me and Donna",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: [], modelName: "fixture",
            memory: Self.memoryShowing(Self.photo),
            dependencies: dependencies(recorder, graph: FamilyAssetIdentityDirectoryTests.graph))
        #expect(response.result.prose.hasPrefix("Got it — I've noted this photo shows you and Donna (South East Montana, 1995)."))
        #expect(response.result.prose.contains("I couldn't mark it as not a photo of Richard Harding Breen Sr"))
    }

    @Test @MainActor func withoutAShownPhotoOrWithASearchTheTurnFallsThrough() async throws {
        let recorder = Recorder()
        let deps = dependencies(recorder, graph: FamilyAssetIdentityDirectoryTests.graph)
        // No photo in memory → ordinary path (our fixture translator throws).
        await #expect(throws: CancellationError.self) {
            try await HallieAppTurnCoordinator.execute(
                question: "this photo is me and Donna",
                records: [], referent: .init(recordID: nil, temporalDate: nil),
                hosts: [], modelName: "fixture",
                memory: .init(), dependencies: deps)
        }
        // A search after a photo → still a search.
        await #expect(throws: CancellationError.self) {
            try await HallieAppTurnCoordinator.execute(
                question: "find photos of me and donna",
                records: [], referent: .init(recordID: nil, temporalDate: nil),
                hosts: [], modelName: "fixture",
                memory: Self.memoryShowing(Self.photo), dependencies: deps)
        }
        #expect(recorder.captions.isEmpty && recorder.exclusions.isEmpty)
    }

    @Test func theExclusionSidecarIsHonouredEndToEnd() throws {
        // The live write path: FamilyAssetStore.excludePhoto → photoURLs(for:).
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("HalliePhotoCaption-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        var store = FamilyAssetStore(
            root: base.appendingPathComponent("40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("thumbs", isDirectory: true))
        store.identity = nil
        let photo = store.peopleDirectory
            .appendingPathComponent("RickDonnaBreenFamily", isDirectory: true)
            .appendingPathComponent("SouthEastMontana1995.png")
        try fm.createDirectory(at: photo.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
            .write(to: photo)
        let sr = FamilyAssetPerson(gedcomID: "@I2@", name: "Richard Harding Breen Sr")
        #expect(store.photoURLs(for: sr).count == 1, "name-only rule shows it before the correction")
        try store.excludePhoto(photo, from: "@I2@", notedBy: "Rick Breen", caption: "me and my family")
        #expect(store.photoURLs(for: sr).isEmpty)
        #expect(store.photoURLs(for: FamilyAssetPerson(gedcomID: "@I1@", name: "Richard Harding Breen Jr")).count == 1)
        let sidecar = try String(contentsOf: FamilyAssetStore.exclusionSidecarURL(for: photo), encoding: .utf8)
        #expect(sidecar.contains("\"@I2@\"") && sidecar.contains("Rick Breen"))
    }
}
