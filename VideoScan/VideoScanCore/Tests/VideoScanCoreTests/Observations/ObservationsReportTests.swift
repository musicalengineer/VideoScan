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
        var files: [DossierFixture.File] = [
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
