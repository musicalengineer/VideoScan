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
//   round 2   (Codex 2026-11-27, three P1s — the verdict is stored per
//              CONTENT, the withdrawal acted per copy), each through the
//              production SQL path and a relaunch, RED against ab7d46f54:
//              P1-1 re-measure on [A damaged, B ok] (store damaged) keeps the
//              damage on both; P1-2 Verify Audio / Check Media on A withdraw
//              B too, so B's star-rating save cannot write "ok" back; P1-3 a
//              card v16 already re-measured ("changes partway", stamped) with
//              its "ok" left is planned, counted by Tidy, and withdrawn.
//              The content step itself (AudioVerdictWithdrawal.decide): unit
//              cases below (new API — feature tests, no red).
// Gates and readers of the two new words: AudioStatusAttentionGateTests.swift.

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

@MainActor
@Suite("GH #518 — a pre-fix 'ok' is withdrawn when a re-measure or a new Verify finds the sound pass reconfigured", .serialized)
struct AudioVerdictWithdrawal518Tests {

    /// A whole-file fixity for `digest` at `size` (no file needed — the
    /// `captured` form stats the path and is nil for a file that is not there).
    private static func fixity(_ digest: String, size: Int64) -> ContentFixity {
        ContentFixity(digest: digest, byteCount: size,
                      stamp: FileIdentityStamp(device: 1, inode: 9, size: size, mtimeNs: 3, ctimeNs: 4, volumeUUID: nil))
    }

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
            r.contentFixity = Self.fixity(digest, size: 4_000)
            return r
        }
        try #require(CatalogCommit.digest(of: copies[0]) == digest && CatalogCommit.digest(of: copies[1]) == digest,
                     "one content, two copies")
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
        _ = VerifyAudioJob.write(reconfigured, onto: r, copies: [r], stored: .none, at: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(r.audioVerifyStatus == "unverified")

        // Not checked for another reason (the track was only partly measured): nothing moves.
        let partial = MasterArchiveTestSupport.soundDiagnosis(channels: [-20, nil])
        guard case .notChecked = partial.verdict else { Issue.record("fixture: \(partial.verdict)"); return }
        let kept = VideoRecord()
        kept.audioVerifyStatus = "ok"
        _ = VerifyAudioJob.write(partial, onto: kept, copies: [kept], stored: .none, at: Date())
        #expect(kept.audioVerifyStatus == "ok")

        // A damaged verdict is never withdrawn by a reconfigured pass.
        let measured = VideoRecord()
        measured.audioVerifyStatus = "damaged"
        _ = VerifyAudioJob.write(reconfigured, onto: measured, copies: [measured], stored: .none, at: Date())
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

    // MARK: Round 2 — the withdrawal is a CONTENT decision (Codex 2026-11-27)

    /// The two fixture rows that are copies of one content (one digest).
    private static func twoCopies(_ model: VideoScanModel) throws -> (VideoRecord, VideoRecord) {
        let a = try #require(model.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.curatedConflictA) })
        let b = try #require(model.records.first { $0.id.uuidString == PoisonedCatalogFixture.id(.curatedConflictB) })
        try #require(CatalogCommit.digest(of: a) != nil && CatalogCommit.digest(of: a) == CatalogCommit.digest(of: b),
                     "the fixture's two copies share one digest")
        return (a, b)
    }

    private static func setOK(_ r: VideoRecord, card: MediaReportCard?) {
        r.mediaReportCard = card
        r.audioVerifyStatus = "ok"
        r.audioVerifyNote = ""
        r.audioVerifyDate = RemeasureFixture.dayAgo
    }

    /// Both copies "ok" with `card`, committed, then a relaunch: memory is
    /// exactly what catalog.sqlite holds.
    private static func launchedWithOKCopies(_ scene: CutoverScene, card: (VideoRecord) -> MediaReportCard?) async throws -> VideoScanModel {
        try await scene.launchOnSQLite()
        let (a, b) = try Self.twoCopies(scene.model)
        Self.setOK(a, card: card(a))
        Self.setOK(b, card: card(b))
        try #require(scene.model.saveCatalogNow())
        return try await Self.relaunch(scene, from: scene.model)
    }

    @Test("REGRESSION round 2 P1-1: re-measure on copies [A damaged, B ok] with the store holding damaged keeps the damage on both — after relaunch neither is 'unverified'")
    func remeasureNeverWithdrawsOverMeasuredDamage() async throws {
        let scene = try CutoverScene.make("w518_r2_damage"); defer { scene.cleanup() }
        var model = try await Self.launchedWithOKCopies(scene) { RemeasureFixture.preFixReconfiguredCard(size: $0.sizeBytes) }
        let (a, b) = try Self.twoCopies(model)
        // A is measured damaged and saved; B still holds the stale "ok" in memory.
        a.audioVerifyStatus = "damaged"
        a.audioVerifyNote = "Damaged audio: the sound is far shorter than the picture"
        a.audioVerifyDate = Date()
        try #require(model.saveCatalogNow())
        try #require(b.audioVerifyStatus == "ok", "Codex's input: B still shows ok")
        try #require(model.records.firstIndex { $0 === a }! < model.records.firstIndex { $0 === b }!, "order [A, B]")

        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.isOnline = { _ in true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(j.totals.reconfigured == 1 && !j.saveFailed, Comment(rawValue: j.summaryLine))
        #expect(j.totals.cardsWritten == 2, "both copies' cards were rewritten: \(j.summaryLine)")

        model = try await Self.relaunch(scene, from: model)
        let (a2, b2) = try Self.twoCopies(model)
        #expect(a2.audioVerifyStatus == "damaged", "A after relaunch: \(a2.audioVerifyStatus)")
        #expect(b2.audioVerifyStatus == "damaged", "B after relaunch: \(b2.audioVerifyStatus)")
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    @Test("REGRESSION round 2 P1-2: Verify Audio on copy A (reconfigured pass) withdraws B too — B's later star-rating save cannot write 'ok' back; both 'unverified' after relaunch")
    func verifyAudioWithdrawsEveryCopy() async throws {
        let scene = try CutoverScene.make("w518_r2_verify"); defer { scene.cleanup() }
        var model = try await Self.launchedWithOKCopies(scene) { _ in nil }
        let (a, b) = try Self.twoCopies(model)

        let job = VerifyAudioJob(record: a, model: model, diagnoseOverride: { _ in RemeasureFixture.reconfigured() })
        job.start()
        await job.task?.value
        try #require(model.saveCatalogNow())
        #expect(a.audioVerifyStatus == "unverified")
        #expect(b.audioVerifyStatus == "unverified", "B withdrawn in the same step: \(b.audioVerifyStatus)")

        b.starRating = 1   // an unrelated edit on B, saved (the store takes 1–3)
        try #require(model.saveCatalogNow())

        model = try await Self.relaunch(scene, from: model)
        let (a2, b2) = try Self.twoCopies(model)
        #expect(a2.audioVerifyStatus == "unverified", "A after relaunch: \(a2.audioVerifyStatus)")
        #expect(b2.audioVerifyStatus == "unverified", "B after relaunch: \(b2.audioVerifyStatus)")
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    @Test("REGRESSION round 2 P1-2: Check Media (full) on copy A with a reconfigured sound pass withdraws B too — B's star-rating save cannot resurrect 'ok'")
    func checkMediaWithdrawsEveryCopy() async throws {
        let scene = try CutoverScene.make("w518_r2_check"); defer { scene.cleanup() }
        var model = try await Self.launchedWithOKCopies(scene) { _ in nil }
        let (a, b) = try Self.twoCopies(model)

        let quick = try CheckMediaFixtures.healthy()
        let video = VideoVerifyDiagnosis(findings: [], facts: quick.videoFacts, sample: nil,
                                         decode: VideoDecodeFacts(coverage: .complete))
        let audio = RemeasureFixture.reconfigured()
        let job = CheckMediaJob(records: [a], tier: .full, model: model, center: nil,
                                quickRunner: { _, _ in .measured(quick) },
                                fullRunner: { _, _, _, _ in
                                    CheckMediaFullInputs(video: .success(video), audio: .success(audio),
                                                         signals: MediaSignalScan(progressive: 900))
                                },
                                soundAdviceLookup: { _ in .none })
        job.start()
        await job.task?.value
        try #require(model.saveCatalogNow())
        #expect(a.audioVerifyStatus == "unverified")
        #expect(b.audioVerifyStatus == "unverified", "B withdrawn in the same step: \(b.audioVerifyStatus)")

        b.starRating = 1
        try #require(model.saveCatalogNow())

        model = try await Self.relaunch(scene, from: model)
        let (a2, b2) = try Self.twoCopies(model)
        #expect(a2.audioVerifyStatus == "unverified", "A after relaunch: \(a2.audioVerifyStatus)")
        #expect(b2.audioVerifyStatus == "unverified", "B after relaunch: \(b2.audioVerifyStatus)")
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    /// The card a v16 Re-measure (or v16 Check Media) left: stamped measured,
    /// its Sound row "not checked — the sound changes partway", no levels.
    private static func v16RemeasuredCard(size: Int64) -> MediaReportCard {
        SoundLevelsRemeasureRules.rewrite(RemeasureFixture.preFixReconfiguredCard(size: size),
                                          with: .measured(RemeasureFixture.reconfigured()),
                                          context: VideoRecord().soundPresenceContext)
    }

    @Test("REGRESSION round 2 P1-3: a card v16 already re-measured (stamped, 'changes partway', no levels) whose record still holds 'ok' is planned, counted by Tidy, and withdrawn — 'unverified' after relaunch")
    func v16RemeasuredOKIsFoundAndWithdrawn() async throws {
        let scene = try CutoverScene.make("w518_r2_v16"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let id = PoisonedCatalogFixture.id(.healthy)
        let rec = try #require(scene.model.records.first { $0.id.uuidString == id })
        Self.setOK(rec, card: Self.v16RemeasuredCard(size: rec.sizeBytes))
        try #require(rec.mediaReportCard?.soundLevels?.isCurrentMeasurement == true, "fixture: the v16 stamp")
        try #require(scene.model.saveCatalogNow())
        var model = try await Self.relaunch(scene, from: scene.model)

        #expect(SoundLevelsRemeasureItem.plan(model.records).contains { $0.id.uuidString == id }, "planned")
        #expect(CatalogTidyCalculator.project(model.records, isOnline: { _ in true }).soundLevelsToRemeasure >= 1, "Tidy counts it")

        let j = SoundLevelsRemeasureJob(model: model)
        j.toolsAvailable = { true }
        j.isOnline = { _ in true }
        j.measure = { _, _ in .measured(RemeasureFixture.reconfigured()) }
        await RemeasureFixture.run(j)
        #expect(!j.saveFailed, Comment(rawValue: j.summaryLine))

        model = try await Self.relaunch(scene, from: model)
        let r = try #require(model.records.first { $0.id.uuidString == id })
        #expect(r.audioVerifyStatus == "unverified", "after relaunch: \(r.audioVerifyStatus)")
        #expect(!SoundLevelsRemeasureItem.plan(model.records).contains { $0.id.uuidString == id }, "done: no longer planned")
        if let c = model.catalogCutover.committer { await c.repository.close() }
    }

    @Test("P1-3 predicate: only a live, full card whose Sound row says 'changes partway' AND whose record says 'ok' is a stale verdict; damaged / unverified / '' / another not-checked reason / a removed row are not")
    func staleVerdictPredicate() {
        let card = Self.v16RemeasuredCard(size: 1_000)
        #expect(SoundLevelsRemeasureRules.need(card, live: true) == nil, "the card alone owes nothing")
        #expect(SoundLevelsRemeasureRules.need(card, live: true, audioStatus: "ok") == .staleVerdict)
        for status in ["damaged", "attention", "unverified", ""] {
            #expect(SoundLevelsRemeasureRules.need(card, live: true, audioStatus: status) == nil, "\(status)")
        }
        #expect(SoundLevelsRemeasureRules.need(card, live: false, audioStatus: "ok") == nil, "a removed row")
        let other = MasterArchiveTestSupport.soundDiagnosis(channels: [-20, nil])
        var partial = card
        partial.checks = card.checks.map { $0.kind == .sound ? CheckMediaRules.soundRow(other) : $0 }
        #expect(SoundLevelsRemeasureRules.need(partial, live: true, audioStatus: "ok") == nil, "another not-checked reason")
        #expect(SoundLevelsRemeasureRules.isReconfiguredRow(CheckMediaRules.soundRow(RemeasureFixture.reconfigured())),
                "today's Sound row for a rate-changing track carries the pinned words")
    }

    // MARK: The content step (AudioVerdictWithdrawal.decide) — unit cases

    private static func copy(_ status: String, _ date: Date? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.audioVerifyStatus = status
        r.audioVerifyNote = status == "ok" ? "" : "note for \(status)"
        r.audioVerifyDate = date
        return r
    }

    @Test("decide: damage in the store or on any copy is kept and set on every copy; an unreadable store changes nothing; an ok anywhere withdraws every copy together; no ok, nothing")
    func contentStepCases() {
        let when = Date(timeIntervalSince1970: 1_800_000_000)
        // Codex's P1-1: [A damaged, B ok], store damaged.
        var a = Self.copy("damaged", when), b = Self.copy("ok")
        var o = AudioVerdictWithdrawal.decide(copies: [a, b], stored: .check(StoredAudioCheck(status: "damaged", note: "note for damaged", checkedAt: when)), at: Date())
        #expect(o.kind == .keptDamage("damaged") && [a, b].map(\.audioVerifyStatus) == ["damaged", "damaged"])
        // Store attention, every copy ok in memory: the store's damage stands.
        a = Self.copy("ok"); b = Self.copy("ok")
        o = AudioVerdictWithdrawal.decide(copies: [a, b], stored: .check(StoredAudioCheck(status: "attention", note: "ref", checkedAt: when)), at: Date())
        #expect(o.kind == .keptDamage("attention") && [a, b].map(\.audioVerifyStatus) == ["attention", "attention"])
        // Unreadable store: refuse rather than guess.
        a = Self.copy("ok"); b = Self.copy("ok")
        o = AudioVerdictWithdrawal.decide(copies: [a, b], stored: .unreadable("disk I/O error"), at: Date())
        #expect(o.changed.isEmpty && [a, b].map(\.audioVerifyStatus) == ["ok", "ok"])
        // Store ok, copies ok / "" / unverified: all "unverified", same note and date.
        a = Self.copy("ok"); b = Self.copy(""); let c = Self.copy("unverified", when)
        o = AudioVerdictWithdrawal.decide(copies: [a, b, c], stored: .check(StoredAudioCheck(status: "ok", note: "", checkedAt: when)), at: when)
        #expect(o.kind == .withdrew && Set([a, b, c].map(\.audioVerifyStatus)) == ["unverified"])
        #expect(Set([a, b, c].map(\.audioVerifyNote)).count == 1 && Set([a, b, c].map(\.audioVerifyDate)).count == 1)
        // Nothing ok anywhere: nothing written.
        a = Self.copy(""); b = Self.copy("unverified", when)
        o = AudioVerdictWithdrawal.decide(copies: [a, b], stored: .none, at: Date())
        #expect(o.kind == .nothingToWithdraw && o.changed.isEmpty)
    }

    @Test("decide: an unreadable stored verdict leaves the re-measure's content alone (it stays a candidate) — nothing written")
    func remeasureLeavesContentAloneWhenTheStoredVerdictIsUnreadable() async throws {
        let dir = try RemeasureFixture.scratch("w518unreadable"); defer { try? FileManager.default.removeItem(at: dir) }
        let m = RemeasureFixture.model(dir)
        let rec = Self.okRecord("/Volumes/T/u.mov")
        rec.contentFixity = Self.fixity(String(repeating: "7c", count: 32), size: 4_000)
        m.records = [rec]
        let card = rec.mediaReportCard
        let j = RemeasureFixture.job(m) { _, _ in .measured(RemeasureFixture.reconfigured()) }
        j.storedAudio = { _ in .unreadable("disk I/O error") }
        await RemeasureFixture.run(j)
        #expect(rec.audioVerifyStatus == "ok" && rec.mediaReportCard == card)
        #expect(j.totals.changedMeanwhile == 1, Comment(rawValue: j.summaryLine))
    }
}
