import Testing
import Foundation
@testable import VideoScanCore

// FindTagJournal contract tests (2026-08-06). The journal is the
// write-back boundary between the detached find-tag daemon and the app:
// these pin the wire format (codex extends with adversarial cases).
struct FindTagJournalTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("findtag-journal-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func sampleStart(person: String = "Donna",
                             recipeID: String = "recipe-v1-native",
                             galleryDigest: String? = "digest-g1") -> FindTagRunStart {
        FindTagRunStart(runId: "RUN-1", at: Date(timeIntervalSince1970: 1_754_000_000),
                        person: person, recipeID: recipeID, engine: "arcface",
                        catalogPath: "/tmp/catalog.json", planned: 3,
                        galleryDigest: galleryDigest)
    }

    private func sampleVerdict(seq: Int, fingerprint: String? = "100|1.5|abc",
                               score: Double? = 0.71,
                               error: String? = nil) -> FindTagVerdict {
        FindTagVerdict(seq: seq, at: Date(timeIntervalSince1970: 1_754_000_100),
                       recordID: "0F4985E1-3037-4D35-9088-3069C33BA9B7",
                       path: "/Volumes/X/clip.mov", fingerprint: fingerprint,
                       score: score, error: error, frames: 220, gatedFaces: 31,
                       transport: "avfoundation", seconds: 41.2)
    }

    // MARK: Round-trip

    @Test func allKindsRoundTripThroughWriterAndReader() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("run.jsonl")

        let writer = try FindTagJournalWriter(fileURL: url)
        let start = sampleStart()
        let verdict = sampleVerdict(seq: 1)
        let beat = FindTagHeartbeat(at: Date(timeIntervalSince1970: 1_754_000_050),
                                    index: 1, planned: 3, currentPath: "/Volumes/X/clip.mov")
        let end = FindTagRunEnd(at: Date(timeIntervalSince1970: 1_754_000_200),
                                status: .completed, scored: 1, errors: 0,
                                reused: 0, skippedHuman: 0)
        try writer.append(.runStart(start))
        try writer.append(.heartbeat(beat), sync: false)
        try writer.append(.verdict(verdict))
        try writer.append(.runEnd(end))
        writer.close()

        let entries = FindTagJournalReader.entries(at: url)
        #expect(entries == [.runStart(start), .heartbeat(beat),
                            .verdict(verdict), .runEnd(end)])
    }

    // MARK: Crash tolerance

    @Test func truncatedTailLineIsSkippedNotFatal() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("run.jsonl")

        let writer = try FindTagJournalWriter(fileURL: url)
        try writer.append(.runStart(sampleStart()))
        try writer.append(.verdict(sampleVerdict(seq: 1)))
        writer.close()
        // Simulate a crash mid-write: garbage partial JSON with no newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"kind\":\"verdict\",\"seq\":2,\"at\":\"20".utf8))
        try handle.close()

        let entries = FindTagJournalReader.entries(at: url)
        #expect(entries.count == 2)   // everything before the torn line stands
        if case .verdict(let v) = entries[1] { #expect(v.seq == 1) }
        else { Issue.record("expected the intact verdict to survive") }
    }

    @Test func unknownSchemaVersionSkipsWholeFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // ANY v this reader doesn't know skips the file — higher, zero,
        // or negative (codex #274: `>` accepted never-issued versions).
        for badVersion in [FindTagJournalSchema.version + 1, 0, -3] {
            let url = dir.appendingPathComponent("v\(badVersion).jsonl")
            var start = sampleStart()
            start.v = badVersion
            let writer = try FindTagJournalWriter(fileURL: url)
            try writer.append(.runStart(start))
            try writer.append(.verdict(sampleVerdict(seq: 1)))
            writer.close()
            #expect(FindTagJournalReader.entries(at: url).isEmpty,
                    "v=\(badVersion) must skip the whole file")
        }
    }

    @Test func unknownKindLineIsSkipped() {
        let data = Data("""
        {"kind":"runStart","v":1,"runId":"R","at":"2026-08-06T12:00:00Z","person":"Donna","recipeID":"recipe-v1-native","engine":"arcface","catalogPath":"/c","planned":1}
        {"kind":"telemetryV9","whatever":true}
        {"kind":"runEnd","at":"2026-08-06T12:01:00Z","status":"completed","scored":0,"errors":0,"reused":0,"skippedHuman":0}
        """.utf8)
        let entries = FindTagJournalReader.entries(in: data)
        #expect(entries.count == 2)   // forward-compatible: skip, don't die
    }

    // MARK: Resume index

    @Test func reusableVerdictsFiltersPersonRecipeAndErrors() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // File 1: matching run — one success, one error.
        let f1 = dir.appendingPathComponent("findtag-20260806-010000-aaaa.jsonl")
        let w1 = try FindTagJournalWriter(fileURL: f1)
        try w1.append(.runStart(sampleStart()))
        try w1.append(.verdict(sampleVerdict(seq: 1, fingerprint: "fp-ok", score: 0.8)))
        try w1.append(.verdict(sampleVerdict(seq: 2, fingerprint: "fp-err",
                                             score: nil, error: "wedged")))
        w1.close()

        // File 2: DIFFERENT person — must be ignored entirely.
        let f2 = dir.appendingPathComponent("findtag-20260806-020000-bbbb.jsonl")
        let w2 = try FindTagJournalWriter(fileURL: f2)
        try w2.append(.runStart(sampleStart(person: "Tim")))
        try w2.append(.verdict(sampleVerdict(seq: 1, fingerprint: "fp-tim", score: 0.9)))
        w2.close()

        // File 3: later matching run re-scores fp-ok — newest must win.
        let f3 = dir.appendingPathComponent("findtag-20260806-030000-cccc.jsonl")
        let w3 = try FindTagJournalWriter(fileURL: f3)
        try w3.append(.runStart(sampleStart()))
        try w3.append(.verdict(sampleVerdict(seq: 1, fingerprint: "fp-ok", score: 0.55)))
        w3.close()

        let index = FindTagJournalReader.reusableVerdicts(
            fromJournalFiles: [f1, f2, f3],
            person: "donna",            // case-insensitive person match
            recipeID: "recipe-v1-native",
            galleryDigest: "digest-g1")

        #expect(index.count == 1)
        #expect(index["fp-ok"]?.score == 0.55)   // later run won
        #expect(index["fp-err"] == nil)          // errors retried, not reused
        #expect(index["fp-tim"] == nil)          // other person ignored
    }

    @Test func galleryChangeInvalidatesReuse() throws {
        // codex #275: a retouched reference gallery must invalidate
        // prior scores — reuse requires an EXACT digest match, and nil
        // on either side disqualifies.
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let f1 = dir.appendingPathComponent("findtag-20260806-010000-aaaa.jsonl")
        let w1 = try FindTagJournalWriter(fileURL: f1)
        try w1.append(.runStart(sampleStart(galleryDigest: "old-gallery")))
        try w1.append(.verdict(sampleVerdict(seq: 1, fingerprint: "fp-ok", score: 0.8)))
        w1.close()
        let f2 = dir.appendingPathComponent("findtag-20260806-020000-bbbb.jsonl")
        let w2 = try FindTagJournalWriter(fileURL: f2)
        try w2.append(.runStart(sampleStart(galleryDigest: nil)))   // pre-digest journal
        try w2.append(.verdict(sampleVerdict(seq: 1, fingerprint: "fp-old", score: 0.9)))
        w2.close()

        // Current gallery differs → nothing reusable from either file.
        #expect(FindTagJournalReader.reusableVerdicts(
            fromJournalFiles: [f1, f2], person: "Donna",
            recipeID: "recipe-v1-native", galleryDigest: "new-gallery").isEmpty)
        // Unknown current gallery → no reuse at all.
        #expect(FindTagJournalReader.reusableVerdicts(
            fromJournalFiles: [f1, f2], person: "Donna",
            recipeID: "recipe-v1-native", galleryDigest: nil).isEmpty)
        // Matching digest still works.
        #expect(FindTagJournalReader.reusableVerdicts(
            fromJournalFiles: [f1, f2], person: "Donna",
            recipeID: "recipe-v1-native", galleryDigest: "old-gallery")["fp-ok"]?.score == 0.8)
    }

    // MARK: Ingest cursor

    @Test func ingestCursorIsIdempotentAndOrdered() throws {
        let entries: [FindTagJournalEntry] = [
            .runStart(sampleStart()),
            .verdict(sampleVerdict(seq: 2)),
            .verdict(sampleVerdict(seq: 1)),
            .verdict(sampleVerdict(seq: 3)),
        ]
        var state = FindTagIngestState()
        let first = state.pendingVerdicts(in: entries, filename: "run.jsonl")
        #expect(first.map(\.seq) == [1, 2, 3])   // seq order regardless of file order

        state.markApplied(filename: "run.jsonl", through: 2)
        let rest = state.pendingVerdicts(in: entries, filename: "run.jsonl")
        #expect(rest.map(\.seq) == [3])

        state.markApplied(filename: "run.jsonl", through: 3)
        #expect(state.pendingVerdicts(in: entries, filename: "run.jsonl").isEmpty)
        // A stale lower mark never rewinds the cursor.
        state.markApplied(filename: "run.jsonl", through: 1)
        #expect(state.pendingVerdicts(in: entries, filename: "run.jsonl").isEmpty)
    }

    @Test func ingestStateRoundTripsAndToleratesMissingFile() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FindTagIngestState.url(inJournalDirectory: dir)

        #expect(FindTagIngestState.restored(from: url) == FindTagIngestState())

        var state = FindTagIngestState()
        state.markApplied(filename: "a.jsonl", through: 41)
        state.save(to: url)
        #expect(FindTagIngestState.restored(from: url).appliedSeq["a.jsonl"] == 41)
    }

    @Test func journalFilenameIsSortableAndCarriesRunId() {
        let name = FindTagPaths.journalFilename(
            runId: "ABCDEF12-3456", at: Date(timeIntervalSince1970: 1_754_000_000))
        #expect(name.hasPrefix("findtag-"))
        #expect(name.hasSuffix(".jsonl"))
        #expect(name.contains("ABCDEF12"))
        #expect(!name.contains("ABCDEF12-3456"))   // truncated to 8 chars
    }
}
