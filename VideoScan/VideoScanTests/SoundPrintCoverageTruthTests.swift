// SoundPrintCoverageTruthTests.swift
// GH #442 (Rick 2026-11-06 17:12): the Catalog Status band said "9 files
// without a sound print"; clicking it ran Fingerprint Sound, which found
// nothing to do ("0 of 0 · 10,176 already done · 1,136 skipped after 3
// tries") and said "No file needed a sound fingerprint" — and the band kept
// its 9. Two faults, one fact:
//   1. TWO RULES. The band's Sound Prints arm counted ANY stamp as covered
//      and every row with bytes as applicable; the planner skips only a
//      CURRENT stamp (`AudioFingerprintStamp.describes`) and cannot plan a
//      row with no digest. Now both ask `AudioFingerprintBackfillPlanner.need`.
//   2. A STALE BAND. The job's stamps and tries are in-place field writes;
//      nothing told the coverage pass, so the band kept the count from the
//      last unrelated catalog change (the 9 were rows still un-tried at that
//      moment — on the live copy every row is observed by both rules).
//   Plus the words: a run (or the sheet) with nothing to do says why.
//
// Dimensions: LOGIC + TRUTH (the mixed fixture, every row class, band ==
// plan), SENSOR (the real job on a real catalog.sqlite refreshes the band),
// SCALE (100k rows: band and plan agree, in budget). Media matrix: N/A (no
// decode). ISOLATION: sandboxes only; a poisoned row (no digest, stale v1
// stamp beside a full SHA-256) is one of the classes.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// The planner's bucket for one record — asked of the PLANNER itself
/// (`plan(records: [r])`), so the truth test never restates the rule.
@MainActor
private func plannerClass(_ r: VideoRecord) -> String {
    let p = AudioFingerprintBackfillPlanner.plan(records: [r]) { _ in false }
    if p.fileCount == 1 { return "planned" }
    if p.alreadyStamped == 1 { return "stamped" }
    if p.gaveUp == 1 { return "gaveUp" }
    if p.noDigest == 1 { return "noDigest" }
    return "inactive"
}

@MainActor
enum SoundCoverageFixture {
    static let offlineRoot = "/Volumes/GH442-NotMounted"

    /// A 64-hex-digit digest (`c` must be a hex digit, or the row has no full digest).
    static func digest(_ c: Character) -> String { String(repeating: c, count: 64) }

    /// A live row with bytes; `full` = a whole-file SHA-256 covering its size.
    static func row(_ name: String, full: Character? = "a", sampled: Bool = true, root: String? = nil,
                    size: Int64 = 2_000) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = (root ?? "/tmp/gh442") + "/" + name
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioCodec = "aac"
        r.sizeBytes = size
        r.durationSeconds = 3
        if sampled { r.contentHash = "v1:" + name }
        if let full {
            // The memberwise init: no file is read (`captured` stats the path).
            r.contentFixity = ContentFixity(digest: digest(full), byteCount: size,
                                            stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 0))
        }
        return r
    }

    static func stamp(_ key: String, size: Int64 = 2_000, engine: Int = AudioFingerprintStamp.currentEngineVersion)
        -> AudioFingerprintStamp {
        AudioFingerprintStamp(engineVersion: engine, contentDigest: key, sizeBytes: size, outcome: .fingerprinted,
                              analyzedSeconds: 3, complete: true, landmarks: 40, bytes: 400)
    }

    static func attempt(_ c: Character, tries: Int, engine: Int = AudioFingerprintStamp.currentEngineVersion)
        -> AudioFingerprintAttempt {
        AudioFingerprintAttempt(contentDigest: "sha256:" + digest(c), engineVersion: engine, outcome: .heardTooLittle,
                                attempts: tries)
    }

    /// One row per class the band and the planner must agree on.
    static func mixed() -> [(label: String, record: VideoRecord)] {
        let cur = AudioFingerprintStamp.currentEngineVersion
        var out: [(String, VideoRecord)] = []
        let stamped = row("stamped.mov", full: "a"); stamped.audioFingerprint = stamp("sha256:" + digest("a"))
        out.append(("stamped", stamped))
        let staleSize = row("staleSize.mov", full: "b"); staleSize.audioFingerprint = stamp("sha256:" + digest("b"), size: 1_999)
        out.append(("stale stamp: other size", staleSize))
        let staleV1 = row("staleV1.mov", full: "c"); staleV1.audioFingerprint = stamp("v1:staleV1.mov")
        out.append(("stale stamp: sampled key beside a full SHA-256", staleV1))
        let staleEngine = row("staleEngine.mov", full: "d")
        staleEngine.audioFingerprint = stamp("sha256:" + digest("d"), engine: AudioFingerprintStamp.oldestTrustedVersion - 1)
        out.append(("stale stamp: untrusted engine", staleEngine))
        let gaveUp = row("gaveUp.mov", full: "e"); gaveUp.audioFingerprintAttempt = attempt("e", tries: 3)
        out.append(("gave up, this engine", gaveUp))
        let oldTries = row("oldTries.mov", full: "f"); oldTries.audioFingerprintAttempt = attempt("f", tries: 3, engine: cur - 1)
        out.append(("gave up, older engine (retried)", oldTries))
        let trying = row("trying.mov", full: "1"); trying.audioFingerprintAttempt = attempt("1", tries: 2)
        out.append(("2 tries of 3", trying))
        let staleAndGaveUp = row("staleGaveUp.mov", full: "2")
        staleAndGaveUp.audioFingerprint = stamp("v1:staleGaveUp.mov"); staleAndGaveUp.audioFingerprintAttempt = attempt("2", tries: 3)
        out.append(("stale stamp beside a give-up", staleAndGaveUp))
        out.append(("never stamped", row("fresh.mov", full: "3")))
        out.append(("sampled hash only", row("sampledOnly.mov", full: nil)))
        out.append(("no digest at all", row("noDigest.mov", full: nil, sampled: false)))
        out.append(("never stamped, drive offline", row("offline.mov", full: "4", root: offlineRoot)))
        let offlineStamped = row("offlineStamped.mov", full: "5", root: offlineRoot)
        offlineStamped.audioFingerprint = stamp("sha256:" + digest("5"))
        out.append(("stamped, drive offline", offlineStamped))
        return out
    }

    static func report(_ records: [VideoRecord]) -> AnalyzeCoverageReport {
        AnalyzeCoverageCalculator.compute(inputs: AnalyzeCoverageCalculator.project(records), volumes: [],
                                          mountedRoots: [], scope: AnalysisScope())
    }
}

@Suite("Sound prints — the band and Fingerprint Sound judge one fact by one rule (GH #442)", .serialized)
@MainActor
struct SoundPrintCoverageTruthTests {

    // MARK: - TRUTH: every row class

    @Test("RED #442 TRUTH: for every row class the band's covered / uncovered / not-applicable is the planner's stamped+gave-up / planned / no-digest")
    func theBandCountsWhatThePlannerWouldDo() {
        let fixture = SoundCoverageFixture.mixed()
        for (label, r) in fixture {
            let cls = plannerClass(r)
            let report = SoundCoverageFixture.report([r])
            let k = report.counts(.soundPrints)
            let offline = r.fullPath.hasPrefix(SoundCoverageFixture.offlineRoot)
            switch cls {
            case "stamped", "gaveUp":
                #expect(offline ? k.offline == 1 : (k.eligible == 1 && k.covered == 1),
                        "\(label): the planner skips it (\(cls)) — the band must count it covered")
            case "planned":
                #expect(offline ? k.offline == 1 : (k.eligible == 1 && k.remaining == 1),
                        "\(label): the planner would read it — the band must count it left (\(k.line))")
            case "noDigest":
                #expect(k.eligible == 0 && k.remaining == 0 && k.notApplicable == 1,
                        "\(label): the planner cannot key it — the band must not call it left to do (\(k.line))")
            default:
                Issue.record("\(label): unexpected planner class \(cls)")
            }
            #expect(report.soundGaveUp == (cls == "gaveUp" ? 1 : 0),
                    "\(label): the gave-up note counts exactly the planner's give-ups")
        }

        // The whole fixture at once: the band's number IS the job's plan.
        let records = fixture.map(\.record)
        let plan = AudioFingerprintBackfillPlanner.plan(records: records) { _ in false }
        let sound = SoundCoverageFixture.report(records).counts(.soundPrints)
        let items = plan.lanes.flatMap(\.items)
        let reachablePlanned = items.filter { !$0.path.hasPrefix(SoundCoverageFixture.offlineRoot) }.count
        #expect(sound.remaining == reachablePlanned,
                "band says \(sound.remaining) without a sound print; the job would read \(reachablePlanned) on connected drives")
        #expect(plan.fileCount == 8 && reachablePlanned == 7,
                "fixture: 3 stale stamps + older-engine tries + 2 of 3 + never stamped + sampled-only + one offline (got \(plan.fileCount), \(reachablePlanned))")
        #expect(plan.noDigest == 1 && plan.gaveUp == 2 && plan.alreadyStamped == 2,
                "plan: \(plan.fileCount) planned · \(plan.alreadyStamped) stamped · \(plan.gaveUp) gave up · \(plan.noDigest) no digest")
    }

    // MARK: - SENSOR: the real job refreshes the band

    @Test("RED #442 SENSOR: after the real Fingerprint Sound job gives up on a file, the band stops counting it — no unrelated catalog change needed")
    func theJobsWritesRefreshTheBand() async throws {
        let scene = try CutoverScene.make("gh442_refresh"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, digest) = try AttemptScene.soundFile(scene, label: "quiet1")
        r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + digest, outcome: .heardTooLittle, attempts: 2)
        try #require(scene.model.saveCatalogNow())
        scene.model.scheduleAnalyzeCoverageRefresh()
        // Drain every pending debounced pass (the fixture's own appends
        // schedule one 250 ms out) so none can land after the job and hide
        // the bug: wait until the publish count holds still.
        var published = -1
        while published != scene.model.analyzeCoverageSnapshot.publishCount {
            published = scene.model.analyzeCoverageSnapshot.publishCount
            try await Task.sleep(for: .milliseconds(700))
        }
        let before = scene.model.analyzeCoverageSnapshot.report.counts(.soundPrints)
        let plannedBefore = scene.model.audioFingerprintBackfillPlan().fileCount
        try #require(before.remaining >= 1 && plannedBefore >= 1, "fixture: the file is left before the run")

        let job = await AttemptScene.run(scene.model, pass: { _ in
            AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 3,
                             activeSeconds: [true, true, false], hashes: [], times: [], secondsAboveSilenceCeiling: 2)
        })
        #expect(job.totals[.heardTooLittle] == 1, Comment(rawValue: job.totals.line))
        try await Self.settle(scene.model) { $0.soundGaveUp == 1 }
        let report = scene.model.analyzeCoverageSnapshot.report
        #expect(report.soundGaveUp == 1, "the band never heard that the job gave up on the file")
        #expect(report.counts(.soundPrints).remaining == before.remaining - 1,
                "the band still says \(report.counts(.soundPrints).remaining) without a sound print after the job gave up on one of \(before.remaining)")
        #expect(scene.model.audioFingerprintBackfillPlan().fileCount == plannedBefore - 1, "the plan dropped the given-up file")
    }

    /// Wait (≤ 3 s) for the debounced coverage pass to land a report that
    /// satisfies `done`; returns either way (the caller asserts).
    static func settle(_ model: VideoScanModel, until done: (AnalyzeCoverageReport) -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !done(model.analyzeCoverageSnapshot.report), Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(50))
    }

    // MARK: - Words: nothing to do says why

    @Test("RED #442 WORDS: the sheet with nothing to read names the give-ups and that a new engine retries them, never 'every file already has one'")
    func theSheetSaysWhyThereIsNothingToDo() {
        var plan = AudioFingerprintBackfillPlan()
        plan.alreadyFingerprinted = 10_176
        plan.gaveUpHeardTooLittle = 900
        plan.gaveUpFailed = 236
        let line = AudioFingerprintBackfillSheet.headline(plan)
        #expect(!line.contains("Every file already has a sound fingerprint"), Comment(rawValue: line))
        #expect(line.contains("1,136") && line.contains("3 tries") && line.contains("new engine"), Comment(rawValue: line))
        #expect(line.contains("10,176"), Comment(rawValue: line))

        var done = AudioFingerprintBackfillPlan()
        done.alreadyFingerprinted = 12
        #expect(AudioFingerprintBackfillSheet.headline(done).contains("12"), "all stamped: the count of done files")
    }

    @Test("WORDS: the finished job's detail with nothing done says why (already done, gave up, never hashed)")
    func theDetailSaysWhyThereIsNothingToDo() {
        var t = AudioFingerprintBackfillTotals()
        t.alreadyStamped = 10_176
        t.gaveUp = 1_136
        let words = AudioFingerprintBackfillTotals.nothingToDoWords(t)
        #expect(words.contains("10,176 already done") && words.contains("1,136 skipped after 3 tries"), Comment(rawValue: words))
        #expect(!words.contains("No file needed"), Comment(rawValue: words))
        var never = AudioFingerprintBackfillTotals()
        never.noDigest = 4
        #expect(AudioFingerprintBackfillTotals.nothingToDoWords(never).contains("4 never hashed"))
    }

    // MARK: - SCALE

    @Test("SCALE: 100k rows of every class — band and plan agree, both inside the budget (Debug)")
    func scaleAgrees() {
        let classes = SoundCoverageFixture.mixed().map(\.record).filter { !$0.fullPath.hasPrefix(SoundCoverageFixture.offlineRoot) }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let src = classes[i % classes.count]
            let r = VideoRecord()
            r.filename = src.filename
            r.fullPath = "/tmp/gh442/\(i)/" + src.filename
            r.streamTypeRaw = src.streamTypeRaw
            r.audioCodec = src.audioCodec
            r.sizeBytes = src.sizeBytes
            r.contentHash = src.contentHash
            r.contentFixity = src.contentFixity
            r.audioFingerprint = src.audioFingerprint
            r.audioFingerprintAttempt = src.audioFingerprintAttempt
            records.append(r)
        }
        let start = Date()
        let plan = AudioFingerprintBackfillPlanner.plan(records: records) { _ in false }
        let sound = SoundCoverageFixture.report(records).counts(.soundPrints)
        let elapsed = Date().timeIntervalSince(start)
        #expect(sound.remaining == plan.fileCount)
        #expect(sound.covered == plan.alreadyStamped + plan.gaveUp)
        #expect(elapsed < 6, "plan + coverage over 100k rows took \(elapsed) s (budget 6 s, Debug)")
    }
}
