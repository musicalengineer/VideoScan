// ArchiveAngelSoundGateTests.swift
// Archive Angel cannot ask (Rick 2026-11-10): a silent or no-track file is
// not promoted and is reported as "Needs your OK: no sound". The Angel has no
// gate of its own — its Promote is the one PromoteToArchiveJob, so the one
// sound gate decides; `ArchiveAngelPromoter.settle` only chooses the words.
//
// The real promoter and the real job against a sandbox archive; the
// measurement is a canned diagnosis. Invariant I-6 (design §5): a refused
// row is never settled as promoted, keeps its buffer folder, and has the
// facts it inherited rolled back.
//
// RED before the gate was wired (2026-11-10): the refused rows were promoted.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Archive Angel — a file without usable sound needs your OK", .serialized)
@MainActor
struct ArchiveAngelSoundGateTests {

    typealias S = MasterArchiveTestSupport

    struct Bench {
        let sb: S.Sandbox
        let model: VideoScanModel
        let rec: VideoRecord
        let sibling: VideoRecord
        var plan: ArchiveAngelPlan
        var bufferFolder: URL { URL(fileURLWithPath: plan.batchDir).appendingPathComponent(rec.id.uuidString) }
    }

    /// One prepared, selected, ready row whose proven sibling carries a
    /// hand-entered date (so there is an inherited fact to roll back), with
    /// its buffer folder on disk.
    static func bench(_ label: String) throws -> Bench {
        let sb = try S.makeSandbox(label)
        let file = try S.writeBlob(at: sb.sources.appendingPathComponent("test_tape.mov"), bytes: 4096, seed: 71)
        let model = S.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let rec = S.makeRecord(path: file.path, starRating: 3)
        rec.contentHash = "v1:tape"
        let sibling = try AngelTestFixity.verifiedTwin(of: rec, named: "test_tape_copy.mov", in: sb.sources)
        sibling.userDate = "1987-06"; sibling.userDateConfidence = "known"
        model.records = [rec, sibling]
        var entry = ArchiveAngelPlan.Entry(
            id: rec.id, sourcePath: file.path, filename: "test_tape.mov", sizeBytes: 4096,
            sourceContentHash: "v1:tape", sourceModifiedAt: nil,
            durationSeconds: 600, score: 105, evidence: [], proposedName: "test_tape.mov",
            proposedDate: "1987-06", status: .ready)
        entry.selected = true
        var plan = ArchiveAngelPlan(batchDir: sb.root.appendingPathComponent("batch-sound").path,
                                    requestedCount: 1, makeLossless: false, entries: [entry])
        plan.status = .ready
        let bench = Bench(sb: sb, model: model, rec: rec, sibling: sibling, plan: plan)
        try FileManager.default.createDirectory(at: bench.bufferFolder, withIntermediateDirectories: true)
        try Data("companion".utf8).write(to: bench.bufferFolder.appendingPathComponent("test_tape.vs.archive.mov"))
        try S.initialize(model, in: sb)
        return bench
    }

    /// Promote the batch through the real promoter and wait for it to settle.
    static func promote(_ b: Bench, measure: PromoteSoundGate.Measure) async throws -> (job: PromoteToArchiveJob, settled: ArchiveAngelPlan) {
        var plan = b.plan
        var settled: ArchiveAngelPlan?
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: plan, catalog: b.model)
        let job = try #require(ArchiveAngelPromoter().promote(plan: &plan, model: b.model, center: MediaFileOperationsCenter(),
                                                              freshFixity: fresh) { settled = $0 },
                               "\(plan.log)")
        job.soundMeasure = measure
        await job.task?.value
        await job.completionTask?.value
        for _ in 0..<1_000 where settled == nil {
            await Task.yield(); try? await Task.sleep(for: .milliseconds(2))
        }
        return (job, try #require(settled, "the promoter settled the job"))
    }

    static func expectNotPromoted(_ b: Bench, _ settled: ArchiveAngelPlan, failurePrefix: String,
                                  sourceLocation: SourceLocation = #_sourceLocation) throws {
        let row = try #require(settled.entries.first, sourceLocation: sourceLocation)
        #expect(row.status != .promoted, "never settled as promoted", sourceLocation: sourceLocation)
        #expect(row.promotedRelPath == nil, sourceLocation: sourceLocation)
        #expect(row.failure?.hasPrefix(failurePrefix) == true, "\(row.failure ?? "nil")", sourceLocation: sourceLocation)
        #expect(b.model.masterArchiveCopy(of: b.rec) == nil, sourceLocation: sourceLocation)
        #expect(S.archivedFiles(b.sb).isEmpty, "\(S.archivedFiles(b.sb))", sourceLocation: sourceLocation)
        #expect(FileManager.default.fileExists(atPath: b.bufferFolder.path), "the row's buffer is kept", sourceLocation: sourceLocation)
        #expect(b.rec.userDate == nil, "the inherited date is rolled back: \(b.rec.userDate ?? "nil")", sourceLocation: sourceLocation)
        #expect(settled.report?.promotedOriginals == 0, sourceLocation: sourceLocation)
        #expect(settled.report?.failed == ["test_tape.mov"], sourceLocation: sourceLocation)
        #expect(settled.log.contains { $0.contains("test_tape.mov — \(failurePrefix)") }, "\(settled.log.suffix(4))",
                sourceLocation: sourceLocation)
    }

    @Test("REFUSED: a silent track is not promoted — the row reads 'Needs your OK: no sound', buffer kept, inherited date undone")
    func silentNeedsYourOK() async throws {
        let b = try Self.bench("angel_sg_silent"); defer { b.sb.cleanup() }
        let (job, settled) = try await Self.promote(b, measure: S.measure(S.soundDiagnosis(channels: [-68, -68])))
        #expect(job.outcomes.first?.refusalCode == "sound-silent")
        try Self.expectNotPromoted(b, settled, failurePrefix: "Needs your OK: no sound — Not promoted — the sound track is silent")
        // Durable: the words are in plan.json.
        let reloaded = try ArchiveAngelPlanStore.load(batchDir: settled.batchDir)
        #expect(reloaded.entries.first?.failure?.hasPrefix("Needs your OK: no sound") == true)
    }

    @Test("REFUSED: no audio track is not promoted — 'Needs your OK: no sound'")
    func noTrackNeedsYourOK() async throws {
        let b = try Self.bench("angel_sg_none"); defer { b.sb.cleanup() }
        let (_, settled) = try await Self.promote(b, measure: S.measure(S.soundDiagnosis(channels: [], audioStreams: 0)))
        try Self.expectNotPromoted(b, settled, failurePrefix: "Needs your OK: no sound — Not promoted — this file has no sound track")
    }

    @Test("REFUSED: damaged sound and could-not-check have their own words; neither is promoted")
    func damagedAndUnchecked() async throws {
        let damaged = try Self.bench("angel_sg_damaged"); defer { damaged.sb.cleanup() }
        let d = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.durationMismatch(audioSeconds: 2, videoSeconds: 10)])
        try Self.expectNotPromoted(damaged, try await Self.promote(damaged, measure: S.measure(d)).settled,
                                   failurePrefix: "Needs repair: sound damaged — ")
        let unchecked = try Self.bench("angel_sg_unchecked"); defer { unchecked.sb.cleanup() }
        let failing = S.measure(throwing: AudioVerifyProbeError.probeFailed("ffprobe exited with status 1"))
        try Self.expectNotPromoted(unchecked, try await Self.promote(unchecked, measure: failing).settled,
                                   failurePrefix: "Could not check the sound — ")
    }

    @Test("with the owner's “Silent — checked” tag the same silent row promotes")
    func taggedRowPromotes() async throws {
        let b = try Self.bench("angel_sg_tagged"); defer { b.sb.cleanup() }
        b.rec.tags = [WorkflowTags.silentChecked]
        let (job, settled) = try await Self.promote(b, measure: S.measure(S.soundDiagnosis(channels: [-68, -68])))
        #expect(job.outcomes.first?.kind == .promoted, "\(job.outcomes)")
        let row = try #require(settled.entries.first)
        #expect(row.status == .promoted && row.failure == nil && row.promotedRelPath != nil, "\(row.failure ?? "")")
        #expect(b.model.masterArchiveCopy(of: b.rec) != nil)
        #expect(settled.report?.promotedOriginals == 1)
    }

    @Test("a row with sound promotes exactly as before the gate")
    func soundPromotes() async throws {
        let b = try Self.bench("angel_sg_sound"); defer { b.sb.cleanup() }
        let (_, settled) = try await Self.promote(b, measure: S.soundPresent)
        #expect(settled.entries.first?.status == .promoted)
        #expect(b.rec.userDate == "1987-06", "the inherited date stays on a row that landed")
    }

    @Test("every Angel promote goes through the one job: the promoter has no archive write of its own")
    func theAngelHasNoSecondDoor() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveAngel/Promote/ArchiveAngelPromoter.swift"), encoding: .utf8)
        #expect(source.contains("center.startPromote(plan: promotePlan, model: model)"))
        for forbidden in ["ArchivePromoteEngine.", "ArchiveManifestCSV.append", "registerPromotedCopy(", "PromoteToArchiveJob(plan:"] {
            #expect(!source.contains(forbidden), "the Angel promoter must not \(forbidden) — that would skip the sound gate")
        }
    }
}
