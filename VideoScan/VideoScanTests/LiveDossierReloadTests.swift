import Foundation
import Testing
@testable import VideoScan

// MARK: - Live dossier reload + dashboard-coverage + fleet-stats tests
//
// Three suites for today's logic that previously had no coverage:
//
//   * LiveDossierReloadTests — VideoScanModel.mergeDossierFields(from:)
//     correctness: dossier-only field copy, user-edit preservation,
//     vintage skip-check, missing-record skip.
//   * CatalogCoverageTests — DossierDashboardView's CatalogCoverage
//     channel counts across 6 dimensions.
//   * FleetStatsTests — FleetStats.load(from:) line-count + mtime +
//     age-bucket behavior, fed from real on-disk fixtures.

// MARK: - Helpers (private to this file)

@MainActor
private func makeRecord(
    path: String,
    detectedPeople: [String] = [],
    notes: String = "",
    scenes: [SceneCaption] = [],
    transcript: String? = nil,
    inferredDate: Date? = nil,
    conf: Float? = nil,
    dossierAt: Date? = nil,
    dossierBy: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.detectedPeople = detectedPeople
    r.notes = notes
    r.sceneCaptions = scenes
    r.audioTranscript = transcript
    r.inferredRecordDate = inferredDate
    r.inferredDateConfidence = conf
    r.dossierProcessedAt = dossierAt
    r.dossierProcessedBy = dossierBy
    return r
}

// MARK: - Live reload merge

@MainActor
@Suite("VideoScanModel.mergeDossierFields")
struct LiveDossierReloadTests {

    @Test("dossier fields from disk land on the matching in-memory record")
    func dossierFieldsCopyOver() {
        let model = VideoScanModel()
        let mem = makeRecord(path: "/a")
        model.records = [mem]

        let snap = makeRecord(
            path: "/a",
            scenes: [SceneCaption(timestamp: 0.5, text: "kitchen")],
            transcript: "happy birthday Matt",
            inferredDate: Date(timeIntervalSince1970: 1_700_000_000),
            conf: 0.95,
            dossierAt: Date(timeIntervalSince1970: 1_800_000_000),
            dossierBy: "qwen+whisper"
        )

        let n = model.mergeDossierFields(from: [snap])
        #expect(n == 1)
        #expect(mem.sceneCaptions.count == 1)
        #expect(mem.audioTranscript == "happy birthday Matt")
        #expect(mem.inferredDateConfidence == 0.95)
        #expect(mem.dossierProcessedBy == "qwen+whisper")
    }

    @Test("user-editable fields are never overwritten")
    func userFieldsPreserved() {
        let model = VideoScanModel()
        let mem = makeRecord(
            path: "/a",
            detectedPeople: ["Matt"],     // user-edited
            notes: "ground truth"          // user-edited
        )
        model.records = [mem]

        // The snapshot deliberately carries DIFFERENT user-field
        // values to prove they're not stomped. (In production the
        // merger would never write these, but a corrupted/older
        // snapshot might have them — the merge code must still ignore.)
        let snap = makeRecord(
            path: "/a",
            detectedPeople: ["Should-Not-Land"],
            notes: "should-not-land",
            scenes: [SceneCaption(timestamp: 1.0, text: "x")],
            dossierAt: Date()
        )

        _ = model.mergeDossierFields(from: [snap])
        #expect(mem.detectedPeople == ["Matt"])
        #expect(mem.notes == "ground truth")
        #expect(mem.sceneCaptions.count == 1)
    }

    @Test("same dossier vintage is skipped — no re-copy")
    func sameVintageSkipped() {
        let model = VideoScanModel()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let mem = makeRecord(
            path: "/a",
            scenes: [SceneCaption(timestamp: 0.5, text: "old")],
            dossierAt: stamp,
            dossierBy: "qwen+whisper"
        )
        model.records = [mem]

        let snap = makeRecord(
            path: "/a",
            scenes: [SceneCaption(timestamp: 0.5, text: "fresher-text-that-shouldnt-land")],
            dossierAt: stamp,                          // same vintage
            dossierBy: "qwen+whisper"
        )

        let n = model.mergeDossierFields(from: [snap])
        #expect(n == 0, "Same-vintage snapshot must be skipped")
        #expect(mem.sceneCaptions.first?.text == "old")
    }

    @Test("snapshot record with nil dossierProcessedAt is skipped")
    func skipUndossieredSnapshot() {
        let model = VideoScanModel()
        let mem = makeRecord(path: "/a")
        model.records = [mem]
        let snap = makeRecord(path: "/a")  // dossierAt = nil
        let n = model.mergeDossierFields(from: [snap])
        #expect(n == 0)
        #expect(mem.dossierProcessedAt == nil)
    }

    @Test("snapshot record without a matching in-memory path is appended as new")
    func missingPathAppendedAsNew() {
        // Changed 2026-06-06: brand-new records are now appended to
        // model.records instead of dropped. Existing rows still
        // preserved with their identity.
        let model = VideoScanModel()
        let mem = makeRecord(path: "/known")
        model.records = [mem]
        let snap = makeRecord(
            path: "/ghost",
            scenes: [SceneCaption(timestamp: 0.5, text: "x")],
            dossierAt: Date()
        )
        let n = model.mergeDossierFields(from: [snap])
        #expect(n == 1, "the new record at /ghost should be appended")
        #expect(model.records.count == 2)
        #expect(model.records.last?.fullPath == "/ghost")
        #expect(mem.sceneCaptions.isEmpty, "the existing /known record must not be touched")
    }

    @Test("brand-new records on disk are appended to model.records")
    func brandNewRecordsAppended() {
        let model = VideoScanModel()
        let memA = makeRecord(path: "/a")
        model.records = [memA]

        let snapA = makeRecord(path: "/a", dossierAt: Date())          // existing
        let snapB = makeRecord(path: "/new1", dossierAt: Date())       // new
        let snapC = makeRecord(path: "/new2")                          // new, no dossier
        let n = model.mergeDossierFields(from: [snapA, snapB, snapC])

        // 2 appended + 1 merged in-place (the existing /a got dossier'd)
        #expect(n == 3)
        #expect(model.records.count == 3, "model.records must include the two new ones")
        let paths = model.records.map(\.fullPath).sorted()
        #expect(paths == ["/a", "/new1", "/new2"])
    }

    @Test("appending preserves @ObservedObject identity of existing rows")
    func identityPreservedOnMergePass() {
        // A record reference held by a SwiftUI view (Inspector, list row)
        // must still be the SAME object after a sync merge — otherwise
        // the view loses its selection / scroll position.
        let model = VideoScanModel()
        let memA = makeRecord(path: "/a")
        memA.notes = "user typed this"
        model.records = [memA]

        let snapA = makeRecord(path: "/a",
                               notes: "should-not-land",
                               scenes: [SceneCaption(timestamp: 1, text: "scene")],
                               dossierAt: Date())
        _ = model.mergeDossierFields(from: [snapA])
        // Same object reference, dossier fields updated, user fields untouched.
        #expect(model.records[0] === memA, "Existing row must keep its identity")
        #expect(memA.sceneCaptions.count == 1)
        #expect(memA.notes == "user typed this")
    }

    @Test("merging onto many records updates exactly the matching ones")
    func multiRecordMatch() {
        let model = VideoScanModel()
        let a = makeRecord(path: "/a")
        let b = makeRecord(path: "/b")
        let c = makeRecord(path: "/c")
        model.records = [a, b, c]

        let now = Date()
        let snaps: [VideoRecord] = [
            makeRecord(path: "/a", scenes: [SceneCaption(timestamp: 0, text: "A")], dossierAt: now),
            makeRecord(path: "/c", scenes: [SceneCaption(timestamp: 0, text: "C")], dossierAt: now),
            makeRecord(path: "/no-match", dossierAt: now)
        ]
        let n = model.mergeDossierFields(from: snaps)
        // 2 merged in-place (/a, /c) + 1 appended (/no-match)
        #expect(n == 3)
        #expect(a.sceneCaptions.first?.text == "A")
        #expect(b.sceneCaptions.isEmpty, "/b had no matching snapshot, must be left alone")
        #expect(c.sceneCaptions.first?.text == "C")
        #expect(model.records.contains { $0.fullPath == "/no-match" },
                "the new path /no-match must be appended")
    }
}

// MARK: - CatalogCoverage

@MainActor
@Suite("CatalogCoverage.init(records:)")
struct CatalogCoverageTests {

    @Test("empty catalog → all zeros")
    func emptyCatalog() {
        let cov = CatalogCoverage(records: [])
        #expect(cov.total == 0)
        #expect(cov.dossiered == 0)
        #expect(cov.scenes == 0)
        #expect(cov.ocrDates == 0)
        #expect(cov.transcripts == 0)
        #expect(cov.strongDates == 0)
    }

    @Test("counts per-channel populated records independently")
    func mixedChannels() {
        let now = Date()
        let r1 = makeRecord(path: "/a",
                            scenes: [SceneCaption(timestamp: 0, text: "x")],
                            dossierAt: now)
        let r2 = makeRecord(path: "/b",
                            transcript: "hello",
                            dossierAt: now)
        let r3 = makeRecord(path: "/c",
                            inferredDate: now,
                            conf: 0.95,
                            dossierAt: now)
        r3.ocrDateCandidates = [SceneCaption(timestamp: 0, text: "JUN 21 1991")]
        let r4 = makeRecord(path: "/d")  // not dossiered

        let cov = CatalogCoverage(records: [r1, r2, r3, r4])
        #expect(cov.total == 4)
        #expect(cov.dossiered == 3)
        #expect(cov.scenes == 1)
        #expect(cov.transcripts == 1)
        #expect(cov.ocrDates == 1)
        #expect(cov.strongDates == 1)
        #expect(cov.remaining == 1)
    }

    @Test("strongDates counts only records with confidence ≥ 0.85")
    func strongDatesThreshold() {
        let r1 = makeRecord(path: "/a", conf: 0.95, dossierAt: Date())
        let r2 = makeRecord(path: "/b", conf: 0.85, dossierAt: Date())
        let r3 = makeRecord(path: "/c", conf: 0.50, dossierAt: Date())
        let r4 = makeRecord(path: "/d", conf: 0.30, dossierAt: Date())
        let r5 = makeRecord(path: "/e", dossierAt: Date()) // conf = nil

        let cov = CatalogCoverage(records: [r1, r2, r3, r4, r5])
        // 0.95 and 0.85 both qualify; 0.50, 0.30, nil don't.
        #expect(cov.strongDates == 2)
    }

    @Test("empty transcript string does not count")
    func emptyTranscriptDoesNotCount() {
        let r1 = makeRecord(path: "/a", transcript: "", dossierAt: Date())
        let r2 = makeRecord(path: "/b", transcript: "real", dossierAt: Date())
        let cov = CatalogCoverage(records: [r1, r2])
        #expect(cov.transcripts == 1, "Empty-string transcript should not count")
    }
}

// MARK: - FleetStats

@Suite("FleetStats.load(from:)")
struct FleetStatsTests {

    /// Build a temp directory with optional per-host JSONL fixtures.
    /// Returns the directory URL and a cleanup callback.
    private func makeFixtureDir(
        m4Lines: Int? = nil,
        m5Lines: Int? = nil,
        m1Lines: Int? = nil
    ) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs-fleet-test-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let n = m4Lines {
            let content = String(repeating: "{\"ok\":1}\n", count: n)
            try? content.write(to: dir.appendingPathComponent("m4.jsonl"), atomically: true, encoding: .utf8)
        }
        if let n = m5Lines {
            let content = String(repeating: "{\"ok\":1}\n", count: n)
            try? content.write(to: dir.appendingPathComponent("m5.jsonl"), atomically: true, encoding: .utf8)
        }
        if let n = m1Lines {
            let content = String(repeating: "{\"ok\":1}\n", count: n)
            try? content.write(to: dir.appendingPathComponent("m1.jsonl"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    @Test("empty directory → all hosts show zero records, no last-write")
    func emptyDir() throws {
        let dir = makeFixtureDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = FleetStats.load(from: dir)
        #expect(stats[.m4].recordCount == 0)
        #expect(stats[.m5].recordCount == 0)
        #expect(stats[.m1].recordCount == 0)
        #expect(stats[.m4].lastWrite == nil)
        #expect(stats.isEmpty)
    }

    @Test("line counts match the number of \\n in each JSONL")
    func lineCounts() throws {
        let dir = makeFixtureDir(m4Lines: 100, m5Lines: 50, m1Lines: 25)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = FleetStats.load(from: dir)
        #expect(stats[.m4].recordCount == 100)
        #expect(stats[.m5].recordCount == 50)
        #expect(stats[.m1].recordCount == 25)
        #expect(!stats.isEmpty)
    }

    @Test("missing per-host file leaves that host empty without erroring")
    func partialFiles() throws {
        let dir = makeFixtureDir(m4Lines: 5)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = FleetStats.load(from: dir)
        #expect(stats[.m4].recordCount == 5)
        #expect(stats[.m5].recordCount == 0)
        #expect(stats[.m5].lastWrite == nil)
        #expect(stats[.m1].recordCount == 0)
    }

    @Test("freshly-written file shows 'running' liveness label")
    func activeLabel() throws {
        let dir = makeFixtureDir(m4Lines: 5)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stats = FleetStats.load(from: dir)
        // mtime just now → age < 120s → "running"
        // (Rick 2026-06-09 verb-rename pass a71b105 changed "active" →
        // "running"; this test wasn't updated and went stale.)
        #expect(stats[.m4].aliveLabel == "running")
    }

    @Test("HostStat.empty has nil lastWrite and zero counts")
    func hostStatEmpty() {
        let empty = FleetStats.HostStat.empty
        #expect(empty.recordCount == 0)
        #expect(empty.lastWrite == nil)
        // Same a71b105 verb-rename: empty stat now reports "idle"
        // (sentinel nil + lastWrite nil + recordCount 0 → idle).
        #expect(empty.aliveLabel == "idle")
    }
}
