// HalliePlaceFacetTests.swift
// Hallie's deterministic PLACE facet (Rick 2026-09-12) — five dimensions:
//
//   - LOGIC: the facet step (keyword way, question way, no-op without
//     places), exact matching in the executor (whole phrase / town-only,
//     never substring), AND with a person, the relax ladder dropping the
//     place, the place-only sentence, the not-found sentence, the record
//     route ("where was this taken"), the AST decode.
//   - SCALE: facet match and known-place collection over 100k snapshots.
//   - ISOLATION: no UserDefaults, no real paths, no model — the same
//     production Dependencies the other deterministic Hallie tests use
//     (executePresence is a pure function).
//   - SENSOR: `placeSearchIsExactNotSubstringOfTranscript` — a transcript
//     that says "cape cod" must NOT satisfy the place facet.
//
// Media matrix: not applicable (no probing).

import Foundation
import Testing
@testable import VideoScan

// MARK: - Helpers

private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func snapshot(
    _ path: String,
    confirmed: [String] = [],
    transcript: String? = nil,
    place: String? = nil,
    status: String? = nil
) -> ArchivistPresenceRecordSnapshot {
    ArchivistPresenceRecordSnapshot(
        fullPath: path,
        confirmedPeople: confirmed.map { ConfirmedTag(name: $0, confirmedAt: confirmedAt) },
        transcript: transcript,
        transcriptModel: transcript == nil ? nil : "whisper-model",
        userPlace: place,
        userPlaceStatus: status)
}

@Suite("Hallie place facet — the step")
struct HalliePlaceFacetStepTests {

    private let known = ["Cape Cod", "Franklin, MA", "Westford", "Montana", "North Conway, NH"]

    @Test("knownPlaces: distinct, longest first, unplaced skipped")
    func knownPlaces() {
        let records = [
            snapshot("/v/a.mov", place: "Cape Cod"), snapshot("/v/b.mov", place: "Cape Cod"),
            snapshot("/v/c.mov", place: "Franklin, MA"), snapshot("/v/d.mov"),
            snapshot("/v/e.mov", place: "NH"),
        ]
        #expect(HalliePlaceFacet.knownPlaces(in: records) == ["Franklin, MA", "Cape Cod", "NH"])
        #expect(HalliePlaceFacet.knownPlaces(in: []).isEmpty)
    }

    @Test("a keyword that is one of Rick's places becomes the facet and leaves the keywords")
    func keywordWay() {
        var payload = ArchivistQueryAST.Presence(people: ["Donna"], keywords: ["cape cod", "beach"])
        let d = HalliePlaceFacet.apply(to: &payload, question: "videos of donna at cape cod on the beach", knownPlaces: known)
        #expect(d == HalliePlaceFacet.Detection(place: "Cape Cod", consumed: ["cape cod"], fromQuestion: false))
        #expect(payload.place == "Cape Cod")
        #expect(payload.keywords == ["beach"])
        #expect(payload.people == ["Donna"])
        #expect(d?.note.contains("one of your places") == true)
    }

    @Test("town-only keyword matches a 'Town, ST' place; the facet keeps the asked form")
    func townOnlyKeyword() {
        var payload = ArchivistQueryAST.Presence(keywords: ["franklin"])
        let d = HalliePlaceFacet.apply(to: &payload, question: "anything from franklin", knownPlaces: known)
        #expect(d?.place == "Franklin")
        #expect(payload.place == "Franklin")
        #expect(payload.keywords == nil)
    }

    @Test("the question names a place after a preposition even when the translator dropped it")
    func questionWay() {
        var payload = ArchivistQueryAST.Presence()
        let d = HalliePlaceFacet.apply(to: &payload, question: "what do we have from Montana?", knownPlaces: known)
        #expect(d == HalliePlaceFacet.Detection(place: "Montana", consumed: [], fromQuestion: true))
        #expect(payload.place == "Montana")

        // Split keywords made only of the place's words leave too; "cape"
        // alone is not a place, so the keyword way passes and the
        // question way consumes the split words.
        var split = ArchivistQueryAST.Presence(keywords: ["cape", "cod", "beach"])
        let d2 = HalliePlaceFacet.apply(to: &split, question: "videos at Cape Cod, the beach ones", knownPlaces: known)
        #expect(d2 == HalliePlaceFacet.Detection(place: "Cape Cod", consumed: ["cape", "cod"], fromQuestion: true))
        #expect(split.keywords == ["beach"])
        var onlySplit = ArchivistQueryAST.Presence(keywords: ["cape", "cod"])
        let d3 = HalliePlaceFacet.apply(to: &onlySplit, question: "videos at cape cod", knownPlaces: known)
        #expect(d3 == HalliePlaceFacet.Detection(place: "Cape Cod", consumed: ["cape", "cod"], fromQuestion: true))
        #expect(onlySplit.keywords == nil)
    }

    @Test("no placed records → no-op; a place nobody used → no-op; no preposition → no-op")
    func noOps() {
        var a = ArchivistQueryAST.Presence(keywords: ["cape cod"])
        #expect(HalliePlaceFacet.apply(to: &a, question: "videos at cape cod", knownPlaces: []) == nil)
        #expect(a.place == nil && a.keywords == ["cape cod"])

        var b = ArchivistQueryAST.Presence(keywords: ["boston"])
        #expect(HalliePlaceFacet.apply(to: &b, question: "videos in boston", knownPlaces: known) == nil)
        #expect(b.keywords == ["boston"])

        var c = ArchivistQueryAST.Presence(people: ["Montana"])
        #expect(HalliePlaceFacet.apply(to: &c, question: "videos of Montana", knownPlaces: known) == nil,
                "a bare name in the people list is not touched here — the presence step's demotion decides")
        #expect(c.people == ["Montana"])
    }

    // codex #1370 P1: content wording is never a place question.
    @Test("content wording keeps the keyword road: says / mentions / captioned / titled / transcript",
          arguments: [
            "find where someone says Cape Cod",
            "clips where someone mentions cape cod",
            "videos captioned Cape Cod",
            "anything titled Montana",
            "search the transcripts for cape cod",
            "who is talking about Westford in the audio",
            "files named cape cod",
          ])
    func contentWordingIsNotAPlace(question: String) {
        for term in ["cape cod", "Cape Cod", "montana", "westford"] {
            var payload = ArchivistQueryAST.Presence(keywords: [term])
            #expect(HalliePlaceFacet.apply(to: &payload, question: question, knownPlaces: known) == nil, "'\(question)' / \(term)")
            #expect(payload.keywords == [term])
            #expect(payload.place == nil)
        }
        #expect(HalliePlaceFacet.hasContentWording(question.lowercased()))
    }

    @Test("a keyword needs a location shape: at/in/from/of <place>, videos <place>, <place> videos",
          arguments: [
            ("videos at cape cod", true), ("show me cape cod videos", true), ("videos cape cod", true),
            ("anything from Cape Cod", true), ("videos of cape cod", true),   // the demoted-name case
            ("who is cape cod", false), ("is cape cod a place", false), ("cape cod", false),
          ])
    func keywordNeedsLocationShape(question: String, expected: Bool) {
        var payload = ArchivistQueryAST.Presence(keywords: ["cape cod"])
        let d = HalliePlaceFacet.apply(to: &payload, question: question, knownPlaces: known)
        #expect((d != nil) == expected, "'\(question)'")
        #expect((payload.place == "Cape Cod") == expected)
    }

    @Test("an existing place is only canonicalized")
    func existingPlace() {
        var p = ArchivistQueryAST.Presence(keywords: ["cape cod"], place: "franklin, ma")
        #expect(HalliePlaceFacet.apply(to: &p, question: "x", knownPlaces: known) == nil)
        #expect(p.place == "Franklin, MA")
        #expect(p.keywords == ["cape cod"])
    }

    @Test("mentions: whole-word after a place preposition only")
    func mentions() {
        #expect(HalliePlaceFacet.mentions("cape cod", in: "videos at cape cod"))
        #expect(HalliePlaceFacet.mentions("montana", in: "what do we have from montana?"))
        #expect(HalliePlaceFacet.mentions("westford", in: "videos of donna in westford"))
        #expect(!HalliePlaceFacet.mentions("westford", in: "videos of westford"), "'of' names a person here; the demotion step decides")
        #expect(!HalliePlaceFacet.mentions("cod", in: "videos at cape cod"))
        #expect(!HalliePlaceFacet.mentions("montana", in: "montana videos"))
    }
}

@Suite("Hallie place facet — executor and wording")
struct HalliePlaceFacetExecutorTests {

    private func run(_ payload: ArchivistQueryAST.Presence, _ records: [ArchivistPresenceRecordSnapshot]) -> ArchivistPresenceResult {
        ArchivistPresenceExecutor.execute(ArchivistPresenceQuery(payload), records: records)
    }

    // SENSOR (2026-09-12): the whole point of the field.
    @Test func placeSearchIsExactNotSubstringOfTranscript() throws {
        let saidIt = snapshot("/v/CapeCod1997.mov", transcript: "we drove down to cape cod that summer")
        let shotThere = snapshot("/v/tape12.mov", place: "Cape Cod", status: "known")
        let result = run(.init(place: "cape cod"), [saidIt, shotThere])
        #expect(result.conclusion == .present)
        #expect(result.evidence.totalMatchCount == 1)
        #expect(result.evidence.citations.map(\.filename) == ["tape12.mov"])
        let basis = try #require(result.evidence.citations.first?.bases.first)
        #expect(basis == .userPlace(queryTerm: "Cape Cod", matchedValue: "Cape Cod", status: "known"))
        #expect(basis.summary == "place Cape Cod (known) matches Cape Cod exactly")
        // The keyword road still finds the transcript — unchanged.
        #expect(run(.init(keywords: ["cape cod"]), [saidIt, shotThere]).evidence.citations.map(\.filename) == ["CapeCod1997.mov"])
    }

    @Test("town-only matches 'Town, ST'; substring never does")
    func townOnly() {
        let franklin = snapshot("/v/f.mov", place: "Franklin, MA")
        #expect(run(.init(place: "Franklin"), [franklin]).evidence.totalMatchCount == 1)
        #expect(run(.init(place: "franklin, ma"), [franklin]).evidence.totalMatchCount == 1)
        #expect(run(.init(place: "Frank"), [franklin]).conclusion == .noEvidence)
        #expect(run(.init(place: "MA"), [franklin]).conclusion == .noEvidence)
        #expect(run(.init(place: "  "), [franklin]).conclusion == .insufficientConstraints, "blank place is no facet")
    }

    @Test("place ANDs with a person; the default status is estimated")
    func andWithPerson() throws {
        let donnaWestford = snapshot("/v/dw.mov", confirmed: ["Donna"], place: "Westford")
        let donnaCape = snapshot("/v/dc.mov", confirmed: ["Donna"], place: "Cape Cod")
        let rickWestford = snapshot("/v/rw.mov", confirmed: ["Rick"], place: "Westford")
        let result = run(.init(people: ["Donna"], place: "Westford"), [donnaWestford, donnaCape, rickWestford])
        #expect(result.evidence.citations.map(\.filename) == ["dw.mov"])
        #expect(result.interpretedQuery == "shape=presence person=Donna place=Westford")
        let bases = try #require(result.evidence.citations.first?.bases)
        #expect(bases.contains(.userPlace(queryTerm: "Westford", matchedValue: "Westford", status: "estimated")))
    }

    @Test("relax ladder: nothing placed there → the place is dropped and the offer names it")
    func relaxDropsPlace() {
        let donna = snapshot("/v/donna.mov", confirmed: ["Donna"])
        let result = run(.init(people: ["Donna"], place: "Westford"), [donna])
        #expect(result.conclusion == .noEvidenceButRelaxed(dropped: .place))
        #expect(result.evidence.totalMatchCount == 1)
        let answer = ArchivistPresenceAnswerComposer.compose(result)
        #expect(answer.prose == "I don't see anything placed at Westford, but I have 1 video of Donna — want those?")
        #expect(answer.basisLine.hasSuffix("after setting aside place."))
    }

    @Test("place-only hit names the place and the files")
    func placeOnlySentence() {
        let a = snapshot("/v/a.mov", place: "Cape Cod"), b = snapshot("/v/b.mov", place: "Cape Cod")
        let answer = ArchivistPresenceAnswerComposer.compose(run(.init(place: "Cape Cod"), [a, b, snapshot("/v/c.mov")]))
        #expect(answer.prose == "2 videos placed at “Cape Cod” — a.mov, b.mov.")
        #expect(answer.basisLine == "Basis: 2 cited of 2 matching catalog items.")
    }

    @Test("place-only miss says the field is exact and where to add places; person+place miss offers the place")
    func missWording() {
        let miss = ArchivistPresenceAnswerComposer.compose(run(.init(place: "Montana"), [snapshot("/v/a.mov")]))
        #expect(miss.prose == "I looked for videos at Montana and found nothing in the catalog. No video carries that place yet — I match the Place field exactly. Add places in the inspector (Where Was This?) and I'll find them.")
        #expect(miss.retryOffer == nil)

        let personMiss = ArchivistPresenceAnswerComposer.noEvidence(for: "shape=presence person=Ellen place=Westford")
        #expect(personMiss.prose == "I looked for videos of Ellen at Westford and found nothing in the catalog. Want me to try without the place, or with a different name?")
        #expect(personMiss.retryOffer == .place)
        let offer = HallieOfferAcceptance.Offer(question: "q", executed: .init(people: ["Ellen"], place: "Westford"), dropping: .place)
        #expect(offer.ast == .presence(.init(people: ["Ellen"])))

        // The pinned person-only and person+words sentences are untouched.
        #expect(ArchivistPresenceAnswerComposer.noEvidence(for: "shape=presence person=Ellen").retryOffer == nil)
        #expect(ArchivistPresenceAnswerComposer.noEvidence(for: "shape=presence person=Ellen keyword=cake").retryOffer == .words)
    }

    @Test("parseFacets reads the place beside the other facets")
    func parseFacets() {
        let f = ArchivistPresenceAnswerComposer.parseFacets("shape=presence person=Donna Breen years=1990...1994 place=North Conway, NH keyword=snow")
        #expect(f.people == ["Donna Breen"])
        #expect(f.years == "1990–1994")
        #expect(f.place == "North Conway, NH")
        #expect(f.keywords == ["snow"])
    }

    @Test("the AST decodes a place on presence and a place operation on record")
    func astDecodes() throws {
        let presence = try JSONDecoder().decode(ArchivistQueryAST.self, from: Data(
            #"{"shape":"presence","payload":{"people":["Donna"],"place":"Cape Cod"}}"#.utf8))
        #expect(presence == .presence(.init(people: ["Donna"], place: "Cape Cod")))
        let record = try JSONDecoder().decode(ArchivistQueryAST.self, from: Data(
            #"{"shape":"record","payload":{"reference":{"kind":"currentSelection"},"operations":["place"]}}"#.utf8))
        #expect(record == .record(.init(reference: .currentSelection, operations: [.place])))
    }

    @Test("VideoRecord → snapshot carries the place and its status")
    @MainActor
    func snapshotFromRecord() {
        let rec = VideoRecord()
        rec.fullPath = "/v/x.mov"; rec.filename = "x.mov"
        #expect(ArchivistPresenceRecordSnapshot(record: rec).userPlace == nil)
        #expect(ArchivistPresenceRecordSnapshot(record: rec).userPlaceStatus == nil)
        rec.userPlace = "Cape Cod"; rec.userPlaceConfidence = "known"
        let snap = ArchivistPresenceRecordSnapshot(record: rec)
        #expect(snap.userPlace == "Cape Cod")
        #expect(snap.userPlaceStatus == "known")
        let dossier = ArchivistRecordDossierSnapshot(record: rec)
        #expect(dossier.userPlace == "Cape Cod")
        #expect(dossier.userPlaceStatus == .known)
    }

    @Test("scale: place facet and known-place collection over 100k snapshots", .timeLimit(.minutes(1)))
    func scale100k() {
        var records: [ArchivistPresenceRecordSnapshot] = []
        records.reserveCapacity(100_000)
        let pool = ["Cape Cod", "Franklin, MA", "Westford", "Montana"]
        for i in 0..<100_000 {
            records.append(snapshot("/v/\(i).mov", transcript: "cape cod",
                                    place: i % 3 == 0 ? pool[(i / 3) % pool.count] : nil))
        }
        let clock = ContinuousClock()
        var known: [String] = []
        let collect = clock.measure { known = HalliePlaceFacet.knownPlaces(in: records) }
        #expect(known.count == 4)
        #expect(collect < .seconds(1), "knownPlaces took \(collect)")
        var result: ArchivistPresenceResult?
        let elapsed = clock.measure { result = run(.init(place: "Cape Cod"), records) }
        #expect(result?.evidence.totalMatchCount == 8_334, "only the placed rows — every row's transcript says it")
        #expect(elapsed < .seconds(3), "place facet took \(elapsed) over 100k")
    }
}

@Suite("Hallie place facet — through the turn executor")
struct HalliePlaceFacetTurnTests {

    private func turn(_ question: String, _ ast: ArchivistQueryAST,
                      _ records: [ArchivistPresenceRecordSnapshot]) async throws -> HallieTurnExecutor.Result {
        try await HallieTurnExecutor.execute(
            HallieTurnExecutor.Request(intent: HallieTurnExecutor.Intent(
                originalQuestion: question, ast: ast, playAfterAnswer: false)),
            context: HallieTurnExecutor.Context(presenceRecords: records))
    }

    @Test("'videos at cape cod' → the place facet, not the transcript")
    func videosAtCapeCod() async throws {
        let placed = snapshot("/v/tape12.mov", place: "Cape Cod")
        let said = snapshot("/v/CapeCod1997.mov", transcript: "we drove down to cape cod")
        let r = try await turn("videos at cape cod", .presence(.init(keywords: ["cape cod"])), [placed, said])
        #expect(r.outcome == .answered)
        #expect(r.matchCount == 1)
        #expect(r.citations.map(\.filename) == ["tape12.mov"])
        #expect(r.basisLine.contains("“Cape Cod” is one of your places"))
        #expect(r.queryDescription == "shape=presence place=Cape Cod")
    }

    @Test("'videos of Donna in Westford' → person AND place (the demoted name becomes the place)")
    func donnaInWestford() async throws {
        let dw = snapshot("/v/dw.mov", confirmed: ["Donna"], place: "Westford")
        let dc = snapshot("/v/dc.mov", confirmed: ["Donna"], place: "Cape Cod")
        let r = try await turn("videos of Donna in Westford", .presence(.init(people: ["Donna", "Westford"])), [dw, dc])
        #expect(r.outcome == .answered)
        #expect(r.citations.map(\.filename) == ["dw.mov"])
        #expect(r.queryDescription == "shape=presence person=Donna place=Westford")
    }

    @Test("'what do we have from Montana' with an empty translation → the question names the place")
    func fromMontana() async throws {
        let m = snapshot("/v/m.mov", place: "Montana"), other = snapshot("/v/o.mov", place: "Westford")
        let r = try await turn("what do we have from Montana?", .presence(.init()), [m, other])
        #expect(r.outcome == .answered)
        #expect(r.citations.map(\.filename) == ["m.mov"])
    }

    @Test("with nothing placed anywhere the words are searched exactly as before")
    func unchangedWithoutPlaces() async throws {
        let said = snapshot("/v/CapeCod1997.mov", transcript: "we drove down to cape cod")
        let r = try await turn("videos at cape cod", .presence(.init(keywords: ["cape cod"])), [said])
        #expect(r.outcome == .answered)
        #expect(r.citations.map(\.filename) == ["CapeCod1997.mov"])
        #expect(!r.basisLine.contains("one of your places"))
    }

    @Test("isolation: a place turn writes nothing to UserDefaults")
    func noDefaults() async throws {
        let before = Set(UserDefaults.standard.dictionaryRepresentation().keys)
        _ = try await turn("videos at cape cod", .presence(.init(keywords: ["cape cod"])), [snapshot("/v/a.mov", place: "Cape Cod")])
        let added = Set(UserDefaults.standard.dictionaryRepresentation().keys).subtracting(before)
        #expect(added.isEmpty, "place turn polluted UserDefaults with: \(added.sorted())")
    }
}

@Suite("Hallie place — the record route")
struct HalliePlaceRecordRouteTests {
    typealias Record = ArchivistQueryAST.Record

    @Test("'where was this taken' and friends are record place questions",
          arguments: [
            "where was this taken?", "Where was this filmed", "where's it from?", "where was that shot",
            "what town is this", "which place was this one", "the location of it", "where was this",
          ])
    func detectsPlaceAsk(question: String) {
        #expect(ArchivistRecordQuestion.detect(question) == Record(reference: .currentSelection, operations: [.place]),
                "'\(question)'")
    }

    @Test("a named file works too; family-tree and date asks stay out",
          arguments: [
            ("where was New Hampshire.mov taken", Optional(Record(reference: .file(name: "New Hampshire.mov"), operations: [.place]))),
            ("where was Eileen Latta born", nil),
            ("when was this filmed", nil),
            ("where is it in the tree", nil),
          ])
    func namedFileAndGuards(question: String, expected: Record?) {
        #expect(ArchivistRecordQuestion.detect(question) == expected, "'\(question)'")
    }

    @Test("the record executor answers the place with Rick's confidence, or says none is recorded")
    func executorAnswers() {
        let presence = snapshot("/v/tape.mov")
        let known = ArchivistRecordDossierSnapshot(presence: presence, userPlace: "Cape Cod", userPlaceStatus: .known)
        let k = ArchivistRecordExecutor.execute(.init(reference: .currentSelection, operations: [.place]), snapshot: known, ownerName: nil)
        #expect(k.prose == "tape.mov was taken at Cape Cod — you marked that as certain.")
        #expect(k.basisLine.contains("place Cape Cod (known)"))
        #expect(k.offeredActions.contains { if case .ask(_, let label) = $0 { return label == "Where was it taken" } ; return false } == false,
                "no chip for the thing just asked")

        let guessed = ArchivistRecordDossierSnapshot(presence: presence, userPlace: "Franklin, MA", userPlaceStatus: .estimated)
        let g = ArchivistRecordExecutor.execute(.init(reference: .currentSelection, operations: [.place]), snapshot: guessed, ownerName: nil)
        #expect(g.prose == "tape.mov was taken at Franklin, MA, as your best guess.")

        let none = ArchivistRecordDossierSnapshot(presence: presence)
        let n = ArchivistRecordExecutor.execute(.init(reference: .currentSelection, operations: [.place]), snapshot: none, ownerName: nil)
        #expect(n.prose == "No place is recorded for tape.mov yet — you can add one in the inspector (Where Was This?).")
        #expect(n.basisLine.contains("no place recorded"))

        // "who is in it" offers the place chip; "about" covers the place.
        let who = ArchivistRecordExecutor.execute(.init(reference: .currentSelection, operations: [.people]), snapshot: known, ownerName: nil)
        #expect(who.offeredActions.contains { if case .ask(let q, let label) = $0 { return label == "Where was it taken" && q == "where was /v/tape.mov taken" }; return false })
        let about = ArchivistRecordExecutor.execute(.init(reference: .currentSelection, operations: [.about]), snapshot: known, ownerName: nil)
        #expect(about.prose.contains("was taken at Cape Cod"))
        #expect(ArchivistRecordExecutor.question(for: .init(reference: .currentSelection, operations: [.people, .place]), path: "/v/tape.mov")
                == "who is in /v/tape.mov and where was it taken")
    }
}
