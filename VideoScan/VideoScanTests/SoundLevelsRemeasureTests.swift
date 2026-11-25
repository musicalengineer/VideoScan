// SoundLevelsRemeasureTests.swift — GH #516, "Re-measure sound levels"
// (DECISIONS 2026-11-25: an improved measurement re-measures old results in
// the background).
//
// A Check Media card saved before 2441ceb42 can carry, on its Sound row, the
// LAST filter graph's Left/Right levels for a sound track whose rate, format
// or layout changes partway. With no live diagnosis Media Info, the report
// card and the card's text showed them as loudness (CLAUDE.md rule 1). The job
// measures each such file again and rewrites that row.
//
// Five dimensions + truth (rule 8):
//   logic      the regression (a pre-fix card's levels are gone after the job,
//              on every surface that reads them), #470 short-decode levels
//              still shown, an ordinary file refreshed, the plan predicate,
//              offline / changed-size withdrawn then measured when back,
//              Pause, Stop + resume from the cursor, a failed save undone,
//              a card Check Media rewrote meanwhile left alone, read-only and
//              missing-tool refusals, the real save surviving a reload.
//   scale      the plan over 100k records inside a time budget.
//   media      mp4/h264, mov/prores, mkv/ffv1+pcm, mxf/mpeg2, avi/dv and a
//              rate-changing NUT through the REAL measurement; files unchanged.
//   isolation  a corrupt / unwritable schedule file, a restored old catalog,
//              copies of one content disagreeing, poisoned cards (future date, odd evidence,
//              quick tier, removed rows) — never fewer cards than needed.
//   sensor     one engine (the Sound row rule, the job's start), no
//              VideoScanModel extension, the scheduler on the master only,
//              the persisted withdrawn words pinned.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Fixtures

@MainActor
enum RemeasureFixture {

    static let dayAgo = Date().addingTimeInterval(-86_400)

    /// A full card as pre-fix code saved it for a rate-changing track (the
    /// P1 era): "not checked" — yet the last graph's levels as evidence.
    static func preFixReconfiguredCard(size: Int64, checkedAt: Date = dayAgo) -> MediaReportCard {
        let why = AudioShortDecode.reconfigured(statedSeconds: nil).reason
        let rows = [
            MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decodes."),
            MediaCheck(kind: .sound, verdict: .notRun(reason: why), sentence: "Not checked — \(why).",
                       evidence: [MediaEvidence("Left", "-85 dB average, -79 dB peak"),
                                  MediaEvidence("Right", "-77 dB average, -71 dB peak")]),
        ]
        return MediaReportCard(tier: .full, checkedAt: checkedAt, fileSizeBytes: size,
                               headline: "\(MediaReportCard.soundNotCheckedLead)\(why). No problems were found in the rest of the full check.",
                               checks: rows)
    }

    /// A full card with ordinary levels and an OK Sound row.
    static func card(levels: [Double], size: Int64, checkedAt: Date = dayAgo, tier: MediaReportCard.Tier = .full) -> MediaReportCard {
        let names = levels.count == 2 ? ["Left", "Right"] : levels.indices.map { "Channel \($0 + 1)" }
        let evidence = zip(names, levels).map { MediaEvidence($0, String(format: "%.0f dB average, %.0f dB peak", $1, $1 + 6)) }
        let rows = [
            MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decodes."),
            MediaCheck(kind: .sound, verdict: .ok, sentence: "The sound plays at a healthy level on every channel.",
                       evidence: evidence),
        ]
        var c = MediaReportCard(tier: tier, checkedAt: checkedAt, fileSizeBytes: size,
                                headline: CheckMediaRules.fullPassHeadline, checks: rows)
        c.soundMeasuredSilent = false
        return c
    }

    /// The pre-P1 shape: the last graph read silent → "silent" warning.
    static func preFixSilentCard(size: Int64) -> MediaReportCard {
        var c = card(levels: [-85, -77], size: size)
        c.checks = c.checks.map {
            $0.kind == .sound ? MediaCheck(kind: .sound, verdict: .warning, sentence: "The sound track is silent.",
                                           evidence: $0.evidence, fix: "Look for the matching sound.") : $0
        }
        c.headline = "Plays, with 1 thing to look at: sound track."
        c.soundMeasuredSilent = true
        return c
    }

    static func record(_ path: String, size: Int64, card: MediaReportCard?) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = size
        r.mediaReportCard = card
        return r
    }

    nonisolated static func reconfigured() -> AudioVerifyDiagnosis {
        MasterArchiveTestSupport.soundDiagnosis(channels: [-84.63, -77.26], shortDecode: .reconfigured(statedSeconds: nil))
    }

    nonisolated static func healthy(_ l: Double, _ r: Double) -> AudioVerifyDiagnosis {
        MasterArchiveTestSupport.soundDiagnosis(channels: [l, r])
    }

    static func model(_ dir: URL) -> VideoScanModel {
        let m = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        return m
    }

    /// Nothing is owed: no candidate card at all (the job's "done").
    static func nothingOwed(_ records: [VideoRecord]) -> Bool { SoundLevelsRemeasureItem.plan(records).isEmpty }

    /// Only cards withdrawn earlier remain (no unstamped levels).
    static func onlyWithdrawn(_ records: [VideoRecord]) -> Bool {
        SoundLevelsRemeasureItem.plan(records).allSatisfy { $0.need == .withdrawn }
    }

    static func job(_ m: VideoScanModel, save: Bool? = true,
                    measure: @escaping SoundLevelsRemeasureJob.Measure) -> SoundLevelsRemeasureJob {
        let j = SoundLevelsRemeasureJob(model: m)
        j.measure = measure
        j.toolsAvailable = { true }
        if let save { j.commitForTesting = { _ in save } }
        return j
    }

    static func run(_ j: SoundLevelsRemeasureJob) async {
        j.start()
        await j.task?.value
    }

    static func scratch(_ label: String) throws -> URL {
        let dir = ShowAgainSandbox.physical(FileManager.default.temporaryDirectory)
            .appendingPathComponent("test_remeasure_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Every surface that reads a saved card's levels with no live diagnosis.
    static func shownLevels(_ card: MediaReportCard?) -> (mediaInfo: [MediaEvidence], text: String) {
        (MediaInfoSheet.channelLevels(diagnosis: nil, card: card), card.map(CheckMediaRules.text(of:)) ?? "")
    }
}

/// A drive's connected state a test flips (serialized suite; ≈ a plain bool).
final class OnlineFlag: @unchecked Sendable { var on = false }

/// The paths a stub measured, in order (≈ a mutex-guarded vector).
actor MeasuredPaths {
    private(set) var paths: [String] = []
    func add(_ p: String) { paths.append(p) }
}

// MARK: - Logic

@MainActor
@Suite("GH #516 — re-measure sound levels (logic)", .serialized)
struct SoundLevelsRemeasureLogicTests {

    @Test("REGRESSION: a pre-fix card's partial-graph levels are shown with no live diagnosis until the job runs; after it, none on any surface")
    func preFixReconfiguredCardLosesItsLevels() async throws {
        let dir = try RemeasureFixture.scratch("regress"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = RemeasureFixture.record("/Volumes/Tapes/tone_then_silence.nut", size: 4_000,
                                          card: RemeasureFixture.preFixReconfiguredCard(size: 4_000))
        let silent = RemeasureFixture.record("/Volumes/Tapes/rate_change.mov", size: 5_000,
                                             card: RemeasureFixture.preFixSilentCard(size: 5_000))
        m.records = [rec, silent]
        // The bug, as Rick saw it: the saved card's levels shown as loudness.
        #expect(RemeasureFixture.shownLevels(rec.mediaReportCard).mediaInfo.count == 2)

        await RemeasureFixture.run(RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) })

        for r in [rec, silent] {
            let card = try #require(r.mediaReportCard)
            let shown = RemeasureFixture.shownLevels(card)
            #expect(shown.mediaInfo.isEmpty, "\(r.filename): Media Info still shows \(shown.mediaInfo)")
            #expect(!shown.text.contains("dB average"), "\(r.filename): the card's text still carries levels")
            #expect(card.check(.sound)?.evidence.isEmpty == true)
            #expect(card.check(.sound)?.sentence.contains("changes partway") == true)
            #expect(card.soundMeasuredSilent == nil, "no silence claim from a partial graph")
            #expect(card.isSoundNotChecked, "the headline says the sound was not checked: \(card.headline)")
            #expect(card.check(.decode) != nil && card.checkedAt == RemeasureFixture.dayAgo, "only the Sound row changed")
        }
    }

    @Test("#470: a decode that ended early keeps its levels (one graph, the part that decoded) — still shown after the job")
    func shortDecodeEvidenceStillShows() async throws {
        let dir = try RemeasureFixture.scratch("short"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = RemeasureFixture.record("/Volumes/T/cut_short.mov", size: 9_000,
                                          card: RemeasureFixture.card(levels: [-18, -20], size: 9_000))
        m.records = [rec]
        let short = MasterArchiveTestSupport.soundDiagnosis(channels: [-18, -20],
                                                            shortDecode: AudioShortDecode(missingSeconds: 3, statedSeconds: 12))
        let j = RemeasureFixture.job(m) { _, _ in .measured(short) }
        await RemeasureFixture.run(j)
        let card = try #require(rec.mediaReportCard)
        #expect(RemeasureFixture.shownLevels(card).mediaInfo.count == 2, "\(card.check(.sound)?.evidence ?? [])")
        #expect(card.check(.sound)?.sentence.contains("stopped early") == true)
        #expect(j.totals.refreshed == 1 && j.totals.reconfigured == 0)
    }

    @Test("an ordinary file: today's levels replace the old ones; verdict, headline, date and every other row kept")
    func ordinaryFileIsRefreshed() async throws {
        let dir = try RemeasureFixture.scratch("fresh"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let old = RemeasureFixture.card(levels: [-30, -31], size: 7_000)
        let rec = RemeasureFixture.record("/Volumes/T/ok.mov", size: 7_000, card: old)
        m.records = [rec]
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.healthy(-18, -19)) }
        await RemeasureFixture.run(j)
        let card = try #require(rec.mediaReportCard)
        #expect(card.check(.sound)?.evidence.map(\.value) == ["-18 dB average, -12 dB peak", "-19 dB average, -13 dB peak"])
        #expect(card.check(.sound)?.verdict == .ok)
        #expect(card.headline == old.headline && card.checkedAt == old.checkedAt && card.check(.decode) == old.check(.decode))
        #expect(card.soundMeasuredSilent == false)
        #expect(j.totals.refreshed == 1)
        // Done: the rewritten card carries today's stamp; nothing is planned again.
        #expect(card.soundLevels == .measured)
        #expect(RemeasureFixture.nothingOwed(m.records))
        if case .finished(let s) = j.state { #expect(s.hasPrefix("Measured again 1")) } else { Issue.record("\(j.state)") }
    }

    @Test("the plan reads the card alone: full cards with levels and no current stamp (whatever their date); one item per content; the Tidy count is the same predicate")
    func thePlanPredicate() throws {
        let pre = RemeasureFixture.record("/V/pre.mov", size: 1, card: RemeasureFixture.card(levels: [-20, -20], size: 1))
        var stampedCard = RemeasureFixture.card(levels: [-20, -20], size: 1)
        stampedCard.soundLevels = .measured
        let post = RemeasureFixture.record("/V/post.mov", size: 1, card: stampedCard)
        var oldStamp = RemeasureFixture.card(levels: [-20, -20], size: 1, checkedAt: Date().addingTimeInterval(86_400 * 30))
        oldStamp.soundLevels = .init(version: 1, state: .measured)
        let older = RemeasureFixture.record("/V/older-pass.mov", size: 1, card: oldStamp)
        let quick = RemeasureFixture.record("/V/quick.mov", size: 1, card: RemeasureFixture.card(levels: [-20], size: 1, tier: .quick))
        var noLevels = RemeasureFixture.card(levels: [], size: 1)
        noLevels.checks = noLevels.checks.map { $0.kind == .sound ? MediaCheck(kind: .sound, verdict: .ok, sentence: "x", evidence: [MediaEvidence("Dated", "1990")]) : $0 }
        let none = RemeasureFixture.record("/V/nolevels.mov", size: 1, card: noLevels)
        let noCard = RemeasureFixture.record("/V/nocard.mov", size: 1, card: nil)
        let mono = RemeasureFixture.record("/V/mono.wav", size: 1, card: RemeasureFixture.card(levels: [-20, -20, -20], size: 1))
        let records = [pre, post, older, quick, none, noCard, mono]
        let plan = SoundLevelsRemeasureItem.plan(records)
        #expect(Set(plan.map(\.filename)) == ["pre.mov", "older-pass.mov", "mono.wav"])
        let projected = CatalogTidyCalculator.project(records, isOnline: { _ in true })
        #expect(projected.soundLevelsToRemeasure == plan.count)
        let counts = CatalogTidyCalculator.counts(projected, degenerateOCRCaptions: 0)
        #expect(CatalogTidyRow.rows(counts).first { $0.kind == .soundLevelsToRemeasure }?.runTitle == "Run")
        #expect(counts.menuTotal == plan.count)
        // Today's Check Media stamps every card it makes: never a candidate.
        let fresh = CheckMediaRules.card(tier: .full, checks: [MediaCheck(kind: .sound, verdict: .ok, sentence: "x",
                                                                         evidence: [MediaEvidence("Left", "-18 dB average")])],
                                         quick: try CheckMediaFixtures.healthy(), at: Date())
        #expect(fresh.soundLevels == .measured)
        #expect(SoundLevelsRemeasureRules.need(fresh, live: true) == nil)
    }

    @Test("not connected / not the size checked: levels withdrawn (never shown as current), counted; measured when the file is back")
    func offlineAndChangedAreWithdrawnThenMeasured() async throws {
        let dir = try RemeasureFixture.scratch("offline"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let offline = RemeasureFixture.record(dir.appendingPathComponent("gone.mov").path, size: 3_000,
                                              card: RemeasureFixture.card(levels: [-20, -21], size: 3_000))
        let changedPath = dir.appendingPathComponent("grew.mov")
        try Data(count: 4_096).write(to: changedPath)
        let changed = RemeasureFixture.record(changedPath.path, size: 3_000,
                                              card: RemeasureFixture.card(levels: [-20, -21], size: 3_000))
        m.records = [offline, changed]
        // The REAL measurement: it never reaches ffmpeg for these two.
        let j = SoundLevelsRemeasureJob(model: m)
        j.toolsAvailable = { true }
        j.commitForTesting = { _ in true }
        j.isOnline = { !$0.hasSuffix("gone.mov") }   // gone.mov's drive is away
        await RemeasureFixture.run(j)
        #expect(j.totals.offline == 1 && j.totals.changed == 1 && j.totals.withdrawn == 2)
        for r in [offline, changed] {
            let card = try #require(r.mediaReportCard)
            #expect(RemeasureFixture.shownLevels(card).mediaInfo.isEmpty, "\(r.filename)")
            let row = try #require(card.check(.sound))
            #expect(SoundLevelsRemeasureRules.isWithdrawnRow(row), "\(row.sentence)")
            #expect(card.isSoundNotChecked, Comment(rawValue: card.headline))
        }
        #expect(offline.mediaReportCard?.check(.sound)?.sentence.contains("not connected") == true)
        #expect(changed.mediaReportCard?.check(.sound)?.sentence.contains("no longer the size") == true)
        // NOT done: one card waits for its drive; the plan (and Tidy) still name both.
        #expect(RemeasureFixture.onlyWithdrawn(m.records) && !RemeasureFixture.nothingOwed(m.records))
        if case .finished(let s) = j.state { #expect(s.contains("waiting for 1 drive (1 card)"), "\(s)") }
        let plan = SoundLevelsRemeasureItem.plan(m.records)
        #expect(plan.count == 2 && plan.allSatisfy { $0.need == .withdrawn })
        // The drive is back: a run by hand measures them.
        let again = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.healthy(-18, -19)) }
        await RemeasureFixture.run(again)
        #expect(again.totals.refreshed == 2)
        #expect(offline.mediaReportCard.map { RemeasureFixture.shownLevels($0).mediaInfo.count } == 2)
        #expect(RemeasureFixture.nothingOwed(m.records), "nothing waits any more: done")
        // A withdrawn row on a removed file is not waited for.
        var withdrawn = try #require(changed.mediaReportCard)
        withdrawn = SoundLevelsRemeasureRules.rewrite(withdrawn, with: .notMeasured(.offline), context: changed.soundPresenceContext)
        #expect(SoundLevelsRemeasureRules.need(withdrawn, live: false) == nil)
    }

    @Test("Stop mid-run: cards before the stop are saved and rewritten, the rest untouched; a new run resumes at the cursor and finishes")
    func stopKeepsCardsConsistentAndResumes() async throws {
        let dir = try RemeasureFixture.scratch("stop"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        m.records = (0..<5).map { RemeasureFixture.record("/Volumes/T/f\($0).mov", size: 1_000,
                                                          card: RemeasureFixture.preFixReconfiguredCard(size: 1_000)) }
        let ordered = m.records.sorted { $0.id.uuidString < $1.id.uuidString }
        let measured = MeasuredPaths()
        final class JobRef: @unchecked Sendable { weak var job: SoundLevelsRemeasureJob? }
        let ref = JobRef()
        let stopAt = ordered[2].fullPath
        let j = RemeasureFixture.job(m) { path, _ in
            if path == stopAt {
                await MainActor.run { ref.job?.cancel() }
                try await Task.sleep(nanoseconds: 5_000_000_000)   // cancelled: throws
            }
            await measured.add(path)
            return .measured(RemeasureFixture.reconfigured())
        }
        ref.job = j
        await RemeasureFixture.run(j)
        #expect(j.state == .cancelled)
        #expect(await measured.paths == ordered.prefix(2).map(\.fullPath))
        for (i, r) in ordered.enumerated() {
            let levels = RemeasureFixture.shownLevels(r.mediaReportCard).mediaInfo.count
            #expect(levels == (i < 2 ? 0 : 2), "card \(i): \(levels) level(s) shown")
        }
        // No cursor: the stamp on each rewritten card IS the progress.
        #expect(SoundLevelsRemeasureItem.plan(m.records).map(\.id) == ordered.suffix(3).map(\.id))

        let resumed = MeasuredPaths()
        let j2 = RemeasureFixture.job(m) { path, _ in
            await resumed.add(path)
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j2)
        #expect(await resumed.paths == ordered.suffix(3).map(\.fullPath), "resumes at the first card not yet saved")
        #expect(ordered.allSatisfy { RemeasureFixture.shownLevels($0.mediaReportCard).mediaInfo.isEmpty })
        #expect(RemeasureFixture.nothingOwed(m.records))
    }

    @Test("Pause holds before the next file; Resume continues; nothing is written while paused")
    func pauseAndResume() async throws {
        let dir = try RemeasureFixture.scratch("pause"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        m.records = (0..<3).map { RemeasureFixture.record("/Volumes/T/p\($0).mov", size: 1_000,
                                                          card: RemeasureFixture.card(levels: [-30, -30], size: 1_000)) }
        let measured = MeasuredPaths()
        let j = RemeasureFixture.job(m) { path, _ in
            await measured.add(path)
            return .measured(RemeasureFixture.healthy(-18, -18))
        }
        j.start()
        j.pause()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(await measured.paths.isEmpty, "paused before the first file")
        #expect(j.isPaused && j.state == .running)
        #expect(m.records.allSatisfy { $0.mediaReportCard?.check(.sound)?.evidence.first?.value.hasPrefix("-30") == true })
        j.resume()
        await j.task?.value
        #expect(await measured.paths.count == 3 && j.totals.refreshed == 3)
    }

    @Test("a refused commit stops the job and puts that content's card back exactly as it was; nothing else is touched")
    func failedSaveIsUndone() async throws {
        let dir = try RemeasureFixture.scratch("savefail"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let cards = (0..<3).map { _ in RemeasureFixture.preFixReconfiguredCard(size: 1_000) }
        m.records = cards.enumerated().map { RemeasureFixture.record("/Volumes/T/s\($0.offset).mov", size: 1_000, card: $0.element) }
        let j = RemeasureFixture.job(m, save: false) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        guard case .failed(let words) = j.state else { Issue.record("\(j.state)"); return }
        #expect(words.contains("could not store"))
        #expect(words.contains("catalog rows before 3 · after 3"), "a commit-failure OUTCOME carries the row counts (Codex third pass P2-6)")
        #expect(zip(m.records, cards).allSatisfy { $0.mediaReportCard == $1 }, "the refused content put back, the rest untouched")
        #expect(SoundLevelsRemeasureItem.plan(m.records).count == 3, "all three still owed")
    }

    @Test("a card Check Media rewrote during the run (inside the debounce window) is left as it is")
    func cardChangedMeanwhileIsLeftAlone() async throws {
        let dir = try RemeasureFixture.scratch("meanwhile"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = RemeasureFixture.record("/Volumes/T/m.mov", size: 1_000, card: RemeasureFixture.preFixReconfiguredCard(size: 1_000))
        m.records = [rec]
        let fresh = RemeasureFixture.card(levels: [-12, -13], size: 1_000, checkedAt: Date())
        /// Hands the main-actor objects to the stub (it only touches them on the main actor).
        final class Box: @unchecked Sendable { let rec: VideoRecord; let model: VideoScanModel
            init(_ r: VideoRecord, _ m: VideoScanModel) { rec = r; model = m } }
        let box = Box(rec, m)
        let j = RemeasureFixture.job(m) { _, _ in
            await MainActor.run { box.rec.mediaReportCard = fresh; box.model.saveCatalogDebounced() }
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j)
        #expect(rec.mediaReportCard == fresh, "the fresh card wins")
        #expect(j.totals.changedMeanwhile == 1)
    }

    @Test("refused on a read-only catalog (a viewer, or after a role flip) and without ffmpeg — nothing read or changed")
    func refusals() async throws {
        let dir = try RemeasureFixture.scratch("refuse"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let card = RemeasureFixture.preFixReconfiguredCard(size: 1_000)
        m.records = [RemeasureFixture.record("/Volumes/T/r.mov", size: 1_000, card: card)]
        let measured = MeasuredPaths()
        let noTool = RemeasureFixture.job(m) { p, _ in await measured.add(p); return .measured(RemeasureFixture.reconfigured()) }
        noTool.toolsAvailable = { false }
        await RemeasureFixture.run(noTool)
        #expect(noTool.wasRefused)
        m.isReadOnly = true
        let viewer = RemeasureFixture.job(m) { p, _ in await measured.add(p); return .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(viewer)
        #expect(viewer.wasRefused)
        #expect(await measured.paths.isEmpty && m.records[0].mediaReportCard == card)
    }

    @Test("ffmpeg going away mid-run stops the job; the card it was reading is not touched")
    func toolLostMidRun() async throws {
        let dir = try RemeasureFixture.scratch("toollost"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        m.records = (0..<2).map { RemeasureFixture.record("/Volumes/T/t\($0).mov", size: 1_000,
                                                          card: RemeasureFixture.preFixReconfiguredCard(size: 1_000)) }
        let second = m.records.sorted { $0.id.uuidString < $1.id.uuidString }[1]
        let before = second.mediaReportCard
        let secondPath = second.fullPath
        let j = RemeasureFixture.job(m) { path, _ in
            if path == secondPath { throw AudioVerifyProbeError.toolUnavailable("gone") }
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j)
        guard case .failed = j.state else { Issue.record("\(j.state)"); return }
        #expect(second.mediaReportCard == before)
        #expect(SoundLevelsRemeasureItem.plan(m.records).contains { $0.id == second.id }, "still owed")
    }

    @Test("a drive offline on the first run: its cards are withdrawn and counted waiting in Tidy (not done); the drive returns → the next Run measures them, and only then is nothing owed")
    func driveOfflineThenBack() async throws {
        let dir = try RemeasureFixture.scratch("driveback"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let away = RemeasureFixture.record("/Volumes/Away/a.mov", size: 1_000, card: RemeasureFixture.card(levels: [-30, -30], size: 1_000))
        let here = RemeasureFixture.record("/Volumes/Here/b.mov", size: 1_000, card: RemeasureFixture.card(levels: [-30, -30], size: 1_000))
        m.records = [away, here]
        let drive = OnlineFlag()
        let online: @Sendable (String) -> Bool = { $0.hasPrefix("/Volumes/Here") || drive.on }
        func job() -> SoundLevelsRemeasureJob {
            let j = RemeasureFixture.job(m) { path, _ in
                online(path) ? .measured(RemeasureFixture.healthy(-18, -18)) : .notMeasured(.offline)
            }
            j.isOnline = online
            return j
        }
        let first = job()
        await RemeasureFixture.run(first)
        #expect(first.totals.refreshed == 1 && first.totals.offline == 1)
        #expect(RemeasureFixture.onlyWithdrawn(m.records) && !RemeasureFixture.nothingOwed(m.records),
                "a card waits for its drive: not done")
        #expect(RemeasureFixture.shownLevels(away.mediaReportCard).mediaInfo.isEmpty, "withdrawn, never shown as current")
        let tidy = CatalogTidyCalculator.counts(CatalogTidyCalculator.project(m.records, isOnline: online),
                                                degenerateOCRCaptions: 0)
        #expect(tidy.soundLevelsWaitingCards == 1 && tidy.soundLevelsWaitingDrives == 1)
        #expect(CatalogTidyRow.rows(tidy).last?.detail.contains("1 of them wait for 1 drive to be connected") == true)

        // The drive returns: Tidy's count is the reminder; Rick presses Run.
        drive.on = true
        #expect(SoundLevelsRemeasureItem.waiting(m.records, isOnline: online).ready == 1)
        let second = job()
        await RemeasureFixture.run(second)
        #expect(second.totals.refreshed == 1)
        #expect(RemeasureFixture.shownLevels(away.mediaReportCard).mediaInfo.count == 2)
        #expect(RemeasureFixture.nothingOwed(m.records), "only now: nothing owed")
    }

    @Test("a drive that never returns blocks no other card; a file missing from a CONNECTED drive is not 'waiting'")
    func driveThatNeverReturns() async throws {
        let dir = try RemeasureFixture.scratch("never"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let lost = RemeasureFixture.record("/Volumes/Lost/x.mov", size: 1_000, card: RemeasureFixture.preFixReconfiguredCard(size: 1_000))
        let others = (0..<3).map { RemeasureFixture.record("/Volumes/Here/o\($0).mov", size: 1_000,
                                                          card: RemeasureFixture.preFixReconfiguredCard(size: 1_000)) }
        let missing = RemeasureFixture.record(dir.appendingPathComponent("moved-away.mov").path, size: 1_000,
                                              card: RemeasureFixture.card(levels: [-20, -20], size: 1_000))
        m.records = [lost] + others + [missing]
        let online: @Sendable (String) -> Bool = { !$0.hasPrefix("/Volumes/Lost") }
        let j = RemeasureFixture.job(m) { path, size in
            if path.hasPrefix("/Volumes/Here") { return .measured(RemeasureFixture.reconfigured()) }
            return try await SoundLevelsRemeasureJob.measureFile(path: path, expectedSize: size, isOnline: online)
        }
        j.isOnline = online
        await RemeasureFixture.run(j)
        #expect(j.totals.reconfigured == 3 && j.totals.offline == 1 && j.totals.notFound == 1)
        #expect(others.allSatisfy { RemeasureFixture.shownLevels($0.mediaReportCard).mediaInfo.isEmpty })
        #expect(missing.mediaReportCard?.check(.sound).map(SoundLevelsRemeasureRules.isWaitingForDrive) == false)
        #expect(RemeasureFixture.onlyWithdrawn(m.records) && !RemeasureFixture.nothingOwed(m.records))
        #expect(SoundLevelsRemeasureItem.waiting(m.records, isOnline: online) == SoundLevelsRemeasureWaiting(cards: 1, drives: ["/Volumes/Lost"], ready: 0))
    }

    @Test("relaunch: the real save reaches the catalog; a reloaded catalog carries the rewritten card and nothing is planned again")
    func survivesARelaunch() async throws {
        let dir = try RemeasureFixture.scratch("relaunch"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = RemeasureFixture.record("/Volumes/T/d.mov", size: 1_000, card: RemeasureFixture.preFixReconfiguredCard(size: 1_000))
        m.records = [rec]
        let j = RemeasureFixture.job(m, save: nil) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.savedCount == 1 && !j.saveFailed)
        let reloaded = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true)).load()
        let card = reloaded.first { $0.id == rec.id }?.mediaReportCard
        #expect(card != nil && RemeasureFixture.shownLevels(card).mediaInfo.isEmpty)
        #expect(card?.soundLevels == .measured, "the stamp survives the reload")
        #expect(RemeasureFixture.nothingOwed(reloaded))
    }
}

// MARK: - Codex cycle #373: copies of one content, mid-read loss, rows at START

/// Two records of the same bytes (one whole-file digest) with `card` each.
@MainActor
private func twoCopies(_ m: VideoScanModel, a: MediaReportCard, b: MediaReportCard) -> (VideoRecord, VideoRecord) {
    let digest = String(repeating: "ab", count: 32)
    func make(_ path: String, _ card: MediaReportCard) -> VideoRecord {
        let r = RemeasureFixture.record(path, size: 1_000, card: card)
        r.contentFixity = ContentFixity(digest: digest, byteCount: 1_000,
                                        stamp: FileIdentityStamp(device: 1, inode: UInt64(path.count), size: 1_000, mtimeNs: 3))
        return r
    }
    let ra = make("/Volumes/T/a.mov", a), rb = make("/Volumes/U/b.mov", b)
    m.records = [ra, rb]
    return (ra, rb)
}

@MainActor
@Suite("GH #516 — re-measure sound levels: Codex cycle #373 (copies, drives, rows)", .serialized)
struct SoundLevelsRemeasureCodex373Tests {

    @Test("P0-1 (memory): A was checked again; B still holds the old card — re-measuring B writes NOTHING (cards are stored per digest)")
    func aSiblingsNewerCardIsNeverOverwritten() async throws {
        let dir = try RemeasureFixture.scratch("sib"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        var fresh = RemeasureFixture.card(levels: [-12, -13], size: 1_000, checkedAt: Date())
        fresh.soundLevels = .measured
        fresh.repairedCopy = MediaRepairLink(recordID: UUID(), path: "/Volumes/T/a-repaired.mov", repairedAt: Date(), fixes: ["x"])
        let old = RemeasureFixture.preFixReconfiguredCard(size: 1_000)
        let (a, b) = twoCopies(m, a: fresh, b: old)
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(a.mediaReportCard == fresh && b.mediaReportCard == old, "nothing written to either copy")
        #expect(j.totals.changedMeanwhile == 1 && j.totals.cardsWritten == 0)
    }

    @Test("P0-1: copies that agree are ONE item; every copy gets the same rewritten card")
    func agreeingCopiesAreOneItem() async throws {
        let dir = try RemeasureFixture.scratch("sib2"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let old = RemeasureFixture.preFixReconfiguredCard(size: 1_000)
        let (a, b) = twoCopies(m, a: old, b: old)
        #expect(SoundLevelsRemeasureItem.plan(m.records).count == 1)
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.totals.cardsWritten == 2 && a.mediaReportCard == b.mediaReportCard)
        #expect(RemeasureFixture.shownLevels(b.mediaReportCard).mediaInfo.isEmpty)
    }

    @Test("P0-1: the card stored for the digest differs from the one read (or cannot be read) → nothing written")
    func theStoredCardDecides() async throws {
        let dir = try RemeasureFixture.scratch("stored"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let old = RemeasureFixture.preFixReconfiguredCard(size: 1_000)
        let (a, _) = twoCopies(m, a: old, b: old)
        var newer = RemeasureFixture.card(levels: [-12, -13], size: 1_000, checkedAt: Date())
        newer.soundLevels = .measured
        for stored in [SoundLevelsStoredCard.card(newer), .unreadable("bad JSON")] {
            let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
            j.storedCard = { _ in stored }
            await RemeasureFixture.run(j)
            #expect(a.mediaReportCard == old && j.totals.changedMeanwhile == 1)
        }
        // The same card stored (its date in whole seconds, as the store keeps it) → written.
        var same = old
        same.checkedAt = Date(timeIntervalSince1970: old.checkedAt.timeIntervalSince1970.rounded(.down))
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        j.storedCard = { _ in .card(same) }
        await RemeasureFixture.run(j)
        #expect(j.totals.cardsWritten == 2)
    }

    @Test("P0-1 on catalog.sqlite (Codex's SQL case): A's newer card, its other rows and its repaired-copy link survive B's re-measure and a relaunch")
    func newerCardSurvivesOnSQLite() async throws {
        let scene = try CutoverScene.make("remeasure_p01"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let media = scene.folder.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let size = 32 * 1024
        let aURL = try MasterArchiveTestSupport.writeBlob(at: media.appendingPathComponent("a.mov"), bytes: size, seed: 516)
        let bURL = media.appendingPathComponent("b.mov")
        try FileManager.default.copyItem(at: aURL, to: bURL)
        let digest = try scene.sha256(aURL)
        let old = RemeasureFixture.preFixReconfiguredCard(size: Int64(size))
        var ids: [UUID] = []
        for url in [aURL, bURL] {
            let r = try scene.freshCopy(of: .healthy, path: url.path)
            r.sizeBytes = Int64(size)
            r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(size))
            r.mediaReportCard = old
            scene.model.records.append(r)
            ids.append(r.id)
            try #require(scene.model.saveCatalogNow(), "fixture: stored")
        }
        var model = try await relaunchRemeasure(scene, from: scene.model)
        // Verify checks A again: a newer card, a repaired-copy link.
        var fresh = RemeasureFixture.card(levels: [-12, -13], size: Int64(size), checkedAt: Date())
        fresh.soundLevels = .measured
        fresh.repairedCopy = MediaRepairLink(recordID: UUID(), path: media.appendingPathComponent("a-repaired.mov").path,
                                             repairedAt: Date(), fixes: ["balance"])
        try #require(model.record(forID: ids[0]) != nil)
        model.record(forID: ids[0])?.mediaReportCard = fresh
        try #require(model.saveCatalogNow())
        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.totals.cardsWritten == 0, Comment(rawValue: SoundLevelsRemeasureJob.summaryCounts(j.totals)))
        model = try await relaunchRemeasure(scene, from: model)
        for id in ids {
            let card = try #require(model.record(forID: id)?.mediaReportCard)
            #expect(SoundLevelsRemeasureRules.sameCard(card, fresh), "copy \(id): the newer card was lost")
            #expect(card.repairedCopy?.path.hasSuffix("a-repaired.mov") == true)
        }
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P2-5: a drive gone after the stat (the read fails and the drive is away) waits for the drive; on a connected drive it is 'could not measure'")
    func driveGoneMidRead() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try RemeasureFixture.scratch("midread"); defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("not-media.mov").path
        try Data(repeating: 7, count: 4_096).write(to: URL(fileURLWithPath: path))
        guard case .notMeasured(let away) = try await SoundLevelsRemeasureJob.measureFile(path: path, expectedSize: 4_096, isOnline: { _ in false }) else {
            Issue.record("measured an unreadable file"); return
        }
        #expect(away == .offline)
        guard case .notMeasured(let here) = try await SoundLevelsRemeasureJob.measureFile(path: path, expectedSize: 4_096, isOnline: { _ in true }) else {
            Issue.record("measured an unreadable file"); return
        }
        if case .failed = here {} else { Issue.record("connected drive: \(here)") }
    }

    @Test("P2-7: OUTCOME's 'before' is the row count at START, not at the end")
    func rowsCountedAtStart() async throws {
        let dir = try RemeasureFixture.scratch("rows"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        m.records = [RemeasureFixture.record("/Volumes/T/r.mov", size: 1_000, card: RemeasureFixture.preFixReconfiguredCard(size: 1_000))]
        final class Box: @unchecked Sendable { let m: VideoScanModel; init(_ m: VideoScanModel) { self.m = m } }
        let box = Box(m)
        let j = RemeasureFixture.job(m) { _, _ in
            await MainActor.run { box.m.records.append(RemeasureFixture.record("/Volumes/T/new.mov", size: 1, card: nil)) }
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j)
        #expect(j.rowsAtStart == 1 && m.records.count == 2)
        #expect(SoundLevelsRemeasureJob.rowsClause(before: 1, after: 2, written: 1).hasPrefix("catalog rows before 1 · after 2 · difference +1"))
        #expect(SoundLevelsRemeasureJob.rowsClause(before: 5, after: 5, written: 0).contains("difference none"))
    }
}

// MARK: - Codex closing pass (3845c3ddd)

@MainActor
@Suite("GH #516 — re-measure sound levels: Codex closing pass (one synchronous commit per content)", .serialized)
struct SoundLevelsRemeasureClosingTests {

    /// A content's copies of the same bytes on catalog.sqlite, committed with `card`.
    private func copies(_ scene: CutoverScene, name: String, count: Int, seed: UInt64, card: (Int64) -> MediaReportCard) throws -> [UUID] {
        let media = scene.folder.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        let size = 24 * 1024
        let first = try MasterArchiveTestSupport.writeBlob(at: media.appendingPathComponent("\(name)0.mov"), bytes: size, seed: seed)
        let digest = try scene.sha256(first)
        var ids: [UUID] = []
        for k in 0..<count {
            let url = media.appendingPathComponent("\(name)\(k).mov")
            if k > 0 { try FileManager.default.copyItem(at: first, to: url) }
            let r = try scene.freshCopy(of: .healthy, path: url.path)
            r.sizeBytes = Int64(size)
            r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(size))
            r.mediaReportCard = card(Int64(size))
            scene.model.records.append(r)
            ids.append(r.id)
            try #require(scene.model.saveCatalogNow(), "fixture: stored")
        }
        return ids
    }

    private func freshCard(_ size: Int64) -> MediaReportCard {
        var c = RemeasureFixture.card(levels: [-12, -13], size: size, checkedAt: Date())
        c.soundLevels = .measured
        c.repairedCopy = MediaRepairLink(recordID: UUID(), path: "/Volumes/T/repaired.mov", repairedAt: Date(), fixes: ["balance"])
        return c
    }

    final class Box: @unchecked Sendable {
        var model: VideoScanModel
        var calls = 0
        var firstPath: String?
        init(_ m: VideoScanModel) { model = m }
    }

    @Test("P0-1 on catalog.sqlite: content D is rewritten and COMMITTED before the next content's await; Check Media's newer card on a copy of D, written during it, survives a relaunch on every copy")
    func secondDigestInterleaving() async throws {
        let scene = try CutoverScene.make("remeasure_close1"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let d = try copies(scene, name: "d", count: 2, seed: 101) { RemeasureFixture.preFixReconfiguredCard(size: $0) }
        let e = try copies(scene, name: "e", count: 2, seed: 202) { RemeasureFixture.preFixReconfiguredCard(size: $0) }
        let model = try await relaunchRemeasure(scene, from: scene.model)
        let box = Box(model)
        let size = try #require(model.record(forID: d[0])?.sizeBytes)
        let fresh = freshCard(size)
        let groups: [[UUID]] = [d, e]
        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.measure = { path, _ in
            let second = await MainActor.run { () -> Bool in box.calls += 1; if box.calls == 1 { box.firstPath = path }; return box.calls == 2 }
            if second {
                // Verify checks the FIRST content's other copy again, mid-run.
                await MainActor.run {
                    let firstGroup = groups.first { g in g.contains { box.model.record(forID: $0)?.fullPath == box.firstPath } } ?? []
                    // The copy a save visits FIRST (id order) — Codex's
                    // case: a batched save would then store the other copy's
                    // older card last.
                    let first = firstGroup.min { $0.uuidString < $1.uuidString }.flatMap { box.model.record(forID: $0) }
                    first?.mediaReportCard = fresh
                    _ = box.model.saveCatalogNow()
                }
            }
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j)
        let firstGroup = try #require(groups.first { g in g.contains { model.record(forID: $0)?.fullPath == box.firstPath } })
        let after = try await relaunchRemeasure(scene, from: model)
        for id in firstGroup {
            let card = try #require(after.record(forID: id)?.mediaReportCard)
            #expect(SoundLevelsRemeasureRules.sameCard(card, fresh), "copy \(id): Check Media's newer card was lost")
        }
        if let c = after.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P0-2 on catalog.sqlite: a copy added and saved while the stored card was being read (with a newer card) is found BY DIGEST at write time — nothing written; its card survives a relaunch")
    func copyAddedMidRead() async throws {
        let scene = try CutoverScene.make("remeasure_close2"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let d = try copies(scene, name: "m", count: 1, seed: 303) { RemeasureFixture.preFixReconfiguredCard(size: $0) }
        let model = try await relaunchRemeasure(scene, from: scene.model)
        let source = try #require(model.record(forID: d[0]))
        let size = source.sizeBytes
        let fresh = freshCard(size)
        let addedURL = URL(fileURLWithPath: source.fullPath).deletingLastPathComponent().appendingPathComponent("added.mov")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: source.fullPath), to: addedURL)
        let digest = try #require(CatalogCommit.digest(of: source))
        let box = Box(model)
        var addedID: UUID?
        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        j.storedCard = { dg in
            let snapshot = await SoundLevelsRemeasureJob.readStoredCard(box.model.catalogCutover.committer?.repository, digest: dg)
            // Meanwhile: a scan adds another copy of D and Verify checks it (newer card), saved.
            let added = VideoRecord()
            added.fullPath = addedURL.path
            added.filename = addedURL.lastPathComponent
            added.directory = addedURL.deletingLastPathComponent().path
            added.sizeBytes = size
            added.streamTypeRaw = StreamType.videoAndAudio.rawValue
            added.contentFixity = ContentFixity.captured(path: addedURL.path, digest: digest, byteCount: size)
            added.mediaReportCard = fresh
            box.model.records.append(added)
            addedID = added.id
            _ = box.model.saveCatalogNow()
            return snapshot   // the OLD snapshot
        }
        await RemeasureFixture.run(j)
        #expect(j.totals.cardsWritten == 0, Comment(rawValue: SoundLevelsRemeasureJob.summaryCounts(j.totals)))
        let after = try await relaunchRemeasure(scene, from: model)
        for id in d + [try #require(addedID)] {
            let card = try #require(after.record(forID: id)?.mediaReportCard)
            #expect(SoundLevelsRemeasureRules.sameCard(card, fresh), "copy \(id): the added copy's newer card was lost")
        }
        if let c = after.catalogCutover.committer { await c.repository.close() }
    }

    @Test("copies whose cards differ are left alone, counted and named in OUTCOME; a later Run simply tries again")
    func disagreeingCopiesNamedInOutcome() async throws {
        let dir = try RemeasureFixture.scratch("disagree"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        var fresh = RemeasureFixture.card(levels: [-12, -13], size: 1_000, checkedAt: Date())
        fresh.soundLevels = .measured
        let (a, b) = twoCopies(m, a: fresh, b: RemeasureFixture.preFixReconfiguredCard(size: 1_000))
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        if case .finished(let s) = j.state { #expect(s.contains("1 file left alone: their copies' cards differ"), "\(s)") }
        else { Issue.record("\(j.state)") }
        #expect(a.mediaReportCard == fresh && SoundLevelsRemeasureItem.plan(m.records).count == 1, "still a candidate for a later Run")
        // Once B is checked again (copies agree), a later Run has nothing to refuse.
        b.mediaReportCard = fresh
        #expect(RemeasureFixture.nothingOwed(m.records))
    }

    @Test("third pass P0-1 on catalog.sqlite: one copy's row is refused (a path collision), the other's card LANDS — memory is set to what the store holds, never blindly back to the old card; another save and a relaunch never bring the old levels back")
    func partialCommitMemoryEqualsStore() async throws {
        let scene = try CutoverScene.make("remeasure_partial"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let ids = try copies(scene, name: "p", count: 2, seed: 404) { RemeasureFixture.preFixReconfiguredCard(size: $0) }
        let model = try await relaunchRemeasure(scene, from: scene.model)
        let a = try #require(model.record(forID: ids[0])), b = try #require(model.record(forID: ids[1]))
        let digest = try #require(CatalogCommit.digest(of: a))
        // B's row can no longer be stored: its path now collides with A's live path.
        b.fullPath = a.fullPath
        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        guard case .failed(let words) = j.state else { Issue.record("\(j.state)"); return }
        #expect(words.contains("exactly the card catalog.sqlite holds") && words.contains("catalog rows before"), "\(words)")
        guard case .card(let stored) = await SoundLevelsRemeasureJob.readStoredCard(model.catalogCutover.committer?.repository, digest: digest) else {
            Issue.record("no stored card"); return
        }
        #expect(stored.soundLevels == .measured, "A's rewritten card landed")
        #expect(j.totals.cardsWritten == 2, "the copies whose rewritten card landed are counted (fourth pass P2): \(j.totals.cardsWritten)")
        for copy in [a, b] {
            let card = try #require(copy.mediaReportCard)
            #expect(SoundLevelsRemeasureRules.sameCard(card, stored), "memory equals the store")
        }
        _ = model.saveCatalogNow()   // another ordinary save
        let after = try await relaunchRemeasure(scene, from: model)
        for id in ids {
            let card = try #require(after.record(forID: id)?.mediaReportCard)
            #expect(RemeasureFixture.shownLevels(card).mediaInfo.isEmpty, "copy \(id): the old levels came back")
            #expect(card.soundLevels == .measured)
        }
        if let c = after.catalogCutover.committer { await c.repository.close() }
    }

    @Test("fourth/fifth pass P0 on catalog.sqlite: Check Media publishes a newer card on a copy DURING the recovery read-back — EVERY copy takes that newer card (one card per content), named in OUTCOME; it survives the refused copy becoming saveable, a save and a relaunch")
    func recoveryKeepsACardChangedMeanwhile() async throws {
        let scene = try CutoverScene.make("remeasure_recovery"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let ids = try copies(scene, name: "q", count: 2, seed: 505) { RemeasureFixture.preFixReconfiguredCard(size: $0) }
        let model = try await relaunchRemeasure(scene, from: scene.model)
        let a = try #require(model.record(forID: ids[0])), b = try #require(model.record(forID: ids[1]))
        let bPath = b.fullPath
        b.fullPath = a.fullPath   // B's row is refused: the commit returns false
        var fresh = freshCard(a.sizeBytes)
        fresh.checks.append(MediaCheck(kind: .black, verdict: .ok, sentence: "No black stretches."))
        let box = Box(model)
        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        j.storedCard = { digest in
            let snapshot = await SoundLevelsRemeasureJob.readStoredCard(box.model.catalogCutover.committer?.repository, digest: digest)
            box.calls += 1
            if box.calls == 2 {   // the recovery read-back: Verify checks A again meanwhile
                a.mediaReportCard = fresh
                box.model.saveCatalogDebounced()
            }
            return snapshot
        }
        await RemeasureFixture.run(j)
        #expect(box.calls == 2, "the pre-write check and the recovery read-back")
        #expect(a.mediaReportCard == fresh, "Check Media's newer card was overwritten by the recovery")
        #expect(b.mediaReportCard == fresh, "the refused copy holds the content's newer card too")
        guard case .failed(let words) = j.state else { Issue.record("\(j.state)"); return }
        #expect(words.contains("checked again meanwhile"), "\(words)")
        _ = model.saveCatalogNow()
        // Codex fifth pass: B becomes saveable again — it must not write an older card over A's.
        b.fullPath = bPath
        _ = model.saveCatalogNow()
        let after = try await relaunchRemeasure(scene, from: model)
        for id in ids {
            let reloaded = try #require(after.record(forID: id)?.mediaReportCard)
            #expect(SoundLevelsRemeasureRules.sameCard(reloaded, fresh), "copy \(id): after B is saveable again, save + relaunch, the newer card survives")
        }
        if let c = after.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P2-5: a content waiting for a drive is ready when ANY copy's drive is back")
    func anyCopyBackMakesItReady() throws {
        let dir = try RemeasureFixture.scratch("anycopy"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let withdrawn = SoundLevelsRemeasureRules.rewrite(RemeasureFixture.card(levels: [-20, -20], size: 1_000),
                                                          with: .notMeasured(.offline), context: VideoRecord().soundPresenceContext)
        let (a, b) = twoCopies(m, a: withdrawn, b: withdrawn)   // a on /Volumes/T, b on /Volumes/U
        let online: (String) -> Bool = { $0.hasPrefix("/Volumes/U") }
        #expect(SoundLevelsRemeasureItem.waiting(m.records, isOnline: online).ready == 1)
        _ = (a, b)
    }

    @Test("P2-6: a pass that ran but measured nothing (undecodable codec, no analysis) stays WITHDRAWN for a retry — never stamped measured")
    func unmeasurableStaysWithdrawn() {
        var shape = AudioVerifyShape()
        shape.videoCodec = "h264"
        shape.audioStreams = 1
        shape.audioCodec = "weird"
        let d = AudioVerifyDiagnosis(findings: [.unsupportedCodec(codec: "weird", decodable: false)], shape: shape, balanceAnalysis: nil)
        let r = SoundLevelsRemeasureRules.Remeasured.measured(d)
        #expect(SoundLevelsRemeasureRules.result(of: r).isWithdrawn)
        let card = SoundLevelsRemeasureRules.rewrite(RemeasureFixture.card(levels: [-20, -20], size: 1), with: r,
                                                     context: VideoRecord().soundPresenceContext)
        #expect(card.soundLevels == .withdrawn)
        #expect(SoundLevelsRemeasureRules.need(card, live: true) == .withdrawn)
        #expect(card.check(.sound)?.evidence.isEmpty == true)
    }
}

/// Quit and launch again on the same catalog.sqlite.
@MainActor
private func relaunchRemeasure(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
    if let committer = model.catalogCutover.committer { await committer.repository.close() }
    let sandbox = scene.sandbox
    let fresh = VideoScanModel(logDirectory: sandbox.logs)
    fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
    fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
    fresh.records = fresh.loadCatalogAtLaunch()
    try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
    return fresh
}

// MARK: - Scale

@MainActor
@Suite("GH #516 — re-measure sound levels (scale)")
struct SoundLevelsRemeasureScaleTests {

    @Test("the plan over 100k records (half with pre-fix cards) inside 3 s, Debug; the Tidy count agrees")
    func planAt100k() {
        let cutoff = Date()
        let pre = RemeasureFixture.card(levels: [-20, -21], size: 1)
        var post = RemeasureFixture.card(levels: [-20, -21], size: 1, checkedAt: cutoff.addingTimeInterval(1))
        post.soundLevels = .measured
        let records = (0..<100_000).map { i in
            RemeasureFixture.record("/Volumes/T/\(i).mov", size: 1, card: i.isMultiple(of: 2) ? pre : (i % 3 == 0 ? nil : post))
        }
        let clock = ContinuousClock()
        var plan: [SoundLevelsRemeasureItem] = []
        let elapsed = clock.measure { plan = SoundLevelsRemeasureItem.plan(records) }
        #expect(plan.count == 50_000)
        #expect(elapsed < .seconds(3), "plan took \(elapsed)")
        #expect(CatalogTidyCalculator.project(records, isOnline: { _ in true }).soundLevelsToRemeasure == 50_000)
    }
}

// MARK: - Isolation

@MainActor
@Suite("GH #516 — re-measure sound levels (isolation: poisoned state)", .serialized)
struct SoundLevelsRemeasureIsolationTests {

    @Test("Codex P0-2: nothing outside the card decides — finished work is not repeated (the stamp), a restored older catalog is found again")
    func theCardAloneDecides() async throws {
        let dir = try RemeasureFixture.scratch("cardalone"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = RemeasureFixture.record("/Volumes/T/c.mov", size: 1_000, card: RemeasureFixture.preFixReconfiguredCard(size: 1_000))
        m.records = [rec]
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.totals.reconfigured == 1)
        #expect(RemeasureFixture.nothingOwed(m.records))
        rec.mediaReportCard = RemeasureFixture.preFixReconfiguredCard(size: 1_000)   // a restored older catalog
        #expect(SoundLevelsRemeasureItem.plan(m.records).count == 1)
    }

    @Test("poisoned cards: a date in the future is measured too; odd evidence values are measured and replaced; a missing Sound row, a quick card and no card are skipped")
    func poisonedCards() async throws {
        let dir = try RemeasureFixture.scratch("poison"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let future = RemeasureFixture.record("/Volumes/T/future.mov", size: 1_000,
                                             card: RemeasureFixture.preFixReconfiguredCard(size: 1_000, checkedAt: Date().addingTimeInterval(86_400 * 400)))
        var oddCard = RemeasureFixture.card(levels: [-20, -20], size: 1_000)
        oddCard.checks = oddCard.checks.map { $0.kind == .sound ? MediaCheck(kind: .sound, verdict: .ok, sentence: "",
                                                                             evidence: [MediaEvidence("Left", "\u{0}garbage"), MediaEvidence("Right", "")]) : $0 }
        let odd = RemeasureFixture.record("/Volumes/T/odd.mov", size: 1_000, card: oddCard)
        var noSoundRow = RemeasureFixture.card(levels: [-20, -20], size: 1_000)
        noSoundRow.checks.removeAll { $0.kind == .sound }
        let missingRow = RemeasureFixture.record("/Volumes/T/norow.mov", size: 1_000, card: noSoundRow)
        let quickCard = RemeasureFixture.card(levels: [-20, -20], size: 1_000, tier: .quick)
        let quick = RemeasureFixture.record("/Volumes/T/quick.mov", size: 1_000, card: quickCard)
        let none = RemeasureFixture.record("/Volumes/T/none.mov", size: 1_000, card: nil)
        m.records = [future, odd, missingRow, quick, none]
        let measured = MeasuredPaths()
        let j = RemeasureFixture.job(m) { p, _ in await measured.add(p); return .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(Set(await measured.paths) == [future.fullPath, odd.fullPath])
        #expect(RemeasureFixture.shownLevels(future.mediaReportCard).mediaInfo.isEmpty)
        #expect(RemeasureFixture.shownLevels(odd.mediaReportCard).mediaInfo.isEmpty)
        #expect(missingRow.mediaReportCard == noSoundRow && quick.mediaReportCard == quickCard && none.mediaReportCard == nil)
    }
}

// MARK: - Media matrix

@MainActor
@Suite("GH #516 — re-measure sound levels (media matrix, real measurement)")
struct SoundLevelsRemeasureMediaMatrixTests {

    private static let fixtures: [(name: String, args: [String])] = {
        let v = ["-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=25"]
        let a = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000", "-ac", "2"]
        return [
            ("test_remeasure_h264.mp4", v + a + ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]),
            ("test_remeasure_prores.mov", v + a + ["-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
            ("test_remeasure_ffv1.mkv", v + a + ["-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            ("test_remeasure_mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x576:rate=25"] + a
                + ["-c:v", "mpeg2video", "-c:a", "pcm_s16le", "-ar", "48000"]),
            ("test_remeasure_dv.avi", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x480:rate=30000/1001"] + a
                + ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"]),
        ]
    }()

    @Test("five containers are measured again (today's levels kept); a rate-changing track keeps none; no file changes",
          .timeLimit(.minutes(5)))
    func everyContainer() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("remeasure_mm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        func size(_ p: String) throws -> Int64 { (try FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0 }
        for f in Self.fixtures {
            let path = dir.appendingPathComponent(f.name).path
            try CleanupTestMedia.runFFmpeg(f.args, output: path)
            m.records.append(RemeasureFixture.record(path, size: try size(path),
                                                     card: RemeasureFixture.card(levels: [-85, -77], size: try size(path))))
        }
        let nut = try ReconfiguredSoundFixture.make(into: dir, name: "test_remeasure_reconfig.nut",
                                                    first: (48_000, 2, 2), second: (96_000, 2, 6),
                                                    statesLength: false, secondSilent: true)
        let reconfigured = RemeasureFixture.record(nut, size: try size(nut),
                                                   card: RemeasureFixture.preFixReconfiguredCard(size: try size(nut)))
        m.records.append(reconfigured)
        let before = try m.records.map { try MediaFingerprint.of($0.fullPath) }
        let j = SoundLevelsRemeasureJob(model: m)
        j.commitForTesting = { _ in true }
        await RemeasureFixture.run(j)
        #expect(j.totals.refreshed == 5 && j.totals.reconfigured == 1, Comment(rawValue: SoundLevelsRemeasureJob.summaryCounts(j.totals)))
        for r in m.records where r.id != reconfigured.id {
            let levels = RemeasureFixture.shownLevels(r.mediaReportCard).mediaInfo
            #expect(levels.count == 2 && !levels.contains { $0.value.hasPrefix("-85") }, "\(r.filename): \(levels)")
        }
        #expect(RemeasureFixture.shownLevels(reconfigured.mediaReportCard).mediaInfo.isEmpty)
        #expect(try m.records.map { try MediaFingerprint.of($0.fullPath) } == before, "read-only on media")
    }
}

// MARK: - Sensors (source)

@Suite("GH #516 — re-measure sound levels Sensor (source)")
struct SoundLevelsRemeasureSensorTests {

    @Test("one rule, one engine, one door: the Sound row rule is Check Media's; only Tidy's Run starts the job (no unattended scheduler); no VideoScanModel extension")
    func shape() throws {
        let job = try SourceTree.appSource(named: "SoundLevelsRemeasureJob.swift")
        let rules = try SourceTree.appSource(named: "SoundLevelsRemeasure.swift")
        let full = try SourceTree.appSource(named: "CheckMediaRules+Full.swift")
        let tidy = try SourceTree.appSource(named: "CatalogTidy.swift")
        let app = try SourceTree.appSource(named: "VideoScanApp.swift")
        for src in [job, rules] {
            #expect(!src.contains("extension VideoScanModel"), "rule 12")
        }
        #expect(rules.contains("CheckMediaRules.soundRow(d)"), "the rewrite uses Check Media's own Sound row rule")
        #expect(full.contains("return soundRow(diagnosis)"), "Check Media's checkSound is the same rule")
        #expect(job.contains("VerifyAudioProbe.diagnose(path: path)"), "today's sound pass is Check Media's")
        #expect(job.contains("copy.mediaReportCard = new") && job.contains("committer.commitNow(ids: Set(ids))"),
                "writes only the card, committed per content through the committer's scoped synchronous door")
        #expect(tidy.contains("$0.startSoundLevelsRemeasure(model: model)"))
        #expect(!app.contains("SoundLevelsRemeasure") && !app.contains("soundLevelsRemeasure"), "nothing starts it at launch")
        #expect(!SourceTree.appSources.contains { $0.relative.hasSuffix("SoundLevelsRemeasureScheduler.swift") }, "the unattended scheduler is gone")
    }

    @Test("the withdrawn words are persisted on cards — pinned (a reworded lead would strand every withdrawn row)")
    func withdrawnLeadIsPinned() {
        #expect(SoundLevelsRemeasureRules.withdrawnLead
                == "the sound levels saved here came from an earlier version of VideoScan and are withdrawn until the sound can be measured again")
        #expect(MediaReportCard.SoundLevelsStamp.currentVersion == 2)
        #expect(SoundLevelsRemeasureRules.offlineWordsPinned == "its drive is not connected")
    }
}
