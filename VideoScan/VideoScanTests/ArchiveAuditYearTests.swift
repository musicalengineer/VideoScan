import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Archive ▸ Audit <year>… (Rick 2026-10-07). LOGIC: one test per repeat
// rule (each evidence type), the events / unlabeled split, the verdict
// line, and the "keep both" hiding rule. ISOLATION: the sidecar round-trips
// through a temp directory, a poisoned file starts empty, and the default
// directory under a test host is scratch. Occasion tags re-colour the cue
// and the year strip.

private func card(_ title: String, year: Int? = 1995, occasion: ArchiveOccasion? = .unlabeled,
                  word: String? = nil, seconds: Double = 120) -> ArchiveAuditInput {
    let id = UUID()
    var c = ArchiveAuditInput(id: id, title: title, year: year, durationSeconds: seconds)
    if let occasion {
        c.occasion = occasion == .unlabeled ? .unlabeled
            : ArchiveOccasionCue(occasion: occasion, word: word ?? occasion.word, help: "")
    }
    c.memberIDs = [id]
    c.lineageKeys = [id]
    return c
}

private func kinds(_ r: ArchiveAuditReport) -> [ArchiveAuditRepeatKind] { r.repeats.map(\.kind) }

private let christmasMorning = """
    okay everybody look over here it is christmas morning and the kids are coming down the stairs \
    to see what santa brought them this year grandma is sitting by the tree with her coffee
    """

@Suite("Audit year — repeat rules")
struct ArchiveAuditYearRulesTests {

    @Test func sameContentFingerprintIsSameFootage() {
        var a = card("Christmas tape"), b = card("Xmas copy")
        a.contentHashes = ["v1:abc"]; b.contentHashes = ["v1:abc"]
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b, card("Beach")], decisions: [])
        #expect(kinds(r) == [.sameFootage])
        #expect(Set(r.repeats[0].itemIDs) == [a.id, b.id])
        #expect(r.repeats[0].evidence.first?.contains("same content fingerprint") == true)
    }

    @Test func madeFromTheOtherIsSameFootage() {
        let a = card("Birthday master")
        var b = card("Birthday cleaned")
        b.lineageKeys.append(a.id)                      // b.derivedFrom == a
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b], decisions: [])
        #expect(kinds(r) == [.sameFootage])
        #expect(r.repeats[0].evidence == ["“Birthday cleaned” was made from “Birthday master”"])
    }

    @Test func sameSourceRecordIsSameFootage() {
        let source = UUID()
        var a = card("Copy one"), b = card("Copy two")
        a.lineageKeys.append(source); b.lineageKeys.append(source)
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b], decisions: [])
        #expect(kinds(r) == [.sameFootage])
        #expect(r.repeats[0].evidence.first?.contains("same source recording") == true)
    }

    @Test func sameFootageGroupIsSameFootage() {
        let g = UUID()
        var a = card("Lake 1"), b = card("Lake 2"), c = card("Lake 3")
        a.footageGroupIDs = [g]; b.footageGroupIDs = [g]; c.footageGroupIDs = [g]
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b, c], decisions: [])
        #expect(kinds(r) == [.sameFootage])
        #expect(r.repeats[0].itemIDs.count == 3, "one group, not three pairs")
        #expect(r.repeats[0].evidence.allSatisfy { $0.contains("Find Similar Footage") })
    }

    @Test func transcriptOverlapIsPossiblySame() {
        var a = card("Morning A"), b = card("Morning B"), c = card("Picnic")
        a.transcript = christmasMorning
        b.transcript = christmasMorning + " and then we all had pancakes in the kitchen"
        c.transcript = "the picnic at the lake was windy and the dog chased the frisbee all afternoon long"
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b, c], decisions: [])
        #expect(kinds(r) == [.possiblySame])
        #expect(Set(r.repeats[0].itemIDs) == [a.id, b.id])
        #expect(r.repeats[0].evidence[0].contains("possibly"))
    }

    @Test func transcriptOverlapThresholdAndShortSpeech() {
        let a = ArchiveTranscriptOverlap.shingles(christmasMorning)
        let unrelated = ArchiveTranscriptOverlap.shingles(
            "we drove to the cape on saturday and the traffic over the bridge was terrible again")
        #expect(ArchiveTranscriptOverlap.containment(a, a) == 1)
        #expect(ArchiveTranscriptOverlap.containment(a, unrelated) < ArchiveTranscriptOverlap.threshold)
        let short = ArchiveTranscriptOverlap.shingles("okay okay okay okay okay okay")
        #expect(ArchiveTranscriptOverlap.containment(short, short) == 0, "too little speech to judge")
    }

    @Test func transcriptPairAlreadySameFootageIsNotRepeated() {
        var a = card("A"), b = card("B")
        a.contentHashes = ["v1:x"]; b.contentHashes = ["v1:x"]
        a.transcript = christmasMorning; b.transcript = christmasMorning
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b], decisions: [])
        #expect(kinds(r) == [.sameFootage])
    }

    @Test func threeVideosOfOneOccasionIsSameEvent() {
        let two = [card("Cake", occasion: .birthday), card("Candles", occasion: .birthday)]
        #expect(ArchiveAuditBuilder.build(year: 1995, inputs: two, decisions: []).repeats.isEmpty)
        let four = two + [card("Presents", occasion: .birthday), card("Games", occasion: .birthday)]
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: four, decisions: [])
        #expect(kinds(r) == [.sameEvent])
        #expect(r.repeats[0].itemIDs.count == 4)
        #expect(r.repeats[0].evidence[0].hasPrefix("4 videos are 🎂 Birthday"))
    }

    @Test func sharedLineageWithAnotherYearIsFiledFromAnotherYear() {
        let tape = card("Tape 12", year: 1992)
        var dub = card("Tape 12 dub", year: 1995)
        dub.lineageKeys.append(tape.id)
        let g = UUID()
        var x = card("Picnic", year: 1995), y = card("Picnic again", year: 1992)
        x.footageGroupIDs = [g]; y.footageGroupIDs = [g]
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [tape, dub, x, y], decisions: [])
        let filed = r.filedFromOtherYears
        #expect(filed.count == 2)
        #expect(filed.allSatisfy { $0.otherYear == 1992 })
        #expect(filed.contains { $0.itemIDs == [dub.id] && $0.otherYearIDs == [tape.id] })
        #expect(r.items[tape.id] != nil, "the other-year relative is nameable in the sheet")
        #expect(r.repeatCount == 0, "filed-from-another-year is not counted as a repeat")
        #expect(r.verdict == "1995: 0 events · no repeats · 2 filed from 1992")
    }

    @Test func eventsAndUnlabeledAndVerdict() {
        var a = card("Xmas", occasion: .christmas), b = card("Turkey", occasion: .thanksgiving)
        let c = card("Camp", occasion: .trip, word: "Camping"), d = card("Lake", occasion: .trip, word: "Lake")
        let u = card("clip0042"), photo = card("Portrait", occasion: nil)
        a.contentHashes = ["v1:h"]; b.contentHashes = ["v1:h"]
        let r = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b, c, d, u, photo, card("Other year", year: 1990)],
                                          decisions: [])
        #expect(r.events.map(\.word) == ["Christmas", "Thanksgiving", "Camping", "Lake"])
        #expect(r.unlabeledIDs == [u.id])
        #expect(r.verdict == "1995: 4 events · 1 repeat")
    }

    @Test func keepBothHidesTheGroupUntilANewMemberJoins() {
        var a = card("A"), b = card("B")
        a.contentHashes = ["v1:z"]; b.contentHashes = ["v1:z"]
        let decision = ArchiveAuditDecision(kind: .sameFootage, itemIDs: [b.id, a.id], decidedAt: Date())
        let hidden = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b], decisions: [decision])
        #expect(hidden.repeats.isEmpty && hidden.dismissedCount == 1)
        #expect(hidden.verdict == "1995: 0 events · no repeats")
        // A different KIND of decision on the same ids hides nothing.
        let otherKind = ArchiveAuditDecision(kind: .possiblySame, itemIDs: [a.id, b.id], decidedAt: Date())
        #expect(ArchiveAuditBuilder.build(year: 1995, inputs: [a, b], decisions: [otherKind]).repeats.count == 1)
        // A third copy turns up: new information, so it asks again.
        var c = card("C"); c.contentHashes = ["v1:z"]
        let again = ArchiveAuditBuilder.build(year: 1995, inputs: [a, b, c], decisions: [decision])
        #expect(again.repeats.count == 1 && again.dismissedCount == 0)
    }
}

@Suite("Audit year — keep-both and occasion-tag sidecar")
@MainActor
struct ArchiveAuditStoreTests {

    private func tempDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("archive-audit-tests-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func keepBothRoundTripsThroughTheSidecar() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = UUID(), b = UUID()
        let store = ArchiveAuditStore(directory: dir)
        #expect(store.keepBoth(kind: .sameFootage, ids: [a, b], titles: ["A", "B"]))
        #expect(!store.keepBoth(kind: .sameFootage, ids: [b, a]), "same group twice is a no-op")
        #expect(await store.save())

        let reloaded = ArchiveAuditStore(directory: dir)
        await reloaded.loadIfNeeded()
        #expect(reloaded.decisionCount == 1)
        #expect(reloaded.hasDecision(kind: .sameFootage, ids: [a, b]))
        let index = ArchiveAuditDecisionIndex(reloaded.decisions)
        #expect(index.covers(kind: .sameFootage, ids: [b, a]))
        #expect(reloaded.forgetDecision(kind: .sameFootage, ids: [a, b]))
        #expect(reloaded.decisionCount == 0)
    }

    @Test func occasionTagRoundTripsAndClears() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID(), other = UUID()
        let store = ArchiveAuditStore(directory: dir)
        store.setTag(itemID: id, occasion: .christmas, title: "clip0042")
        store.setTag(itemID: other, occasion: .other, word: " Graduation ", title: "clip0043")
        #expect(await store.save())

        let reloaded = ArchiveAuditStore(directory: dir)
        await reloaded.loadIfNeeded()
        #expect(reloaded.tag(for: id)?.cue.occasion == .christmas)
        #expect(reloaded.tag(for: other)?.cue.word == "Graduation")
        #expect(reloaded.clearTag(itemID: id))
        #expect(reloaded.tag(for: id) == nil)
    }

    @Test func poisonedSidecarStartsEmpty() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(ArchiveAuditStore.filename)
        try Data("{\"storeVersion\":1,\"decisions\":[{\"trunc".utf8).write(to: url)
        let store = ArchiveAuditStore(directory: dir)
        await store.loadIfNeeded()
        #expect(store.decisionCount == 0 && store.tags.isEmpty)

        try Data("{\"storeVersion\":99,\"savedAt\":\"2026-10-07T00:00:00Z\",\"decisions\":[],\"tags\":[]}".utf8).write(to: url)
        let future = ArchiveAuditStore(directory: dir)
        await future.loadIfNeeded()
        #expect(future.decisionCount == 0, "a future store version is ignored, not trusted")
    }

    @Test func defaultDirectoryIsScratchUnderATestHost() {
        let path = ArchiveAuditStore.defaultDirectory.path
        #expect(path.contains("VideoScan-tests"))
        #expect(!path.contains("Application Support"))
    }
}

@Suite("Audit year — occasion tags on the decade page")
struct ArchiveOccasionTagTests {

    private func item(_ title: String, kind: ArchiveTimelineItem.Kind = .video) -> ArchiveTimelineItem {
        var i = ArchiveTimelineItem(id: UUID(), title: title, archiveFilename: title + ".mov",
                                    relPath: "1990-1999/1995/\(title).mov", year: 1995, kind: kind,
                                    durationSeconds: 60, peopleText: "", isVerified: true)
        i.occasion = kind == .video ? .unlabeled : nil
        return i
    }

    @Test func tagRecoloursTheCueAndTheYearStrip() {
        let video = item("clip0042"), photo = item("portrait", kind: .photo)
        let tag = ArchiveOccasionTag(itemID: video.id, occasion: "christmas", word: "Christmas", taggedAt: Date())
        let photoTag = ArchiveOccasionTag(itemID: photo.id, occasion: "birthday", word: "Birthday", taggedAt: Date())
        let tagged = ArchiveOccasionTags.apply([video.id: tag, photo.id: photoTag], to: [video, photo])
        #expect(tagged[0].occasion?.occasion == .christmas)
        #expect(tagged[0].occasion?.help.contains("you tagged") == true)
        #expect(tagged[1].occasion == nil, "photos carry no cue, tagged or not")
        let strip = ArchiveTimelineSnapshot.build(items: tagged, matching: "").timeline.decades[0].years[0].occasionStrip
        #expect(strip.segments.map(\.occasion) == [.christmas])
    }

    @Test func unknownOccasionInTheFileReadsAsOther() {
        let tag = ArchiveOccasionTag(itemID: UUID(), occasion: "solstice", word: "", taggedAt: Date())
        #expect(tag.cue.occasion == .other && tag.cue.word == "Other")
    }
}
