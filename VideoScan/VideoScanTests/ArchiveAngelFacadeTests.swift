// ArchiveAngelFacadeTests.swift
// The Archive Angel's front door (ArchiveAngel/Facade/ArchiveAngel.swift):
// `model.archiveAngel` answers exactly what the pieces behind it answer.

import Combine
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel façade — forwards, never re-derives", .serialized)
@MainActor
struct ArchiveAngelFacadeTests {

    private func model() throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-facade")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    @Test("reads through the façade equal the evidence store's own answers (candidate set, evidence, badge)")
    func readsForward() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        // QA on S3: the façade only recommends records the LIVE catalog holds.
        let recs = (0..<3).map { i -> VideoRecord in
            let r = VideoRecord(); r.filename = "f\(i).mov"; r.fullPath = "/Volumes/T/f\(i).mov"; return r
        }
        model.records = recs
        let a = recs[0].id, b = recs[1].id, c = recs[2].id
        let now = Date()
        model.archiveAngel.store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, records: [
            a: .init(score: 120, lines: [.init(points: 120, line: "★★★")], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now),
            b: .init(score: 70, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: now),
            c: .init(score: 0, lines: [], rejection: .tooShort, useCount: 0, lastUsed: nil, computedAt: now),
        ]))
        let angel = model.archiveAngel
        #expect(angel.candidateIDs == [a, b])
        #expect(angel.candidateIDs == angel.store.candidateIDs)
        #expect(angel.evidence(for: a) == angel.store.record(for: a))
        #expect(angel.evidence(for: c)?.grade == .x)
        #expect(angel.evidence(for: UUID()) == nil)
        #expect(angel.badge(for: a) == ArchiveAngelCatalogBadge.make(for: angel.store.record(for: a)))
        #expect(angel.badge(for: a)?.text == "Promote me")
        #expect(angel.badge(for: b)?.text == "Worth a look")
        #expect(angel.badge(for: c) == nil)
    }

    @Test("one façade per model: the property is stable across reads")
    func stable() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.archiveAngel === model.archiveAngel)
    }

    // MARK: S2 — ownership, settings, busy gate, prepare, batches, indexed lookup

    /// A job runner that records what it was asked and never starts anything
    /// (no MFO window, no ffmpeg).
    /// A stand-in for a background verify / footage job (never runs anything).
    @MainActor
    final class FakeBackgroundJob: @MainActor MediaFileOperationJob {
        let id = UUID()
        let kind: MediaFileOperationKind
        let title: String
        var subtitle = ""
        var fraction: Double = 0
        var isIndeterminate = true
        let startedAt = Date()
        var finishedAt: Date?
        @Published var settable: MediaFileOperationState = .running
        var state: MediaFileOperationState { settable }
        init(kind: MediaFileOperationKind, title: String) { self.kind = kind; self.title = title }
        func cancel() { settable = .cancelled }
    }

    @MainActor
    final class FakeRunner: AngelJobRunner {
        var isBusy = false
        var calls: [(count: Int, recordIDs: [UUID]?, lossless: Bool, root: URL, policy: AngelRecommendationPolicy)] = []
        var verifyStarts: [UUID] = []
        var footageStarts = 0
        var refuseFootage = false
        func startVerifyAudioForAngel(record: VideoRecord, model: VideoScanModel) -> (any MediaFileOperationJob)? {
            verifyStarts.append(record.id)
            return FakeBackgroundJob(kind: .verifyAudio, title: "Verify Audio — \(record.filename)")
        }
        func startFindSimilarFootageForAngel(model: VideoScanModel) -> (any MediaFileOperationJob)? {
            footageStarts += 1
            return refuseFootage ? nil : FakeBackgroundJob(kind: .findSimilarFootage, title: "Find Similar Footage — whole catalog")
        }
        func startArchiveAngelByUser(count: Int, recordIDs: [UUID]?, makeLossless: Bool,
                                     model: VideoScanModel, bufferRoot: URL,
                                     policy: AngelRecommendationPolicy) -> ArchiveAngelJob {
            calls.append((count, recordIDs, makeLossless, bufferRoot, policy))
            return ArchiveAngelJob(model: model, center: MediaFileOperationsCenter(), count: count,
                                   makeLossless: makeLossless, bufferRoot: bufferRoot,
                                   explicitRecordIDs: recordIDs, policy: policy)
        }
    }

    private func env(_ root: URL, defaults: UserDefaults, testHost: Bool = true) -> AngelEnvironment {
        var e = AngelEnvironment.app
        e.bufferRoot = root.appendingPathComponent("Buffer", isDirectory: true)
        e.evidenceDirectory = root.appendingPathComponent("evidence", isDirectory: true)
        e.policyOverrideURL = root.appendingPathComponent("no-policy.json")
        e.defaults = defaults
        e.isTestHost = testHost
        return e
    }

    private func suite() -> UserDefaults {
        UserDefaults(suiteName: "test_angel_facade_\(UUID().uuidString)") ?? .standard
    }

    @Test("the model has ONE Angel property and the façade owns the store, sweep and attention it wires together")
    func ownsItsState() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let angel = model.archiveAngel
        #expect(angel.sweep.store === angel.store, "the sweep writes the façade's evidence store")
        #expect(angel.environment.bufferRoot == ArchiveAngelPlanStore.testHostBufferRoot)
        #expect(angel.store.directory == AngelEnvironment.testHostEvidenceDirectory)
        #expect(angel.sweepEnabled, "test host: the pristine ON default")
        #expect(angel.policy == .builtIn)
    }

    @Test("settings: SAME keys; the start sheet's count / lossless and Assess Continuously persist through the façade")
    func settingsKeys() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: defaults))
        #expect(angel.batchCount == 25 && !angel.makeLossless, "defaults 25 / off")
        angel.setBatchCount(35)
        angel.setMakeLossless(true)
        #expect(defaults.object(forKey: "archiveAngel.count") as? Int == 35)
        #expect(defaults.bool(forKey: "archiveAngel.makeLossless"))
        #expect(angel.batchCount == 35 && angel.makeLossless)
        angel.setContinuous(false)
        #expect(defaults.object(forKey: "archiveAngel.sweepEnabled") as? Bool == false)
        #expect(!angel.sweepEnabled)
        #expect(angel.sweep.status == .disabled)
        // A production-mode façade restores it; a test-host one ignores it (poisoned-state rule).
        #expect(!ArchiveAngel(model: model, environment: env(root, defaults: defaults, testHost: false)).sweepEnabled)
        #expect(ArchiveAngel(model: model, environment: env(root, defaults: defaults, testHost: true)).sweepEnabled)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    // MARK: Angel Checks + Keep footage current (docs/archive_angel_wise_design.md §4–§5)

    @Test("settings: checks and footage-auto keys, ON when missing, persisted through the façade; a test host starts from the pristine defaults")
    func checksAndFootageSettings() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ArchiveAngelSettings.checksEnabledKey == "archiveAngel.checksEnabled")
        #expect(ArchiveAngelSettings.footageAutoEnabledKey == "archiveAngel.footageAutoEnabled")
        let defaults = suite()
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: defaults))
        #expect(angel.checksEnabled && angel.footageAutoEnabled, "ON by default")
        angel.setChecks(false)
        angel.setFootageAuto(false)
        #expect(defaults.object(forKey: "archiveAngel.checksEnabled") as? Bool == false)
        #expect(defaults.object(forKey: "archiveAngel.footageAutoEnabled") as? Bool == false)
        #expect(!angel.checksEnabled && !angel.footageAutoEnabled)
        #expect(angel.checks.status == .disabled)
        let production = ArchiveAngel(model: model, environment: env(root, defaults: defaults, testHost: false))
        #expect(!production.checksEnabled && !production.footageAutoEnabled, "a production façade restores the choice")
        #expect(ArchiveAngel(model: model, environment: env(root, defaults: defaults, testHost: true)).checksEnabled,
                "a test host never reads the person's preference")
        defaults.removePersistentDomain(forName: defaults.description)
    }

    @Test("checkFacts: the seams answer the checker — never-verified sound, sound track, mount, Master Archive, gone record")
    func checkFacts() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let angel = model.archiveAngel
        let r = VideoRecord()
        r.filename = "tape.mov"; r.fullPath = "/Volumes/NoSuchVolume_\(UUID().uuidString.prefix(6))/tape.mov"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let v = VideoRecord()
        v.filename = "silent.mov"; v.fullPath = root.appendingPathComponent("silent.mov").path
        v.streamTypeRaw = StreamType.videoOnly.rawValue
        let ok = VideoRecord()
        ok.filename = "checked.mov"; ok.fullPath = root.appendingPathComponent("checked.mov").path
        ok.streamTypeRaw = StreamType.videoAndAudio.rawValue
        ok.audioVerifyStatus = "ok"; ok.audioVerifyDate = Date()
        model.records = [r, v, ok]
        let f = try #require(angel.checkFacts(for: r.id))
        #expect(f.audioNotVerified && f.hasAudioTrack && !f.volumeMounted && !f.onMasterArchive)
        #expect(f.ineligibleReason == "drive not connected")
        #expect(angel.checkFacts(for: v.id)?.hasAudioTrack == false)
        #expect(angel.checkFacts(for: ok.id)?.audioNotVerified == false)
        #expect(angel.checkFacts(for: UUID()) == nil)
        #expect(angel.checkFacts(for: ok.id)?.volumeMounted == true, "a boot-disk path is reachable")
    }

    @Test("keep footage current: fires once after arming when nothing is grouped, not while busy / read-only / off, and not again within 6 h")
    func footageAutoRun() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: defaults))
        let runner = FakeRunner()
        #expect(!angel.considerFootageRun(trigger: "no runner"), "no runner attached: nothing starts")
        angel.attach(jobRunner: runner)
        runner.isBusy = true
        #expect(!angel.considerFootageRun(trigger: "busy") && runner.footageStarts == 0)
        runner.isBusy = false
        #expect(angel.considerFootageRun(trigger: "first complete assessment"))
        #expect(runner.footageStarts == 1)
        #expect(angel.lastFootageAutoRunAt != nil)
        #expect(!angel.considerFootageRun(trigger: "again"), "disarmed after a run")
        #expect(runner.footageStarts == 1)
        // Turning the setting on re-arms — but a record grouped just now is current.
        let r = VideoRecord()
        r.filename = "a.mov"; r.fullPath = "/Volumes/T/a.mov"
        r.footage = FootageMembership(groupID: r.id, groupSize: 2, confidence: .likely, role: .original, rank: 0,
                                      likelyOriginalID: r.id, originalInCatalog: true, evidence: [],
                                      scannedAt: Date(), algorithmVersion: 1)
        model.records = [r]
        angel.setFootageAuto(true)
        #expect(runner.footageStarts == 1, "groups are current (scanned just now)")
        // A day-old run is stale.
        r.footage?.scannedAt = Date().addingTimeInterval(-25 * 3600)
        angel.setFootageAuto(true)
        #expect(runner.footageStarts == 2)
        // Off: never.
        angel.setFootageAuto(false)
        #expect(!angel.considerFootageRun(trigger: "off") && runner.footageStarts == 2)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    @Test("footage currency seam: counts grouped active records and the newest run stamp")
    func footageCurrency() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let none = model.footageCurrency()
        #expect(none.grouped == 0 && none.newestScan == nil)
        let a = VideoRecord(), b = VideoRecord(), c = VideoRecord()
        let older = Date(timeIntervalSince1970: 1_700_000_000), newer = Date(timeIntervalSince1970: 1_800_000_000)
        a.footage = FootageMembership(groupID: a.id, groupSize: 2, confidence: .likely, role: .original, rank: 0,
                                      likelyOriginalID: a.id, originalInCatalog: true, evidence: [], scannedAt: older, algorithmVersion: 1)
        b.footage = FootageMembership(groupID: a.id, groupSize: 2, confidence: .likely, role: .copy, rank: 1,
                                      likelyOriginalID: a.id, originalInCatalog: true, evidence: [], scannedAt: newer, algorithmVersion: 1)
        model.records = [a, b, c]
        let cur = model.footageCurrency()
        #expect(cur.grouped == 2 && cur.newestScan == newer)
    }

    @Test("busy gate: the sweep parks while the job runner reports an Angel/Promote job (AngelJobRunner.isBusy)")
    func busyGate() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: suite()))
        let runner = FakeRunner()
        runner.isBusy = true
        angel.attach(jobRunner: runner)
        angel.launch()
        angel.sweep.run(reason: "test")
        for _ in 0..<100 where !angel.sweep.status.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(angel.sweep.status == .paused(reason: "another job is using the catalog"))
        runner.isBusy = false
        for _ in 0..<300 {
            if case .done = angel.sweep.status { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        if case .done = angel.sweep.status {} else { Issue.record("the sweep ran once the runner was idle — \(angel.sweep.status)") }
        angel.sweep.stop()
        #expect(!MediaFileOperationsCenter().isBusy, "an empty center is not busy")
    }

    @Test("prepare: the façade hands the runner ITS buffer root and policy; the catalog path reads the remembered lossless choice")
    func prepareInjects() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: defaults))
        await angel.policyLoaded()   // codex #1643: Prepare waits for the off-main policy load
        let runner = FakeRunner()
        let job = angel.prepare(count: 10, lossless: false, using: runner)
        #expect(job != nil)
        angel.setMakeLossless(true)
        let ids = [UUID(), UUID()]
        angel.prepare(recordIDs: ids, using: runner)
        #expect(runner.calls.count == 2)
        #expect(runner.calls[0].count == 10 && runner.calls[0].recordIDs == nil && !runner.calls[0].lossless)
        #expect(runner.calls[1].recordIDs == ids && runner.calls[1].lossless, "lossless follows the start sheet's choice")
        #expect(runner.calls.allSatisfy { $0.root == angel.environment.bufferRoot && $0.policy == angel.policy })
        #expect(job?.bufferRoot == angel.environment.bufferRoot)
        defaults.removePersistentDomain(forName: defaults.description)
    }

    @Test("batches: refreshBatches (moved from ArchiveView) lists a ready batch from the façade's buffer, never one with 0 ready rows")
    func refreshBatchesMoved() async throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: suite()))
        let buffer = angel.environment.bufferRoot
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/ArchiveAngel")
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var ready = try dec.decode(ArchiveAngelPlan.self, from: Data(contentsOf: fixtures.appendingPathComponent("plan_promoted_single.json")))
        ready.status = .ready
        for i in ready.entries.indices { ready.entries[i].status = .ready }
        ready.batchDir = buffer.appendingPathComponent("batch-2026-09-20T17-25-00").path
        var empty = try dec.decode(ArchiveAngelPlan.self, from: Data(contentsOf: fixtures.appendingPathComponent("plan_ready_empty.json")))
        empty.batchDir = buffer.appendingPathComponent("batch-2026-09-22T16-23-04").path
        for plan in [ready, empty] {
            try FileManager.default.createDirectory(atPath: plan.batchDir, withIntermediateDirectories: true)
            try ArchiveAngelPlanStore.save(plan)
        }
        angel.refreshBatches(reason: "test")
        for _ in 0..<300 where angel.batches.hygiene.generation == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        #expect(angel.batches.ready.map(\.id) == [ready.id], "the 0-ready batch is not offered")
        #expect(angel.batches.unreadable.isEmpty)
        #expect(angel.batches.hygiene.generation == 1)
    }

    @Test("SCALE: AngelCatalog.record(forPath:) answers exactly what the old records.first scan did — 100k records, 2,000 lookups under 0.5 s")
    func indexedPathLookup() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/V\(i % 5)/tape_\(i).mov"
            r.filename = "tape_\(i).mov"
            recs.append(r)
        }
        let twin = VideoRecord()                 // a second record at an existing path: FIRST wins, as before
        twin.fullPath = recs[500].fullPath
        recs.append(twin)
        model.records = recs
        let catalog: any AngelCatalog = model
        for i in [0, 500, 99_999] {
            let path = recs[i].fullPath
            #expect(catalog.record(forPath: path) === model.records.first { $0.fullPath == path })
        }
        #expect(catalog.record(forPath: "/Volumes/nowhere.mov") == nil)
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            for i in stride(from: 0, to: 100_000, by: 50) { _ = catalog.record(forPath: recs[i].fullPath) }
        }
        let secs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(secs < 0.5, "2,000 indexed lookups over 100k records in \(secs) s")
    }

    @Test("the shared helpers the app reaches through the façade answer exactly what the Angel's own do")
    func sharedHelpers() {
        #expect(ArchiveAngel.attentionKinds == ArchiveAngelAttentionStore.attentionKinds)
        for stem in ["Cape Cod 1993_balanced", "clip 1", "Thanksgiving.vs.edit", "plain"] {
            #expect(ArchiveAngel.familyBaseStem(stem) == ArchiveAngelFamily.baseStem(stem))
            #expect(ArchiveAngel.derivativeBaseStem(stem) == ArchiveAngelNaming.derivativeBaseStem(stem))
        }
        for notes in ["", "Grandma's 80th", "[ffprobe] codec=dv"] {
            #expect(ArchiveAngel.hasHumanNote(notes) == ArchiveAngelCandidate.hasHumanNote(notes))
        }
        #expect(ArchiveAngel.finishedJobCount([]) == 0)
    }

    @Test("busy gate on the REAL center: an active Promote → busy; an active Verify Audio → not busy; finished → not busy")
    func busyGateRealCenter() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let promoteCenter = MediaFileOperationsCenter()
        let promote = PromoteToArchiveJob(plan: ArchivePromotePlan(rootPath: root.path, entries: [], skipped: [],
                                                                   totalBytes: 0, freeBytesAtRoot: nil),
                                          model: model)
        #expect(promoteCenter.add(promote))
        #expect(promote.state.isActive, "a job not yet started is .running")
        #expect(promoteCenter.isBusy, "an active Promote parks the sweep")
        promote.cancel()
        #expect(!promote.state.isActive || promote.state.cancelWasRequested)

        let verifyCenter = MediaFileOperationsCenter()
        let rec = VideoRecord()
        rec.fullPath = root.appendingPathComponent("clip.mov").path
        let verify = VerifyAudioJob(record: rec, model: model)
        #expect(verifyCenter.add(verify))
        #expect(verify.state.isActive)
        #expect(!verifyCenter.isBusy, "a Verify Audio job does not park the Angel's sweep")
    }
}
