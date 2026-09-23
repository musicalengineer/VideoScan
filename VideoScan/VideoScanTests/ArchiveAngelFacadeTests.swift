// ArchiveAngelFacadeTests.swift
// The Archive Angel's front door (ArchiveAngel/Facade/ArchiveAngel.swift):
// `model.archiveAngel` answers exactly what the pieces behind it answer.

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
        let a = UUID(), b = UUID(), c = UUID()
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
    @MainActor
    final class FakeRunner: AngelJobRunner {
        var isBusy = false
        var calls: [(count: Int, recordIDs: [UUID]?, lossless: Bool, root: URL, policy: AngelRecommendationPolicy)] = []
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
    func prepareInjects() throws {
        let (model, root) = try model()
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = suite()
        let angel = ArchiveAngel(model: model, environment: env(root, defaults: defaults))
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
