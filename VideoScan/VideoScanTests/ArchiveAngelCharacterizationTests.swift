// ArchiveAngelCharacterizationTests.swift
// S0 of the Archive Angel consolidation (docs/archive_angel_consolidation_plan.md):
// CHARACTERIZATION ONLY — these tests pin what the code does TODAY so the
// S1 file moves and the S2 seams can be shown to be behaviour-preserving.
// Nothing here says the current behaviour is right (S3 changes the rules on
// purpose and will update the pinned numbers in the same commit, with the
// old → new counts logged).
//
// Four pins:
//   1. golden plan.json fixtures decode, and re-encode with the SAME key set
//      (no stored property / enum raw value may be renamed — plan.json is
//      the only record of a prepared batch and is not regenerable);
//   2. the nudge's ready / near-ready counts and the Angel's grade + floor
//      histogram over 100k synthetic records, under a time budget;
//   3. the ArchiveReadiness token (written into the archive manifest);
//   4. the ledger kinds, rejection reasons, grades, plan enums and the
//      Angel's UserDefaults keys (on-disk vocabulary).
//
// Fixtures: Fixtures/ArchiveAngel/plan_*.json — anonymized copies of real
// batches (names, paths, notes, evidence lines and log lines replaced;
// structure, enum values, dates and UUIDs kept).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - 1. Golden plan.json

@Suite("Archive Angel S0 — golden plan.json fixtures decode and keep their keys")
struct ArchiveAngelGoldenPlanTests {

    static let fixtureNames = [
        "plan_promoted_with_skips.json",
        "plan_promoted_with_edits.json",
        "plan_promoted_single.json",
        "plan_ready_empty.json",
    ]

    static func fixturesDir(from filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/ArchiveAngel", isDirectory: true)
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: fixturesDir().appendingPathComponent(name))
    }

    static func decode(_ data: Data) throws -> ArchiveAngelPlan {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(ArchiveAngelPlan.self, from: data)
    }

    /// Every key path in a JSON value ("entries[].steps[].kind"), so a
    /// renamed optional property — which decodes as nil and would silently
    /// drop off on the next save — shows up as a missing path.
    static func keyPaths(_ any: Any, prefix: String = "") -> Set<String> {
        var out = Set<String>()
        if let dict = any as? [String: Any] {
            for (k, v) in dict {
                // `rejected` is a reason → count map: its keys are data, not schema.
                let path = prefix.isEmpty ? k : prefix + "." + k
                out.insert(path)
                if k == "rejected" { continue }
                out.formUnion(keyPaths(v, prefix: path))
            }
        } else if let list = any as? [Any] {
            for v in list { out.formUnion(keyPaths(v, prefix: prefix + "[]")) }
        }
        return out
    }

    @Test("each golden plan.json decodes with the current ArchiveAngelPlan", arguments: fixtureNames)
    func decodes(name: String) throws {
        let plan = try Self.decode(try Self.data(name))
        #expect(!plan.batchDir.isEmpty)
        #expect(plan.batchID.hasPrefix("batch-"))
    }

    @Test("decode → encode keeps every key the file had (no renamed stored property)", arguments: fixtureNames)
    func roundTripKeepsKeys(name: String) throws {
        let original = try Self.data(name)
        let plan = try Self.decode(original)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let again = try enc.encode(plan)
        let before = Self.keyPaths(try JSONSerialization.jsonObject(with: original))
        let after = Self.keyPaths(try JSONSerialization.jsonObject(with: again))
        let lost = before.subtracting(after)
        #expect(lost.isEmpty, "keys lost on re-encode (a rename?): \(lost.sorted())")
        // And the decoded value survives a second trip unchanged.
        #expect(try Self.decode(again) == plan)
    }

    @Test("the pinned facts of each fixture (status, rows, row states, report, rejections)")
    func pinnedFacts() throws {
        let skips = try Self.decode(try Self.data("plan_promoted_with_skips.json"))
        #expect(skips.status == .promoted)
        #expect(skips.entries.count == 10)
        #expect(Set(skips.entries.map(\.status)) == [.failed, .promoted, .skipped])
        #expect(skips.skippedCount == skips.entries.filter { $0.status == .skipped }.count)
        #expect(skips.report?.skippedByUser != nil)
        #expect(skips.rejected["Already in the archive"] == 1148)
        #expect(skips.rejectedTotal == skips.rejected.values.reduce(0, +))

        let edits = try Self.decode(try Self.data("plan_promoted_with_edits.json"))
        #expect(edits.status == .promoted)
        #expect(edits.entries.contains { $0.userEditedName != nil })
        #expect(edits.entries.flatMap(\.steps).contains { $0.seconds != nil })
        #expect(Set(edits.entries.flatMap(\.steps).map(\.state)) == [.pending, .failed, .skipped, .done])

        let single = try Self.decode(try Self.data("plan_promoted_single.json"))
        #expect(single.entries.count == 1)
        #expect(single.entries.first?.status == .promoted)
        #expect(single.rejected.isEmpty)

        let empty = try Self.decode(try Self.data("plan_ready_empty.json"))
        #expect(empty.status == .ready)
        #expect(empty.entries.isEmpty)
        #expect(empty.readyCount == 0)
        #expect(empty.report == nil)
    }

    @Test("ArchiveAngelPlanStore.load reads a golden fixture from a batch folder and re-points batchDir")
    func storeLoadsFixture() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("angel-s0-\(UUID().uuidString)/batch-2026-09-19T12-49-52", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir.deletingLastPathComponent()) }
        try Self.data("plan_promoted_with_skips.json")
            .write(to: dir.appendingPathComponent(ArchiveAngelPlan.planFilename))
        let plan = try ArchiveAngelPlanStore.load(batchDir: dir.path)
        #expect(plan.batchDir == dir.path)
        #expect(plan.entries.count == 10)
    }
}

// MARK: - 2. Nudge counts + Angel grade histogram at 100k

/// A deterministic synthetic catalog (xorshift, fixed seed): the same 100k
/// records every run, so the counts below are exact pins, not ranges.
enum ArchiveAngelS0Catalog {

    struct RNG {
        var state: UInt64
        mutating func next() -> UInt64 {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return state
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
    }

    static let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09-21, fixed
    static let codecs = ["dvvideo", "h264", "prores", "mpeg2video", "hevc", "mpeg4", "", "mjpeg"]
    static let folders = ["Tapes", "Family Movies", "iMovie Cache", "Exports", "DCIM", "Photos Library.photoslibrary/originals"]

    static func uuid(_ i: Int) -> UUID {
        guard let id = UUID(uuidString: String(format: "00000000-0000-4000-8000-%012X", i)) else {
            preconditionFailure("synthetic UUID \(i) did not parse")
        }
        return id
    }

    static func candidates(_ n: Int) -> [ArchiveAngelCandidate] {
        var rng = RNG(state: 0x9E37_79B9_7F4A_7C15)
        var out: [ArchiveAngelCandidate] = []
        out.reserveCapacity(n)
        let streams = [StreamType.videoAndAudio.rawValue, StreamType.videoOnly.rawValue,
                       StreamType.audioOnly.rawValue, StreamType.videoAndAudio.rawValue]
        let stages: [ArchiveStage] = [.none, .none, .none, .none, .readyForArchive, .masterAssigned, .archived]
        let dispositions: [MediaDisposition] = [.unreviewed, .unreviewed, .unreviewed, .important, .suspectedJunk, .confirmedJunk]
        let roles: [VolumeRole] = [.workspace, .workspace, .backup, .unassigned]
        for i in 0..<n {
            let folder = folders[rng.below(folders.count)]
            let stem = rng.below(10) == 0 ? "clip_\(i % 500)_balanced" : "clip_\(i % 700)"
            let duration = Double(rng.below(7200))
            let codec = codecs[rng.below(codecs.count)]
            let kbps = [50, 800, 3000, 25_000][rng.below(4)]
            let hasDate = rng.below(3) != 0
            var c = ArchiveAngelCandidate(
                id: uuid(i), filename: stem + ".mov", fullPath: "/Volumes/V\(i % 4)/\(folder)/\(i / 1000)/\(stem).mov",
                sizeBytes: Int64(duration * Double(kbps) * 1000 / 8), durationSeconds: duration,
                streamTypeRaw: streams[rng.below(streams.count)],
                isPlayable: rng.below(40) == 0 ? "No" : "Yes",
                starRating: [0, 0, 0, 0, 1, 2, 3][rng.below(7)],
                mediaDisposition: dispositions[rng.below(dispositions.count)],
                archiveStage: stages[rng.below(stages.count)],
                junkScore: [0, 0, 3, 10, 60][rng.below(5)],
                confirmedPeople: rng.below(6) == 0 ? ["P\(i % 9)"] : [],
                detectedPeople: rng.below(4) == 0 ? ["M\(i % 5)"] : [],
                hasUserNotes: rng.below(8) == 0, tagCount: rng.below(3),
                hasCaptions: rng.below(5) == 0, hasOCRText: rng.below(9) == 0,
                hasEmbeddedDate: rng.below(3) == 0, hasTapeOrClipName: rng.below(7) == 0,
                userDate: rng.below(12) == 0 ? "199\(i % 10)" : nil,
                inferredRecordDate: hasDate ? Date(timeIntervalSince1970: Double(rng.below(1_700_000_000))) : nil,
                inferredDateConfidence: hasDate ? [0.3, 0.6, 0.85, 0.95][rng.below(4)] : nil,
                formatAtRisk: rng.below(4) == 0, audioProblem: rng.below(20) == 0 ? "left only" : nil,
                isPairedHalf: rng.below(30) == 0, hasArchivedDuplicate: rng.below(25) == 0,
                isOnlyCopy: rng.below(3) == 0, volumeRole: roles[rng.below(roles.count)],
                volumeName: "V\(i % 4)", volumeOnline: rng.below(15) != 0,
                isOnMasterArchive: rng.below(50) == 0,
                useCount: rng.below(5) == 0 ? rng.below(40) : 0,
                lastUsed: rng.below(6) == 0 ? now.addingTimeInterval(-Double(rng.below(900)) * 86_400) : nil,
                videoCodec: codec,
                duplicateGroupID: rng.below(6) == 0 ? uuid(1_000_000 + i % 3000) : nil,
                deviceModel: rng.below(10) == 0 ? "iPhone 12" : "",
                captureDate: rng.below(2) == 0 ? now.addingTimeInterval(-Double(rng.below(8000)) * 86_400) : nil)
            if rng.below(10) == 0 {
                var a = ArchiveAngelAttention.none
                a.note(.angelProposed, at: now.addingTimeInterval(-5 * 86_400))
                a.note(.angelSkipped, at: now.addingTimeInterval(-4 * 86_400))
                if rng.below(3) == 0 {
                    a.note(.angelSkipped, at: now.addingTimeInterval(-3 * 86_400))
                    a.note(.angelSkipped, at: now.addingTimeInterval(-2 * 86_400))
                }
                c.attention = a
            }
            out.append(c)
        }
        return out
    }

    @MainActor
    static func records(_ n: Int) -> [VideoRecord] {
        var rng = RNG(state: 0xD1B5_4A32_D192_ED03)
        let dispositions: [MediaDisposition] = [.unreviewed, .unreviewed, .important, .suspectedJunk, .confirmedJunk, .recoverable]
        let stages: [ArchiveStage] = [.none, .none, .none, .readyForArchive, .masterAssigned]
        let dups: [DuplicateDisposition] = [.none, .none, .none, .keep, .extraCopy, .review]
        var out: [VideoRecord] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let r = VideoRecord(id: uuid(i))
            r.filename = rng.below(5) == 0 ? "\(i % 200)0000.MTS" : "tape_\(i).mov"
            r.fullPath = "/Volumes/V\(i % 3)/\(r.filename)"
            r.durationSeconds = Double(rng.below(4000))
            r.starRating = [0, 0, 0, 1, 2, 3][rng.below(6)]
            r.mediaDisposition = dispositions[rng.below(dispositions.count)]
            r.archiveStage = stages[rng.below(stages.count)]
            r.duplicateDisposition = dups[rng.below(dups.count)]
            if rng.below(4) == 0 {
                r.duplicateGroupID = uuid(2_000_000 + i % 5000)
                r.duplicateGroupCount = 2
            }
            r.junkScore = [0, 0, 10, 49, 50, 90][rng.below(6)]
            switch rng.below(4) {
            case 0: r.embeddedCreationDate = Date(timeIntervalSince1970: Double(rng.below(1_600_000_000)))
            case 1: r.userDate = "19\(80 + i % 20)"; r.userDateConfidence = "sure"
            default: break
            }
            out.append(r)
        }
        return out
    }

    /// The sweep's per-record path (floor, then verdict), as a grade histogram
    /// plus floor reasons — exactly what `ArchiveAngelSweep.perform` stores.
    static func histogram(_ cs: [ArchiveAngelCandidate], weights: ArchiveAngelWeights = .standard)
    -> (grades: [ArchiveAngelGrade: Int], rejections: [ArchiveAngelRejection: Int], scoreSum: Int) {
        var grades: [ArchiveAngelGrade: Int] = [:]
        var rejections: [ArchiveAngelRejection: Int] = [:]
        var sum = 0
        for c in cs {
            if let r = ArchiveAngelScorer.hardFloor(c, weights: weights, now: now) {
                grades[.x, default: 0] += 1; rejections[r, default: 0] += 1; continue
            }
            switch ArchiveAngelScorer.verdict(c, weights: weights, now: now) {
            case .eligible(let score, _):
                grades[ArchiveAngelGrade.from(score: score), default: 0] += 1
                sum += score
            case .rejected(let r):
                grades[.x, default: 0] += 1; rejections[r, default: 0] += 1
            }
        }
        return (grades, rejections, sum)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

@Suite("Archive Angel S0 — nudge counts and grade histogram pinned at 100k records", .serialized)
@MainActor
struct ArchiveAngelScaleCharacterizationTests {

    // Pinned 2026-09-22 from main 05f4be42 (rules v10). S3b changes them on purpose.
    static let pinnedGrades: [ArchiveAngelGrade: Int] = [.a: 9016, .b: 3228, .c: 1404, .d: 76, .x: 86276]
    static let pinnedRejections: [ArchiveAngelRejection: Int] = [
        .notVideo: 24976, .alreadyArchived: 32815, .duplicateArchived: 1653, .volumeOffline: 1049,
        .tooShort: 448, .recentPhoneClip: 7057, .junk: 3958, .suspectedJunk: 4527, .notPlayable: 991,
        .pairedHalf: 1339, .derivativeOfOriginal: 79, .appCache: 3384, .proxyStream: 3513, .resting: 485,
    ]
    static let pinnedScoreSum = 1_699_691
    static let pinnedNudgeReady = 11_787
    static let pinnedNudgeNear = 11_482
    static let pinnedNudgeHead = [2649, 31596, 76168, 40491, 15136, 42680, 66721, 35713, 40586, 75163, 93926, 13672, 92296, 13579, 82583]
    static let pinnedSelectionHead = [24591, 23613, 73414, 26643, 20311, 28174, 37705, 39336, 95208, 20465]
    static let pinnedSelectionOverflow = 12_919
    static let pinnedSelectionRejected: [ArchiveAngelRejection: Int] =
        pinnedRejections.merging([.duplicateOfPick: 695, .sameFamilyAsPick: 102]) { a, _ in a }

    /// The index `i` of a synthetic record from its UUID.
    static func index(_ id: UUID) -> Int {
        Int(id.uuidString.suffix(12), radix: 16) ?? -1
    }

    @Test("SCALE: grade + floor histogram over 100k candidates — exact counts, floor + verdict under 1 s")
    func gradeHistogram() {
        var cs = ArchiveAngelS0Catalog.candidates(100_000)
        let clock = ContinuousClock()
        var h: (grades: [ArchiveAngelGrade: Int], rejections: [ArchiveAngelRejection: Int], scoreSum: Int) = ([:], [:], 0)
        // The two whole-set passes the sweep's snapshot runs (not timed —
        // ArchiveAngelAttentionTests.hundredThousandBudget owns them).
        ArchiveAngelScorer.markDerivatives(&cs)
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: ArchiveAngelS0Catalog.now)
        // Timed: the sweep's per-record work (floor, then verdict).
        let elapsed = clock.measure { h = ArchiveAngelS0Catalog.histogram(cs) }
        let s = ArchiveAngelS0Catalog.seconds(elapsed)
        print("[angel-s0] grades \(ArchiveAngelGrade.allCases.map { "\($0.rawValue):\(h.grades[$0] ?? 0)" }.joined(separator: " ")) · score sum \(h.scoreSum) · \(String(format: "%.3f", s)) s")
        print("[angel-s0] rejections " + ArchiveAngelRejection.allCases.map { "\($0):\(h.rejections[$0] ?? 0)" }.joined(separator: " "))
        #expect(h.grades.values.reduce(0, +) == 100_000)
        #expect(h.grades == Self.pinnedGrades)
        #expect(h.rejections == Self.pinnedRejections)
        #expect(h.scoreSum == Self.pinnedScoreSum)
        #expect(s < 1, "100k floor + verdict in \(s) s")
    }

    @Test("the batch pick over the same 100k — first 10 picks and rejection counts pinned")
    func selectionPinned() {
        var cs = ArchiveAngelS0Catalog.candidates(100_000)
        ArchiveAngelScorer.markDerivatives(&cs)
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: ArchiveAngelS0Catalog.now)
        let sel = ArchiveAngelScorer.select(cs, count: 10, now: ArchiveAngelS0Catalog.now)
        let head = sel.picks.map { Self.index($0.id) }
        print("[angel-s0] selection head \(head) overflow \(sel.overflow)")
        print("[angel-s0] selection rejected " + ArchiveAngelRejection.allCases.map { "\($0):\(sel.rejected[$0] ?? 0)" }.joined(separator: " "))
        #expect(head == Self.pinnedSelectionHead)
        #expect(sel.rejected == Self.pinnedSelectionRejected)
        #expect(sel.overflow == Self.pinnedSelectionOverflow)
    }

    @Test("SCALE: ArchiveNudge.assess over 100k records — ready / near-ready counts pinned, under 1 s")
    func nudgeCounts() {
        let records = ArchiveAngelS0Catalog.records(100_000)
        let clock = ContinuousClock()
        var nudge = ArchiveNudge.empty
        let elapsed = clock.measure { nudge = ArchiveNudge.assess(records) }
        let s = ArchiveAngelS0Catalog.seconds(elapsed)
        let head = nudge.shortlist.map { Self.index($0.id) }
        print("[angel-s0] nudge ready \(nudge.ready.count) near \(nudge.nearReady.count) head \(head) · \(String(format: "%.3f", s)) s")
        #expect(nudge.ready.count == Self.pinnedNudgeReady)
        #expect(nudge.nearReady.count == Self.pinnedNudgeNear)
        #expect(head == Self.pinnedNudgeHead)
        #expect(s < 1, "nudge over 100k in \(s) s")
    }

    @Test("the background sweep stores the same grade histogram as the pure path (10k, no Spotlight, no disk budget)")
    func sweepMatchesPurePath() async throws {
        var cs = ArchiveAngelS0Catalog.candidates(10_000)
        ArchiveAngelScorer.markDerivatives(&cs)
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: ArchiveAngelS0Catalog.now)
        let expected = ArchiveAngelS0Catalog.histogram(cs)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-s0-sweep-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ArchiveAngelEvidenceStore(directory: dir)
        let sweep = ArchiveAngelSweep(store: store)
        let snapshot = cs
        var cfg = ArchiveAngelSweep.Configuration(candidates: { snapshot }, isExternallyBusy: { false })
        cfg.playHistory = { _ in [:] }
        cfg.checkpointEvery = 1_000_000
        cfg.quietSeconds = 0
        cfg.now = { ArchiveAngelS0Catalog.now }
        sweep.configure(cfg, enabled: true)
        await sweep.runAndWait(reason: "s0")
        sweep.stop()
        #expect(store.gradeCounts() == expected.grades)
        #expect(store.consideredCount == 10_000)
    }
}

// MARK: - 3/4. On-disk vocabulary

@Suite("Archive Angel S0 — on-disk vocabulary and the readiness token")
struct ArchiveAngelVocabularyTests {

    @Test("ledger kinds: raw values and order unchanged (the Media Ledger is append-only on disk)")
    func ledgerKinds() {
        #expect(MediaLedgerEvent.Kind.allCases.map(\.rawValue) == [
            "cataloged", "setAside", "putBack", "archived", "copyTrashed", "copyDeleted", "restored",
            "placeSet", "dateSet", "attestation", "approval", "angelProposed", "angelSkipped", "angelCleared",
        ])
        #expect(MediaLedgerEvent.Actor.allCases.map(\.rawValue) == ["rick", "tidy", "promote", "angel", "app"])
        #expect(ArchiveAngelAttentionStore.attentionKinds == [.angelProposed, .angelSkipped, .angelCleared])
    }

    @Test("rejection reasons: raw values unchanged (plan.json `rejected` keys and evidence.json)")
    func rejectionRawValues() {
        #expect(ArchiveAngelRejection.allCases.map(\.rawValue) == [
            "Not a video",
            "Already in the archive",
            "A copy is already in the archive",
            "Volume offline",
            "Too short (under 2 min — short clips are usually pieces of a longer original)",
            "Live Photo motion (part of a photo, not a video)",
            "Phone clip under 10 years old (Rick 2026-09-21: only older phone clips are worth archiving)",
            "Marked junk",
            "Looks like junk (machine evidence, unrated)",
            "Not playable / un-probeable",
            "Half of an A/V pair — combine first",
            "Already in a prepared batch",
            "Same content as another pick (duplicate group) — one copy is enough",
            "A derivative export — its original is in the catalog",
            "An app's cache / render file (name or folder), not an original",
            "Too small for its length — a thumbnail or proxy stream, not the original",
            "Resting — you passed on it three times; it comes back 90 days after the last pass",
            "A variant of another pick (same event family) — one per batch",
        ])
    }

    @Test("grades, plan status / entry status / step kind / step state raw values unchanged")
    func planEnums() {
        #expect(ArchiveAngelGrade.allCases.map(\.rawValue) == ["A", "B", "C", "D", "X"])
        #expect([ArchiveAngelPlan.Status.preparing, .ready, .promoting, .promoted, .discarded].map(\.rawValue)
                == ["preparing", "ready", "promoting", "promoted", "discarded"])
        #expect([ArchiveAngelPlan.EntryStatus.pending, .preparing, .ready, .promoted, .failed, .skipped].map(\.rawValue)
                == ["pending", "preparing", "ready", "promoted", "failed", "skipped"])
        #expect(ArchiveAngelPlan.StepKind.allCases.map(\.rawValue)
                == ["verifyAudio", "balanceAudio", "accessCopy", "losslessCopy"])
        #expect([ArchiveAngelPlan.StepState.pending, .done, .skipped, .failed].map(\.rawValue)
                == ["pending", "done", "skipped", "failed"])
        #expect(ArchiveAngelPlan.planFilename == "plan.json")
        #expect(ArchiveAngelEvidenceStore.filename == "evidence.json")
        #expect(ArchiveAngelEvidenceFile.currentVersion == 1)
        #expect(ArchiveAngelScorer.rulesVersion == 10)
    }

    @Test("grade bands unchanged: A ≥ 100, B 60–99, C 25–59, D 1–24, else X")
    func gradeBands() {
        let pins: [(Int, ArchiveAngelGrade)] = [(-5, .x), (0, .x), (1, .d), (24, .d), (25, .c), (59, .c),
                                                (60, .b), (99, .b), (100, .a), (400, .a)]
        for (score, grade) in pins { #expect(ArchiveAngelGrade.from(score: score) == grade, "score \(score)") }
    }

    @Test("the Angel's UserDefaults keys are unchanged (a rename would silently reset Rick's settings)")
    func defaultsKeys() {
        // S2 gathered the three into ArchiveAngelSettings — the strings are
        // what S0 pinned (the sweep's key, and the start sheet's two
        // @AppStorage literals); the defaults are ON / 25 / off.
        #expect(ArchiveAngelSettings.sweepEnabledKey == "archiveAngel.sweepEnabled")
        #expect(ArchiveAngelSettings.batchCountKey == "archiveAngel.count")
        #expect(ArchiveAngelSettings.makeLosslessKey == "archiveAngel.makeLossless")
        #expect(ArchiveAngelSettings() == ArchiveAngelSettings(sweepEnabled: true, batchCount: 25, makeLossless: false))
        #expect(ArchiveAngelStartSheet.choices == [10, 25, 35, 50])
    }

    @Test("the buffer root under a test host is the per-process scratch folder, never Rick's buffer")
    func testHostBufferRoot() {
        #expect(ArchiveAngelPlanStore.defaultBufferRoot == ArchiveAngelPlanStore.testHostBufferRoot)
        #expect(!ArchiveAngelPlanStore.defaultBufferRoot.path.contains("/Movies/VideoScan Buffer"))
    }

    // MARK: Readiness token (written into the archive manifest)

    static func inputs(stream: StreamType, playable: String = "Yes", video: String = "", audio: String = "",
                       verify: String = "", note: String = "", userDate: String? = nil,
                       embedded: Date? = nil) -> ArchiveReadiness.Inputs {
        var i = ArchiveReadiness.Inputs()
        i.streamTypeRaw = stream.rawValue
        i.isPlayable = playable
        i.videoCodec = video
        i.audioCodec = audio
        i.audioVerifyStatus = verify
        i.audioVerifyNote = note
        i.userDate = userDate
        i.userDateConfidence = userDate == nil ? nil : "sure"
        i.embeddedCreationDate = embedded
        i.filename = "clip.mov"
        return i
    }

    @Test("ArchiveReadiness.token for a table of inputs is byte-identical to today's")
    func readinessTokens() {
        let camera = Date(timeIntervalSince1970: 773_000_000)   // 1994
        let table: [(ArchiveReadiness.Inputs, String)] = [
            (Self.inputs(stream: .videoAndAudio, video: "dvvideo", audio: "pcm_s16le", verify: "ok", userDate: "1994"),
             "playable;audio=verified;format=at-risk:DV;date=known"),
            (Self.inputs(stream: .videoAndAudio, video: "prores", audio: "pcm_s24le", embedded: camera),
             "playable;audio=unverified;format=safe;date=known"),
            (Self.inputs(stream: .videoOnly, video: "h264"),
             "playable;audio=none;format=safe;date=undated"),
            (Self.inputs(stream: .videoAndAudio, video: "mpeg4", audio: "aac", verify: "damaged", note: "dropouts"),
             "playable;audio=problem;format=at-risk:MPEG-4_Part_2;date=undated"),
            (Self.inputs(stream: .ffprobeFailed),
             "unprobeable;audio=none;format=unknown;date=undated"),
        ]
        for (i, expected) in table {
            let token = ArchiveReadiness.assess(i).token
            print("[angel-s0] readiness \(i.streamTypeRaw)/\(i.videoCodec) → \(token)")
            #expect(token == expected)
        }
    }
}
