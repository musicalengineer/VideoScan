// ObservationsReportTests.swift — the Observations window's numbers and its
// search (ObservationsReport.swift, ObservationsSearch.swift;
// docs/design/file_dossier_view.md Part II). Streamlined (Rick 11/06: an
// experiment) — the thin safety net only:
//   TRUTH      every shown count equals a direct SQL count written another
//              way, on a fixture catalog with every observation table filled;
//              every search hit's text contains the query or derives from a
//              matching era / probe tuple; a file name, a path or a note is
//              NEVER a hit (§II.0); era.none is never an era and a rejected
//              era is never found; the scopes select what they say.
//   READ-ONLY  the report and the search leave the catalog's generation and
//              every row count untouched.
//   SCALE      a 100k measurement that prints (no budget asserted yet).
// Synthetic names, paths and digests only.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ObservationsReport")
struct ObservationsReportTests {

    static let now = Date(timeIntervalSince1970: 1_762_400_000)
    static let by8B = "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3"

    /// 1 DV with captions / transcript / era / people / OCR date; 2 DV with an era Rick rejected and a "no speech" transcript;
    /// 3 DV era.none; 4 ProRes with a "Tahoe" caption and the "beach" transcript; 5 audio only, not transcribed;
    /// 6 unprobed; 7 in another folder, no observations; 8 removed (not in "everything").
    static func scene() async throws -> (StoreFixture, GRDBCatalogRepository) {
        let files: [DossierFixture.File] = [
            .init(n: 1, path: "/V/tapes/Christmas_1990.dv", embedded: 1_044_957_600, embeddedSource: "format:creation_time"),
            .init(n: 2, path: "/V/tapes/Easter_1992.dv"),
            .init(n: 3, path: "/V/tapes/Summer_1994.dv"),
            .init(n: 4, path: "/V/masters/Tahoe_scan.mov", container: "QuickTime / MOV", videoCodec: "prores", audioCodec: "pcm_s24le",
                  extra: ["resolution": "1920x1080", "frameRate": "23.976", "scanType": "progressive", "audioSampleRate": "48000 Hz", "audioChannels": "2"]),
            .init(n: 5, path: "/V/audio/Grandma_story.wav", stream: "Audio only", container: "WAV", videoCodec: "", audioCodec: "pcm_s16le", extra: [:]),
            .init(n: 6, path: "/V/tapes/Unknown.mov", stream: "", container: "", videoCodec: "", audioCodec: "", extra: [:]),
            .init(n: 7, path: "/V/other/Picnic.dv"),
        ]
        let fixture = try await DossierFixture.catalog(files)
        // 8: removed (a marker is written at insert, as EraFixture does — the UPDATE triggers guard the engine's path).
        try DossierFixture.execute(fixture, "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                                   [DossierFixture.hex(8)])
        try DossierFixture.execute(fixture, """
            INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes, digest_computed_at,
                               digest_source, stream_type, duration_s, container, video_codec, audio_codec, lifecycle, archive_stage,
                               volume_case_sensitive, removal_state, removal_since, removal_reason)
            VALUES (?, ?, '', '/V/tapes/Gone.dv', '/v/tapes/gone.dv', 'Gone.dv', 'dv', '/V/tapes', 100, 1, 'archiveFixity', 'Video+Audio', 600,
                    'DV (Digital Video)', 'dvvideo', 'pcm_s16le', 'Cataloged', 'None', 0, 'removedFromCatalog', 1, 'test')
            """, [DossierFixture.fileID(8), DossierFixture.hex(8)])
        var k1 = DossierFixture.Knowledge(captionModel: "qwen-test", transcript: "we opened the presents and the dog ran under the tree",
                                          transcriptModel: "whisper-medium", dossierBy: "qwen-test+whisper")
        k1.captions = [("scene", 1, "a living room with a christmas tree and presents"), ("scene", 9, "a dog near the tree"),
                       ("ocrText", 2, "DEC 25 1990"), ("ocrDate", 2, "1990-12-25")]
        k1.people = [("Donna", "detected"), ("Rick", "suspected"), ("Donna", "confirmed")]
        k1.inferred = (at: 662_000_000, confidence: 0.8, source: "catch-up", reason: nil)
        k1.userDate = "1990"
        k1.assertions = [("era.fused", "1990-1994", by8B, "inferred", #"{"validEraWindows":2,"windows":[]}"#),
                         ("ocr.date", "1990-12-25", by8B, "inferred", #"{"atS":2.0}"#)]
        try DossierFixture.seed(fixture, 1, k1)
        var k2 = DossierFixture.Knowledge(captionModel: "qwen-test", transcript: "", transcriptModel: "whisper-medium")
        k2.assertions = [("era.fused", "1960-1964", by8B, "inferred", "{}"), ("era.fused", "1960-1964", "rick", "rejected", "{}")]
        k2.captions = [("scene", 3, "children hunting eggs in a garden")]
        try DossierFixture.seed(fixture, 2, k2)
        var k3 = DossierFixture.Knowledge()
        k3.assertions = [("era.none", "none", by8B, "inferred", #"{"reason":"no era window passed"}"#)]
        k3.inferred = (at: nil, confidence: nil, source: nil, reason: "no evidence at all")
        try DossierFixture.seed(fixture, 3, k3)
        var k4 = DossierFixture.Knowledge(captionModel: "qwen-test", transcript: "the beach at Tahoe was cold that year", transcriptModel: "whisper-medium")
        k4.captions = [("scene", 0, "a lake shore with pine trees, Tahoe")]
        k4.assertions = [("era.fused", "2001-2003", by8B, "inferred", "{}")]
        try DossierFixture.seed(fixture, 4, k4)
        // A note with a word that must never be searchable, and an event.
        try DossierFixture.execute(fixture, "INSERT INTO user_notes (digest, text) VALUES (?, 'secretnote about the beach')", [DossierFixture.hex(1)])
        try DossierFixture.execute(fixture, "INSERT INTO events (event_id, name, state, created_at, updated_at) VALUES (?, 'Christmas 1990', 'confirmed', 1, 1)",
                                   ["00000000-0000-0000-0000-00000000E001"])
        try DossierFixture.execute(fixture, "INSERT INTO event_members (event_id, digest, imported_key) VALUES (?, ?, 'k')",
                                   ["00000000-0000-0000-0000-00000000E001", DossierFixture.hex(1)])
        let repository = try await DossierFixture.open(fixture)
        return (fixture, repository)
    }

    static func report(_ r: GRDBCatalogRepository, _ scope: ObservationsScope = .everything) async throws -> ObservationsReport {
        try await r.read { try ObservationsReport.build(reader: $0, scope: scope, now: now) }
    }

    static func search(_ r: GRDBCatalogRepository, _ q: String, _ scope: ObservationsScope = .everything) async throws -> ObservationsSearch {
        try await r.read { try ObservationsSearch.search(reader: $0, scope: scope, query: q, now: now) }
    }

    static func count(_ f: StoreFixture, _ sql: String) throws -> Int { try EraFixture.count(f, sql) }

    // MARK: TRUTH — every count equals a direct count

    @Test func everyCountEqualsADirectCount() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let r = try await Self.report(repository)
        let live = "SELECT DISTINCT content_digest FROM files WHERE removal_state IS NULL"
        #expect(r.files == (try Self.count(fixture, "SELECT count(*) FROM files WHERE removal_state IS NULL")))
        #expect(r.contents == (try Self.count(fixture, "SELECT count(*) FROM (\(live))")))
        #expect(r.contents == 7 && r.files == 7, "the removed file is not the collection")

        // Technical: the format readings sum to the probed contents; codecs are the files' columns.
        let probed = try Self.count(fixture, "SELECT count(DISTINCT content_digest) FROM files WHERE removal_state IS NULL AND stream_type NOT IN ('', 'ffprobe failed')")
        #expect(r.technical.group("Format readings")?.rows.reduce(0) { $0 + ($1.count ?? 0) } == probed)
        #expect(r.technical.row("Video codecs", "dvvideo")?.count == (try Self.count(fixture, "SELECT count(DISTINCT content_digest) FROM files WHERE removal_state IS NULL AND video_codec = 'dvvideo'")))
        #expect(r.technical.row("Video codecs", "prores")?.count == 1)
        #expect(r.technical.row("Probe", "Not probed yet")?.count == 1 && r.technical.row("Probe", "Not probed yet")?.standing == .missing)
        #expect(r.technical.row("Embedded creation dates", "2000s")?.count == 1)
        #expect(r.technical.row("Embedded creation dates", "2000s")?.evidence?.contains("copied to a computer") == true, "a DV date is the copy, not the shoot")
        #expect(r.technical.summary.contains("DV camcorder/deck capture"))

        // Patterns: eras (found = 1 and 4; 2 rejected; 3 none), captions, speech, people, inferred, events.
        #expect(r.patterns.row("Machine era", "1990s")?.count == 1, "1990–1994's middle year is 1992")
        #expect(r.patterns.row("Machine era", "2000s")?.count == 1)
        #expect(r.patterns.row("Machine era", "Rejected by you")?.count == 1 && r.patterns.row("Machine era", "Rejected by you")?.standing == .fact)
        #expect(r.patterns.row("Machine era", "No usable era")?.count == 1 && r.patterns.row("Machine era", "No usable era")?.standing == .nothingFound)
        #expect(r.patterns.row("Machine era", "Not analyzed yet")?.count == 1, "7 is video with no era row (6 is unprobed, 5 audio)")
        let found = try Self.count(fixture, """
            SELECT count(*) FROM provenance_assertions a WHERE a.field = 'era.fused' AND a.state = 'inferred' AND a.by LIKE 'machine:%'
               AND a.subject_id IN (\(live))
               AND NOT EXISTS (SELECT 1 FROM provenance_assertions j WHERE j.subject_id = a.subject_id AND j.field = a.field AND j.state = 'rejected' AND j.value = a.value AND j.seq > a.seq)
            """)
        let eraRows = try #require(r.patterns.group("Machine era")).rows
        #expect(eraRows.filter { $0.label.hasSuffix("0s") }.reduce(0) { $0 + ($1.count ?? 0) } == found)
        #expect(r.patterns.row("Scenes described", "Files with scenes described")?.count == (try Self.count(fixture, "SELECT count(DISTINCT digest) FROM captions WHERE kind = 'scene' AND digest IN (\(live))")))
        #expect(r.patterns.row("Scenes described", "Frames described")?.count == (try Self.count(fixture, "SELECT count(*) FROM captions WHERE kind = 'scene' AND digest IN (\(live))")))
        #expect(r.patterns.row("Scenes described", "Not described yet")?.count == 2, "3 and 7: video, no caption run")
        #expect(r.patterns.row("Speech", "Files with speech")?.count == (try Self.count(fixture, "SELECT count(*) FROM transcripts WHERE text <> '' AND digest IN (\(live))")))
        #expect(r.patterns.row("Speech", "No speech found")?.count == 1 && r.patterns.row("Speech", "No speech found")?.standing == .nothingFound)
        #expect(r.patterns.row("Speech", "Not transcribed yet")?.count == 3, "3, 5 and 7 have audio and no transcript")
        #expect(r.patterns.row("Speech", "Words in all")?.count == 11 + 8)
        #expect(r.patterns.row("Most described", "tree")?.count == 2)
        #expect(r.patterns.row("Most said", "beach")?.count == 1)
        #expect(r.patterns.row("On-screen text", "Files with on-screen text")?.count == 1)
        #expect(r.patterns.row("On-screen text", "Files with on-screen dates")?.count == 1)
        #expect(r.patterns.row("Burned-in dates", "1990-12-25")?.count == 1)
        #expect(r.patterns.row("People the machine found", "Donna (detected)")?.count == 1)
        #expect(r.patterns.row("People the machine found", "Rick (suspected)")?.count == 1)
        #expect(r.patterns.row("People the machine found", "Confirmed by you (the comparison)")?.count == 1)
        #expect(r.patterns.row("People the machine found", "Confirmed by you (the comparison)")?.source == "Rick")
        #expect(r.patterns.row("Inferred dates", "1990s")?.count == 1 && r.patterns.row("Inferred dates", "Examined, no evidence")?.count == 1)
        #expect(r.patterns.row("Events", "Christmas 1990")?.count == 1)

        // Collection: coverage and the comparison.
        #expect(r.analyzed == 4 && r.collection.row("This scope", "Nothing yet")?.count == 3, "1–4 analyzed; 5, 6, 7 nothing")
        #expect(r.collection.row("Machine eras across the collection", "Agrees with your date within 5 years")?.value == "1 of 1 (100 %)")
        #expect(r.collection.row("Machine eras across the collection", "Span of machine eras")?.value == "1990–2003")
        #expect(r.collection.row("Models and runs", "Scene captions · qwen-test")?.count == 3)
        #expect(r.collection.row("Models and runs", "Era · 8B")?.count == 4, "1, 2, 3 and 4 have a row by the 8B")
        #expect(r.collection.row("Speech en masse", "Words in all transcripts")?.count == 19)
        await repository.close()
    }

    @Test func theScopesSelectWhatTheySay() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let tapes = try await Self.report(repository, .folder("/V/tapes"))
        #expect(tapes.contents == 4, "1, 2, 3, 6 — 8 is removed, /V/other is outside")
        let two = try await Self.report(repository, .files([DossierFixture.fileID(4), DossierFixture.fileID(8)]))
        #expect(two.contents == 2, "a selection names what it names, removed or not")
        #expect(two.patterns.row("Machine era", "2000s")?.count == 1)
        let pass = try await Self.report(repository, .since(1_700_000_150))
        #expect(pass.contents == 4, "caption runs are stamped 1700000100 (before); transcripts 1700000200 and the assertions 1762000000 (after): 1, 2, 3, 4")
        let nothing = try await Self.report(repository, .folder("/nowhere"))
        #expect(nothing.contents == 0 && nothing.technical.summary == "nothing in scope" && nothing.patterns.summary == "nothing analyzed yet")
        await repository.close()
    }

    // MARK: TRUTH — search

    @Test func everyHitContainsOrDerivesFromTheQuery() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        let tree = try await Self.search(repository, "tree")
        #expect(tree.hits.count == 4, "two captions, one transcript, one 'pine trees' caption")
        #expect(tree.hits.allSatisfy { $0.text.lowercased().contains("tree") })
        #expect(tree.hits.allSatisfy { $0.recordID != nil && !$0.filename.isEmpty && !$0.source.isEmpty }, "no hit without its source and file")
        #expect(tree.hits.first { $0.kind == .scene && $0.at == 9 }?.filename == "Christmas_1990.dv")
        let era = try await Self.search(repository, "early 1990s")
        #expect(era.hits.map(\.kind) == [.era] && era.hits.first?.text == "early 1990s (1990–1994)")
        #expect(try await Self.search(repository, "1991").hits.contains { $0.kind == .era }, "a year inside the range")
        #expect(try await Self.search(repository, "1960s").hits.isEmpty, "the rejected era is never found")
        let donna = try await Self.search(repository, "donna")
        #expect(donna.hits.map(\.kind) == [.person] && donna.hits.first?.source.contains("unconfirmed") == true, "the confirmed tag is Rick's, not a hit")
        let dv = try await Self.search(repository, "firewire")
        #expect(dv.hits.isEmpty == false && dv.hits.allSatisfy { $0.kind == .technical && $0.text.contains("DV camcorder") })
        #expect(try await Self.search(repository, "prores").hits.map(\.filename) == ["Tahoe_scan.mov"])
        let dec = try await Self.search(repository, "dec 25")
        #expect(dec.hits.map(\.kind) == [.onScreenText])
        #expect(try await Self.search(repository, "1990-12-25").hits.map(\.kind).sorted() == [.onScreenDate, .burnedInDate])
        #expect(try await Self.search(repository, "christmas 1990").hits.contains { $0.kind == .event })
        #expect(try await Self.search(repository, "x").hits.isEmpty, "two characters minimum")
        await repository.close()
    }

    @Test func aFileNameOrPathOrNoteIsNeverAHit() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        #expect(try await Self.search(repository, "easter").hits.isEmpty, "Easter_1992.dv is a file name")
        #expect(try await Self.search(repository, "tapes").hits.isEmpty, "/V/tapes is a path")
        #expect(try await Self.search(repository, "secretnote").hits.isEmpty, "a user note is Rick's")
        #expect(try await Self.search(repository, "picnic").hits.isEmpty, "Picnic.dv has no observation")
        let tahoe = try await Self.search(repository, "tahoe")
        #expect(tahoe.hits.map(\.kind).sorted() == [.scene, .speech], "Tahoe_scan.mov's name is not why these match")
        await repository.close()
    }

    // MARK: READ-ONLY

    @Test func theReportAndTheSearchWriteNothing() async throws {
        let (fixture, repository) = try await Self.scene()
        defer { fixture.remove() }
        func fingerprint() throws -> [Int] {
            try ["files", "captions", "transcripts", "provenance_assertions", "people_tags", "inferred_dates", "events", "user_dates", "user_notes"]
                .map { try Self.count(fixture, "SELECT count(*) FROM \($0)") } + [try Self.count(fixture, "SELECT generation FROM generations WHERE id = 1")]
        }
        let before = try fingerprint()
        _ = try await Self.report(repository)
        _ = try await Self.search(repository, "tree")
        _ = try await Self.report(repository, .files([DossierFixture.fileID(1)]))
        #expect(try fingerprint() == before)
        await repository.close()
    }

    // MARK: SCALE — a measurement (prints; no budget asserted yet — streamlined, Rick 11/06)

    @Test(.tags(.scale), .timeLimit(.minutes(10)))
    func oneHundredThousandFilesMeasured() async throws {
        let count = 100_000
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try DossierFixture.seedScale(fixture, count: count)
        let repository = try await DossierFixture.open(fixture)
        let clock = ContinuousClock()
        var report: ObservationsReport?
        let tookReport = try await clock.measure { report = try await Self.report(repository) }
        var search: ObservationsSearch?
        let tookSearch = try await clock.measure { search = try await Self.search(repository, "scene 3") }
        let tookTechnical = try await clock.measure { _ = try await Self.search(repository, "dv camcorder") }
        let tookEra = try await clock.measure { _ = try await Self.search(repository, "1970s") }
        #expect(report?.contents == count && report?.analyzed == count)
        #expect(search?.truncated == true && search?.hits.count == ObservationsSearch.perKind)
        print("ObservationsReport scale: 100k files — report \(tookReport) · text search \(tookSearch) · technical search \(tookTechnical) · era search \(tookEra)")
        await repository.close()
    }
}

// MARK: - ObservationsTypedRowsTests — the Observations reads' row boundary
// (CatalogObservationsRows.swift, GRDBCatalogRepository+Observations.swift)
// and three regressions found in review (2026-11-10), each seen red first:
//   A  a transcript hit shows its match when the query holds a LIKE
//      metacharacter ("100%", "tim_", a backslash);
//   B  every hit's id is unique (two machine people on one content, two
//      events on one content, one content under two probe tuples);
//   C  a burned-in date's source names the signer that read it (a shown
//      fact), never a hard-coded model.
// Then the typed rows: a stored value outside the known set is refused or
// carried as `unknown`, never defaulted.
// Synthetic names, paths and digests only.

@Suite("Observations — typed rows and review regressions")
struct ObservationsTypedRowsTests {

    static let by8B = ObservationsReportTests.by8B
    static let by2B = "machine:qwen3-vl-2b-4bit/dates-v1@r1"

    static func catalog(_ count: Int) async throws -> StoreFixture {
        try await DossierFixture.catalog((1...count).map { .init(n: $0, path: "/V/clips/clip-\($0).dv") })
    }

    // MARK: A — the transcript window is cut around the match, whatever the query's characters

    @Test(arguments: [("100%", "100% sure"), ("tim_", "tim_ sure"), ("a\\b", "a\\b sure")])
    func aTranscriptHitShowsItsMatchWhenTheQueryHoldsALikeMetacharacter(query: String, ending: String) async throws {
        let fixture = try await Self.catalog(2)
        defer { fixture.remove() }
        let long = String(repeating: "word ", count: 98) + ending                 // ≈ 500 characters, the match at the very end
        try DossierFixture.seed(fixture, 1, DossierFixture.Knowledge(transcript: long, transcriptModel: "whisper-medium"))
        // The metacharacter is a literal, never a wildcard: this transcript must not match.
        try DossierFixture.seed(fixture, 2, DossierFixture.Knowledge(transcript: "100 sure, timx sure, axb sure", transcriptModel: "whisper-medium"))
        let repository = try await DossierFixture.open(fixture)
        let found = try await ObservationsReportTests.search(repository, query)
        #expect(found.hits.map(\.kind) == [.speech], "one transcript holds \(query) literally")
        let hit = try #require(found.hits.first)
        #expect(hit.text.contains(query), "the hit shows its match, not the transcript's first words: \(hit.text)")
        #expect(hit.filename == "clip-1.dv")
        await repository.close()
    }

    // MARK: B — a hit's id is unique (a SwiftUI Table's row identity)

    @Test func everyHitHasItsOwnID() async throws {
        let fixture = try await Self.catalog(1)
        defer { fixture.remove() }
        // people_tags' key is (digest, name, kind): two machine names on one content, same kind.
        var k = DossierFixture.Knowledge()
        k.people = [("Zed", "detected"), ("Zedekiah", "detected")]
        try DossierFixture.seed(fixture, 1, k)
        // Two events with one name and one state, the same content in both.
        for id in ["00000000-0000-0000-0000-00000000E001", "00000000-0000-0000-0000-00000000E002"] {
            try DossierFixture.execute(fixture, "INSERT INTO events (event_id, name, state, created_at, updated_at) VALUES (?, 'Reunion', 'confirmed', 1, 1)", [id])
            try DossierFixture.execute(fixture, "INSERT INTO event_members (event_id, digest, imported_key) VALUES (?, ?, 'k')", [id, DossierFixture.hex(1)])
        }
        // One content under two probe tuples (a second copy probed as another container).
        try DossierFixture.execute(fixture, """
            INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes, digest_computed_at,
                               digest_source, stream_type, duration_s, container, video_codec, audio_codec, lifecycle, archive_stage, volume_case_sensitive)
            VALUES (?, ?, '', '/V/clips/copy.mov', '/v/clips/copy.mov', 'copy.mov', 'mov', '/V/clips', 100, 1, 'archiveFixity', 'Video+Audio', 600,
                    'QuickTime / MOV', 'dvvideo', 'pcm_s16le', 'Cataloged', 'None', 0)
            """, [DossierFixture.fileID(9), DossierFixture.hex(1)])
        let repository = try await DossierFixture.open(fixture)
        for (query, kind, count) in [("zed", ObservationsSearch.Kind.person, 2), ("reunion", .event, 2), ("dvvideo", .technical, 2)] {
            let found = try await ObservationsReportTests.search(repository, query)
            #expect(found.hits.map(\.kind) == Array(repeating: kind, count: count), "\(query): \(found.hits.map(\.text))")
            #expect(Set(found.hits.map(\.id)).count == found.hits.count, "\(query): duplicate ids \(found.hits.map(\.id))")
        }
        await repository.close()
    }

    // MARK: C — a burned-in date's source is the signer that read it

    @Test func aBurnedInDateNamesTheSignerThatReadIt() async throws {
        let fixture = try await Self.catalog(3)
        defer { fixture.remove() }
        var k1 = DossierFixture.Knowledge()
        k1.assertions = [("ocr.date", "1988-12-25", Self.by2B, "inferred", #"{"atS":4.0}"#)]
        try DossierFixture.seed(fixture, 1, k1)
        var k2 = DossierFixture.Knowledge()
        k2.assertions = [("ocr.date", "1991-07-04", Self.by2B, "inferred", "{}")]
        try DossierFixture.seed(fixture, 2, k2)
        var k3 = DossierFixture.Knowledge()
        k3.assertions = [("ocr.date", "1991-07-04", Self.by8B, "inferred", "{}")]
        try DossierFixture.seed(fixture, 3, k3)
        let repository = try await DossierFixture.open(fixture)
        let report = try await ObservationsReportTests.report(repository)
        let one = try #require(report.patterns.row("Burned-in dates", "1988-12-25"))
        #expect(one.count == 1 && one.source == "2B date reader, unconfirmed", "the signer is the 2B: \(one.source)")
        #expect(one.evidence?.contains(Self.by2B) == true, "the ⓘ names the whole signer")
        let both = try #require(report.patterns.row("Burned-in dates", "1991-07-04"))
        #expect(both.count == 2 && both.source == "2B, 8B date reader, unconfirmed", "one row per date, every signer named: \(both.source)")
        // The search hit and the report row say the same about the same row.
        let hit = try #require(try await ObservationsReportTests.search(repository, "1988-12-25").hits.first)
        #expect(hit.kind == .burnedInDate && hit.source == one.source && hit.at == 4)
        await repository.close()
    }

    // MARK: Typed rows — decoded once, never defaulted

    typealias Verdict = CatalogRow.ObservationEraVerdict.Verdict

    @Test func anEraVerdictIsExactlyOneVerdictOrRefused() throws {
        #expect(try Verdict(found: true, rejected: false, gaveUp: false, none: false, value: "1990-1994") == .found("1990-1994"))
        #expect(try Verdict(found: false, rejected: true, gaveUp: false, none: false, value: "1960-1964") == .rejected("1960-1964"))
        #expect(try Verdict(found: false, rejected: false, gaveUp: true, none: false, value: nil) == .gaveUp)
        #expect(try Verdict(found: false, rejected: false, gaveUp: false, none: true, value: nil) == .noUsableEra)
        #expect(try Verdict(found: false, rejected: false, gaveUp: false, none: false, value: nil) == .other)
        #expect(throws: Refusal.self, "two verdicts at once") { try Verdict(found: true, rejected: true, gaveUp: false, none: false, value: "1990-1994") }
        #expect(throws: Refusal.self, "found and no usable era") { try Verdict(found: true, rejected: false, gaveUp: false, none: true, value: "1990-1994") }
        #expect(throws: Refusal.self, "a found era without its value") { try Verdict(found: true, rejected: false, gaveUp: false, none: false, value: nil) }
        #expect(throws: Refusal.self, "a rejected era without its value") { try Verdict(found: false, rejected: true, gaveUp: false, none: false, value: nil) }
    }

    /// The scene through the real reader: every verdict the SQL classifies arrives as its case, and a
    /// signer with only an `ocr.date` row is `other` — analyzed, and in no era row.
    @Test func theReaderDecodesEveryVerdictAndOtherIsInNoEraRow() async throws {
        let (fixture, repository) = try await ObservationsReportTests.scene()
        defer { fixture.remove() }
        var k = DossierFixture.Knowledge()
        k.assertions = [("ocr.date", "1999-01-01", Self.by2B, "inferred", "{}"),
                        ("era.none", "none", "machine:gave-up-test/era-v1@r1", "inferred", #"{"gaveUp":true,"reason":"3 tries"}"#)]
        try DossierFixture.seed(fixture, 7, k)
        let verdicts = try await repository.read { try $0.observationEraVerdicts(.everything) }
        func contents(_ v: Verdict) -> Int { verdicts.filter { $0.verdict == v }.reduce(0) { $0 + $1.contents } }
        #expect(contents(.found("1990-1994")) == 1 && contents(.found("2001-2003")) == 1)
        #expect(contents(.rejected("1960-1964")) == 1 && contents(.noUsableEra) == 1 && contents(.gaveUp) == 1)
        #expect(verdicts.filter { $0.by == Self.by2B }.map(\.verdict) == [.other], "only an ocr.date row: analyzed, no era verdict")
        #expect(verdicts.compactMap(\.foundValue).sorted() == ["1990-1994", "2001-2003"], "an era is a found verdict and nothing else")
        let era = try #require(try await ObservationsReportTests.report(repository).patterns.group("Machine era")).rows
        let counted = era.filter { !$0.label.hasPrefix("Reading: ") && $0.label != "Not analyzed yet" }.reduce(0) { $0 + ($1.count ?? 0) }
        #expect(counted == verdicts.reduce(0) { $0 + $1.contents } - contents(.other), "every verdict but `other` is in exactly one era row")
        #expect(era.first { $0.label == "Given up" }?.count == 1)
        await repository.close()
    }

    @Test func aStoredKindOutsideTheSetIsRefusedInWords() throws {
        #expect(try CatalogRow.ObservationPersonKind(stored: "suspected") == .suspected)
        #expect(throws: Refusal("people_tags.kind \"rejected\" is not a kind the Observations read selects")) {
            try CatalogRow.ObservationPersonKind(stored: "rejected")
        }
        #expect(CatalogRow.ObservationPersonKind.allCases.filter(\.isMachine) == [.detected, .suspected])
        #expect(try CatalogRow.ObservationHitKind(stored: "ocrDate") == .ocrDate)
        #expect(throws: Refusal("a search hit of kind \"captions\" is not a kind the Observations read knows")) {
            try CatalogRow.ObservationHitKind(stored: "captions")
        }
        // Every stored hit kind is its own kind in the window (no two fold into one, none is dropped).
        #expect(Set(CatalogRow.ObservationHitKind.allCases.map(ObservationsSearch.Kind.init)) == Set(ObservationsSearch.Kind.allCases))
    }

    /// The hit SQL's kind literals and the enum cannot drift apart unseen: every kind comes back
    /// through the real reader (a literal the enum does not know would throw here).
    @Test func everyHitKindComesBackThroughTheRealReader() async throws {
        let (fixture, repository) = try await ObservationsReportTests.scene()
        defer { fixture.remove() }
        var seen = Set<ObservationsSearch.Kind>()
        var ids: [String] = []
        for query in ["tree", "dec 25", "1990-12-25", "donna", "christmas 1990", "early 1990s", "prores"] {
            let found = try await ObservationsReportTests.search(repository, query)
            #expect(Set(found.hits.map(\.id)).count == found.hits.count, "\(query): duplicate ids")
            seen.formUnion(found.hits.map(\.kind))
            ids += found.hits.map(\.id)
        }
        #expect(seen == Set(ObservationsSearch.Kind.allCases), "missing: \(Set(ObservationsSearch.Kind.allCases).subtracting(seen))")
        #expect(ids.allSatisfy { !$0.isEmpty })
        await repository.close()
    }

    @Test func anEventStateThisVersionDoesNotKnowIsShownAsStoredNeverAsDismissed() {
        typealias State = CatalogRow.ObservationEventState
        #expect(State(stored: "confirmed") == .confirmed && State(stored: "dismissed") == .dismissed)
        #expect(State(stored: "suggested") == .unknown("suggested") && State(stored: "") == .unknown(""))
        let group = ObservationsReport.eventsGroup([.init(name: "Reunion", state: .unknown("suggested"), members: 2),
                                                    .init(name: "Picnic", state: .dismissed, members: 1),
                                                    .init(name: "Christmas", state: .confirmed, members: 3)])
        #expect(group.rows.map(\.value) == ["2 files · state “suggested” (not one this version knows)", "1 file · dismissed by you", "3 files · confirmed by you"])
        #expect(group.rows.map(\.standing) == [.missing, .nothingFound, .fact])
    }

    @Test func theTextsReadStreamsTheKindItIsAskedFor() async throws {
        let (fixture, repository) = try await ObservationsReportTests.scene()
        defer { fixture.remove() }
        func texts(_ kind: CatalogRow.ObservationTextsKind) async throws -> [String] {
            try await repository.read { reader in
                var out: [String] = []
                try reader.observationTexts(.everything, kind: kind) { out.append($0) }
                return out
            }
        }
        let scenes = try await texts(.sceneCaptions), said = try await texts(.transcripts)
        #expect(scenes.count == (try ObservationsReportTests.count(fixture, "SELECT count(*) FROM captions WHERE kind = 'scene'")) && scenes.count == 4)
        #expect(said.sorted() == ["the beach at Tahoe was cold that year", "we opened the presents and the dog ran under the tree"], "the empty transcript is not a text")
        #expect(Set(scenes).isDisjoint(with: said))
        await repository.close()
    }

    // MARK: The technical tier's facets — keyed by a case, the label derived from it

    /// A facet's raw value is the label TechnicalReading gives its line. If TechnicalReading renames
    /// one, this goes red — the tier would otherwise drop the whole group in silence.
    @Test func everyTechnicalFacetIsALabelTechnicalReadingEmits() {
        let tuple = CatalogRow.ObservationTechnicalTuple(container: "DV (Digital Video)", ext: "dv", videoCodec: "dvvideo", audioCodec: "pcm_s16le",
                                                         streamType: "Video+Audio", resolution: "720x480", frameRate: "29.97", scanType: "bb",
                                                         audioSampleRate: "32000 Hz", audioChannels: "2", make: "Sony", model: "DCR-TRV900",
                                                         encoder: "Lavf58.76.100", contents: 1, durationSeconds: 600)
        let labels = Set(TechnicalReading.interpret(tuple.facts, now: ObservationsReportTests.now).map(\.label))
        for facet in ObservationsReport.TechnicalFacet.allCases {
            #expect(labels.contains(facet.rawValue), "TechnicalReading emits no “\(facet.rawValue)” line")
        }
        typealias Facet = ObservationsReport.TechnicalFacet
        #expect(Facet.allCases.map(\.groupTitle) == ["Containers", "Video codecs", "Audio", "Frame sizes", "Frame rates", "Scan",
                                                    "Cameras (make / model)", "Encoders / muxers"], "the groups, in the order shown")
        #expect(Facet.frameRate.rowLabel("29.97") == "29.97 fps" && Facet.audio.rowLabel("first audio stream: pcm_s16le") == "pcm_s16le")
        #expect(Facet(rawValue: "Creation time") == nil && Facet(rawValue: "container") == nil, "an uncounted line and a typo are no facet")
    }

    @Test func theTechnicalTierHasOneGroupPerFacetWithItsSource() async throws {
        let (fixture, repository) = try await ObservationsReportTests.scene()
        defer { fixture.remove() }
        let technical = try await ObservationsReportTests.report(repository).technical
        #expect(technical.groups.map(\.title) == ["Format readings"] + ObservationsReport.TechnicalFacet.allCases.map(\.groupTitle) + ["Embedded creation dates", "Probe"])
        for facet in ObservationsReport.TechnicalFacet.allCases {
            let rows = try #require(technical.group(facet.groupTitle)).rows
            #expect(rows.allSatisfy { $0.source == facet.source && $0.standing == .fact }, "\(facet)")
        }
        #expect(technical.row("Frame rates", "29.97 fps")?.count == 4 && technical.row("Containers", "DV (Digital Video)")?.count == 4)
        #expect(technical.row("Scan", "interlaced, bottom field first (as flagged)")?.evidence?.hasPrefix("interlaced") == true, "the ⓘ is what the value suggests")
        await repository.close()
    }
}
