// CatalogStatusFreshnessTests.swift
// Catalog Status, phase 3 (Rick 2026-10-16,
// docs/design/catalog_status_freshness_2026_10_16.md §2–§4): the three
// integrity rows, the freshness rows built from the coverage pass, the
// summary → chip / menu words, the one-button door rule, the update
// queue, and the source sensors that keep every surface on ONE snapshot.
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — full-hash counting excludes a sampled `v1:` hash; sound
//               stamp counting (fingerprinted AND noAudio); presence from
//               a synthetic catalog-audit.json (round-tripped through the
//               real marker), a missing file and a garbage file → never
//               ran, never a crash; summary → chip words; door rule.
//   Scale     — 100k records: coverage + freshness rows + judgement inside
//               the coverage pass's own 1.5 s budget (its harness, reused).
//   Isolation — temp folders per test; a UserDefaults-free path; the
//               sidecar probe never touches App Support.
//   Sensor    — no view body touches `model.records`; the chip, band, menu
//               item and toolbar dot observe only CatalogFreshnessSnapshot;
//               the band's mirror observes the job's own change signal and
//               calls the job's own pause/resume/cancel.
//   Structure — the three integrity rows are first; the Analyze menu's
//               first item is the summary sentence.
// Media matrix: N/A — catalog metadata and two small sidecar files; no
// media file is opened.
//
// Suites (filter by SUITE — method-level -only-testing runs zero tests):
//   CatalogFreshnessRowsTests · CatalogFreshnessFactsTests ·
//   CatalogStatusWordsTests · CatalogFreshnessScaleTests ·
//   CatalogFreshnessSnapshotTests · CatalogStatusUpdateQueueTests ·
//   CatalogStatusSensorTests · CatalogStatusStructureTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let now = Date(timeIntervalSince1970: 1_760_600_000)   // 2026-10-16 ~06:13 UTC
private let wording = FreshnessWording(calendar: Calendar(identifier: .gregorian), groupingSeparator: ",")

private let laCie = AnalyzeVolumeFact(root: "/Volumes/LaCie", isReachable: true, isRetired: false)
private let x9 = AnalyzeVolumeFact(root: "/Volumes/X9", isReachable: false, isRetired: false)

private func compute(_ inputs: [AnalyzeCoverageInput]) -> AnalyzeCoverageReport {
    AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [laCie, x9], mountedRoots: ["/", "/Volumes/LaCie"],
                                      scope: AnalysisScope(), now: now)
}

private func auditRecord(outcome: CatalogAuditRunRecord.Outcome = .completed, partial: Bool = false,
                         counts: [String: Int], finished: Bool = true) -> CatalogAuditRunRecord {
    var r = CatalogAuditRunRecord(startedAt: now.addingTimeInterval(-3_600))
    r.finishedAt = finished ? now.addingTimeInterval(-1_800) : nil
    r.outcome = outcome
    r.partial = partial
    r.counts = counts
    return r
}

private func rows(_ report: AnalyzeCoverageReport, facts: CatalogFreshnessFacts = .init(),
                  running: Set<AnalyzeCycler> = []) -> [FreshnessRow] {
    CatalogFreshnessRows.rows(report: report, facts: facts, running: running)
}

private func row(_ cycler: AnalyzeCycler, in rows: [FreshnessRow]) -> FreshnessRow {
    rows.first { $0.kind == cycler.rawValue } ?? FreshnessRow(kind: "?", title: "?")
}

// MARK: - Rows

@Suite("Catalog Status — freshness rows from the coverage pass")
struct CatalogFreshnessRowsTests {

    /// A whole-file SHA-256 covering exactly the record's size counts; a
    /// sampled `v1:` scan hash, or a fixity whose byte count differs, does not.
    @Test @MainActor func fullHashCountingExcludesTheSampledHash() {
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3)
        let full = VideoRecord()
        full.fullPath = "/Volumes/LaCie/full.mov"; full.sizeBytes = 100
        full.contentFixity = ContentFixity(digest: "abc", byteCount: 100, stamp: stamp, computedAt: now)
        let sampled = VideoRecord()
        sampled.fullPath = "/Volumes/LaCie/sampled.flv"; sampled.sizeBytes = 100
        sampled.contentHash = "v1:deadbeef"
        let shortRead = VideoRecord()
        shortRead.fullPath = "/Volumes/LaCie/short.mov"; shortRead.sizeBytes = 100
        shortRead.contentFixity = ContentFixity(digest: "abc", byteCount: 50, stamp: stamp, computedAt: now)

        let inputs = [full, sampled, shortRead].map { AnalyzeCoverageInput(record: $0) }
        #expect(inputs[0].hasFullDigest && inputs[0].fullDigestAt == now)
        #expect(!inputs[1].hasFullDigest && inputs[1].fullDigestAt == nil)
        #expect(!inputs[2].hasFullDigest && inputs[2].fullDigestAt == nil, "a short read is not a full hash")

        let r = compute(inputs)
        let k = r.counts(.fullHashes)
        #expect(k.eligible == 3 && k.covered == 1 && k.newestStamp == now)
        let hashes = row(.fullHashes, in: rows(r))
        #expect(hashes.uncovered == 2)
        #expect(FreshnessPolicy.judge(hashes, now: now, wording: wording).words == "2 files without a full hash")
    }

    /// Both stamp outcomes count — "no sound" is a complete answer.
    @Test @MainActor func soundStampCountingTakesFingerprintedAndNoAudio() {
        func record(_ name: String, _ outcome: AudioFingerprintStamp.Outcome?) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = "/Volumes/LaCie/\(name)"; r.sizeBytes = 10
            if let outcome {
                r.audioFingerprint = AudioFingerprintStamp(computedAt: now, contentDigest: "sha256:x", sizeBytes: 10,
                                                           outcome: outcome, analyzedSeconds: 1, complete: true,
                                                           landmarks: 1, bytes: 1)
            }
            return r
        }
        let inputs = [record("a.mov", .fingerprinted), record("b.mov", .noAudio), record("c.mov", nil),
                      record("zero.mov", nil)].map { AnalyzeCoverageInput(record: $0) }
        var zero = inputs[3]; zero.sizeBytes = 0
        let r = compute(Array(inputs.prefix(3)) + [zero])
        let k = r.counts(.soundPrints)
        #expect(k.eligible == 3 && k.covered == 2 && k.notApplicable == 1)
        #expect(row(.soundPrints, in: rows(r)).uncovered == 1)
    }

    @Test func presenceRowReadsTheAuditMarker() {
        let r = compute([
            .init(fullPath: "/Volumes/LaCie/a.mov"), .init(fullPath: "/Volumes/LaCie/b.mov"),
            .init(fullPath: "/Volumes/LaCie/c.mov"), .init(fullPath: "/Volumes/X9/off.mov"),
        ])
        // No marker: never ran, 3 waiting.
        let never = row(.filePresence, in: rows(r))
        #expect(never.eligible == 3 && never.offline == 1 && never.covered == 0 && never.lastOutcome == .neverRan)
        #expect(never.cadence == .seconds(86_400))
        // The policy's precedence: coverage first (the count is the useful
        // number), so "never ran" with eligible rows reads as the rows.
        #expect(FreshnessPolicy.judge(never, now: now, wording: wording).words == "3 files not yet checked")
        #expect(FreshnessPolicy.judge(never, now: now, wording: wording).colour == .yellow)

        // A completed run that checked everything: green, checked 30 min ago.
        let clean = auditRecord(counts: ["present": 3, "notAsked": 1, "planned": 4])
        let green = row(.filePresence, in: rows(r, facts: .init(audit: clean)))
        #expect(green.covered == 3 && green.needsDecision == 0 && green.lastOutcome == .ok)
        #expect(FreshnessPolicy.judge(green, now: now, wording: wording).colour == .green)

        // gone + changed → a decision (red), even though everything was checked.
        let found = auditRecord(counts: ["present": 1, "gone": 1, "changed": 1, "planned": 3])
        let red = row(.filePresence, in: rows(r, facts: .init(audit: found)))
        #expect(red.needsDecision == 2)
        let verdict = FreshnessPolicy.judge(red, now: now, wording: wording)
        #expect(verdict.colour == .red)
        #expect(verdict.words == "2 files pointing at nothing or changed on disk — look at Fix Links")

        // Checked fewer than are eligible now (a scan added files): yellow.
        let stale = auditRecord(counts: ["present": 2, "planned": 2])
        let yellow = row(.filePresence, in: rows(r, facts: .init(audit: stale)))
        #expect(yellow.covered == 2 && yellow.uncovered == 1)
        #expect(FreshnessPolicy.judge(yellow, now: now, wording: wording).words == "1 file not yet checked")
    }

    @Test func soundStoreProblemAndRunningLandOnTheRows() {
        let r = compute([.init(fullPath: "/Volumes/LaCie/a.mov", hasSoundStamp: true)])
        let facts = CatalogFreshnessFacts(soundStoreProblem: "the fingerprint file is not a database (damaged or replaced): /x")
        let built = rows(r, facts: facts, running: [.fullHashes])
        let sound = row(.soundPrints, in: built)
        #expect(sound.storeUnavailable == facts.soundStoreProblem)
        #expect(FreshnessPolicy.judge(sound, now: now, wording: wording).colour == .red)
        #expect(row(.fullHashes, in: built).isRunning)
        #expect(!row(.soundPrints, in: built).isRunning)
    }

    @Test func rowsFollowTheRegistryIntegrityFirst() {
        let built = rows(compute([]))
        #expect(built.map(\.kind) == AnalyzeCycler.allCases.map(\.rawValue))
        #expect(Array(built.prefix(3)).map(\.kind) == ["filePresence", "fullHashes", "soundPrints"])
        #expect(row(.filePresence, in: built).cadence == .seconds(86_400), "presence runs nightly: one day")
        #expect(row(.fullHashes, in: built).cadence == nil && row(.soundPrints, in: built).cadence == nil,
                "hashes and sound prints have no clock — stale only by coverage")
        // The metadata cyclers keep their "current" notion: no clock.
        for c in AnalyzeCycler.allCases where !c.isIntegrity {
            #expect(row(c, in: built).cadence == nil, "\(c) has no cadence")
        }
    }

    @Test func stateJudgesEveryRowAndSummarizes() {
        let r = compute([.init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10)])
        let state = CatalogFreshnessState.judged(rows: rows(r), now: now, wording: wording)
        #expect(state.isComputed)
        #expect(state.verdicts.count == AnalyzeCycler.allCases.count)
        #expect(state.summary.colour == .yellow)
        #expect(state.staleCyclers.first == .filePresence, "integrity rows lead the stale list")
        #expect(state.isRunning(.fullHashes) == false)
    }
}

// MARK: - Facts (the two small files)

@Suite("Catalog Status — audit marker and sidecar facts")
struct CatalogFreshnessFactsTests {

    private func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-status-facts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test @MainActor func markerFileNameMatchesTheReader() {
        #expect(CatalogFreshnessFactsReader.auditMarkerFileName == CatalogAuditRunMarker.fileName)
        #expect(CatalogFreshnessFactsReader.cutoverLatchFileName == CatalogAuthority.latchFileName)
    }

    /// RED 2026-10-18, Rick's first afternoon on catalog.sqlite: the
    /// import's Audit ran on catalog.json at 15:38:49, the switch landed at
    /// 15:39:47, and the File Presence row read that run's 144 never-seen +
    /// 1 changed rows — all quarantined, none a record — as 145 red "Fix
    /// Links" decisions for hours. A marker from before the switch is not
    /// this catalog's audit: yellow, "not checked since the switch", Run now.
    @Test func anAuditFromBeforeTheSwitchIsNotThisCatalogs() throws {
        let dir = try scratch()
        let catalog = dir.appendingPathComponent("catalog.json").path
        let switched = now.addingTimeInterval(-600)
        try CatalogSwitch.latchData(CatalogRow.FinishedImport(runID: "R", finishedAt: 0, sourceSHA256: "ab", sourceGeneration: 4_900),
                                    at: switched)
            .write(to: dir.appendingPathComponent(CatalogFreshnessFactsReader.cutoverLatchFileName))
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog).switchedAt == switched)

        var before = auditRecord(counts: ["present": 10_831, "neverSeenByAnAudit": 144, "changed": 1, "planned": 11_194])
        before.startedAt = switched.addingTimeInterval(-58)
        before.finishedAt = switched.addingTimeInterval(-54)
        let presence = CatalogAuditPresenceFacts.from(before, switchedAt: switched)
        #expect(presence.predatesSwitch)
        #expect(presence.needsDecision == 0 && presence.checked == 0 && presence.outcome == .neverRan && presence.lastCompleted == nil)
        #expect(CatalogAuditPresenceFacts.from(before).needsDecision == 145, "no latch: judged as before")

        let report = compute([.init(fullPath: "/Volumes/LaCie/a.mov"), .init(fullPath: "/Volumes/LaCie/b.mov"),
                              .init(fullPath: "/Volumes/LaCie/c.mov")])
        let stale = row(.filePresence, in: rows(report, facts: .init(audit: before, switchedAt: switched)))
        let verdict = FreshnessPolicy.judge(stale, now: now, wording: wording)
        #expect(verdict.colour == .yellow, Comment(rawValue: verdict.words))
        #expect(verdict.words == "3 files not checked since the switch to SQLite")
        #expect(CatalogStatusDoor.door(for: verdict.reason, cycler: .filePresence) == .runNow, "Run now, not the unbuilt Fix Links")

        // The first audit after the switch is this catalog's: its finds are red again.
        var after = auditRecord(counts: ["present": 2, "gone": 1, "planned": 3])
        after.startedAt = switched.addingTimeInterval(60)
        after.finishedAt = switched.addingTimeInterval(64)
        let red = row(.filePresence, in: rows(report, facts: .init(audit: after, switchedAt: switched)))
        #expect(FreshnessPolicy.judge(red, now: now, wording: wording).colour == .red)
        #expect(red.needsDecision == 1)
    }

    /// Round trip through the REAL marker (its encoder), then the reader.
    @Test @MainActor func aRealMarkerRoundTrips() throws {
        let dir = try scratch()
        let marker = CatalogAuditRunMarker()
        marker.attach(catalogFile: dir.appendingPathComponent("catalog.json").path)
        marker.noteStarted(at: now.addingTimeInterval(-60))
        var totals = CatalogAuditTotals()
        totals.planned = 5
        totals.add(.present, rows: 3)
        totals.add(.gone, rows: 1)
        totals.add(.notAsked, rows: 1)
        marker.noteFinished(.completed, totals: totals, marked: 1, partial: false, catalogGeneration: nil, at: now)

        let facts = CatalogFreshnessFactsReader.read(catalogFile: dir.appendingPathComponent("catalog.json").path)
        let audit = try #require(facts.audit)
        #expect(audit.outcome == .completed && audit.finishedAt == now)
        let presence = CatalogAuditPresenceFacts.from(audit)
        #expect(presence.checked == 4, "everything but not-asked")
        #expect(presence.needsDecision == 1 && presence.outcome == .ok && presence.lastCompleted == now)
        #expect(facts.soundStoreProblem == nil, "no sidecar yet is not a fault")
    }

    @Test func missingAndGarbageMarkersReadAsNeverRan() throws {
        let dir = try scratch()
        let catalog = dir.appendingPathComponent("catalog.json").path
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog).audit == nil)
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent(CatalogFreshnessFactsReader.auditMarkerFileName))
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog).audit == nil)
        try Data("{\"startedAt\": 12, \"outcome\": \"martian\"}".utf8)
            .write(to: dir.appendingPathComponent(CatalogFreshnessFactsReader.auditMarkerFileName))
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog).audit == nil)
        #expect(CatalogAuditPresenceFacts.from(nil).outcome == .neverRan)
    }

    @Test func outcomeMapping() {
        func facts(_ o: CatalogAuditRunRecord.Outcome, partial: Bool = false, finished: Bool = true) -> FreshnessRow.Outcome {
            CatalogAuditPresenceFacts.from(auditRecord(outcome: o, partial: partial, counts: [:], finished: finished)).outcome
        }
        #expect(facts(.completed) == .ok)
        #expect(facts(.completed, partial: true) == .partial)
        #expect(facts(.stopped, partial: true) == .partial)
        #expect(facts(.failed) == .failed)
        #expect(facts(.running, finished: false) == .failed, "a run that never ended was killed — red")
        #expect(facts(.refused) == .neverRan)
    }

    @Test func aPoisonedSidecarIsAProblemAndAnAbsentOneIsNot() throws {
        let dir = try scratch()
        #expect(CatalogFreshnessFactsReader.soundStoreProblem(in: dir) == nil)
        try Data("this is not sqlite".utf8).write(to: dir.appendingPathComponent(AudioFingerprintStore.fileName))
        let problem = try #require(CatalogFreshnessFactsReader.soundStoreProblem(in: dir))
        #expect(problem.contains("not a database"))
    }

    /// Codex cycle #80, P2: a run that stopped part way is yellow "run it
    /// again"; the gone/changed it counted so far never become a red
    /// decision — only a COMPLETED, non-partial run may claim one.
    @Test func aPartialRunContributesNoDecision() {
        let partial = auditRecord(outcome: .completed, partial: true, counts: ["present": 1, "gone": 3, "planned": 4])
        let facts = CatalogAuditPresenceFacts.from(partial)
        #expect(facts.outcome == .partial)
        #expect(facts.needsDecision == 0, "a partial run claims no decision (got \(facts.needsDecision))")
        #expect(facts.checked == 4, "what it did check still counts")
        let stopped = auditRecord(outcome: .stopped, partial: true, counts: ["gone": 2, "planned": 4])
        #expect(CatalogAuditPresenceFacts.from(stopped).needsDecision == 0)
        let whole = auditRecord(outcome: .completed, partial: false, counts: ["present": 1, "gone": 3, "planned": 4])
        #expect(CatalogAuditPresenceFacts.from(whole).needsDecision == 3, "a whole run keeps its decision")

        let report = compute([.init(fullPath: "/Volumes/LaCie/a.mov")])
        let presence = row(.filePresence, in: rows(report, facts: .init(audit: partial)))
        let verdict = FreshnessPolicy.judge(presence, now: now, wording: wording)
        #expect(verdict.colour == .yellow)
        #expect(verdict.words == "the last run stopped part way — run it again")
        #expect(CatalogStatusDoor.door(for: verdict.reason, cycler: .filePresence) == .runNow)
    }

    /// Codex cycle #80, P2: the red "store unavailable" fires only when the
    /// sidecar FILE exists and cannot be opened. Before the first run there
    /// is no file, so a read-only catalog folder is not a fault here (the
    /// backfill job refuses the folder itself when it runs).
    @Test func anAbsentSidecarInAReadOnlyFolderIsNotAProblem() throws {
        let dir = try scratch()
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path) }
        try #require(!fm.isWritableFile(atPath: dir.path), "the scratch folder could not be made read-only here")
        #expect(CatalogFreshnessFactsReader.soundStoreProblem(in: dir) == nil,
                "an absent sidecar reads as never ran, not red (got \(CatalogFreshnessFactsReader.soundStoreProblem(in: dir) ?? "nil"))")
        let catalog = dir.appendingPathComponent("catalog.json").path
        #expect(CatalogFreshnessFactsReader.read(catalogFile: catalog).soundStoreProblem == nil)
        // Present but unopenable stays red, writable folder or not.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        try Data("this is not sqlite".utf8).write(to: dir.appendingPathComponent(AudioFingerprintStore.fileName))
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        #expect(CatalogFreshnessFactsReader.soundStoreProblem(in: dir) != nil, "garbage in a read-only folder is still red")
    }
}

// MARK: - Words: chip, menu, door, launch line

@Suite("Catalog Status — chip, menu and door words")
struct CatalogStatusWordsTests {

    // Rick 2026-10-20: the band's colour answers "does the catalog reflect
    // reality?" (CatalogRealityPolicy) — no longer the worst row. The rows
    // still carry their own verdicts and the stale list.
    private func state(_ rows: [FreshnessRow], reality: CatalogRealityFacts = CatalogRealityFacts()) -> CatalogFreshnessState {
        CatalogFreshnessState.judged(rows: rows, reality: CatalogRealityInputs(facts: reality), now: now, wording: wording)
    }

    private var validatedAnHourAgo: CatalogRealityFacts {
        CatalogRealityFacts(validation: .completed(at: now.addingTimeInterval(-3_600)), rowsToCheck: 3)
    }

    @Test func greenChipSaysReflectsReality() {
        let s = state([
            FreshnessRow(kind: "filePresence", title: "File Presence", eligible: 3, covered: 3,
                         lastCompleted: now.addingTimeInterval(-1_800), lastOutcome: .ok, cadence: .seconds(86_400)),
            FreshnessRow(kind: "fullHashes", title: "Full Hashes", eligible: 3, covered: 3, lastOutcome: .ok),
        ], reality: validatedAnHourAgo)
        #expect(s.summary.colour == .green)
        #expect(CatalogStatusWords.chipWords(s) == "reflects reality")
        #expect(CatalogStatusWords.menuTitle(s.summary.colour) == "Catalog Status…")
    }

    @Test func yellowAndRedChipsAreShort() {
        var unsettled = validatedAnHourAgo
        unsettled.unsettled = [CatalogRealityCount(count: 660, words: "tier 1 File identity: 660 files still have only a sampled hash — Fill In Full Hashes")]
        let yellow = state([
            FreshnessRow(kind: "fullHashes", title: "Full Hashes", eligible: 700, covered: 40, lastOutcome: .ok,
                         phrases: CatalogFreshnessRows.phrases(.fullHashes)),
            FreshnessRow(kind: "soundPrints", title: "Sound Prints", eligible: 20, covered: 8, lastOutcome: .ok,
                         phrases: CatalogFreshnessRows.phrases(.soundPrints)),
        ], reality: unsettled)
        #expect(CatalogStatusWords.chipWords(yellow) == "can't fully vouch")
        #expect(yellow.summary.headline == "The catalog can't fully vouch for itself: tier 1 File identity: 660 files still have only a sampled hash — Fill In Full Hashes")
        #expect(CatalogStatusWords.menuTitle(yellow.summary.colour) == "Catalog Status — can't fully vouch…")
        #expect(yellow.summary.items.map(\.words) == ["660 files without a full hash", "12 files without a sound print"],
                "the stale rows are still listed under the band")

        var broken = validatedAnHourAgo
        broken.breaks = [CatalogRealityCount(count: 2, words: "2 paths have more than one live row"),
                         CatalogRealityCount(count: 1, words: "1 duplicate groups hold files with different whole-file digests")]
        let red = state([], reality: broken)
        #expect(CatalogStatusWords.chipWords(red) == "something is wrong")
        #expect(CatalogStatusWords.menuTitle(.red) == "Catalog Status — something is wrong…")
        #expect(CatalogStatusWords.launchLine(red.reality)
                == "Something is wrong: 2 paths have more than one live row · 1 more — 1 duplicate groups hold files with different whole-file digests. Catalog ▸ Catalog Status… lists the doors.")
    }

    @Test func uncomputedStaysQuietAndNothingKnownCannotVouch() {
        #expect(CatalogStatusWords.chipWords(CatalogFreshnessState()) == "checking…")
        // Every drive offline and no Validate on record: the catalog can't vouch (yellow), not "nothing to check".
        let offline = state([FreshnessRow(kind: "fullHashes", title: "Full Hashes", offline: 5)])
        #expect(offline.summary.colour == .yellow)
        #expect(CatalogStatusWords.chipWords(offline) == "can't fully vouch")
    }

    /// ONE button per item (§2.1), from the reason.
    @Test func doorRule() {
        typealias D = CatalogStatusDoor
        #expect(D.door(for: .uncovered(3), cycler: .fullHashes) == .runNow)
        #expect(D.door(for: .neverRan(waiting: 1), cycler: .filePresence) == .runNow)
        #expect(D.door(for: .overdue(lastCompleted: nil), cycler: .filePresence) == .runNow)
        #expect(D.door(for: .lastRunPartial, cycler: .soundPrints) == .runNow)
        #expect(D.door(for: .lastRunFailed, cycler: .filePresence) == .runAgain)
        #expect(D.door(for: .storeUnavailable("x"), cycler: .soundPrints) == .fingerprintAgain)
        #expect(D.door(for: .needsDecision(3), cycler: .filePresence) == .fixLinks)
        #expect(!D.fixLinks.isEnabled, "Fix Links is not built: shown disabled")
        #expect(D.fixLinksHelp.contains("coming next"))
        #expect(D.door(for: .notMounted(2), cycler: .fullHashes) == .none)
        #expect(D.door(for: .current(checked: nil), cycler: .fullHashes) == .none)
        #expect(D.runNow.title == "Run now" && D.runAgain.title == "Run again" && D.fingerprintAgain.title == "Fingerprint again")
    }
}

// MARK: - Scale

@Suite("Catalog Status — scale")
struct CatalogFreshnessScaleTests {

    /// The coverage harness's 100k rows, plus the freshness rows and their
    /// judgement, inside the coverage pass's own budget.
    @Test func hundredThousandRowsStayInsideTheCoverageBudget() {
        var volumes: [AnalyzeVolumeFact] = []
        for i in 0..<10 {
            volumes.append(.init(root: "/Volumes/Vol\(i)", isReachable: i % 5 != 0, isRetired: false))
        }
        var inputs: [AnalyzeCoverageInput] = []
        inputs.reserveCapacity(100_000)
        let streams = [StreamType.videoAndAudio, .videoOnly, .audioOnly, .videoAndAudio, .ffprobeFailed]
        for i in 0..<100_000 {
            let stamp = i % 3 == 0 ? Date(timeIntervalSince1970: Double(i)) : nil
            inputs.append(.init(fullPath: "/Volumes/Vol\(i % 10)/folder\(i % 40)/clip\(i).mov",
                                streamTypeRaw: streams[i % streams.count].rawValue,
                                sizeBytes: Int64(i % 7),
                                isHidden: i % 97 == 0,
                                dupStamped: i % 2 == 0,
                                footageScannedAt: stamp,
                                hasHash: i % 3 == 0,
                                hasFullDigest: i % 4 == 0, fullDigestAt: i % 4 == 0 ? stamp : nil,
                                hasSoundStamp: i % 5 == 0, soundStampAt: i % 5 == 0 ? stamp : nil))
        }
        let audit = auditRecord(counts: ["present": 60_000, "notAsked": 20_000, "planned": 80_000])
        let start = ContinuousClock.now
        let report = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: volumes,
                                                       mountedRoots: ["/"], scope: AnalysisScope(), now: now)
        let rows = CatalogFreshnessRows.rows(report: report, facts: .init(audit: audit), running: [.fullHashes])
        let state = CatalogFreshnessState.judged(rows: rows, now: now, wording: wording)
        let elapsed = ContinuousClock.now - start
        #expect(report.activeRecords == 100_000)
        #expect(rows.count == AnalyzeCycler.allCases.count)
        #expect(state.summary.colour == .yellow)
        #expect(state.verdict(.fullHashes)?.words == "running")
        #expect(elapsed < PerformanceLane.debugCeiling(.milliseconds(1_500)),
                "coverage + freshness took \(elapsed) for 100k records — over the 1.5 s budget")
    }
}

// MARK: - The snapshot (equality-gated; re-reads facts when a job stops)

@Suite("Catalog Status — the one snapshot", .serialized)
@MainActor
struct CatalogFreshnessSnapshotTests {

    @Test func publishIsEqualityGatedAndRunningRejudges() {
        let snapshot = CatalogFreshnessSnapshot()
        #expect(!snapshot.state.isComputed, "quiet until the first pass")
        let report = compute([.init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10)])
        snapshot.publish(report: report, facts: .init())
        #expect(snapshot.state.isComputed && snapshot.publishCount == 1)
        snapshot.publish(report: report, facts: .init())
        #expect(snapshot.publishCount == 1, "an unchanged pass publishes nothing")
        snapshot.setRunning([.fullHashes])
        #expect(snapshot.publishCount == 2 && snapshot.state.isRunning(.fullHashes))
        #expect(snapshot.state.verdict(.fullHashes)?.words == "running")
        #expect(!snapshot.state.staleCyclers.contains(.fullHashes), "a running kind is not queued")
        snapshot.setRunning([.fullHashes])
        #expect(snapshot.publishCount == 2, "the same set is a no-op")
    }

    @Test func aKindThatStopsRereadsTheMarker() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("catalog-status-snapshot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let catalogFile = dir.appendingPathComponent("catalog.json").path
        let snapshot = CatalogFreshnessSnapshot()
        let report = compute([.init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10)])
        snapshot.publish(report: report, facts: CatalogFreshnessFactsReader.read(catalogFile: catalogFile),
                         catalogFile: catalogFile)
        #expect(snapshot.state.row(.filePresence)?.lastOutcome == .neverRan)
        snapshot.setRunning([.filePresence])
        // The audit "finishes": it writes its marker and leaves the center.
        let marker = CatalogAuditRunMarker()
        marker.attach(catalogFile: catalogFile)
        marker.noteStarted(at: now.addingTimeInterval(-60))
        var totals = CatalogAuditTotals()
        totals.planned = 1
        totals.add(.present)
        marker.noteFinished(.completed, totals: totals, marked: 0, partial: false, catalogGeneration: nil, at: now)
        snapshot.setRunning([])
        for _ in 0..<50 where snapshot.state.row(.filePresence)?.lastOutcome != .ok {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let presence = try #require(snapshot.state.row(.filePresence))
        #expect(presence.lastOutcome == .ok && presence.lastCompleted == now && presence.covered == 1,
                "the marker was re-read without a catalog mutation")
    }

    @Test func modelOwnsOneSnapshotAndItsPassFeedsIt() async throws {
        let model = VideoScanModel()
        let r = VideoRecord()
        r.fullPath = "/Volumes/T/a.mov"; r.filename = "a.mov"; r.sizeBytes = 10
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        model.records = [r]
        for _ in 0..<40 where !model.catalogFreshness.state.isComputed || model.analyzeCoverageSnapshot.report.activeRecords == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(model.catalogFreshness.state.isComputed)
        #expect(model.catalogFreshness.state.rows.count == AnalyzeCycler.allCases.count)
    }

    /// Codex cycle #80, P2: a running METADATA engine (here Duplicates —
    /// the model's own flag, the one AnalyzeRunner.isRunning reads) lands
    /// in the SAME snapshot as the MFO jobs: "running" on its row and out
    /// of "Update everything stale". The path is not under /Volumes so the
    /// record is reachable without a mount.
    @Test func aRunningMetadataEngineIsNotStale() async throws {
        let model = VideoScanModel()
        let r = VideoRecord()
        r.fullPath = "/Users/Shared/catalog-status-test/a.mov"; r.filename = "a.mov"; r.sizeBytes = 10
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        model.records = [r]
        let snapshot = model.catalogFreshness
        for _ in 0..<40 where !snapshot.state.isComputed || model.analyzeCoverageSnapshot.report.activeRecords == 0 {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(snapshot.state.staleCyclers.contains(.duplicates), "one unstamped file: Duplicates is stale")

        model.isAnalyzingDuplicates = true
        for _ in 0..<20 where !snapshot.state.isRunning(.duplicates) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(snapshot.state.isRunning(.duplicates), "the model's own engine flag feeds its snapshot")
        #expect(snapshot.state.verdict(.duplicates)?.words == "running")
        #expect(!snapshot.state.staleCyclers.contains(.duplicates), "a running kind is not queued")

        model.isAnalyzingDuplicates = false
        for _ in 0..<20 where snapshot.state.isRunning(.duplicates) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(!snapshot.state.isRunning(.duplicates))
        #expect(snapshot.state.staleCyclers.contains(.duplicates), "stale again once the pass ends")
    }

    /// Codex cycle #80, P2, the OCR case named in the finding: the dossier
    /// engine's snapshot (Captions / OCR / Transcribe share it) feeds the
    /// same freshness snapshot — a running OCR pass reads "running" and is
    /// not queued by "Update everything stale".
    @Test func aRunningDossierStageIsNotStale() async throws {
        let snapshot = CatalogFreshnessSnapshot()
        let dossier = DossierDashboardSnapshot()
        snapshot.observeDossier(dossier)
        snapshot.publish(report: compute([.init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10)]), facts: .init())
        #expect(snapshot.state.staleCyclers.contains(.ocr) && snapshot.state.staleCyclers.contains(.transcribe))

        var active = DossierDashboardState()
        active.statusIsActive = true
        dossier.publish(active)
        for _ in 0..<20 where !snapshot.state.isRunning(.ocr) { try await Task.sleep(nanoseconds: 50_000_000) }
        for stage in [AnalyzeCycler.sceneCaptions, .ocr, .transcribe] {
            #expect(snapshot.state.isRunning(stage), "\(stage) shares the dossier engine")
            #expect(snapshot.state.verdict(stage)?.words == "running")
            #expect(!snapshot.state.staleCyclers.contains(stage), "\(stage) is running, not stale")
        }
        #expect(!snapshot.state.isRunning(.duplicates), "only the dossier stages")

        dossier.publish(DossierDashboardState())
        for _ in 0..<20 where snapshot.state.isRunning(.ocr) { try await Task.sleep(nanoseconds: 50_000_000) }
        #expect(snapshot.state.staleCyclers.contains(.ocr), "stale again once the batch ends")
    }

    /// Codex cycle #80, P2: the coverage snapshot the Analyze menu and the
    /// panel ALSO observe must not republish identical counts because the
    /// clock moved — `computedAt` is a caption, not a change.
    @Test func identicalCoverageAtALaterTimePublishesOnce() {
        let inputs = [AnalyzeCoverageInput(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10)]
        func report(_ inputs: [AnalyzeCoverageInput], at: Date) -> AnalyzeCoverageReport {
            AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [laCie, x9], mountedRoots: ["/", "/Volumes/LaCie"],
                                              scope: AnalysisScope(), now: at)
        }
        let first = report(inputs, at: now)
        let again = report(inputs, at: now.addingTimeInterval(60))
        #expect(first == again, "equality ignores computedAt")
        let snapshot = AnalyzeCoverageSnapshot()
        snapshot.publish(first)
        snapshot.publish(again)
        #expect(snapshot.publishCount == 1, "identical coverage at a later time publishes once (got \(snapshot.publishCount))")
        #expect(snapshot.report.computedAt == now, "the caption keeps the time of the last real change")
        let changed = report(inputs + [.init(fullPath: "/Volumes/LaCie/b.mov", sizeBytes: 10)], at: now.addingTimeInterval(120))
        snapshot.publish(changed)
        #expect(snapshot.publishCount == 2 && snapshot.report.computedAt == now.addingTimeInterval(120),
                "a real change still publishes, and brings its time")
    }
}

// MARK: - The update queue

@Suite("Catalog Status — update everything stale", .serialized)
@MainActor
struct CatalogStatusUpdateQueueTests {

    @Test func startsOneKindAtATimeInTheOrderGiven() {
        let model = VideoScanModel()
        let runner = AnalyzeRunner(model: model, orchestrator: nil, center: nil)
        let queue = CatalogStatusUpdateQueue()
        queue.graceSeconds = 2
        // Date Inference is synchronous on the main actor (never "running"
        // between frames); the integrity kinds refuse without a center.
        queue.enqueue([.dateInference, .fullHashes, .dateInference], runner: runner, source: "test")
        #expect(queue.pending == [.dateInference, .fullHashes], "duplicates dropped, order kept")
        queue.advanceIfIdle(now: now)
        #expect(queue.current == .dateInference && queue.pending == [.fullHashes])
        queue.advanceIfIdle(now: now.addingTimeInterval(1))
        #expect(queue.current == .dateInference, "inside the grace window nothing moves")
        queue.advanceIfIdle(now: now.addingTimeInterval(3))
        #expect(queue.current == .fullHashes && queue.pending.isEmpty)
        queue.advanceIfIdle(now: now.addingTimeInterval(6))
        #expect(queue.current == nil && !queue.isActive)
    }

    @Test func clearPendingKeepsTheKindInFlight() {
        let model = VideoScanModel()
        let runner = AnalyzeRunner(model: model, orchestrator: nil, center: nil)
        let queue = CatalogStatusUpdateQueue()
        queue.enqueue([.dateInference, .fullHashes], runner: runner, source: "test")
        queue.advanceIfIdle(now: now)
        queue.clearPending()
        #expect(queue.current == .dateInference && queue.pending.isEmpty)
    }

    @Test func runnerKnowsWhichKindsAreRunning() {
        let model = VideoScanModel()
        let center = MediaFileOperationsCenter()
        let runner = AnalyzeRunner(model: model, orchestrator: nil, center: center)
        for c in AnalyzeCycler.allCases { #expect(!runner.isRunning(c), "\(c) idle on an empty model") }
        #expect(runner.activeIntegrityJob(for: .filePresence) == nil)
        #expect(CatalogFreshnessSnapshot.integrityRunning(in: center).isEmpty)
    }
}

// MARK: - Source sensors

@Suite("Catalog Status — source sensors")
struct CatalogStatusSensorTests {

    private func source(_ file: String) throws -> String { try SourceTree.appSource(named: file) }

    private func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records",
                                "for rec in records", "records.reduce", "records.first", "records.count"]

    @Test func noStatusSurfaceWalksRecords() throws {
        for file in ["CatalogStatusChip.swift", "CatalogStatusBand.swift", "CatalogAnalyzeMenu.swift",
                     "CatalogStatusMenuItem.swift", "AnalyzePanelView.swift", "DossierToolbarChip.swift",
                     "CatalogFreshnessSnapshot.swift", "CatalogStatusUpdateQueue.swift"] {
            let src = code(try source(file))
            for walk in recordsWalks {
                #expect(!src.contains(walk), "\(file) walks records: `\(walk)`")
            }
        }
    }

    /// The chip, the menu item and the toolbar dot observe ONLY the snapshot.
    @Test func chipMenuItemAndDotObserveOnlyTheSnapshot() throws {
        let chip = code(try source("CatalogStatusChip.swift"))
        #expect(chip.contains("@ObservedObject var freshness: CatalogFreshnessSnapshot"))
        #expect(!chip.contains("@EnvironmentObject") && !chip.contains("VideoScanModel"), "the chip never sees the model")
        #expect(chip.contains("CatalogStatusWords.chipWords(freshness.state)"))
        #expect(chip.contains("AnalyzeWindowOpener.open(using: openWindow, source: \"status-chip\")"))
        #expect(chip.contains("Text(CatalogStatusWords.chipPrefix)"))
        #expect(chip.contains("size: 15, weight: .medium, design: .monospaced"), "the totals strip's 15pt mono register")

        let item = code(try source("CatalogStatusMenuItem.swift"))
        #expect(item.contains("@ObservedObject var freshness: CatalogFreshnessSnapshot"))
        #expect(!item.contains("VideoScanModel"))
        #expect(item.contains("CatalogStatusWords.menuTitle("))

        let dot = code(try source("DossierToolbarChip.swift"))
        #expect(dot.contains("@ObservedObject var freshness: CatalogFreshnessSnapshot"))
        #expect(dot.contains("accessibilityIdentifier(\"catalog.analyzeCatalog.dot\")"))

        let footer = code(try source("VolumeTableTotalsFooter.swift"))
        #expect(footer.contains("CatalogStatusChip(freshness: freshness)"))
        #expect(!footer.contains("@ObservedObject"), "the footer stays a pure layout")
    }

    /// The band mirrors the MFO row: same job object, same calls, no
    /// second progress implementation.
    @Test func bandMirrorsTheJobTheMFORowObserves() throws {
        let band = code(try source("CatalogStatusBand.swift"))
        #expect(band.contains("let state: CatalogFreshnessState"), "the band is handed a value")
        #expect(band.contains(".onReceive(job.objectWillChange)"), "the mirror observes the job's own change signal")
        for call in ["job.pause()", "job.resume()", "job.cancel()", "Text(job.subtitle)",
                     "MediaFileOperationClock.text(for: job, at: now)", "ProgressView(value: job.isPaused ? job.fraction"] {
            #expect(band.contains(call), "mirror missing `\(call)`")
        }
        #expect(!band.contains("fractionValue") && !band.contains(".progressLine("), "no progress arithmetic of its own")
        #expect(band.contains("CatalogStatusDoor.door(for:"))
        let panel = code(try source("AnalyzePanelView.swift"))
        #expect(panel.contains("@ObservedObject private var freshness: CatalogFreshnessSnapshot"))
        #expect(panel.contains("runningJob: { cycler in runner.activeIntegrityJob(for: cycler) }"))
        #expect(panel.contains("center.revealJobID = job.id"), "See details opens the MFO window at that row")
        #expect(panel.contains("openWindow(id: MediaFileOperationsWindowOpener.sceneID)"))
        let window = code(try source("MediaFileOperationsWindow.swift"))
        #expect(window.contains(".onChange(of: center.revealJobID, initial: true)"))
    }

    @Test func integrityRunsGoThroughTheCenterWithTheModelsMarkers() throws {
        let runner = code(try source("AnalyzeRunner.swift"))
        #expect(runner.contains("startCatalogAudit(model: model, marker: model.catalogAuditRunMarker)"))
        #expect(runner.contains("startFullHashBackfill(model: model, marker: model.fullHashResumeMarker)"))
        #expect(runner.contains("startAudioFingerprintBackfill(model: model)"))
        #expect(!runner.contains("CatalogAuditJob("), "never a second engine")
        let app = code(try source("VideoScanApp.swift"))
        #expect(app.contains("catalogModel.catalogFreshness.observeRunning(in: fileOpsCenter)"))
        // Codex cycle #80: the metadata engines feed the SAME snapshot —
        // the dossier engine from the app, the model's flags from its init.
        #expect(app.contains("catalogModel.catalogFreshness.observeDossier(captionOrchestrator.dashboardSnapshot)"))
        #expect(code(try source("VideoScanModel.swift")).contains("catalogFreshness.observeEngines(of: self)"))
        #expect(app.contains("CatalogStatusMenuItem(freshness: catalogModel.catalogFreshness)"))
        #expect(app.contains("marker: catalogModel.catalogAuditRunMarker"))
        #expect(app.contains("marker: catalogModel.fullHashResumeMarker"))
        #expect(!app.contains("@StateObject private var catalogAuditMarker"), "the markers are model-owned")
        let coverage = code(try source("VideoScanModel+AnalyzeCoverage.swift"))
        #expect(coverage.contains("CatalogFreshnessFactsReader.read(catalogFile: catalogFile)"), "facts read in the detached pass")
        #expect(coverage.contains("self.catalogFreshness.publish(report: report, facts: facts, catalogFile: catalogFile)"))
        #expect(coverage.contains("announceAtLaunch(to: self)"))
    }

    @Test func storageTabCheckIsRetitledAndKept() throws {
        let volumes = code(try source("VolumesWindow.swift"))
        #expect(volumes.contains("Label(\"Check Totals…\""))
        #expect(!volumes.contains("\"Audit Catalog…\""))
        #expect(volumes.contains("CatalogAuditSheet()"), "the bookkeeping check keeps its code")
        let sheet = code(try source("CatalogAuditSheet.swift"))
        #expect(sheet.contains("Text(\"Check Totals\")"))
        // Rick 2026-10-20: the presence check is step 1 of the one verb.
        let menuItem = code(try source("ValidateCatalogMenuItem.swift"))
        #expect(menuItem.contains("Button(\"Validate Catalog…\")"), "the presence check runs as Validate Catalog")
    }
}

// MARK: - Structure

@Suite("Catalog Status — structure")
struct CatalogStatusStructureTests {

    @Test func theThreeIntegrityRowsComeFirst() {
        #expect(Array(AnalyzeCycler.allCases.prefix(3)) == [.filePresence, .fullHashes, .soundPrints])
        #expect(AnalyzeCycler.integrityJobs == [.filePresence, .fullHashes, .soundPrints, .integrity])
        #expect(AnalyzeCycler.allCases.filter(\.isIntegrity) == AnalyzeCycler.integrityJobs)
        #expect(AnalyzeCycler.integrityJobs.allSatisfy { $0.isPausable }, "the four MFO jobs pause")
        #expect(AnalyzeCycler.integrityJobs.allSatisfy { !$0.hasVolumeScope })
        #expect(AnalyzeCycler.allCases[3] == .integrity, "Verify Catalog's row comes right after the three")
        #expect(AnalyzeCycler.filePresence.autoRunsToday, "the nightly runs the audit")
        #expect(!AnalyzeCycler.fullHashes.autoRunsToday && !AnalyzeCycler.soundPrints.autoRunsToday)
        #expect([AnalyzeCycler.filePresence, .fullHashes, .soundPrints].map(\.title) == ["File Presence", "Full Hashes", "Sound Prints"])
    }

    @Test func analyzeMenusFirstItemIsTheSummary() throws {
        let src = try SourceTree.appSource(named: "CatalogAnalyzeMenu.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let menu = try #require(src.range(of: "Menu {"))
        let summary = try #require(src.range(of: "Button(Self.summaryTitle(freshness.state), action: onOpenPanel)"))
        let rows = try #require(src.range(of: "ForEach(AnalyzeCycler.allCases)"))
        #expect(menu.upperBound < summary.lowerBound && summary.upperBound < rows.lowerBound,
                "the summary sentence is the first row, above the per-cycler rows")
        let body = src[menu.upperBound..<summary.lowerBound]
        #expect(!body.contains("Button(") && !body.contains("Text("), "nothing sits above the summary")
        #expect(src.contains("@ObservedObject var freshness: CatalogFreshnessSnapshot"))
        #expect(CatalogAnalyzeMenu.summaryTitle(CatalogFreshnessState()) == "Checking what the catalog knows…")
        var s = CatalogFreshnessState.judged(rows: [], now: now, wording: wording)
        s.summary.headline = "2 things need attention"
        #expect(CatalogAnalyzeMenu.summaryTitle(s) == "2 things need attention")
    }

    @Test func coverageReportCarriesTheIntegrityKinds() {
        let r = compute([.init(fullPath: "/Volumes/LaCie/a.mov", sizeBytes: 10, hasFullDigest: true)])
        #expect(r.byCycler.keys.contains(.filePresence) && r.byCycler.keys.contains(.fullHashes) && r.byCycler.keys.contains(.soundPrints))
        #expect(!r.coverageKnown(.filePresence), "no stamp per row — the audit marker stands in")
        #expect(r.counts(.filePresence).eligible == 1 && r.counts(.filePresence).covered == 0)
        #expect(r.counts(.fullHashes).covered == 1)
        #expect(r.byVolume[.filePresence] == nil, "no per-volume table for the integrity kinds")
    }
}
