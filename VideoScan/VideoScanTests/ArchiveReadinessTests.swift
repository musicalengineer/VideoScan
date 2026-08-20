// ArchiveReadinessTests.swift
// Five-dimension coverage for the archival readiness assessment
// (Rick 2026-08-16): LOGIC (codec table matrix incl. case/alias
// variants, audio states, date states, blocking only on !isPlayable,
// audio-first warning order, token/summary), manifest header
// compatibility (legacy 12-col manifests keep their column count, new
// manifests carry `readiness`, validation accepts both), a promote SENSOR
// (a DV file lands with the at-risk token in its row; an un-probeable
// file is refused without the override and promoted with it), ISOLATION
// (temp sandbox, isolated store — the shared App Support is never
// touched), and a SCALE guard (assess() over 100k inputs).

import Foundation
import Testing
@testable import VideoScan

// MARK: - Logic

@Suite("Archive readiness — logic")
struct ArchiveReadinessLogicTests {

    private func inputs(_ configure: (inout ArchiveReadiness.Inputs) -> Void) -> ArchiveReadiness.Inputs {
        var i = ArchiveReadiness.Inputs()
        i.isPlayable = "Yes"
        i.streamTypeRaw = StreamType.videoAndAudio.rawValue
        i.videoCodec = "h264"
        i.audioCodec = "aac"
        i.userDate = "1992"
        configure(&i)
        return i
    }

    @Test("codec table: at-risk variants (case + aliases)",
          arguments: ["dvvideo", "DVVIDEO", "dv", "DVCPRO", "hdv", "mpeg2video", "MPEG-2 Video", "mpeg1video", "vob",
                      "svq1", "svq3", "cinepak", "cvid", "indeo5", "iv50", "rv40", "wmv3", "WMV3", "vc1", "VC-1", "wvc1",
                      "mpeg4", "divx", "xvid", "DX50", "h263", "flv1", "vp6f", "msmpeg4v3"])
    func atRiskCodecs(codec: String) {
        let r = ArchiveReadiness.assess(inputs { $0.videoCodec = codec })
        guard case .atRisk = r.format else { Issue.record("\(codec) should be at-risk, got \(r.format)"); return }
        #expect(!r.blocking)
        #expect(r.warnings.contains { $0.contains("at-risk") })
    }

    @Test("codec table: archival-safe variants (case + aliases)",
          arguments: ["prores", "ProRes", "prores_ks", "ProRes 422 HQ", "apch", "dnxhd", "dnxhr", "h264", "H.264", "avc1",
                      "libx264", "hevc", "HEVC", "h265", "hvc1", "ffv1", "FFV1", "rawvideo", "v210", "mjpeg", "av1", "huffyuv"])
    func safeCodecs(codec: String) {
        let r = ArchiveReadiness.assess(inputs { $0.videoCodec = codec })
        #expect(r.format == .archivalSafe, "\(codec) → \(r.format)")
        #expect(!r.warnings.contains { $0.contains("at-risk") })
    }

    @Test("unknown codec → .unknown (warn, not at-risk); empty codec → unknown without a warning")
    func unknownCodec() {
        let r = ArchiveReadiness.assess(inputs { $0.videoCodec = "zzquux" })
        #expect(r.format == .unknown)
        #expect(r.warnings.contains { $0.contains("not in the archival table") })
        #expect(!r.blocking)
        let e = ArchiveReadiness.assess(inputs { $0.videoCodec = "" })
        #expect(e.format == .unknown)
        #expect(!e.warnings.contains { $0.contains("archival table") })
    }

    @Test("audio-only records: format from the audio codec (pcm/aac/flac/alac/mp3 safe; wma/ra at-risk)")
    func audioOnlyFormat() {
        for ok in ["pcm_s16le", "PCM_S24LE", "aac", "flac", "alac", "mp3", "pcm_f32be"] {
            let r = ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.audioOnly.rawValue; $0.audioCodec = ok; $0.videoCodec = "" })
            #expect(r.format == .archivalSafe, "\(ok)")
        }
        for bad in ["wmav2", "cook", "ra_144", "qdm2"] {
            let r = ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.audioOnly.rawValue; $0.audioCodec = bad; $0.videoCodec = "" })
            guard case .atRisk = r.format else { Issue.record("\(bad) should be at-risk"); continue }
        }
    }

    @Test("audio states: verifiedOK / verifiedProblem(note) / notVerified / noAudioTrack")
    func audioStates() {
        #expect(ArchiveReadiness.assess(inputs { $0.audioVerifyStatus = "ok"; $0.audioVerifyDate = Date() }).audio == .verifiedOK)
        #expect(ArchiveReadiness.assess(inputs { $0.audioVerifyStatus = "damaged"; $0.audioVerifyNote = "Damaged audio — invalid codec (qdm2)" }).audio
                == .verifiedProblem("Damaged audio — invalid codec (qdm2)"))
        #expect(ArchiveReadiness.assess(inputs { $0.audioVerifyStatus = "damaged" }).audio == .verifiedProblem("damaged audio"))
        #expect(ArchiveReadiness.assess(inputs { $0.audioVerifyStatus = "ok"; $0.audioVerifyNote = "silent audio" }).audio == .verifiedProblem("silent audio"))
        #expect(ArchiveReadiness.assess(inputs { _ in }).audio == .notVerified)
        #expect(ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.videoOnly.rawValue }).audio == .noAudioTrack)
    }

    @Test("date states: user date → known; inferred ≥0.6 → known; <0.6 → lowConfidence; nothing → undated")
    func dateStates() throws {
        #expect(ArchiveReadiness.assess(inputs { _ in }).date == .known)
        var comps = DateComponents(); comps.year = 2005; comps.month = 3; comps.day = 9
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let d = try #require(cal.date(from: comps))
        #expect(ArchiveReadiness.assess(inputs { $0.userDate = nil; $0.inferredRecordDate = d; $0.inferredDateConfidence = 0.9 }).date == .known)
        #expect(ArchiveReadiness.assess(inputs { $0.userDate = nil; $0.inferredRecordDate = d; $0.inferredDateConfidence = 0.3 }).date == .lowConfidence)
        #expect(ArchiveReadiness.assess(inputs { $0.userDate = nil }).date == .undated)
    }

    @Test("blocking ONLY when un-probeable (ffprobe failed / no streams); 'Codec unsupported' is playable + warned; at-risk/unverified/undated never block")
    func blockingOnlyUnprobeable() {
        #expect(ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.ffprobeFailed.rawValue; $0.isPlayable = "ffprobe failed" }).blocking)
        #expect(ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.noStreams.rawValue; $0.isPlayable = "No streams" }).blocking)
        let unsupported = ArchiveReadiness.assess(inputs { $0.isPlayable = "Codec unsupported"; $0.videoCodec = "svq3" })
        #expect(!unsupported.blocking && unsupported.playable)
        #expect(unsupported.warnings.contains { $0.contains("decoders") })
        let worst = ArchiveReadiness.assess(inputs { $0.videoCodec = "dvvideo"; $0.userDate = nil; $0.audioVerifyStatus = "damaged" })
        #expect(!worst.blocking)
        #expect(worst.warnings.count >= 3)
    }

    @Test("warnings are AUDIO-FIRST, then format, then date")
    func warningOrder() {
        let r = ArchiveReadiness.assess(inputs {
            $0.videoCodec = "dvvideo"; $0.userDate = nil
            $0.audioVerifyStatus = "damaged"; $0.audioVerifyNote = "Damaged audio — audio much shorter than video"
        })
        #expect(r.warnings.count == 3, "\(r.warnings)")
        #expect(r.warnings[0].hasPrefix("Audio problem"))
        #expect(r.warnings[1].hasPrefix("Codec DV"))
        #expect(r.warnings[2].hasPrefix("Undated"))
        let unverified = ArchiveReadiness.assess(inputs { $0.videoCodec = "mpeg2video"; $0.userDate = nil })
        #expect(unverified.warnings.first?.hasPrefix("Audio not verified") == true)
        let unprobeable = ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.ffprobeFailed.rawValue })
        #expect(unprobeable.warnings.first?.hasPrefix("Un-probeable") == true)
    }

    @Test("token + summary + sheet line shapes")
    func tokenAndSummary() {
        let r = ArchiveReadiness.assess(inputs { $0.videoCodec = "dvvideo"; $0.userDate = nil; $0.audioVerifyStatus = "ok" })
        #expect(r.token == "playable;audio=verified;format=at-risk:DV;date=undated")
        #expect(r.summary == "audio verified, codec DV at-risk, undated")
        #expect(r.sheetLine(dateLabel: "xxxx-xx-xx") == "Playable ✓ · Audio ✓ · Codec: DV (at-risk: plan an access copy) · Date: undated")
        let clean = ArchiveReadiness.assess(inputs { $0.audioVerifyStatus = "ok" })
        #expect(clean.token == "playable;audio=verified;format=safe;date=known")
        #expect(clean.warnings.isEmpty)
        let bad = ArchiveReadiness.assess(inputs { $0.streamTypeRaw = StreamType.ffprobeFailed.rawValue; $0.videoCodec = "" })
        #expect(bad.token.hasPrefix("unprobeable;"))
        #expect(!bad.token.contains(","), "token never contains a CSV comma")
    }

    @Test("SCALE: 100k assessments under budget", .timeLimit(.minutes(1)))
    func scale() {
        var i = inputs { $0.videoCodec = "MPEG-2 Video" }
        let t0 = CFAbsoluteTimeGetCurrent()
        var atRisk = 0
        for n in 0..<100_000 {
            i.videoCodec = n % 2 == 0 ? "dvvideo" : "prores"
            if case .atRisk = ArchiveReadiness.assess(i).format { atRisk += 1 }
        }
        let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(atRisk == 50_000)
        #expect(ms < 2_000, "100k assessments took \(Int(ms)) ms")
    }
}

// MARK: - Manifest compatibility

@Suite("Archive readiness — manifest header compatibility")
struct ArchiveReadinessManifestTests {

    private func row(_ rel: String, readiness: String) -> ArchiveManifestCSV.Row {
        ArchiveManifestCSV.Row(promotedAt: Date(), archiveRelPath: rel, sha256: "s", sizeBytes: 1,
                               originalPath: "/p", originalVolume: "v", recordID: UUID(), sourceRecordID: UUID(),
                               recordDate: "", dateConfidence: "", people: [], starRating: 3, readiness: readiness)
    }

    @Test("new manifest carries the readiness column; legacy manifest keeps 12 columns and is never rewritten; validate accepts both")
    func headerCompatibility() throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("rdyhdr")
        defer { sb.cleanup() }
        _ = try VideoScanModel.scaffoldMasterArchive(rootURL: sb.archiveRoot)
        #expect(try String(contentsOf: sb.manifestURL, encoding: .utf8) == MasterArchiveLayout.manifestHeader + "\n")
        try ArchiveManifestCSV.append(row("30_Video/Undated/a.mov", readiness: "playable;audio=verified;format=at-risk:DV;date=undated"),
                                      rootPath: sb.archiveRoot.path)
        let newRows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(newRows.count == 1 && newRows[0].count == 13)
        #expect(newRows[0][ArchiveManifestCSV.readinessColumn] == "playable;audio=verified;format=at-risk:DV;date=undated")
        #expect(throws: Never.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }

        // Legacy: rewrite the file to the OLD header + one old row, then append.
        let legacyRow = ArchiveManifestCSV.line(for: row("30_Video/Undated/old.mov", readiness: "ignored"), legacy: true)
        try (MasterArchiveLayout.manifestHeaderLegacy + "\n" + legacyRow).write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: Never.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        try ArchiveManifestCSV.append(row("30_Video/Undated/b.mov", readiness: "playable;audio=unverified;format=safe;date=known"),
                                      rootPath: sb.archiveRoot.path)
        let text = try String(contentsOf: sb.manifestURL, encoding: .utf8)
        #expect(text.hasPrefix(MasterArchiveLayout.manifestHeaderLegacy + "\n"), "header NOT rewritten")
        let legacyRows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(legacyRows.count == 2)
        #expect(legacyRows.allSatisfy { $0.count == 12 }, "rows appended to a legacy manifest keep 12 columns")
        #expect(ArchiveManifestCSV.rowsBySource(rootPath: sb.archiveRoot.path).count == 2, "parsers read both shapes")

        // A header that is neither is still refused; a header with trailing junk on the same line too.
        try "not,a,header\n".write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
        try (MasterArchiveLayout.manifestHeader + ",extra\n").write(to: sb.manifestURL, atomically: true, encoding: .utf8)
        #expect(throws: ArchivePromoteEngine.Failure.self) { try ArchiveManifestCSV.validate(rootPath: sb.archiveRoot.path) }
    }
}

// MARK: - Promote sensor

@Suite("Archive readiness — promote sensor", .serialized)
@MainActor
struct ArchiveReadinessPromoteTests {

    @Test("a DV file promotes with the at-risk token in its manifest row and the readiness summary in the copy's journey note")
    func dvPromotesWithToken() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("rdydv")
        defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_tape.avi"), bytes: 4096, seed: 7)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1994")
        rec.videoCodec = "dvvideo"; rec.audioCodec = "pcm_s16le"; rec.isPlayable = "Yes"
        rec.audioVerifyStatus = "ok"; rec.audioVerifyDate = Date()
        model.records = [rec]
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        #expect(plan.atRiskFormatCount == 1 && plan.unprobeableCount == 0 && plan.audioNotVerifiedCount == 0)
        #expect(plan.entries[0].readiness.token == "playable;audio=verified;format=at-risk:DV;date=known")

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.count == 1 && rows[0].count == 13)
        #expect(rows[0][ArchiveManifestCSV.readinessColumn] == "playable;audio=verified;format=at-risk:DV;date=known")
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.notes.contains("readiness: audio verified, codec DV at-risk"), "\(copy.notes)")
        // Bytes preserved as-is (no transcode) — the copy is the source.
        #expect(MasterArchiveTestSupport.sha256(ofFile: copy.fullPath) == MasterArchiveTestSupport.sha256(ofFile: src.path))
    }

    @Test("an un-probeable file is refused without the override and promoted with it (probed record; token says unprobeable)")
    func unprobeableNeedsOverride() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("rdyunp")
        defer { sb.cleanup() }
        let src = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_blob.bin"), bytes: 2048, seed: 9)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, streamType: .ffprobeFailed)
        rec.isPlayable = "ffprobe failed"
        model.records = [rec]
        var plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        #expect(plan.unprobeableCount == 1)
        #expect(plan.entries[0].readiness.blocking)

        let refused = PromoteToArchiveJob(plan: plan, model: model)
        refused.start(); await refused.task?.value
        guard case .finished(let s1) = refused.state else { Issue.record("\(refused.state)"); return }
        #expect(s1.contains("skipped 1"), "\(s1)")
        #expect(refused.outcomes.first?.detail.contains("Archive anyway") == true)
        #expect(MasterArchiveTestSupport.archivedFiles(sb).isEmpty)
        #expect(model.masterArchiveCopy(of: rec) == nil)

        plan.allowUnprobeable = true
        let allowed = PromoteToArchiveJob(plan: plan, model: model)
        allowed.start(); await allowed.task?.value
        guard case .finished(let s2) = allowed.state else { Issue.record("\(allowed.state)"); return }
        #expect(s2.hasPrefix("Promoted 1"), "\(s2)")
        #expect(MasterArchiveTestSupport.archivedFiles(sb).count == 1)
        let rows = MasterArchiveTestSupport.manifestRows(sb)
        #expect(rows.first?[ArchiveManifestCSV.readinessColumn].hasPrefix("unprobeable;") == true)
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.notes.contains("un-probeable (archived on your say-so)"))
        // ISOLATION: everything landed in the sandbox only.
        #expect(copy.fullPath.hasPrefix(sb.archiveRoot.path))
    }
}

// MARK: - Family user date (Rick's Mark_Bday case, 2026-08-20)

@Suite("Archive readiness — family user date")
@MainActor
struct ArchiveReadinessFamilyDateTests {
    /// The election can recommend a twin the user never dated; the
    /// family's hand-entered date stands in, and the record's OWN date
    /// always wins over the family's.
    @Test func familyDateStandsInForAnUndatedTwin() {
        let r = VideoRecord()
        r.filename = "Mark_Bday_Thanksgiving_1984.mkv"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.videoCodec = "ffv1"
        r.audioCodec = "pcm_s32le"

        let bare = ArchiveReadiness.assess(record: r)
        #expect(bare.date != .known, "no date signal anywhere → not known")

        let famed = ArchiveReadiness.assess(
            record: r,
            familyUserDate: ("1984-11", UserDateConfidence.known.rawValue))
        #expect(famed.date == .known, "the family's known date is the recording's date")

        r.userDate = "1985"
        r.userDateConfidence = UserDateConfidence.estimated.rawValue
        let own = ArchiveReadiness.assess(
            record: r,
            familyUserDate: ("1984-11", UserDateConfidence.known.rawValue))
        #expect(own.date == .known, "own user date (any confidence) outranks the family's")
    }
}
