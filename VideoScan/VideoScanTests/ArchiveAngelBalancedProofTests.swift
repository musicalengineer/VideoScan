// ArchiveAngelBalancedProofTests.swift
// Prepare's last stage, the balanced-copy proof — REPORT ONLY (2026-11-18).
// Through the REAL ArchiveAngelJob on a generated left-only mov/ProRes + PCM
// clip (tones, no family media), with the proof injected where an outcome
// must be forced:
//
//   LOGIC          each of the four outcomes → its Review line and its engine
//                  START / OUTCOME lines in the job's log; Stop mid-proof;
//                  a Skip mid-proof; the setting off; which rows are proven
//   DECIDES NOTHING  every outcome (and the proof off) leaves the same:
//                  rows, steps, readiness, the Promote selection, the
//                  companions Promote takes and their landing rule, the
//                  Angel's holds (what Delete Duplicates and every Trash
//                  offer ask), the catalog's records, the buffer's files —
//                  and, inside one run, the buffer's BYTES before and after
//                  the proof
//   ISOLATION      the proof throws; ffmpeg/ffprobe missing — never a failed row
//   SCALE          picking the rows to prove over 100k plan rows, budgeted
//   CODABLE        an older plan.json (no note) decodes; the note round-trips
//
// Media matrix (raw DV, mov/PCM, AAC) through the real proof:
// ArchiveAngelBalancedProofMediaTests. Source sensor:
// ArchiveAngelBalancedProofSensorTests.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// What the injected proof saw, read from the test (≈ a mutex-guarded struct).
actor BalancedProofProbe {
    private(set) var calls: [(original: String, balanced: String)] = []
    private(set) var bufferBefore: [String: String]?
    private(set) var cancelled = false

    func called(_ original: String, _ balanced: String, buffer: [String: String]) {
        calls.append((original, balanced))
        bufferBefore = buffer
    }
    func noteCancelled() { cancelled = true }
    var started: Bool { !calls.isEmpty }
}

enum BalancedProofBench {
    typealias Proof = BalancedCopyProof

    struct Bench {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let center: MediaFileOperationsCenter
        let buffer: URL
    }

    @MainActor
    static func bench(_ label: String) throws -> Bench {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        try FileManager.default.createDirectory(at: sb.archiveVolume, withIntermediateDirectories: true)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        model.masterArchive = MasterArchiveDesignation(targetPath: sb.archiveVolume.path,
                                                       rootPath: sb.archiveRoot.path, volumeUUID: nil)
        let buffer = sb.root.appendingPathComponent("Buffer", isDirectory: true)
        try FileManager.default.createDirectory(at: buffer, withIntermediateDirectories: true)
        return Bench(sb: sb, model: model, center: MediaFileOperationsCenter(), buffer: buffer)
    }

    /// A catalogued record for a generated clip, as a scan would leave it.
    @MainActor
    static func record(_ path: String, videoCodec: String, audioCodec: String) -> VideoRecord {
        let r = MasterArchiveTestSupport.makeRecord(path: path, userDate: "1995", starRating: 2)
        r.durationSeconds = 600   // the explicit-pick floor; every tool probes the real file
        r.videoCodec = videoCodec
        r.audioCodec = audioCodec
        r.audioChannels = "2"
        r.isPlayable = "Yes"
        return r
    }

    /// One left-only mov/ProRes + 16-bit PCM clip in the bench's sources.
    @MainActor
    static func leftOnlyMov(_ b: Bench) throws -> VideoRecord {
        let path = try BalancedCopyProofMedia.original(in: b.sb.sources, .movProResPCM16)
        let rec = record(path, videoCodec: "prores", audioCodec: "pcm_s16le")
        b.model.records = [rec]
        return rec
    }

    /// The job, configured, started and awaited (`during` runs once the job is live).
    @MainActor
    static func run(_ b: Bench, _ rec: VideoRecord, prover: Proof.Outcome? = nil,
                    customProver: ArchiveAngelBalancedProof.Prover? = nil, proofOn: Bool = true,
                    during: (@MainActor (ArchiveAngelJob) async -> Void)? = nil) async -> ArchiveAngelJob {
        let job = ArchiveAngelJob(model: b.model, center: b.center, count: 1, makeLossless: false,
                                  bufferRoot: b.buffer, explicitRecordIDs: [rec.id])
        job.provesBalancedCopiesOverride = proofOn
        if let customProver { job.balancedCopyProver = customProver }
        if let outcome = prover { job.balancedCopyProver = { _, _ in outcome } }
        job.start()
        if let during { await during(job) }
        await job.task?.value
        withExtendedLifetime(b.center) {}
        return job
    }

    /// Relative path → SHA-256 of every file under `dir` except plan.json.
    static func bufferDigest(_ dir: String) -> [String: String] {
        var out: [String: String] = [:]
        let root = URL(fileURLWithPath: dir)
        guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        for case let url as URL in walk where url.lastPathComponent != ArchiveAngelPlan.planFilename {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let data = try? Data(contentsOf: url) else { continue }
            let rel = String(url.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
            out[rel] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    /// A proof that records what it was handed and the buffer as it was, then answers `outcome`.
    static func recording(_ probe: BalancedProofProbe, answering outcome: Proof.Outcome) -> ArchiveAngelBalancedProof.Prover {
        { original, balanced in
            let batchDir = URL(fileURLWithPath: balanced).deletingLastPathComponent().deletingLastPathComponent().path
            await probe.called(original, balanced, buffer: bufferDigest(batchDir))
            return outcome
        }
    }

    /// A proof that never answers: it waits to be stopped.
    static func hanging(_ probe: BalancedProofProbe) -> ArchiveAngelBalancedProof.Prover {
        { original, balanced in
            let batchDir = URL(fileURLWithPath: balanced).deletingLastPathComponent().deletingLastPathComponent().path
            await probe.called(original, balanced, buffer: bufferDigest(batchDir))
            do {
                while true { try await Task.sleep(nanoseconds: 20_000_000) }
            } catch {
                await probe.noteCancelled()
                throw error
            }
        }
    }

    /// Wait (polling, bounded) until the injected proof has been called.
    static func waitUntilStarted(_ probe: BalancedProofProbe, seconds: Double = 120) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if await probe.started { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: The four outcomes, built by hand

    static let evidence = Proof.Evidence(
        streams: [], originalClass: .leftOnly, liveChannel: 0, soundCodec: "pcm_s16le", sampleFormat: "s16",
        sampleRateHz: 48_000, soundSHA256: String(repeating: "a", count: 64), soundSamples: 96_000,
        soundStartSeconds: 0, discarded: .init(channel: 1, peakDBFS: -.infinity))
    static let differences: [Proof.Difference] = [
        .init(kind: .track, heldBy: .balancedCopy, what: "a timecode track — not compared with the other file"),
        .init(kind: .container, heldBy: nil, what: "the container differs (dv → mov)"),
        .init(kind: .metadata, heldBy: .original, what: "1 tags (timecode) — not compared with the other file"),
        .init(kind: .metadata, heldBy: .balancedCopy, what: "2 tags (encoder, timecode) — not compared with the other file"),
    ]
    static let outcomes: [(name: String, outcome: Proof.Outcome)] = [
        ("proven", .proven(evidence)),
        ("sameContent", .sameContent(evidence, differs: differences)),
        ("notProven", .notProven(.soundReencoded(codec: "aac"))),
        ("couldNotCheck", .couldNotCheck("the balanced copy could not be read as media")),
    ]
    static func outcome(_ name: String) -> Proof.Outcome {
        outcomes.first { $0.name == name }?.outcome ?? .couldNotCheck("no such outcome in the test: \(name)")
    }

    // MARK: Everything that decides, normalized across runs (ids → names)

    struct Decisions: Equatable, CustomStringConvertible {
        var job: String
        var planStatus: String
        var rows: [String]
        var readiness: ArchiveReadiness
        var promote: [String]
        var promotable: [String]
        var landing: [String]
        var held: [String]
        var heldOnDisk: [String]
        var buffer: [String]
        var records: [String]
        var description: String {
            ([job, planStatus] + rows + promote + promotable + landing + held + heldOnDisk + buffer + records)
                .joined(separator: "\n") + "\n\(readiness)"
        }
    }

    @MainActor
    static func decisions(_ job: ArchiveAngelJob, original: VideoRecord, model: VideoScanModel) -> Decisions {
        let plan = job.plan
        func label(_ id: UUID) -> String {
            id == original.id ? "original" : (model.record(forID: id)?.filename ?? "unknown record")
        }
        var rows: [String] = []
        for e in plan.entries {
            rows.append("row \(e.filename) \(e.status) selected \(e.selected) failure \(e.failure ?? "-")"
                        + " unfinished \(ArchiveAngelJob.unfinishedStepReason(e) ?? "-") originalOnly \(e.isOriginalOnly)"
                        + " loop \(e.loopAction) skippable \(e.isSkippable) nomination \(e.balancedNomination ?? "-")")
            for s in e.steps {
                rows.append("  \(s.kind) \(s.state) | \(s.note) | \(s.outputRelPath.map { ($0 as NSString).lastPathComponent } ?? "-")"
                            + " | \(s.recordID.map(label) ?? "-") | \(s.existingPath ?? "-")")
            }
        }
        var promote: [String] = []
        var promotable: [String] = []
        var landing: [String] = []
        for e in plan.entries where e.status == .ready && e.selected {
            var selection = ArchiveAngelPromoter.PromoteSelection()
            _ = ArchiveAngelPromoter.addRow(e, in: plan, to: &selection)
            promote.append("ids " + selection.ids.map(label).joined(separator: ", "))
            for (id, t) in selection.titles.sorted(by: { label($0.key) < label($1.key) }) { promote.append("title \(label(id)) \(t)") }
            for (id, d) in selection.dates.sorted(by: { label($0.key) < label($1.key) }) { promote.append("date \(label(id)) \(d)") }
            for (id, s) in selection.sources.sorted(by: { label($0.key) < label($1.key) }) { promote.append("source \(label(id)) \(s)") }
            for (id, r) in selection.roles.sorted(by: { label($0.key) < label($1.key) }) { promote.append("role \(label(id)) \(r)") }
            for (id, c) in selection.intended { promote.append("intended \(label(id)) → \(c.map(label).sorted())") }
            promotable += ArchiveAngelPromoter.promotableCompanions(of: e, in: plan).map { "\($0.kind) \($0.state)" }
            for landed in [true, false] {
                let l = ArchiveAngelPromoter.companionLanding(of: e, landed: { _ in landed })
                landing.append("landed=\(landed): access \(l.access) lossless \(l.lossless) balanced \(l.balanced) missing \(l.missing.map(\.kind))")
            }
        }
        let held = ArchiveAngelJob.heldRecordIDs(explicit: [original.id], plan: plan).map(label).sorted()
            + ArchiveAngelPlanStore.inFlightRecordIDs(in: [plan]).map(label).sorted().map { "in flight " + $0 }
        let heldOnDisk: [String]
        switch ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: job.bufferRoot) {
        case .ids(let ids): heldOnDisk = ids.map(label).sorted()
        case .uncertain(let why): heldOnDisk = ["uncertain: \(why)"]
        }
        let entryDirs = Dictionary(uniqueKeysWithValues: plan.entries.map { ($0.id.uuidString, "<row>") })
        let buffer = bufferDigest(plan.batchDir).keys.map { rel in
            entryDirs.reduce(rel) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }.sorted()
        let records = model.records.map { "\($0.filename) derivedFrom \($0.derivedFrom.map(label) ?? "-") \($0.derivationKind ?? "-")" }.sorted()
        return Decisions(job: ArchiveAngelPrepareCharacterizationTests.state(job), planStatus: "\(plan.status)",
                         rows: rows, readiness: ArchiveReadiness.assess(record: original), promote: promote,
                         promotable: promotable, landing: landing, held: held, heldOnDisk: heldOnDisk,
                         buffer: buffer, records: records)
    }
}

@Suite("Archive Angel — the balanced-copy proof after Prepare is report only", .serialized)
@MainActor
struct ArchiveAngelBalancedProofTests {
    typealias B = BalancedProofBench
    typealias Proof = BalancedCopyProof
    typealias AP = ArchiveAngelBalancedProof

    // MARK: LOGIC — pure

    @Test("LOGIC: each outcome is one plain Review line, and its verdict word")
    func eachOutcomeIsOneLine() {
        let when = Date(timeIntervalSince1970: 0)
        let lines = B.outcomes.map { AP.note(for: $0.outcome, at: when) }
        #expect(lines.map(\.verdict) == ["proven the same", "same content", "not proven", "could not check"])
        #expect(lines[0].line == "Balanced copy: proven the same")
        #expect(lines[1].line == "Balanced copy: same content — differs in: track, container, metadata")
        #expect(lines[2].line == "Balanced copy: not proven: the sound was re-encoded (aac) — the original is kept")
        #expect(lines[3].line == "Balanced copy: could not check: the balanced copy could not be read as media")
        #expect(lines[1].detail == B.differences.map(Proof.sentence).joined(separator: " | "))
        #expect(lines[1].detail.hasPrefix("[track] the balanced copy holds a timecode track — not compared with the other file | [container] the container differs"))
        #expect(lines.allSatisfy { !$0.line.contains("\n") && $0.checkedAt == when })
        #expect([0, 2, 3].allSatisfy { lines[$0].detail.isEmpty })
    }

    @Test("LOGIC: a tool's words are kept on one bounded line")
    func wordsAreBoundedAndOneLine() {
        let note = AP.note(for: .couldNotCheck("ffprobe said:\nline two\u{2028}" + String(repeating: "x", count: 5000)))
        #expect(!note.line.contains("\n") && !note.line.contains("\u{2028}"))
        #expect(note.line.count == AP.lineLimit && note.line.hasSuffix("…"))
    }

    @Test("LOGIC: only a ready row whose balance step MADE a copy in this batch is proven")
    func whichRowsAreProven() {
        let batch = "/Buffer/batch-T"
        func entry(_ status: ArchiveAngelPlan.EntryStatus, _ state: ArchiveAngelPlan.StepState,
                   out: String? = nil, existing: String? = nil) -> ArchiveAngelPlan.Entry {
            var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/src/a.mov", filename: "a.mov", sizeBytes: 1,
                                           durationSeconds: 1, score: 1, evidence: [], proposedName: "a.mov")
            e.status = status
            e.set(.balanceAudio, state, output: out)
            if let existing, let i = e.steps.firstIndex(where: { $0.kind == .balanceAudio }) { e.steps[i].existingPath = existing }
            return e
        }
        #expect(AP.pair(for: entry(.ready, .done, out: "X/a_balanced.mov"), batchDir: batch)
                == .init(original: "/src/a.mov", balanced: "/Buffer/batch-T/X/a_balanced.mov"))
        #expect(AP.pair(for: entry(.ready, .done, out: "/elsewhere/a_balanced.mov"), batchDir: batch)?.balanced == "/elsewhere/a_balanced.mov")
        #expect(AP.pair(for: entry(.ready, .done, existing: "/src/a_balanced.mov"), batchDir: batch) == nil, "a reused copy is not this batch's")
        #expect(AP.pair(for: entry(.ready, .skipped), batchDir: batch) == nil)
        #expect(AP.pair(for: entry(.ready, .failed, out: "X/a_balanced.mov"), batchDir: batch) == nil)
        for status in [ArchiveAngelPlan.EntryStatus.pending, .preparing, .failed, .skipped, .promoted] {
            #expect(AP.pair(for: entry(status, .done, out: "X/a_balanced.mov"), batchDir: batch) == nil, "\(status)")
        }
    }

    @Test("LOGIC: the setting defaults ON — only an explicit false turns it off; its key and words are pinned")
    func settingDefaultsOn() throws {
        let suite = "test.angel.proveBalancedCopies.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ArchiveAngelSettings.proveBalancedCopiesKey == "archiveAngel.proveBalancedCopies")
        #expect(ArchiveAngelSettings.proveBalancedCopiesTitle == "Prove balanced copies after Prepare")
        #expect(ArchiveAngelSettings.restored(from: defaults).proveBalancedCopies, "missing key → on")
        defaults.set("yes", forKey: ArchiveAngelSettings.proveBalancedCopiesKey)
        #expect(ArchiveAngelSettings.restored(from: defaults).proveBalancedCopies, "a value of the wrong type → on")
        ArchiveAngelSettings.saveProveBalancedCopies(false, to: defaults)
        #expect(!ArchiveAngelSettings.restored(from: defaults).proveBalancedCopies)
        ArchiveAngelSettings.saveProveBalancedCopies(true, to: defaults)
        #expect(ArchiveAngelSettings.restored(from: defaults).proveBalancedCopies)
        #expect(AP.offLine(count: 2) == "balanced copy proof: OFF — 2 balanced copies made by this batch not checked "
                + "(Archive Angel ▸ Prove balanced copies after Prepare is off); nothing else changes")
    }

    @Test("CODABLE: a plan.json written before the note decodes with none; a note round-trips; no note writes no key")
    func codable() throws {
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/s/a.mov", filename: "a.mov", sizeBytes: 1,
                                       durationSeconds: 1, score: 1, evidence: [], proposedName: "a.mov")
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let bare = try enc.encode(e)
        #expect(String(bytes: bare, encoding: .utf8)?.contains("balancedCopyProof") == false)
        #expect(try dec.decode(ArchiveAngelPlan.Entry.self, from: bare).balancedCopyProof == nil)
        e.balancedCopyProof = AP.note(for: B.outcome("sameContent"), at: Date(timeIntervalSince1970: 1_000_000))
        #expect(try dec.decode(ArchiveAngelPlan.Entry.self, from: enc.encode(e)) == e)
    }

    // MARK: DECIDES NOTHING — pure, every outcome over one hand-built plan

    @Test("DECIDES NOTHING (pure): every outcome on a row leaves the Promote selection, companions, landing, holds and the settle exactly as no proof")
    func pureDecisionsIgnoreTheNote() throws {
        // The companions are real (empty-named, nonempty) files, so Promote's
        // "promotable" rule has something to take or leave.
        let dir = try BalanceAudioTestMedia.makeScratchDir("proof_pure")
        defer { try? FileManager.default.removeItem(at: dir) }
        var plan = ArchiveAngelPlan(batchDir: dir.path, requestedCount: 1, makeLossless: false)
        var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/s/a.mov", filename: "a.mov", sizeBytes: 9,
                                       durationSeconds: 600, score: 5, evidence: [], proposedName: "1995 a.mov",
                                       proposedDate: "1995")
        e.status = .ready
        e.set(.verifyAudio, .done, note: "left only")
        e.set(.balanceAudio, .done, note: "Audio balanced (leftOnly)", output: "\(e.id.uuidString)/a_balanced.mov")
        e.set(.accessCopy, .done, note: "HEVC access copy (from balanced audio)", output: "\(e.id.uuidString)/a.vs.archive.mov")
        e.set(.losslessCopy, .skipped, note: "Lossless off")
        for i in e.steps.indices where e.steps[i].state == .done && e.steps[i].kind != .verifyAudio { e.steps[i].recordID = UUID() }
        plan.entries = [e]
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(e.id.uuidString), withIntermediateDirectories: true)
        for rel in e.steps.compactMap(\.outputRelPath) { try Data([1]).write(to: dir.appendingPathComponent(rel)) }
        #expect(ArchiveAngelPromoter.promotableCompanions(of: e, in: plan).count == 2, "both companions are promotable")
        func fingerprint(_ p: ArchiveAngelPlan) -> String {
            var p = p
            let entry = p.entries[0]
            var sel = ArchiveAngelPromoter.PromoteSelection()
            _ = ArchiveAngelPromoter.addRow(entry, in: p, to: &sel)
            let land = ArchiveAngelPromoter.companionLanding(of: entry, landed: { _ in true })
            func sorted<V>(_ d: [UUID: V]) -> String { d.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ",") }
            let parts: [String] = [
                "\(sel.ids) \(sorted(sel.titles)) \(sorted(sel.dates)) \(sorted(sel.sources)) \(sorted(sel.roles)) \(sorted(sel.intended))",
                "\(land.access) \(land.lossless) \(land.balanced) \(land.missing)",
                "\(ArchiveAngelPlanStore.inFlightRecordIDs(in: [p]).sorted())",
                "\(ArchiveAngelJob.heldRecordIDs(explicit: nil, plan: p).sorted())",
                "\(ArchiveAngelJob.unfinishedStepReason(entry) ?? "-") \(entry.isOriginalOnly) \(entry.loopAction) \(entry.isSkippable)",
                "\(entry.companionsMade) \(p.selectedEntries.map(\.id)) \(p.readyCount) \(p.bytesToCopy)",
                "\(p.settleAfterInterruption(reason: "x")) \(p.status) \(p.entries.map(\.status))",
            ]
            return parts.joined(separator: "\n")
        }
        let baseline = fingerprint(plan)
        for (name, outcome) in B.outcomes {
            var noted = plan
            noted.entries[0].balancedCopyProof = AP.note(for: outcome)
            #expect(fingerprint(noted) == baseline, "\(name) changed a decision")
        }
    }

    // MARK: DECIDES NOTHING — the real job, every outcome

    @Test("DECIDES NOTHING: the real Prepare with each outcome injected leaves every decision as the proof switched off — and the buffer's bytes as they were before the proof",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(10)))
    func realPrepareDecidesTheSameWhateverTheProofSays() async throws {
        let off = try B.bench("proof_off"); defer { off.sb.cleanup() }
        let offRec = try B.leftOnlyMov(off)
        let offProbe = BalancedProofProbe()
        let offJob = await B.run(off, offRec, customProver: B.recording(offProbe, answering: B.outcome("proven")), proofOn: false)
        let baseline = B.decisions(offJob, original: offRec, model: off.model)
        #expect(await offProbe.calls.isEmpty, "the setting off: the proof never runs")
        #expect(baseline.job == "finished" && offJob.plan.entries.first?.balancedCopyProof == nil)
        #expect(baseline.rows.first?.contains("ready") == true && baseline.rows.contains { $0.contains("balanceAudio done") },
                "the fixture must make a balanced copy: \(baseline)")
        #expect(offJob.plan.log.contains(AP.offLine(count: 1)), "\(offJob.plan.log.suffix(4))")

        for (name, outcome) in B.outcomes {
            let b = try B.bench("proof_\(name)"); defer { b.sb.cleanup() }
            let rec = try B.leftOnlyMov(b)
            let probe = BalancedProofProbe()
            let job = await B.run(b, rec, customProver: B.recording(probe, answering: outcome))
            let got = B.decisions(job, original: rec, model: b.model)
            #expect(got == baseline, "\(name): a decision moved\n— with the proof —\n\(got)\n— proof off —\n\(baseline)")
            // Inside the run: what Prepare wrote is byte for byte what it was when the proof began.
            let before = try #require(await probe.bufferBefore)
            #expect(!before.isEmpty && B.bufferDigest(job.plan.batchDir) == before, "\(name): the buffer changed during the proof")
            #expect(await probe.calls.count == 1)
            #expect(job.plan.entries.first?.balancedCopyProof?.line == AP.note(for: outcome).line, "\(name)")
        }
    }

    // MARK: LOGIC — the job's own lines

    @Test("LOGIC: the job writes the engine's own START and OUTCOME lines, verbatim, and keeps the row's line",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func startAndOutcomeLinesAreTheEngines() async throws {
        let b = try B.bench("proof_lines"); defer { b.sb.cleanup() }
        let rec = try B.leftOnlyMov(b)
        let probe = BalancedProofProbe()
        let job = await B.run(b, rec, customProver: B.recording(probe, answering: B.outcome("sameContent")))
        let call = try #require(await probe.calls.first)
        #expect(call.original == rec.fullPath && call.balanced.hasSuffix("_balanced.mov"))
        let start = Proof.startLine(original: call.original, balanced: call.balanced)
        let outcome = Proof.logLine(original: call.original, balanced: call.balanced, outcome: B.outcome("sameContent"))
        let proofLines = job.plan.log.filter { $0.hasPrefix("balanced copy proof:") }
        #expect(proofLines == [start, outcome], "exactly one START and one OUTCOME: \(proofLines)")
        #expect(outcome.contains("OUTCOME SAME CONTENT, DIFFERS IN 4"))
        let entry = try #require(job.plan.entries.first)
        #expect(entry.balancedCopyProof?.line == "Balanced copy: same content — differs in: track, container, metadata")
        // The line is in plan.json on disk, for the review sheet.
        let disk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
        // (plan.json keeps whole seconds: the time is compared to the second.)
        let kept = try #require(disk.entries.first?.balancedCopyProof)
        #expect(kept.line == entry.balancedCopyProof?.line && kept.verdict == "same content")
        #expect(kept.detail == entry.balancedCopyProof?.detail && !kept.detail.isEmpty)
        #expect(disk.status == .ready && entry.status == .ready)
    }

    @Test("LOGIC: Stop mid-proof — the proof is stopped, the row stays ready and kept, nothing it wrote is touched, the line says so",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func stopMidProofKeepsTheRow() async throws {
        let b = try B.bench("proof_stop"); defer { b.sb.cleanup() }
        let rec = try B.leftOnlyMov(b)
        let probe = BalancedProofProbe()
        var before: ArchiveAngelPlan.Entry?
        let job = await B.run(b, rec, customProver: B.hanging(probe)) { job in
            #expect(await B.waitUntilStarted(probe), "the proof never started")
            before = job.plan.entries.first
            job.cancel()
        }
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(await probe.cancelled, "the running proof was stopped")
        var entry = try #require(job.plan.entries.first)
        #expect(entry.status == .ready && entry.failure == nil, "a Stop during the proof never fails the row")
        #expect(entry.balancedCopyProof?.line == "Balanced copy: could not check: the check was stopped")
        entry.balancedCopyProof = nil
        #expect(entry == before, "the row is exactly as Prepare left it")
        // The cancel's settle saves plan.json off the main actor (an atomic
        // write's temporary file sits in the folder meanwhile): wait for it.
        await job.cleanupTask?.value
        let after = B.bufferDigest(job.plan.batchDir)
        let proofStart = try #require(await probe.bufferBefore)
        #expect(after == proofStart, "no partial file, nothing removed: before \(proofStart.keys.sorted()) after \(after.keys.sorted())")
        let disk = try ArchiveAngelPlanStore.load(batchDir: job.plan.batchDir)
        #expect(disk.status == .ready && disk.readyCount == 1, "the batch stays reviewable: \(disk.status)")
        #expect(disk.entries.first?.balancedCopyProof?.verdict == "could not check")
        #expect(job.plan.log.contains { $0.hasPrefix("balanced copy proof: OUTCOME COULD NOT CHECK") && $0.hasSuffix("the check was stopped") })
    }

    @Test("LOGIC: Skip of the row mid-proof stops the proof, then reclaims the row's folder — no line is kept for a skipped row",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)))
    func skipMidProofStopsItAndReclaims() async throws {
        let b = try B.bench("proof_skip"); defer { b.sb.cleanup() }
        let rec = try B.leftOnlyMov(b)
        let probe = BalancedProofProbe()
        let job = await B.run(b, rec, customProver: B.hanging(probe)) { job in
            #expect(await B.waitUntilStarted(probe), "the proof never started")
            #expect(job.skip(entryID: rec.id))
        }
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(await probe.cancelled)
        let entry = try #require(job.plan.entries.first)
        #expect(entry.status == .skipped && entry.balancedCopyProof == nil)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: job.plan.batchDir)
            .appendingPathComponent(rec.id.uuidString).path), "the skipped row's companions were reclaimed")
    }

    // MARK: ISOLATION — the proof fails; never the row

    @Test("ISOLATION: a proof that throws, and missing tools, are 'could not check' — the row stays ready, the job finishes",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(5)),
          arguments: ["throws", "noTools"])
    func proofFailureNeverFailsTheRow(_ how: String) async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "the decoder fell over" } }
        let b = try B.bench("proof_\(how)"); defer { b.sb.cleanup() }
        let rec = try B.leftOnlyMov(b)
        let prover: AP.Prover
        if how == "throws" {
            prover = { @Sendable _, _ in throw Boom() }
        } else {
            prover = { @Sendable o, c in
                await Proof.measure(original: o, balanced: c,
                                    tools: .init(ffmpeg: "/nonexistent/ffmpeg", ffprobe: "/nonexistent/ffprobe"))
            }
        }
        let job = await B.run(b, rec, customProver: prover)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let entry = try #require(job.plan.entries.first)
        #expect(entry.status == .ready && entry.failure == nil)
        #expect(entry.step(.balanceAudio).state == .done && entry.step(.accessCopy).state == .done)
        let expected = how == "throws"
            ? "Balanced copy: could not check: the check failed: the decoder fell over"
            : "Balanced copy: could not check: ffmpeg/ffprobe not found (set VS_FFMPEG_PATH / VS_FFPROBE_PATH or install via Homebrew)"
        #expect(entry.balancedCopyProof?.line == expected)
    }

    // MARK: SCALE

    @Test("SCALE: choosing the rows to prove over 100k plan rows stays within budget")
    func choosingRowsScales() {
        var plan = ArchiveAngelPlan(batchDir: "/B/batch-T", requestedCount: 100_000, makeLossless: false)
        plan.entries = (0..<100_000).map { i in
            var e = ArchiveAngelPlan.Entry(id: UUID(), sourcePath: "/s/\(i).mov", filename: "\(i).mov", sizeBytes: 1,
                                           durationSeconds: 1, score: 1, evidence: [], proposedName: "\(i).mov")
            e.status = .ready
            if i % 3 == 0 { e.set(.balanceAudio, .done, output: "x/\(i)_balanced.mov") }
            return e
        }
        let clock = ContinuousClock()
        var count = 0
        let took = clock.measure { count = AP.work(in: plan).count }
        #expect(count == 33_334)
        #expect(took < .seconds(2), "budget 2 s for 100k rows: \(took)")
    }
}
