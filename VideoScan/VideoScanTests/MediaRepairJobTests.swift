import Darwin
import Foundation
import Testing
@testable import VideoScan

// MARK: - MediaRepairJobTests (Rick 2026-10-08)
//
// The MFO row around the engine: each outcome becomes the matching row
// state (never "finished" unless the copy was published and proved), the
// bookkeeping happens ONLY after a repair, the original's file is never
// written in any outcome, one dispatch per file. Synthetic fixtures in
// temp dirs (RepairFixtures, MediaRepairEngineTests.swift). The model's
// shared catalog store is inert under the test host (CatalogStore guard).

@Suite(.serialized, .timeLimit(.minutes(3))) @MainActor
struct MediaRepairJobTests {

    typealias F = RepairFixtures

    static func record(for url: URL, card: MediaReportCard?) -> VideoRecord {
        let r = VideoRecord()
        r.filename = url.lastPathComponent
        r.fullPath = url.path
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension.lowercased()
        r.sizeBytes = F.size(url)
        r.durationSeconds = 2
        r.mediaReportCard = card
        return r
    }

    /// A quick card whose Layout row is a Problem (the Brockton class).
    static func layoutProblemCard(size: Int64) -> MediaReportCard {
        MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: size,
                        headline: "Sound and picture are stored far apart.",
                        checks: [MediaCheck(kind: .layout, verdict: .problem,
                                            sentence: "All the sound is stored at the end of the file.")])
    }

    static func waitForEnd(_ job: MediaRepairJob) async {
        await job.task?.value
        for _ in 0..<200 where job.state.isActive { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    @Test func success_catalogsCopy_linksOriginal_finished_originalUnchanged() async throws {
        let dir = try F.makeDir("job_success")
        let src = try F.make(.mp4H264, in: dir)
        let before = try F.sha256(src)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: Self.layoutProblemCard(size: F.size(src)))
        model.records.append(rec)
        let center = MediaFileOperationsCenter()
        let out = F.repairedURL(for: src)
        let job = center.startRepair(record: rec, fixes: [.remux], output: out, besideOriginal: true, model: model)
        await Self.waitForEnd(job)

        guard case .finished(let summary) = job.state else { Issue.record("expected finished, got \(job.state)"); return }
        #expect(summary.contains(MediaRepairEngine.verificationLevel))
        #expect(!summary.lowercased().contains("fully verified"))
        #expect(summary.contains("The original is untouched"))
        let copy = try #require(model.records.first { $0.fullPath == out.path })
        #expect(copy.derivedFrom == rec.id)
        #expect(copy.derivationKind == MediaRepairJob.derivationKind)
        #expect(!copy.isAwaitingConfirmation)   // not a repair-lifecycle copy
        #expect(copy.mediaReportCard != nil)
        #expect(rec.mediaReportCard?.repairedCopy?.path == out.path)
        #expect(rec.mediaReportCard?.repairedCopy?.recordID == copy.id)
        #expect(job.comparison != nil)
        #expect(try F.sha256(src) == before)
    }

    @Test func refused_targetTaken_rowSaysNotStarted_noBookkeeping() async throws {
        let dir = try F.makeDir("job_refused")
        let src = try F.make(.mp4H264, in: dir)
        let out = F.repairedURL(for: src)
        try Data("already here".utf8).write(to: out)
        let before = try F.sha256(src)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: Self.layoutProblemCard(size: F.size(src)))
        model.records.append(rec)
        let job = MediaFileOperationsCenter().startRepair(record: rec, fixes: [.remux], output: out,
                                                          besideOriginal: true, model: model)
        await Self.waitForEnd(job)
        guard case .failed(let message) = job.state else { Issue.record("expected failed, got \(job.state)"); return }
        #expect(job.wasRefused)
        #expect(message.hasPrefix("Not started"))
        #expect(model.records.count == 1)
        #expect(rec.mediaReportCard?.repairedCopy == nil)
        #expect(try String(contentsOf: out, encoding: .utf8) == "already here")
        #expect(try F.sha256(src) == before)
    }

    @Test func failed_rowSaysOriginalUntouched_andWhereTheCopyWasKept() async throws {
        let dir = try F.makeDir("job_failed")
        let src = try F.make(.mp4H264, in: dir)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: nil)
        model.records.append(rec)
        let kept = dir.appendingPathComponent("test_clip_repaired.abcd1234.vs-kept.mp4")
        let job = MediaFileOperationsCenter().startRepair(
            record: rec, fixes: [.remux], output: F.repairedURL(for: src), besideOriginal: true, model: model,
            runner: { _, _, _ in .failed(reason: "ffmpeg stopped with status 1.", keptAt: kept) })
        await Self.waitForEnd(job)
        guard case .failed(let message) = job.state else { Issue.record("expected failed, got \(job.state)"); return }
        #expect(!job.wasRefused)
        #expect(message.contains("The original is untouched"))
        #expect(message.contains(kept.path))
        #expect(model.records.count == 1)
        #expect(rec.mediaReportCard?.repairedCopy == nil)
    }

    @Test func cancelled_rowSaysStopped_noBookkeeping() async throws {
        let dir = try F.makeDir("job_cancel")
        let src = try F.make(.mp4H264, in: dir)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: nil)
        model.records.append(rec)
        let job = MediaFileOperationsCenter().startRepair(
            record: rec, fixes: [.remux], output: F.repairedURL(for: src), besideOriginal: true, model: model,
            runner: { _, _, _ in
                while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
                return .cancelled
            })
        try await Task.sleep(nanoseconds: 200_000_000)
        job.cancel()
        await Self.waitForEnd(job)
        #expect(job.state == .cancelled)
        #expect(model.records.count == 1)
    }

    @Test func secondDispatchForTheSameFile_isRefused() async throws {
        let dir = try F.makeDir("job_dup")
        let src = try F.make(.mp4H264, in: dir)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: nil)
        model.records.append(rec)
        let center = MediaFileOperationsCenter()
        let slow: MediaRepairJob.Runner = { _, _, _ in
            while !Task.isCancelled { try? await Task.sleep(nanoseconds: 20_000_000) }
            return .cancelled
        }
        let first = center.startRepair(record: rec, fixes: [.remux], output: F.repairedURL(for: src),
                                       besideOriginal: true, model: model, runner: slow)
        let second = center.startRepair(record: rec, fixes: [.remux], output: F.repairedURL(for: src),
                                        besideOriginal: true, model: model, runner: slow)
        #expect(second.wasRefused)
        #expect(first.state.isActive)
        first.cancel()
        await Self.waitForEnd(first)
    }

    /// The request is built from the model's gate: a protected output path
    /// carries the gate's sentence, and the engine then refuses.
    @Test func requestCarriesTheRecipeInOrder_andNoProtectionForATempFolder() async throws {
        let dir = try F.makeDir("job_request")
        let src = try F.make(.mp4H264, in: dir)
        let model = VideoScanModel()
        let rec = Self.record(for: src, card: nil)
        let req = MediaFileOperationsCenter().repairRequest(record: rec, fixes: [.remux, .removeRepeatedFrames],
                                                            output: F.repairedURL(for: src), model: model)
        #expect(req.recipe.applied == [.removeRepeatedFrames, .remux])
        #expect(req.outputProtectionNote == nil)
    }

    @Test func progressNeverRunsBackwards_andTheWriteDominates() {
        let steps = ["a", MediaRepairPhase.write.step, "c", "d", MediaRepairJob.verifyStep]
        var last = -1.0
        for (i, within) in [(0, nil), (1, 0.0), (1, 0.5), (1, 1.0), (2, nil), (3, nil), (4, nil)] as [(Int, Double?)] {
            let f = MediaRepairJob.overallFraction(steps: steps, index: i, within: within)
            #expect(f >= last)
            last = f
        }
        #expect(MediaRepairJob.overallFraction(steps: steps, index: 1, within: 1) > 0.85)
    }

    /// A sound fix can't be judged by the quick Verify: the comparison must
    /// not claim it fixed (it says "not re-checked yet").
    @Test func comparisonNeverClaimsAFixItCouldNotRecheck() {
        let before = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1, headline: "",
                                     checks: [MediaCheck(kind: .sound, verdict: .problem, sentence: "Damaged sound.")])
        let after = MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: 1, headline: "",
                                    checks: [.notRun(.sound, because: "quick check only")])
        let c = MediaRepairComparison(before: before, after: after, applied: [.rebuildAudio],
                                      outputName: "x_repaired.mov", besideOriginal: true)
        #expect(!c.isFullyRepaired)
        #expect(c.notRecheckedCount == 1)
        #expect(!c.headline.contains("fixed"))
        #expect(c.headline.contains("not re-checked yet"))
    }
}

// MARK: - The sheet's plan (pure)

@Suite struct MediaRepairSelectionTests {

    private let offers = [
        MediaRepairOffer(fix: .removeRepeatedFrames, answers: .distinctFrames, unavailableReason: nil),
        MediaRepairOffer(fix: .rebuildAudio, answers: .sound, unavailableReason: "no sound measurement"),
        MediaRepairOffer(fix: .remux, answers: nil, unavailableReason: nil),
    ]

    @Test func startsAtTheRecommendation_andCanBeChanged() {
        var sel = MediaRepairSelection(offers: offers)
        #expect(sel.chosen == [.removeRepeatedFrames])
        #expect(sel.isRecommendation)
        sel.set(.remux, on: true)
        #expect(sel.isOn(.remux))
        #expect(!sel.isRecommendation)
        sel.set(.removeRepeatedFrames, on: false)
        #expect(sel.recipe(balance: nil).applied == [.remux])
    }

    @Test func anUnavailableFixCannotBeTicked() {
        var sel = MediaRepairSelection(offers: offers)
        sel.set(.rebuildAudio, on: true)
        #expect(!sel.isOn(.rebuildAudio))
    }

    @Test func streamLinesSayCopiedOrReencoded_andTheVerificationLevel() {
        let lossless = MediaRepairSelection.streamLines(MediaRepairRecipe(fixes: [.remux], balance: nil), picture: nil)
        #expect(lossless.contains { $0.hasPrefix("Picture: copied exactly") })
        #expect(lossless.contains { $0.contains("packet for packet") })
        #expect(lossless.last == "Checked afterwards: \(MediaRepairEngine.verificationLevel).")
        let frames = MediaRepairSelection.streamLines(MediaRepairRecipe(fixes: [.removeRepeatedFrames], balance: nil), picture: nil)
        #expect(frames.contains { $0.hasPrefix("Picture: re-encoded") && $0.contains("shorter") })
        #expect(MediaRepairSelection.streamLines(MediaRepairRecipe(fixes: [], balance: nil), picture: nil).isEmpty)
    }

    /// "More repairs" lists every fix, each with a reason when it can't be
    /// used; removing repeated frames is never offered unless Verify found
    /// them (it would cut real stills from a file that plays properly).
    @Test func moreRepairsListsEveryFix_withHonestAvailability() {
        let clean = MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: 1, headline: "",
                                    checks: [MediaCheck(kind: .layout, verdict: .ok, sentence: "fine")])
        let all = MediaRepairPlan.allOffers(for: clean, sound: MediaRepairSoundFacts(), hasPicture: true, hasSound: true)
        #expect(Set(all.map(\.fix)) == Set(MediaRepairFix.allCases))
        let byFix = Dictionary(uniqueKeysWithValues: all.map { ($0.fix, $0) })
        #expect(byFix[.remux]?.isAvailable == true)
        #expect(byFix[.rebuildAudio]?.isAvailable == true)
        #expect(byFix[.balanceAudio]?.unavailableReason?.contains("measures each sound channel") == true)
        #expect(byFix[.removeRepeatedFrames]?.unavailableReason?.contains("real still") == true)
        #expect(MediaRepairSelection(offers: all).chosen.isEmpty, "nothing earned, nothing ticked")
        let silent = MediaRepairPlan.allOffers(for: nil, sound: MediaRepairSoundFacts(), hasPicture: true, hasSound: false)
        #expect(silent.first { $0.fix == .rebuildAudio }?.unavailableReason == "This file has no sound.")
    }

    /// Repair means "play properly" (Rick 2026-10-08): no Repair wording
    /// promises to improve or enhance, or claims a full verification.
    @Test func repairWordingNeverSaysImproveOrEnhance() {
        var text: [String] = MediaRepairFix.allCases.flatMap { [$0.title, $0.explanation] }
        let all = MediaRepairRecipe(fixes: MediaRepairFix.allCases, balance: nil)
        text += all.stepLines + MediaRepairSelection.streamLines(all, picture: nil)
        text += MediaRepairRecipe.order.map { MediaRepairAdvice.fixLine(MediaRepairRecipe(fixes: [$0], balance: nil)) }
        for line in text {
            let lower = line.lowercased()
            #expect(!lower.contains("improv") && !lower.contains("enhanc") && !lower.contains("fully verified"), "\(line)")
        }
    }
}

// MARK: - The sheet's plan-time count: cancellable, cached, with progress

@Suite(.serialized, .timeLimit(.minutes(2))) @MainActor
struct MediaRepairPlanTimeCountTests {

    typealias F = RepairFixtures

    final class Seen: @unchecked Sendable {
        var values: [Double] = []
    }

    /// Closing the sheet cancels its task; the counting ffmpeg must die.
    @Test func cancellingTheCountKillsFFmpeg() async throws {
        let dir = try F.makeDir("count_cancel")
        let pidFile = dir.appendingPathComponent("test_pid")
        let fake = try F.fakeFFmpeg(in: dir, body: "echo $$ > '\(pidFile.path)'\nexec sleep 30")
        let task = Task { try await MediaRepairProbe.keptFrameCount(path: "/dev/null", control: nil, ffmpegPath: fake) }
        var pid: pid_t = 0
        for _ in 0..<100 {
            if let text = try? String(contentsOf: pidFile, encoding: .utf8),
               let p = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) { pid = p; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(pid > 0)
        #expect(kill(pid, 0) == 0, "ffmpeg stand-in is running")
        task.cancel()
        _ = try? await task.value
        var gone = false
        for _ in 0..<200 {
            if kill(pid, 0) != 0 { gone = true; break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(gone, "cancel must kill the counting process")
    }

    /// Reopening the sheet uses this session's count — no second decode
    /// (a failing ffmpeg proves none ran).
    @Test func cachedCountSkipsTheDecode() async throws {
        let dir = try F.makeDir("count_cache")
        let src = try MediaRepairEngineTests.makeRepeatedWithSound(in: dir, soundSeconds: 12)
        let failing = try F.fakeFFmpeg(in: dir, body: "exit 1")
        let cache = MediaRepairKeptFrameCache()
        let key = MediaRepairKeptFrameCache.Key(recordID: UUID(), sizeBytes: F.size(src))
        let cold = await MediaRepairSheet.planPicture(path: src.path, durationSeconds: 60, cacheKey: key, cache: cache,
                                                      ffmpegPath: failing, onChecking: { _ in })
        guard case .refused = cold else { Issue.record("no cache + failing ffmpeg must not be ready: \(cold)"); return }
        cache.store(360, for: key)
        let warm = await MediaRepairSheet.planPicture(path: src.path, durationSeconds: 60, cacheKey: key, cache: cache,
                                                      ffmpegPath: failing, onChecking: { _ in Issue.record("no check expected") })
        guard case .ready(_, let kept) = warm else { Issue.record("cached count must be ready: \(warm)"); return }
        #expect(kept == 360)
        // A changed file (different size) is a different key: counted again.
        #expect(cache.count(for: .init(recordID: key.recordID, sizeBytes: key.sizeBytes + 1)) == nil)
    }

    /// The count reports real progress (out_time over the duration) and
    /// stores its answer for the session.
    @Test func countReportsProgressAndIsCached() async throws {
        let dir = try F.makeDir("count_progress")
        let src = try MediaRepairEngineTests.makeRepeatedWithSound(in: dir, soundSeconds: 12)
        let cache = MediaRepairKeptFrameCache()
        let key = MediaRepairKeptFrameCache.Key(recordID: UUID(), sizeBytes: F.size(src))
        let seen = Seen()
        let result = await MediaRepairSheet.planPicture(path: src.path, durationSeconds: 60, cacheKey: key, cache: cache,
                                                        onChecking: { seen.values.append($0) })
        guard case .ready(_, let kept) = result else { Issue.record("expected ready: \(result)"); return }
        #expect(kept == cache.count(for: key))
        #expect(seen.values.first == 0)
        #expect(seen.values.allSatisfy { (0...1).contains($0) })
    }

    /// A file without sound never decodes (nothing to line up).
    @Test func videoOnlyNeverCounts() async throws {
        let dir = try F.makeDir("count_videoonly")
        let src = dir.appendingPathComponent("test_silent.mov")
        try F.ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=4:size=160x120:rate=6", "-vf", "fps=30",
                      "-c:v", "mjpeg", "-an", src.path])
        let failing = try F.fakeFFmpeg(in: dir, body: "exit 1")
        let result = await MediaRepairSheet.planPicture(
            path: src.path, durationSeconds: 4,
            cacheKey: .init(recordID: UUID(), sizeBytes: 1), cache: MediaRepairKeptFrameCache(),
            ffmpegPath: failing, onChecking: { _ in Issue.record("no check for a silent file") })
        guard case .ready(_, let kept) = result else { Issue.record("expected ready: \(result)"); return }
        #expect(kept == nil)
    }
}
