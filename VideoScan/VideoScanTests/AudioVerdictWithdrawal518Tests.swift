// AudioVerdictWithdrawal518Tests.swift — GH #518 (DECISIONS 2026-11-25
// "re-measure, withdraw what the new code cannot stand behind"; 2026-11-27
// item 2, schema v1.16).
//
// Before 43641a32a / 33e10490e (Codex #368) a sound pass whose ffmpeg filter
// graph was rebuilt mid-stream was not recognised as incomplete, and Verify
// Audio / Check Media could store audioVerifyStatus "ok" for it. Today such a
// pass is "not checked" and stores nothing — but nothing cleared the "ok"
// stored earlier, and the #516 re-measure job rewrote only the card. Clearing
// it to "" would not hold either: the catalog.json value imported beside it
// (derived_unverified) comes back at the next load. So the stored "ok" is
// WITHDRAWN to "unverified" (a bound value that outranks the imported one)
// through the one writer, logged.
//
// These tests read only the stored strings, so the regression ones were run
// RED against the unfixed job/writer (the status stayed "ok"):
//   logic      re-measure withdraws "ok" on a rate-changing file (the
//              regression, in the issue's own words: neither ok nor levels);
//              every copy of the content; damaged / "" / a refreshed "ok"
//              untouched; Verify Audio's writer withdraws on a reconfigured
//              pass and only then;
//   writer     (rule 8) Check Media's fresh verdict written inside the run's
//              window is left alone; a read-only catalog (viewer / role flip)
//              changes nothing; relaunch on catalog.sqlite: an "ok" IMPORTED
//              from catalog.json, withdrawn, stays withdrawn across two
//              relaunches (the imported value never comes back).
// Gates and readers of the two new words: AudioStatusAttentionGateTests.swift.

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

@MainActor
@Suite("GH #518 — a pre-fix 'ok' is withdrawn when a re-measure or a new Verify finds the sound pass reconfigured", .serialized)
struct AudioVerdictWithdrawal518Tests {

    private static func okRecord(_ path: String, size: Int64 = 4_000) -> VideoRecord {
        let r = RemeasureFixture.record(path, size: size, card: RemeasureFixture.preFixReconfiguredCard(size: size))
        r.audioVerifyStatus = "ok"
        r.audioVerifyNote = ""
        r.audioVerifyDate = RemeasureFixture.dayAgo
        return r
    }

    @Test("REGRESSION #518: a record with status ok and a pre-fix card for a rate-changing file — after the re-measure it shows neither ok nor levels")
    func remeasureWithdrawsTheStaleOK() async throws {
        let dir = try RemeasureFixture.scratch("w518"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = Self.okRecord("/Volumes/Tapes/rate_change.nut")
        m.records = [rec]

        await RemeasureFixture.run(RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) })

        #expect(rec.audioVerifyStatus != "ok", "the pre-fix ok still stands")
        #expect(rec.audioVerifyStatus == "unverified")
        #expect(rec.audioVerifyNote.contains("not verified"), "\(rec.audioVerifyNote)")
        #expect(RemeasureFixture.shownLevels(rec.mediaReportCard).mediaInfo.isEmpty, "no levels either")
        #expect(rec.audioVerifyDate != RemeasureFixture.dayAgo, "the withdrawal is dated")
    }

    @Test("every copy of the content is withdrawn in the same step")
    func everyCopyIsWithdrawn() async throws {
        let dir = try RemeasureFixture.scratch("w518copies"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let digest = String(repeating: "5a", count: 32)
        let copies = ["/Volumes/A/t.mov", "/Volumes/B/t.mov"].map { path -> VideoRecord in
            let r = Self.okRecord(path)
            r.contentFixity = ContentFixity.captured(path: path, digest: digest, byteCount: 4_000)
            return r
        }
        m.records = copies
        await RemeasureFixture.run(RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) })
        #expect(copies.map(\.audioVerifyStatus) == ["unverified", "unverified"])
    }

    @Test("only an 'ok' is withdrawn: damaged, attention, never-verified stay as stored; a file whose sound did NOT change partway keeps its ok")
    func onlyAStaleOKIsWithdrawn() async throws {
        let dir = try RemeasureFixture.scratch("w518only"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let damaged = Self.okRecord("/Volumes/T/d.mov"); damaged.audioVerifyStatus = "damaged"
        let never = Self.okRecord("/Volumes/T/n.mov"); never.audioVerifyStatus = ""; never.audioVerifyDate = nil
        let attention = Self.okRecord("/Volumes/T/a.mov"); attention.audioVerifyStatus = "attention"
        m.records = [damaged, never, attention]
        await RemeasureFixture.run(RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) })
        #expect(damaged.audioVerifyStatus == "damaged")
        #expect(never.audioVerifyStatus == "")
        #expect(attention.audioVerifyStatus == "attention")

        let m2 = RemeasureFixture.model(dir.appendingPathComponent("two"))
        let steady = RemeasureFixture.record("/Volumes/T/s.mov", size: 1_000, card: RemeasureFixture.card(levels: [-20, -21], size: 1_000))
        steady.audioVerifyStatus = "ok"
        m2.records = [steady]
        await RemeasureFixture.run(RemeasureFixture.job(m2) { _, _ in .measured(RemeasureFixture.healthy(-19, -20)) })
        #expect(steady.audioVerifyStatus == "ok", "a measured, one-graph sound keeps its ok")
    }

    @Test("Verify Audio's one writer: a NOT-CHECKED pass that found the graph rebuilt withdraws a stored ok; any other not-checked pass leaves it")
    func verifyWriterWithdrawsOnlyOnAReconfiguredPass() throws {
        let reconfigured = RemeasureFixture.reconfigured()
        guard case .notChecked = reconfigured.verdict else { Issue.record("fixture: \(reconfigured.verdict)"); return }
        let r = VideoRecord()
        r.audioVerifyStatus = "ok"
        _ = VerifyAudioJob.write(reconfigured, onto: r, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(r.audioVerifyStatus == "unverified")

        // Not checked for another reason (the track was only partly measured): nothing moves.
        let partial = MasterArchiveTestSupport.soundDiagnosis(channels: [-20, nil])
        guard case .notChecked = partial.verdict else { Issue.record("fixture: \(partial.verdict)"); return }
        let kept = VideoRecord()
        kept.audioVerifyStatus = "ok"
        _ = VerifyAudioJob.write(partial, onto: kept, at: Date())
        #expect(kept.audioVerifyStatus == "ok")

        // A damaged verdict is never withdrawn by a reconfigured pass.
        let measured = VideoRecord()
        measured.audioVerifyStatus = "damaged"
        _ = VerifyAudioJob.write(reconfigured, onto: measured, at: Date())
        #expect(measured.audioVerifyStatus == "damaged")
    }

    @Test("WRITER: a fresh verdict Check Media stored during the run (inside the debounce window) is left alone — a new ok is never withdrawn")
    func aFreshVerdictWrittenMeanwhileIsLeftAlone() async throws {
        let dir = try RemeasureFixture.scratch("w518meanwhile"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = Self.okRecord("/Volumes/T/m.mov", size: 1_000)
        m.records = [rec]
        let fresh = RemeasureFixture.card(levels: [-12, -13], size: 1_000, checkedAt: Date())
        final class Box: @unchecked Sendable { let rec: VideoRecord; let model: VideoScanModel
            init(_ r: VideoRecord, _ m: VideoScanModel) { rec = r; model = m } }
        let box = Box(rec, m)
        let j = RemeasureFixture.job(m) { _, _ in
            await MainActor.run {
                box.rec.mediaReportCard = fresh
                box.rec.audioVerifyStatus = "ok"
                box.rec.audioVerifyDate = Date()
                box.model.saveCatalogDebounced()
            }
            return .measured(RemeasureFixture.reconfigured())
        }
        await RemeasureFixture.run(j)
        #expect(rec.mediaReportCard == fresh)
        #expect(rec.audioVerifyStatus == "ok", "today's measured ok stands")
    }

    @Test("WRITER: a read-only catalog (a viewer, or after a role flip) refuses the job — the stored ok is untouched")
    func aReadOnlyCatalogChangesNothing() async throws {
        let dir = try RemeasureFixture.scratch("w518ro"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = Self.okRecord("/Volumes/T/r.mov")
        m.records = [rec]
        m.isReadOnly = true
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.wasRefused)
        #expect(rec.audioVerifyStatus == "ok")
    }

    // MARK: Relaunch on catalog.sqlite — the imported ok never comes back

    /// The fixture's healthy row as catalog.json carries it: Verify Audio's
    /// "ok" and a pre-fix card. Re-certified so the import gate accepts it.
    private static func plantImportedOK(_ scene: CutoverScene) throws {
        let id = PoisonedCatalogFixture.id(.healthy)
        let tree = try JSONDecoder().decode(CatalogJSONValue.self, from: Data(contentsOf: scene.catalogURL))
        var top = try #require(tree.objectValue)
        var rows = try #require(top["records"]?.arrayValue).map { $0.objectValue ?? [:] }
        let i = try #require(rows.firstIndex { $0["id"]?.stringValue == id })
        let size = rows[i]["sizeBytes"]?.int64Value ?? 0
        let carrier = VideoRecord()
        carrier.mediaReportCard = RemeasureFixture.preFixReconfiguredCard(size: size)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let dto = try JSONDecoder().decode(CatalogJSONValue.self, from: encoder.encode(VideoRecordDTO(carrier)))
        rows[i]["mediaReportCard"] = try #require(dto["mediaReportCard"])
        rows[i]["audioVerifyStatus"] = .string("ok")
        rows[i]["audioVerifyNote"] = .string("")
        rows[i]["audioVerifyDate"] = .string("2026-09-01T00:00:00Z")
        top["records"] = .array(rows.map { .object($0) })
        let bytes = try CatalogJSONValue.makeEncoder().encode(CatalogJSONValue.object(top))
        try bytes.write(to: scene.catalogURL, options: .atomic)
        let report = PoisonedCatalogFixture.integrityReport(catalogSHA256: ImportGateFiles.sha256(of: bytes),
                                                            byteCount: Int64(bytes.count), rowCount: rows.count)
        try CatalogJSONValue.makeEncoder().encode(report)
            .write(to: scene.folder.appendingPathComponent(PoisonedCatalogFixture.integrityFileName), options: .atomic)
    }

    private static func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
        if let committer = model.catalogCutover.committer { await committer.repository.close() }
        let fresh = VideoScanModel(logDirectory: scene.sandbox.logs)
        fresh.catalogStore = CatalogStore(directory: scene.sandbox.catalogDir)
        fresh.mediaLedger = MediaLedger(directory: scene.sandbox.root.appendingPathComponent("ledger", isDirectory: true))
        fresh.records = fresh.loadCatalogAtLaunch()
        try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
        return fresh
    }

    @Test("RELAUNCH on catalog.sqlite: an ok IMPORTED from catalog.json, withdrawn by the re-measure through the real commit, reads 'unverified' after two relaunches — never ok again")
    func theImportedOKNeverComesBack() async throws {
        let scene = try CutoverScene.make("w518_relaunch"); defer { scene.cleanup() }
        try Self.plantImportedOK(scene)
        try await scene.launchOnSQLite()
        let id = PoisonedCatalogFixture.id(.healthy)
        let launched = try #require(scene.model.records.first { $0.id.uuidString == id })
        try #require(launched.audioVerifyStatus == "ok", "the import shows catalog.json's ok")

        let j = SoundLevelsRemeasureJob(model: scene.model)
        j.toolsAvailable = { true }
        j.isOnline = { _ in true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.savedCount >= 1 && !j.saveFailed, Comment(rawValue: j.summaryLine))

        var model = scene.model
        for n in 1...2 {
            model = try await Self.relaunch(scene, from: model)
            let r = try #require(model.records.first { $0.id.uuidString == id })
            #expect(r.audioVerifyStatus == "unverified", "relaunch \(n): \(r.audioVerifyStatus)")
            #expect(RemeasureFixture.shownLevels(r.mediaReportCard).mediaInfo.isEmpty, "relaunch \(n): levels")
        }
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }
}
