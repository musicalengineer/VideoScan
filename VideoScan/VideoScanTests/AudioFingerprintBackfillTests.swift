// AudioFingerprintBackfillTests.swift
// "Fingerprint Sound…" (Rick 2026-10-14) — the five dimensions:
//   LOGIC     — plan selection (needs / already stamped by outcome / changed
//               file redone / engine bump redone / no digest counted /
//               archived first per drive); shared: two copies, one decode,
//               one sidecar row; a second run decodes nothing; video-only
//               rows stamped from the catalog; ffmpeg "no audio" → stamp;
//               a failed decode is named and the run goes on; the memory
//               budget (pure); save cadence; a failed save undoes the
//               unsaved stamps; Stop finishes the file in flight and saves;
//               Pause between files; the words.
//   SCALE     — planning over 100k records on 10 drives inside a budget.
//   MEDIA     — mp4/aac, mov/pcm, mkv/flac, mxf/pcm(+black), avi/pcm, a
//               video-only file (→ no-sound stamp) and a truncated 0-byte
//               file (→ failed) through the REAL job and ffmpeg; the sidecar
//               holds the blob, the record the stamp, a rerun decodes
//               nothing; a small decoder cap → the partial stamp; the pace
//               on three 10-minute files (printed for the report).
//   ISOLATION — a model on the SHARED App Support catalog refuses from a
//               test host; a read-only sidecar folder and a poisoned sidecar
//               refuse by name before any decode; ffmpeg missing refuses
//               naming the Homebrew path; an offline drive is skipped and
//               counted; a drive leaving mid-run stops only its lane.
//   SENSOR    — the job's sources hold no file-moving / -removing /
//               -writing-to-media call and no Process() outside
//               ProcessRunner; every media file is byte-, inode- and
//               mtime-identical after a run and nothing appears beside it;
//               the real save reaches catalog.json and the sidecar lives in
//               the catalog's folder.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Helpers

private func fingerprint(seed: UInt32, count: Int = 120, seconds: Double) -> AudioFingerprint {
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds,
                     hashes: (0..<count).map { UInt32($0) &* 2_654_435_761 &+ seed },
                     times: (0..<count).map { UInt32($0 * 2) })
}

/// A stub pass: one fingerprint per path, as long as the catalog says.
private let stubPass: AudioFingerprintBackfillJob.Pass = { item in
    fingerprint(seed: UInt32(truncatingIfNeeded: item.path.hashValue), seconds: item.durationSeconds)
}

@MainActor
private func runJob(_ model: VideoScanModel,
                    pass: AudioFingerprintBackfillJob.Pass? = stubPass,
                    online: @escaping @Sendable (String) -> Bool = { _ in true },
                    configure: (AudioFingerprintBackfillJob) -> Void = { _ in }) async -> AudioFingerprintBackfillJob {
    let job = AudioFingerprintBackfillJob(model: model)
    job.volumeOnline = online
    job.tickMilliseconds = 20
    job.passForTesting = pass
    // The stubbed pass never runs ffmpeg; any executable satisfies the preflight.
    job.ffmpegPath = "/bin/ls"
    configure(job)
    job.start()
    await job.task?.value
    return job
}

/// Order / call recorder for the stubbed pass (an actor ≈ a mutex-guarded vector).
private actor PassLog {
    private(set) var paths: [String] = []
    func append(_ p: String) { paths.append(p) }
}

@MainActor
private extension ShowAgainSandbox {
    /// A record with a sampled digest (the scan's "v1:" hash) and a duration.
    @discardableResult
    func sound(_ name: String, bytes: Int = 2_000, seconds: Double = 60, onDisk: Bool = true,
               digest: String? = nil, fullHash: String? = nil, archived: Bool = false) throws -> VideoRecord {
        let r = try record(name, bytes: bytes, onDisk: onDisk, stage: .none)
        r.contentHash = digest ?? "v1:" + name
        if let fullHash {
            r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: String(repeating: fullHash, count: 64), byteCount: Int64(bytes))
        }
        r.durationSeconds = seconds
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        if archived { r.derivationKind = ArchivePromotion.derivationKind }
        return r
    }

    func store() throws -> AudioFingerprintStore { try AudioFingerprintStore(directory: catalogDir) }
}

// MARK: - Logic

@Suite("Fingerprint sound — logic", .serialized)
@MainActor
struct AudioFingerprintBackfillLogicTests {

    @Test("plan: only active records without a current stamp; stamped outcomes counted; changed files and engine bumps redone")
    func planSelection() throws {
        let sb = try ShowAgainSandbox.make("afb_plan"); defer { sb.cleanup() }
        let needs = try sb.sound("needs.mov")
        let done = try sb.sound("done.mov")
        done.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 60), contentDigest: "v1:done.mov", sizeBytes: 2_000, durationSeconds: 60)
        let silent = try sb.sound("silent.mov")
        silent.audioFingerprint = .noAudio(contentDigest: "v1:silent.mov", sizeBytes: 2_000)
        let partial = try sb.sound("partial.mov", seconds: 20_000)
        partial.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 14_400), contentDigest: "v1:partial.mov", sizeBytes: 2_000, durationSeconds: 20_000)
        let grew = try sb.sound("grew.mov", bytes: 3_000)
        grew.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 60), contentDigest: "v1:grew.mov", sizeBytes: 2_000, durationSeconds: 60)
        let rehashed = try sb.sound("rehashed.mov")
        rehashed.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 60), contentDigest: "v1:old-bytes", sizeBytes: 2_000, durationSeconds: 60)
        let oldEngine = try sb.sound("oldengine.mov")
        oldEngine.audioFingerprint = AudioFingerprintStamp(engineVersion: Int(AudioFingerprint.currentVersion) + 1, contentDigest: "v1:oldengine.mov",
                                                           sizeBytes: 2_000, outcome: .fingerprinted, analyzedSeconds: 60, complete: true, landmarks: 1, bytes: 8)
        let gainedFullHash = try sb.sound("full.mov")
        gainedFullHash.contentFixity = ContentFixity.captured(path: gainedFullHash.fullPath, digest: String(repeating: "f", count: 64), byteCount: 2_000)
        gainedFullHash.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 60), contentDigest: "v1:full.mov", sizeBytes: 2_000, durationSeconds: 60)
        let unhashed = try sb.sound("unhashed.mov", digest: "")
        let purged = try sb.sound("purged.mov"); purged.purgedAt = Date()
        let superseded = try sb.sound("superseded.mov"); superseded.supersededByID = UUID()
        let aside = try sb.sound("aside.mov"); aside.setAsideReason = "tidy"

        let plan = sb.model.audioFingerprintBackfillPlan()
        #expect(plan.lanes.count == 1)
        #expect(plan.lanes.first?.items.map(\.filename) == ["aside.mov", "full.mov", "grew.mov", "needs.mov", "oldengine.mov", "rehashed.mov"],
                Comment(rawValue: "\(plan.lanes.first?.items.map(\.filename) ?? [])"))
        #expect(plan.alreadyFingerprinted == 1 && plan.noSoundStamped == 1 && plan.partialStamped == 1, "done, silent, partial; full.mov's v1-keyed stamp is redone now that it has a full hash")
        #expect(plan.noDigest == 1 && plan.fileCount == 6 && plan.bytes == 13_000)
        _ = needs; _ = unhashed
        // The preferred digest is the full hash when the record has one.
        let full = AudioFingerprintBackfillPlanner.digests(of: gainedFullHash)
        #expect(full == ["sha256:" + String(repeating: "f", count: 64), "v1:full.mov"])
    }

    @Test("plan: one lane per drive, sorted by root; archived files first inside a lane, then path order")
    func planLanesArchivedFirst() {
        func rec(_ path: String, archived: Bool = false) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = path; r.filename = (path as NSString).lastPathComponent; r.sizeBytes = 10; r.contentHash = "v1:" + path
            if archived { r.derivationKind = ArchivePromotion.derivationKind }
            return r
        }
        let records = [rec("/Volumes/B/z.mov"), rec("/Volumes/A/c.mov"), rec("/Volumes/B/a.mov", archived: true),
                       rec("/Volumes/A/b.mov", archived: true), rec("/Volumes/B/m.mov")]
        let plan = AudioFingerprintBackfillPlanner.plan(records: records) { $0.derivationKind == ArchivePromotion.derivationKind }
        #expect(plan.lanes.map(\.root) == ["/Volumes/A", "/Volumes/B"])
        #expect(plan.lanes[0].items.map(\.filename) == ["b.mov", "c.mov"])
        #expect(plan.lanes[1].items.map(\.filename) == ["a.mov", "m.mov", "z.mov"])
        #expect(plan.archivedCount == 2)
    }

    @Test("two copies of the same bytes: one decode, one sidecar row, both stamped (the second 'shared'); a second run decodes nothing")
    func sharedCopiesAndResume() async throws {
        let sb = try ShowAgainSandbox.make("afb_shared"); defer { sb.cleanup() }
        let master = try sb.sound("a_master.mov", fullHash: "a")
        let copy = try sb.sound("b_copy.mov", fullHash: "a")
        let other = try sb.sound("c_other.mov", fullHash: "c")
        let sameKey = AudioFingerprintStamp.fullDigest(String(repeating: "a", count: 64))
        let calls = PassLog()
        let first = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) })
        #expect(first.state == .finished(summary: first.totals.line), Comment(rawValue: first.subtitle))
        #expect(await calls.paths.count == 2, "the copy was not decoded")
        #expect(first.totals[.fingerprinted] == 2 && first.totals[.shared] == 1, Comment(rawValue: first.totals.line))
        #expect(first.storedCount == 3)
        #expect(master.audioFingerprint?.outcome == .fingerprinted && copy.audioFingerprint?.landmarks == master.audioFingerprint?.landmarks)
        #expect(copy.audioFingerprint?.contentDigest == sameKey && other.audioFingerprint != nil)
        let store = try sb.store()
        #expect(try store.count() == 2, "one row for the shared bytes, one for the other file")
        #expect(try store.fingerprint(for: .init(contentDigest: sameKey, sizeBytes: 2_000))?.landmarkCount == 120)

        let second = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) })
        #expect(second.totals.planned == 0 && second.totals.alreadyStamped == 3, Comment(rawValue: second.totals.line))
        #expect(await calls.paths.count == 2, "nothing decoded again")

        // A sidecar row without a stamp (a crash between the two saves) heals as "shared".
        other.audioFingerprint = nil
        let third = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) })
        let thirdCalls = await calls.paths.count
        #expect(third.totals[.shared] == 1 && thirdCalls == 2, Comment(rawValue: third.totals.line))
        #expect(other.audioFingerprint != nil)
    }

    @Test("a video-only record is stamped 'no sound' from the catalog without a decode; ffmpeg's 'no audio' is stamped too")
    func noSoundStamps() async throws {
        let sb = try ShowAgainSandbox.make("afb_nosound"); defer { sb.cleanup() }
        let videoOnly = try sb.sound("v.mov"); videoOnly.streamTypeRaw = StreamType.videoOnly.rawValue
        let silent = try sb.sound("s.mov")
        let calls = PassLog()
        let job = await runJob(sb.model, pass: { item in
            await calls.append(item.path)
            throw AudioPCMDecoder.Failure.noAudioStream
        })
        #expect(await calls.paths == [silent.fullPath])
        #expect(job.totals[.noAudio] == 2 && job.totals[.failed] == 0, Comment(rawValue: job.totals.line))
        #expect(videoOnly.audioFingerprint?.outcome == .noAudio && silent.audioFingerprint?.outcome == .noAudio)
        #expect(try sb.store().count() == 0, "nothing to keep for silent files")
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 0, "neither is retried")
    }

    @Test("a decode that fails is named with ffmpeg's stderr tail; the lane goes on; a timeout is named too")
    func failedDecodeNamedAndSkipped() async throws {
        let sb = try ShowAgainSandbox.make("afb_fail"); defer { sb.cleanup() }
        let broken = try sb.sound("a_broken.mxf")
        let slow = try sb.sound("b_slow.mov")
        let next = try sb.sound("c_next.mov")
        let job = await runJob(sb.model, pass: { item in
            if item.path.hasSuffix("broken.mxf") { throw AudioPCMDecoder.Failure.decodeFailed(exitCode: 1, stderrTail: "Invalid data found when processing input") }
            if item.path.hasSuffix("slow.mov") { throw AudioPCMDecoder.Failure.timedOut }
            return try await stubPass(item)
        })
        #expect(job.totals[.failed] == 2 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(job.problems.first { $0.path == broken.fullPath }?.detail.contains("Invalid data found") == true)
        #expect(job.problems.first { $0.path == slow.fullPath }?.detail.contains("will try again next run") == true)
        #expect(broken.audioFingerprint == nil && slow.audioFingerprint == nil && next.audioFingerprint != nil)
        #expect(sb.catalogLogText().contains("FAILED \(broken.fullPath)"))
        if case .finished = job.state {} else { Issue.record("expected finished, got \(job.state)") }
    }

    @Test("memory budget (pure): ≤ 4 decodes, ≤ 1.5 GB estimated, a file over the budget runs alone, unknown duration = the cap")
    func decodeBudget() {
        let hour = 3_600.0
        #expect(AudioDecodeBudget.estimateBytes(durationSeconds: hour) == 120_000_000)
        #expect(AudioDecodeBudget.estimateBytes(durationSeconds: 0) == AudioDecodeBudget.estimateBytes(durationSeconds: 4 * hour), "unknown → the cap")
        #expect(AudioDecodeBudget.estimateBytes(durationSeconds: 40 * hour) == AudioDecodeBudget.estimateBytes(durationSeconds: 4 * hour), "never past the cap")
        #expect(AudioDecodeBudget.canStart(durationSeconds: 100 * hour, inFlight: []), "anything may start alone")
        #expect(AudioDecodeBudget.canStart(durationSeconds: 60, inFlight: [4 * hour, 4 * hour, 4 * hour]), "3 × 480 MB = 1.44 GB; a 4th of 2 MB still fits by bytes")
        #expect(!AudioDecodeBudget.canStart(durationSeconds: hour, inFlight: [4 * hour, 4 * hour, 4 * hour]), "…but a 4th of 120 MB does not")
        #expect(!AudioDecodeBudget.canStart(durationSeconds: 60, inFlight: [60, 60, 60, 60]), "never a 5th")
        #expect(AudioDecodeBudget.canStart(durationSeconds: 60, inFlight: [60, 60, 60]))
        #expect(!AudioDecodeBudget.canStart(durationSeconds: 4 * hour, inFlight: [4 * hour, 4 * hour, 4 * hour]), "4 × 480 MB > 1.5 GB")
        #expect(!AudioDecodeBudget.canStart(durationSeconds: 0, inFlight: [4 * hour, 4 * hour, 4 * hour]))
    }

    @Test("the job never runs more decodes at once than the budget allows")
    func budgetHonouredAtRunTime() async throws {
        let sb = try ShowAgainSandbox.make("afb_budget"); defer { sb.cleanup() }
        // Six 4-hour files on six "drives": the budget admits three at a time.
        for i in 0..<6 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/AFB\(i)_\(UUID().uuidString.prefix(4))/tape.mov"; r.filename = "tape\(i).mov"
            r.sizeBytes = 1_000; r.contentHash = "v1:tape\(i)"; r.durationSeconds = 4 * 3_600
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            sb.model.records.append(r)
        }
        let gauge = ConcurrencyGauge()
        let job = await runJob(sb.model, pass: { item in
            await gauge.enter()
            try await Task.sleep(nanoseconds: 60_000_000)
            await gauge.leave()
            return try await stubPass(item)
        }) { $0.fileExists = { _ in true } }
        #expect(job.totals[.fingerprinted] == 6, Comment(rawValue: job.totals.line))
        let peak = await gauge.peak
        #expect(peak == 3, "peak was \(peak)")
    }

    @Test("an acknowledged save every N stamps and at the end; the clock alone triggers one")
    func saveCadence() async throws {
        let sb = try ShowAgainSandbox.make("afb_save"); defer { sb.cleanup() }
        for i in 0..<5 { try sb.sound("f\(i).mov") }
        let byCount = await runJob(sb.model) { j in
            j.checkpointFiles = 2; j.checkpointSeconds = 3_600; j.saveCatalogForTesting = { true }
        }
        #expect(byCount.storedCount == 5 && byCount.saveCount == 3, "after 2, after 4, and the final one (got \(byCount.saveCount))")
        for r in sb.model.records { r.audioFingerprint = nil }
        let byClock = await runJob(sb.model) { j in
            j.checkpointFiles = 10_000; j.checkpointSeconds = 0; j.saveCatalogForTesting = { true }
        }
        #expect(byClock.storedCount == 5 && byClock.saveCount >= 2, "time-based checkpoints fired (got \(byClock.saveCount))")
    }

    @Test("a failed catalog save stops the job, undoes the unsaved stamps and says so; the sidecar rows stay (harmless)")
    func failedSaveUndoes() async throws {
        let sb = try ShowAgainSandbox.make("afb_savefail"); defer { sb.cleanup() }
        let recs = try (0..<4).map { try sb.sound("s\($0).mov") }
        let job = await runJob(sb.model) { j in j.checkpointFiles = 2; j.saveCatalogForTesting = { false } }
        #expect(job.saveFailed && job.storedCount == 0)
        if case .failed(let msg) = job.state { #expect(msg.contains("could not be saved")) } else { Issue.record("expected failed, got \(job.state)") }
        #expect(recs.allSatisfy { $0.audioFingerprint == nil }, "every stamp undone")
        #expect(job.totals.done < 4, "it stopped after the failed save")
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 4, "all four are looked at again next run")
    }

    @Test("Stop finishes the file being read, saves it, ends Cancelled; Pause takes effect between files")
    func stopAndPause() async throws {
        let sb = try ShowAgainSandbox.make("afb_stop"); defer { sb.cleanup() }
        for i in 0..<5 { try sb.sound("t\(i).mov") }
        let job = AudioFingerprintBackfillJob(model: sb.model)
        job.tickMilliseconds = 20
        job.ffmpegPath = "/bin/ls"
        job.passForTesting = { item in
            try await Task.sleep(nanoseconds: 120_000_000)
            return try await stubPass(item)
        }
        job.start()
        try? await Task.sleep(nanoseconds: 40_000_000)
        job.pause()
        #expect(job.subtitle.hasPrefix("Pausing after the current file"), Comment(rawValue: job.subtitle))
        try? await Task.sleep(nanoseconds: 250_000_000)
        #expect(job.totals.done == 1 && job.state == .running, "the first file finished; the second waits")
        job.resume()
        try? await Task.sleep(nanoseconds: 40_000_000)
        job.cancel()
        #expect(job.subtitle.hasPrefix("Stopping — finishing 1 file"), Comment(rawValue: job.subtitle))
        await job.task?.value
        #expect(job.state == .cancelled, "\(job.state)")
        #expect(job.totals.done == 2 && job.storedCount == 2, "the in-flight file was finished and saved: \(job.totals.line)")
        #expect(job.totals[.cancelled] == 0, "nothing was cut off")
        #expect(sb.model.audioFingerprintBackfillPlan().fileCount == 3, "the rest wait for the next run")
    }

    @Test("a quit cuts the decode, records it 'cut off', and still saves what was done")
    func quitCutsAndSaves() async throws {
        let sb = try ShowAgainSandbox.make("afb_quit"); defer { sb.cleanup() }
        for i in 0..<3 { try sb.sound("q\(i).mov") }
        let job = AudioFingerprintBackfillJob(model: sb.model)
        job.tickMilliseconds = 20
        job.ffmpegPath = "/bin/ls"
        job.passForTesting = { item in
            if item.filename == "q1.mov" { try await Task.sleep(nanoseconds: 5_000_000_000) }
            return try await stubPass(item)
        }
        job.start()
        try? await Task.sleep(nanoseconds: 150_000_000)
        job.stopForQuit()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(job.totals[.fingerprinted] == 1 && job.totals[.cancelled] == 1, Comment(rawValue: job.totals.line))
        #expect(job.storedCount == 1)
    }

    @Test("refused on a read-only catalog and when ffmpeg is missing (naming the Homebrew path) — nothing read")
    func refusals() async throws {
        let sb = try ShowAgainSandbox.make("afb_refuse"); defer { sb.cleanup() }
        try sb.sound("a.mov")
        let calls = PassLog()
        let pass: AudioFingerprintBackfillJob.Pass = { item in await calls.append(item.path); return try await stubPass(item) }
        let missing = await runJob(sb.model, pass: pass) { $0.ffmpegPath = "/opt/homebrew/bin/ffmpeg-not-here-\(UUID().uuidString.prefix(4))" }
        #expect(missing.wasRefused)
        if case .failed(let msg) = missing.state {
            #expect(msg.contains("ffmpeg was not found at /opt/homebrew/bin/ffmpeg-not-here") && msg.contains("brew install ffmpeg"), Comment(rawValue: msg))
        } else { Issue.record("expected failed, got \(missing.state)") }
        sb.model.applyReadOnlyMode(true)
        let readOnly = await runJob(sb.model, pass: pass)
        #expect(readOnly.wasRefused)
        #expect(await calls.paths.isEmpty)
    }

    @Test("the words: the totals line, the progress line, the start clause's budget, the sheet's headline")
    func words() {
        var t = AudioFingerprintBackfillTotals()
        t.planned = 3_310; t.plannedBytes = 3_000_000_000_000; t.alreadyStamped = 6_940; t.noDigest = 2
        t.add(.fingerprinted, files: 1_204, bytes: 1_200_000_000_000); t.readBytes = 1_200_000_000_000
        t.landmarks = 2_100_000; t.sidecarBytes = 17_000_000
        t.add(.shared, files: 96, bytes: 0); t.add(.noAudio, files: 12, bytes: 0); t.add(.failed, files: 2, bytes: 0)
        #expect(t.line == "1,204 of 3,310 fingerprinted (1.2 TB read, 2.1M landmarks, 17 MB kept) · 96 shared with a copy · 12 no sound · 2 failed · 6,940 already done · 2 never hashed (scan them first)",
                Comment(rawValue: t.line))
        #expect(t.progressLine(reading: [], lanesActive: 0, elapsed: 1) == "1,314 of 3,310")
        let p = t.progressLine(reading: ["clip.mov", "tape.mxf"], lanesActive: 2, elapsed: 3_000)
        #expect(p.hasPrefix("1,314 of 3,310 · 2 drives reading · clip.mov +1 · 400 MB/s · ~1 h 15 min left"), Comment(rawValue: p))
        #expect(AudioFingerprintBackfillJob.seconds(59.6) == "60 s" && AudioFingerprintBackfillJob.seconds(600) == "10 min"
                && AudioFingerprintBackfillJob.seconds(14_400) == "4.0 h")
        #expect(AudioFingerprintBackfillJob.decodeDeadline(sizeBytes: 50_000_000_000) == 5_300, "300 s + 1 s per 10 MB")
        var plan = AudioFingerprintBackfillPlan()
        #expect(AudioFingerprintBackfillSheet.headline(plan) == "Every file already has a sound fingerprint (0 done). Nothing to do.")
        var lane = AudioFingerprintBackfillLane(root: "/Volumes/A")
        lane.items = [AudioFingerprintBackfillItem(id: UUID(), path: "/Volumes/A/a.mov", filename: "a.mov", sizeBytes: 2_400_000_000_000,
                                                   durationSeconds: 1, isVideoOnly: false, isArchived: true, digests: ["v1:a"]),
                      AudioFingerprintBackfillItem(id: UUID(), path: "/Volumes/A/b.mov", filename: "b.mov", sizeBytes: 1,
                                                   durationSeconds: 1, isVideoOnly: false, isArchived: false, digests: ["v1:b"])]
        plan.lanes = [lane]; plan.alreadyFingerprinted = 6_940
        #expect(AudioFingerprintBackfillSheet.headline(plan) == "2 files need a sound fingerprint — about 2.4 TB to read. 6,940 are already done.")
        #expect(AudioFingerprintBackfillSheet.archiveLine(plan) == "1 archived file goes first, then the other 1 — drive by drive, one reader per drive."
                || AudioFingerprintBackfillSheet.archiveLine(plan) == "1 archived file go first, then the other 1 — drive by drive, one reader per drive.")
    }
}

@Suite("Fingerprint sound — QA round 1 (sharing identity, checkpoint race, budget across the gate)", .serialized)
@MainActor
struct AudioFingerprintBackfillQARound1Tests {

    @Test("P1-a/b: a sampled digest never shares; a shared stamp's key is in the sidecar")
    func sampledDigestNeverShares() async throws {
        let sb = try ShowAgainSandbox.make("afb_v1share"); defer { sb.cleanup() }
        try sb.sound("a_first.mov", digest: "v1:same")
        let b = try sb.sound("b_second.mov", digest: "v1:same")
        b.contentFixity = ContentFixity.captured(path: b.fullPath, digest: String(repeating: "b", count: 64), byteCount: 2_000)
        let calls = PassLog()
        let job = await runJob(sb.model, pass: { await calls.append($0.path); return try await stubPass($0) })
        let decoded = await calls.paths.count
        #expect(decoded == 2, "v1 must not share")
        #expect(job.totals[.shared] == 0)
        let stamp = try #require(b.audioFingerprint)
        #expect(stamp.contentDigest.hasPrefix("sha256:"))
        #expect(try sb.store().fingerprint(for: .init(contentDigest: stamp.contentDigest, sizeBytes: 2_000)) != nil)
        // A sha256 copy of b IS shared, and its stamp names the key the row was found under.
        let c = try sb.sound("c_copy.mov", digest: "v1:other", fullHash: "b")
        let second = await runJob(sb.model, pass: { await calls.append($0.path); return try await stubPass($0) })
        #expect(second.totals[.shared] == 1, Comment(rawValue: second.totals.line))
        let cStamp = try #require(c.audioFingerprint)
        #expect(cStamp.contentDigest == stamp.contentDigest)
        #expect(try sb.store().has(.init(contentDigest: cStamp.contentDigest, sizeBytes: 2_000)))
    }

    @Test("P1-c: a file stamped while a checkpoint save is in flight still reaches the sidecar")
    func checkpointRaceKeepsSidecarBytes() async throws {
        let sb = try ShowAgainSandbox.make("afb_race"); defer { sb.cleanup() }
        func record(_ root: String) -> VideoRecord {
            let r = VideoRecord(); r.fullPath = "/Volumes/\(root)/t.mov"; r.filename = "t.mov"; r.sizeBytes = 1_000
            r.contentHash = "v1:\(root)"; r.durationSeconds = 60; r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            sb.model.records.append(r); return r
        }
        let slow = record("AFBR_B_\(UUID().uuidString.prefix(4))"); _ = record("AFBR_A_\(UUID().uuidString.prefix(4))")
        let job = await runJob(sb.model, pass: { item in
            if item.path.contains("AFBR_B") { try await Task.sleep(nanoseconds: 100_000_000) }
            return try await stubPass(item)
        }) { j in
            j.fileExists = { _ in true }; j.checkpointFiles = 1
            j.saveCatalogForTesting = { try? await Task.sleep(nanoseconds: 300_000_000); return true }
        }
        let stamp = try #require(slow.audioFingerprint)
        #expect(try sb.store().has(.init(contentDigest: stamp.contentDigest, sizeBytes: 1_000)), "stamped but never put")
        #expect(job.storedCount == 2)
    }

    @Test("P2: the budget holds when the gate acquire suspends")
    func budgetHoldsAcrossGateHop() async throws {
        let sb = try ShowAgainSandbox.make("afb_budgetgate"); defer { sb.cleanup() }
        for i in 0..<6 {
            let r = VideoRecord(); r.fullPath = "/Volumes/AFBG\(i)_\(UUID().uuidString.prefix(4))/tape.mov"; r.filename = "tape\(i).mov"
            r.sizeBytes = 1_000; r.contentHash = "v1:g\(i)"; r.durationSeconds = 4 * 3_600; r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            sb.model.records.append(r)
        }
        let gauge = ConcurrencyGauge()
        _ = await runJob(sb.model, pass: { item in
            await gauge.enter(); try await Task.sleep(nanoseconds: 60_000_000); await gauge.leave(); return try await stubPass(item)
        }) { j in
            j.fileExists = { _ in true }
            j.gatesFor = { path in [MediaVolumeGate(root: MediaVolumeGatePolicy.volumeRoot(forPath: path), label: "g", semaphore: AsyncSemaphore(limit: 1))] }
        }
        let peak = await gauge.peak
        #expect(peak == 3, "peak was \(peak)")
    }

    @Test("gap 3: a failed sidecar write reverts the unsaved stamps and stops with a named outcome")
    func failedSidecarPutUndoes() async throws {
        let sb = try ShowAgainSandbox.make("afb_putfail"); defer { sb.cleanup() }
        let recs = try (0..<3).map { try sb.sound("p\($0).mov") }
        let job = await runJob(sb.model) { j in
            j.checkpointFiles = 1
            j.sidecarPutForTesting = { _ in throw AudioFingerprintStore.Failure.sql("disk full") }
        }
        #expect(job.saveFailed && job.storedCount == 0)
        if case .failed(let msg) = job.state { #expect(msg.contains("could not be saved"), Comment(rawValue: msg)) } else { Issue.record("\(job.state)") }
        #expect(recs.allSatisfy { $0.audioFingerprint == nil }, "every stamp undone")
        #expect(try sb.store().count() == 0)
        #expect(sb.catalogLogText().contains("fingerprint file could not be written"))
    }

    @Test("gap 4: an engine version bump redoes a no-sound stamp too")
    func engineBumpRedoesNoAudio() throws {
        let sb = try ShowAgainSandbox.make("afb_bump"); defer { sb.cleanup() }
        let r = try sb.sound("s.mov")
        r.audioFingerprint = AudioFingerprintStamp(engineVersion: Int(AudioFingerprint.currentVersion) - 1, contentDigest: "v1:s.mov",
                                                   sizeBytes: 2_000, outcome: .noAudio, analyzedSeconds: 0, complete: true, landmarks: 0, bytes: 0)
        let plan = sb.model.audioFingerprintBackfillPlan()
        #expect(plan.fileCount == 1 && plan.noSoundStamped == 0)
    }
}

/// Counts how many stubbed passes overlap (≈ an atomic high-water mark).
private actor ConcurrencyGauge {
    private var now = 0
    private(set) var peak = 0
    func enter() { now += 1; peak = max(peak, now) }
    func leave() { now -= 1 }
}

// MARK: - Scale

@Suite("Fingerprint sound — scale (100k records)", .serialized)
@MainActor
struct AudioFingerprintBackfillScaleTests {

    /// 100k records on 10 drives, every 4th already stamped, every 10th
    /// archived. Budget (Debug, M4 Max, headroom ×3+): planning < 1.5 s.
    @Test func planningAt100k() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/Drive\(i % 10)/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i)
            r.contentHash = "v1:\(i)"
            r.durationSeconds = 120
            if i % 4 == 0 {
                r.audioFingerprint = .fingerprinted(fingerprint(seed: 1, seconds: 120), contentDigest: "v1:\(i)", sizeBytes: r.sizeBytes, durationSeconds: 120)
            }
            if i % 10 == 1 { r.derivationKind = ArchivePromotion.derivationKind }
            records.append(r)
        }
        let t0 = Date()
        let plan = AudioFingerprintBackfillPlanner.plan(records: records) { $0.derivationKind == ArchivePromotion.derivationKind }
        let elapsed = -t0.timeIntervalSinceNow
        #expect(plan.lanes.count == 10)
        #expect(plan.alreadyFingerprinted == 25_000 && plan.fileCount == 75_000 && plan.archivedCount == 10_000)
        #expect(plan.lanes.allSatisfy { lane in
            let flags = lane.items.map(\.isArchived)
            return flags == flags.sorted { $0 && !$1 }
        }, "archived first in every lane")
        #expect(elapsed < 1.5, "planning took \(elapsed) s")
    }
}

// MARK: - Isolation

@Suite("Fingerprint sound — isolation: shared catalog, sidecar folder, drives", .serialized)
@MainActor
struct AudioFingerprintBackfillIsolationTests {

    @Test("a model on the SHARED store (the real catalog) refuses from a test host: nothing read, nothing written")
    func sharedStoreRefuses() async throws {
        let sb = try ShowAgainSandbox.make("afb_sharedstore"); defer { sb.cleanup() }
        let a = try sb.sound("a.mov")
        sb.model.catalogStore = CatalogStore.shared
        let calls = PassLog()
        let job = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) })
        #expect(job.wasRefused)
        if case .failed(let msg) = job.state { #expect(msg.contains("shared one")) } else { Issue.record("\(job.state)") }
        #expect(await calls.paths.isEmpty)
        #expect(a.audioFingerprint == nil)
        #expect(job.store == nil, "the sidecar was never opened")
    }

    @Test("a read-only sidecar folder is refused by name before any decode")
    func readOnlySidecarFolderRefuses() async throws {
        let sb = try ShowAgainSandbox.make("afb_rodir"); defer { sb.cleanup() }
        try sb.sound("a.mov")
        let dir = sb.root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        guard !FileManager.default.isWritableFile(atPath: dir.path) else { return }   // root cannot make it read-only
        let calls = PassLog()
        let job = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) }) { $0.storeDirectory = dir }
        #expect(job.wasRefused)
        if case .failed(let msg) = job.state { #expect(msg.contains("not writable"), Comment(rawValue: msg)) } else { Issue.record("\(job.state)") }
        #expect(await calls.paths.isEmpty)
    }

    @Test("a poisoned sidecar (garbage where the database should be) is refused by name; the file is left as found")
    func poisonedSidecarRefuses() async throws {
        let sb = try ShowAgainSandbox.make("afb_poison"); defer { sb.cleanup() }
        try sb.sound("a.mov")
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        let file = sb.catalogDir.appendingPathComponent(AudioFingerprintStore.fileName)
        let garbage = Data("not a database".utf8)
        try garbage.write(to: file)
        let calls = PassLog()
        let job = await runJob(sb.model, pass: { item in await calls.append(item.path); return try await stubPass(item) })
        #expect(job.wasRefused)
        if case .failed(let msg) = job.state { #expect(msg.contains("not a database"), Comment(rawValue: msg)) } else { Issue.record("\(job.state)") }
        #expect(await calls.paths.isEmpty)
        #expect(try Data(contentsOf: file) == garbage)
    }

    @Test("a drive that is not connected is skipped and counted; the run finishes", .timeLimit(.minutes(1)))
    func offlineDriveSkipped() async throws {
        let sb = try ShowAgainSandbox.make("afb_off"); defer { sb.cleanup() }
        let offlineRoot = "/Volumes/AFBOffline_\(UUID().uuidString.prefix(8))"
        let local = try sb.sound("here.mov")
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/away.mov"; away.filename = "away.mov"; away.sizeBytes = 3_000; away.contentHash = "v1:away"
        away.directory = offlineRoot
        sb.model.records.append(away)
        let job = await runJob(sb.model, online: { !$0.hasPrefix(offlineRoot) })
        #expect(job.totals[.driveNotConnected] == 1 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(local.audioFingerprint != nil && away.audioFingerprint == nil)
        #expect(job.lanes.first { $0.root == offlineRoot }?.phase == .disconnected)
        if case .finished = job.state {} else { Issue.record("expected finished, got \(job.state)") }
    }

    @Test("a drive that leaves mid-run stops its lane; the rest are counted, not read", .timeLimit(.minutes(1)))
    func driveLeavingMidRun() async throws {
        let sb = try ShowAgainSandbox.make("afb_leave"); defer { sb.cleanup() }
        let a = try sb.sound("a.mov")
        try sb.sound("b.mov", onDisk: false)   // the look that fails
        let c = try sb.sound("c.mov")
        let calls = CallCounter()
        let job = await runJob(sb.model, online: { _ in calls.next() == 1 })
        #expect(a.audioFingerprint != nil && c.audioFingerprint == nil)
        #expect(job.totals[.driveNotConnected] == 2, Comment(rawValue: job.totals.line))
        #expect(job.lanes.first?.phase == .disconnected)
    }

    @Test("a missing file (drive connected) is named, counted and skipped")
    func missingFile() async throws {
        let sb = try ShowAgainSandbox.make("afb_missing"); defer { sb.cleanup() }
        let gone = try sb.sound("a_gone.mov", onDisk: false)
        let next = try sb.sound("b_next.mov")
        let job = await runJob(sb.model)
        #expect(job.totals[.missing] == 1 && job.totals[.fingerprinted] == 1, Comment(rawValue: job.totals.line))
        #expect(job.problems.contains { $0.path == gone.fullPath && $0.result == .missing })
        #expect(next.audioFingerprint != nil)
    }
}

/// Thread-safe call counter for `volumeOnline` seams (≈ C++ std::atomic<int>).
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

// MARK: - Sensor

@Suite("Fingerprint sound — sensor: read only on media, durable saves", .serialized)
@MainActor
struct AudioFingerprintBackfillSensorTests {

    static let appSources = [
        "AudioFingerprintBackfill.swift", "AudioFingerprintBackfillJob.swift", "AudioFingerprintBackfillDetailView.swift",
        "AudioFingerprintBackfillMenuItem.swift", "VideoScanModel+AudioFingerprintBackfill.swift",
    ]

    @Test("no file-moving, -removing or -writing-to-media call, and no Process() outside ProcessRunner, in the job's sources")
    func sourceIsReadOnly() throws {
        for name in Self.appSources {
            let code = try SourceTree.appSource(named: name).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            for call in CheckCopiesSensorTests.forbidden + ["analyzeDuplicates", "purge", "setAside(", "Process()", "Process(", "posix_spawn"] {
                #expect(!code.contains(call), "\(name) calls \(call)")
            }
        }
    }

    @Test("every file is still at its path with the same bytes, inode and mtime after a run; nothing appeared beside the media; the sidecar is in the catalog's folder")
    func filesUntouched() async throws {
        let sb = try ShowAgainSandbox.make("afb_ro"); defer { sb.cleanup() }
        let recs = try (0..<4).map { try sb.sound("ro\($0).mov", bytes: 3_000 + $0) }
        let before = try recs.map { try MediaFingerprint.of($0.fullPath) }
        let job = await runJob(sb.model)
        #expect(job.totals[.fingerprinted] == 4)
        #expect(try recs.map { try MediaFingerprint.of($0.fullPath) } == before)
        let names = try FileManager.default.contentsOfDirectory(atPath: sb.files.path).sorted()
        #expect(names == recs.map(\.filename).sorted(), "nothing appeared beside the media")
        #expect(job.store?.fileURL.path == sb.catalogDir.appendingPathComponent(AudioFingerprintStore.fileName).path)
        #expect(FileManager.default.fileExists(atPath: sb.catalogDir.appendingPathComponent(AudioFingerprintStore.fileName).path))
    }

    @Test("the real save reaches catalog.json: a reloaded catalog carries the stamps, and the sidecar carries their bytes")
    func stampsSurviveAReload() async throws {
        let sb = try ShowAgainSandbox.make("afb_durable"); defer { sb.cleanup() }
        let a = try sb.sound("d.mov")
        let job = await runJob(sb.model)
        #expect(job.saveCount >= 1 && !job.saveFailed)
        let reloaded = CatalogStore(directory: sb.catalogDir).load()
        let stamp = try #require(reloaded.first { $0.id == a.id }?.audioFingerprint)
        let live = try #require(a.audioFingerprint)
        #expect(stamp.contentDigest == live.contentDigest && stamp.sizeBytes == live.sizeBytes && stamp.landmarks == live.landmarks
                && stamp.bytes == live.bytes && stamp.outcome == live.outcome && stamp.complete == live.complete
                && stamp.analyzedSeconds == live.analyzedSeconds && stamp.engineVersion == live.engineVersion)
        #expect(abs(stamp.computedAt.timeIntervalSince(live.computedAt)) < 1, "catalog.json keeps whole seconds")
        let kept = try #require(try sb.store().fingerprint(for: .init(contentDigest: stamp.contentDigest, sizeBytes: stamp.sizeBytes)))
        #expect(kept.landmarkCount == stamp.landmarks && kept.estimatedBytes == stamp.bytes)
    }

    @Test("exactly one START and one OUTCOME line per run, including a stopped one")
    func oneStartOneOutcome() async throws {
        let sb = try ShowAgainSandbox.make("afb_lines"); defer { sb.cleanup() }
        try sb.sound("l.mov")
        _ = await runJob(sb.model)
        let text = sb.catalogLogText()
        #expect(text.components(separatedBy: "Fingerprint sound: START").count == 2)
        #expect(text.components(separatedBy: "Fingerprint sound: OUTCOME").count == 2)
    }
}

// MARK: - Media matrix

@Suite("Fingerprint sound — media matrix (real ffmpeg)", .serialized)
@MainActor
struct AudioFingerprintBackfillMediaMatrixTests {

    /// Speech-like test sound: two slowly wandering tones plus a little
    /// noise — plenty of spectral peaks for landmarks.
    private static func sound(_ seconds: Int) -> [String] {
        ["-f", "lavfi", "-i",
         "aevalsrc=0.4*sin(2*PI*(400+150*sin(2*PI*0.7*t))*t)+0.3*sin(2*PI*(1200+300*sin(2*PI*0.4*t))*t)+0.03*random(0):s=8000:d=\(seconds)"]
    }
    private static let picture = ["-f", "lavfi", "-i", "testsrc=duration=6:size=160x120:rate=25"]

    private static let fixtures: [(name: String, args: [String])] = [
        ("test_afb_aac.mp4", picture + sound(6) + ["-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]),
        ("test_afb_pcm.mov", picture + sound(6) + ["-shortest", "-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
        ("test_afb_flac.mkv", picture + sound(6) + ["-shortest", "-c:v", "ffv1", "-c:a", "flac"]),
        ("test_afb_pcm.mxf", ["-f", "lavfi", "-i", "color=black:duration=6:size=720x576:rate=25"] + sound(6)
            + ["-shortest", "-c:v", "mpeg2video", "-c:a", "pcm_s16le", "-ar", "48000"]),
        ("test_afb_pcm.avi", ["-f", "lavfi", "-i", "testsrc=duration=6:size=720x480:rate=30000/1001"] + sound(6)
            + ["-shortest", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le", "-ar", "48000"]),
    ]

    private static func model(in dir: URL) -> VideoScanModel {
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        return model
    }

    private static func record(_ path: String, seconds: Double, in model: VideoScanModel) throws -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path; r.filename = (path as NSString).lastPathComponent; r.directory = (path as NSString).deletingLastPathComponent
        r.sizeBytes = (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value ?? 0
        r.contentHash = "v1:" + r.filename
        r.durationSeconds = seconds
        model.records.append(r)
        return r
    }

    @Test("five containers fingerprinted; a video-only file → no-sound stamp; a truncated file → failed; sidecar has the blobs; a rerun decodes nothing; files unchanged",
          .timeLimit(.minutes(3)))
    func matrix() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("afb_mm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = Self.model(in: dir)
        for f in Self.fixtures {
            let path = dir.appendingPathComponent(f.name).path
            try CleanupTestMedia.runFFmpeg(f.args, output: path)
            try Self.record(path, seconds: 6, in: model)
        }
        let videoOnlyPath = dir.appendingPathComponent("test_afb_videoonly.mp4").path
        try CleanupTestMedia.runFFmpeg(Self.picture + ["-an", "-c:v", "libx264", "-preset", "ultrafast"], output: videoOnlyPath)
        let videoOnly = try Self.record(videoOnlyPath, seconds: 6, in: model)
        let truncatedPath = dir.appendingPathComponent("test_afb_truncated.mov").path
        try Data().write(to: URL(fileURLWithPath: truncatedPath))
        let truncated = try Self.record(truncatedPath, seconds: 6, in: model)
        truncated.sizeBytes = 1_000   // the catalog remembers a real file; the disk has 0 bytes
        let before = try model.records.map { try MediaFingerprint.of($0.fullPath) }

        let job = await runJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath }
        #expect(job.totals.planned == 7, Comment(rawValue: job.totals.line))
        #expect(job.totals[.fingerprinted] == 5 && job.totals[.noAudio] == 1 && job.totals[.failed] == 1,
                Comment(rawValue: job.problems.map { "\($0.filename): \($0.detail)" }.joined(separator: " | ")))
        let store = try AudioFingerprintStore(directory: model.audioFingerprintSidecarDirectory)
        for r in model.records where r.audioFingerprint?.outcome == .fingerprinted {
            let stamp = try #require(r.audioFingerprint)
            #expect(stamp.landmarks > 50 && stamp.complete && stamp.analyzedSeconds > 5, "\(r.filename): \(stamp)")
            let kept = try #require(try store.fingerprint(for: .init(contentDigest: stamp.contentDigest, sizeBytes: stamp.sizeBytes)), "\(r.filename)")
            #expect(kept.landmarkCount == stamp.landmarks && kept.estimatedBytes == stamp.bytes)
        }
        #expect(videoOnly.audioFingerprint?.outcome == .noAudio)
        #expect(truncated.audioFingerprint == nil)
        #expect(job.problems.first { $0.path == truncatedPath }?.result == .failed)
        #expect(try model.records.map { try MediaFingerprint.of($0.fullPath) } == before, "no file changed")
        #expect(try store.count() == 5)
        // The sidecar lives in the catalog's folder, never beside the media.
        let beside = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".sqlite") }
        #expect(beside.isEmpty)

        // A rerun plans only the failed file (nothing stamped is decoded again).
        let rerun = await runJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath }
        #expect(rerun.totals.planned == 1 && rerun.totals.alreadyStamped == 6, Comment(rawValue: rerun.totals.line))
    }

    @Test("a decoder cap shorter than the recording → a PARTIAL stamp that says how much was analysed; a rerun does not retry it",
          .timeLimit(.minutes(2)))
    func partialStamp() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("afb_partial")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = Self.model(in: dir)
        let path = dir.appendingPathComponent("test_afb_long.mov").path
        try CleanupTestMedia.runFFmpeg(Self.sound(10) + ["-c:a", "pcm_s16le"], output: path)
        let rec = try Self.record(path, seconds: 10, in: model)
        let job = await runJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath; $0.decoderMaxSeconds = 4 }
        #expect(job.totals[.partial] == 1 && job.totals[.fingerprinted] == 0, Comment(rawValue: job.totals.line))
        let stamp = try #require(rec.audioFingerprint)
        #expect(!stamp.complete && stamp.outcome == .fingerprinted)
        #expect(abs(stamp.analyzedSeconds - 4) < 0.2, "analysed \(stamp.analyzedSeconds) s")
        #expect(job.problems.first?.detail.contains("only the first 4 s of 10 s") == true, Comment(rawValue: job.problems.first?.detail ?? ""))
        let store = try AudioFingerprintStore(directory: model.audioFingerprintSidecarDirectory)
        #expect(try store.summary(for: .init(contentDigest: stamp.contentDigest, sizeBytes: stamp.sizeBytes))?.analyzedSeconds == stamp.analyzedSeconds)
        let rerun = await runJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath; $0.decoderMaxSeconds = 4 }
        #expect(rerun.totals.planned == 0 && rerun.totals.alreadyStamped == 1, "a partial stamp is not retried nightly")
        #expect(model.audioFingerprintBackfillPlan().partialStamped == 1)
    }

    /// The overnight pace, for the report: three 10-minute files, wall
    /// time per file and MB/s (Debug). Loose budget — the point is the
    /// printed numbers, not a gate.
    @Test("pace on three 10-minute files (printed)", .timeLimit(.minutes(5)))
    func paceOnTenMinuteFiles() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("afb_pace")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = Self.model(in: dir)
        for i in 0..<3 {
            let path = dir.appendingPathComponent("test_afb_pace\(i).mp4").path
            try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=duration=600:size=320x240:rate=25"] + Self.sound(600)
                                           + ["-shortest", "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"], output: path)
            try Self.record(path, seconds: 600, in: model)
        }
        let bytes = model.records.reduce(Int64(0)) { $0 + $1.sizeBytes }
        let start = Date()
        let job = await runJob(model, pass: nil) { $0.ffmpegPath = ToolLocator.ffmpegPath }
        let elapsed = Date().timeIntervalSince(start)
        #expect(job.totals[.fingerprinted] == 3, Comment(rawValue: job.totals.line))
        let perFile = elapsed / 3
        let mbps = Double(bytes) / elapsed / 1_000_000
        print(String(format: "PACE (Debug): 3 × 10-min files, %.0f MB total: %.2f s per file, %.1f MB/s, %@",
                     Double(bytes) / 1_000_000, perFile, mbps, job.totals.line))
        #expect(elapsed < 120, "took \(elapsed) s")
    }
}
