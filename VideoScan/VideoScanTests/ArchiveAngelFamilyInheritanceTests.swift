// ArchiveAngelFamilyInheritanceTests.swift
// S4 fixes (Manager 2026-09-23), written RED first against the S4 branch
// before the fix (only pre-existing API is used for the core assertions):
//
//   1. REGRESSION — Rick's hand-entered facts must keep flowing. The retired
//      Promote Helper stamped the copy family's best DATE, PLACE and backup
//      ATTESTATIONS onto the promoted records; the Angel must too — shown at
//      plan build (the row's proposed date is the inherited one) and
//      stamped at Promote, never over a record's own value.
//   2. An original whose `_balanced` companion already exists is NOT
//      balanced again: the prepare step reuses the catalogued copy.
//
// Media: real synthetic ffmpeg fixtures (test_ prefix) for the whole-job
// cases; 4 KB blobs for the Promote case (Promote copies bytes, it does not
// decode). Nothing touches Rick's media, buffer or catalog.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — family facts and the existing balanced copy (S4 fixes)", .serialized)
@MainActor
struct ArchiveAngelFamilyInheritanceTests {
    static let ffmpeg = ToolLocator.ffmpegPath

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let center: MediaFileOperationsCenter
        let buffer: URL
    }

    private func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    private func clip(_ name: String, in dir: URL) async throws -> URL {
        let url = dir.appendingPathComponent(name)
        let r = await ProcessRunner.runProcess(
            executable: Self.ffmpeg,
            arguments: ["-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "testsrc=size=320x240:rate=30:duration=4",
                        "-f", "lavfi", "-i", "sine=frequency=440:duration=4",
                        "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", url.path],
            deadlineSeconds: 120)
        try #require(r.exitCode == 0, "fixture \(name): \(r.stderr)")
        return url
    }

    private func run(_ b: Bench, pick: [VideoRecord], catalog: [VideoRecord]) async -> ArchiveAngelJob {
        b.model.records = catalog
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: pick.count, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: pick.map(\.id))
        job.start()
        await job.task?.value
        return job
    }

    // MARK: 1 — plan build

    @Test("RED→GREEN: a row with no date of its own proposes the date Rick typed on ANOTHER copy")
    func planBuildInheritsTheSiblingsDate() async throws {
        let b = try bench("inherit_plan"); defer { b.sb.cleanup() }
        let a = try await clip("test_inh_tape.mp4", in: b.sb.sources)
        let rec = MasterArchiveTestSupport.makeRecord(path: a.path, starRating: 2)   // NO date of its own
        rec.durationSeconds = 600; rec.videoCodec = "h264"; rec.audioCodec = "aac"; rec.isPlayable = "Yes"
        rec.contentHash = "v1:tape"
        let sibling = MasterArchiveTestSupport.makeRecord(path: "/Volumes/OldMyBook/test_inh_tape.mp4")
        sibling.contentHash = "v1:tape"                      // the same recording
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        let job = await run(b, pick: [rec], catalog: [rec, sibling])
        guard case .finished = job.state else { Issue.record("\(job.state) — \(job.plan.log.suffix(5))"); return }
        let entry = try #require(job.plan.entries.first)
        #expect(entry.proposedDate == "1987-06", "the sibling's hand-entered date: \(entry.proposedDate ?? "nil")")
        #expect(entry.proposedName.hasPrefix("1987-06"), "the proposed archive name follows it: \(entry.proposedName)")
        #expect(rec.userDate == nil, "plan build writes nothing to the record")
    }

    // MARK: 1 — promote

    private func promoteFixture(_ label: String) throws
        -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord, VideoRecord, ArchiveAngelPlan) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("tape.mov"), bytes: 4096, seed: 11)
        let model = MasterArchiveTestSupport.makeModel(sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path, starRating: 3)
        rec.contentHash = "v1:tape"
        let sibling = MasterArchiveTestSupport.makeRecord(path: "/Volumes/OldMyBook/Christmas copy.mov")
        sibling.contentHash = "v1:tape"
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        sibling.userPlace = "Cape Cod"; sibling.userPlaceConfidence = "known"
        sibling.backupAttestations = [BackupAttestation(kind: .offsite, answer: .yes,
                                                        attestedAt: Date(timeIntervalSince1970: 1_757_800_000))]
        model.records = [rec, sibling]
        var entry = ArchiveAngelPlan.Entry(
            id: rec.id, sourcePath: file.path, filename: "tape.mov", sizeBytes: 4096,
            sourceContentHash: "v1:tape", sourceModifiedAt: nil,
            durationSeconds: 600, score: 105, evidence: [], proposedName: "tape.mov",
            proposedDate: "1987-06", status: .ready)
        entry.selected = true
        var plan = ArchiveAngelPlan(batchDir: sb.root.appendingPathComponent("batch-inherit").path,
                                    requestedCount: 1, makeLossless: false, entries: [entry])
        plan.status = .ready
        return (sb, model, rec, sibling, plan)
    }

    @Test("RED→GREEN: Promote stamps the sibling's date, place and backup answers onto the promoted record — and the manifest carries them")
    func promoteStampsTheFamilyFacts() async throws {
        let (sb, model, rec, _, fixturePlan) = try promoteFixture("inherit_promote")
        var plan = fixturePlan
        defer { sb.cleanup() }
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: model, center: MediaFileOperationsCenter()) { _ in }
        #expect(job != nil, "\(plan.log)")
        #expect(rec.userDate == "1987-06" && rec.userDateConfidence == "known")
        #expect(rec.userPlace == "Cape Cod" && rec.userPlaceConfidence == "known")
        #expect(rec.backupAttestation(for: .offsite)?.answer == .yes)
        #expect(plan.log.contains { $0.contains("date 1987-06") && $0.contains("Christmas copy.mov") }, "\(plan.log)")
        await job?.task?.value
        let manifest = (try? String(contentsOf: sb.manifestURL, encoding: .utf8)) ?? ""
        #expect(manifest.contains("Cape Cod"), "the manifest row carries the inherited place")
    }

    @Test("NEGATIVE: a record's own hand-entered date and place are never overwritten by a sibling's")
    func ownValuesAreNeverOverwritten() async throws {
        let (sb, model, rec, _, fixturePlan) = try promoteFixture("inherit_own")
        var plan = fixturePlan
        defer { sb.cleanup() }
        rec.userDate = "1990"; rec.userDateConfidence = "estimated"
        rec.userPlace = "Montana"; rec.userPlaceConfidence = "estimated"
        plan.entries[0].proposedDate = "1990"
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let job = ArchiveAngelPromoter().promote(plan: &plan, model: model, center: MediaFileOperationsCenter()) { _ in }
        #expect(rec.userDate == "1990" && rec.userDateConfidence == "estimated", "own date kept")
        #expect(rec.userPlace == "Montana" && rec.userPlaceConfidence == "estimated", "own place kept")
        await job?.task?.value
    }

    // MARK: 2 — the existing balanced copy

    @Test("RED→GREEN: an original already balanced reuses its catalogued _balanced copy — no second balance",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable, "ffmpeg/ffprobe not available"))
    func anAlreadyBalancedOriginalReusesItsBalancedCopy() async throws {
        let b = try bench("reuse_balanced"); defer { b.sb.cleanup() }
        let path = try BalanceAudioTestMedia.generate(into: b.sb.sources, channelCase: .leftOnly, wrapper: .movH264Pcm)
        let rec = MasterArchiveTestSupport.makeRecord(path: path, userDate: "1995", starRating: 2)
        rec.durationSeconds = 600; rec.videoCodec = "h264"; rec.audioCodec = "pcm_s16le"; rec.isPlayable = "Yes"
        // The copy Balance Audio made earlier (from the Catalog / the Helper).
        let balancedURL = b.sb.sources.appendingPathComponent("test_balance_leftOnly_balanced.mov")
        _ = try await clip("test_reuse_tmp.mp4", in: b.sb.sources)
        try FileManager.default.moveItem(at: b.sb.sources.appendingPathComponent("test_reuse_tmp.mp4"), to: balancedURL)
        let balanced = MasterArchiveTestSupport.makeRecord(path: balancedURL.path, userDate: "1995")
        balanced.derivedFrom = rec.id
        balanced.derivationKind = BalanceAudioFix.derivationKind
        balanced.videoCodec = "h264"; balanced.audioCodec = "aac"; balanced.durationSeconds = 4; balanced.isPlayable = "Yes"

        let job = await run(b, pick: [rec], catalog: [rec, balanced])
        guard case .finished = job.state else { Issue.record("\(job.state) — \(job.plan.log.suffix(5))"); return }
        let entry = try #require(job.plan.entries.first)
        let step = try #require(entry.steps.first { $0.kind == .balanceAudio })
        #expect(step.note.contains("existing balanced copy"), "note: \(step.note)")
        #expect(step.recordID == balanced.id, "the reused copy is the companion")
        #expect(job.plan.log.contains { $0.contains("using existing balanced copy test_balance_leftOnly_balanced.mov") },
                "\(job.plan.log.suffix(8))")
        // No second balance: nothing named *_balanced.* was written in the buffer.
        let entryDir = URL(fileURLWithPath: job.plan.batchDir).appendingPathComponent(entry.id.uuidString)
        let made = (try? FileManager.default.contentsOfDirectory(atPath: entryDir.path)) ?? []
        #expect(!made.contains { $0.contains("_balanced") }, "buffer holds \(made)")
        #expect(b.model.records.filter { $0.derivationKind == BalanceAudioFix.derivationKind }.count == 1,
                "no second balanced record catalogued")
        #expect(FileManager.default.fileExists(atPath: balancedURL.path), "the existing copy is untouched")
    }
}
