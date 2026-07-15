import Foundation
import Testing
@testable import VideoScan

// MARK: - Set-aside migration tests (Tidy Catalog, video-only catalog 2026-07-15)
//
// Covers the migration + visibility half of the feature:
//   Logic    — dry-run plan categories, apply, undo, individual restore,
//              idempotent re-runs, CSV shape.
//   Sensors  — migration-mutates-ONLY-the-field (per-record byte oracle,
//              scoped-scan-wipe P0 class: record count before == after,
//              undo returns catalog.json bytes to identical);
//              apply-time pair-protection re-check (a Correlate between
//              dry-run and confirm wins);
//              set-aside invisible in the default search pipeline but
//              findable with the toggle (positive AND negative);
//              set-aside never offered to the correlator;
//              rescan preservation carries setAsideReason (never
//              resurrects);
//              legacy catalog JSON (no key) decodes as in-scope.
//   Scale    — dry-run + apply + undo over 100k synthetic records with
//              an explicit time budget.
// Media matrix: N/A — migration is pure catalog metadata, never disk.

@MainActor
private func rec(
    _ filename: String,
    stream: StreamType = .videoAndAudio,
    dir: String = "/Volumes/T/media",
    duration: Double = 0,
    setAside: String? = nil,
    purged: Bool = false
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.durationSeconds = duration
    r.sizeBytes = 1_000_000
    r.setAsideReason = setAside
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    return r
}

/// Deterministic per-record JSON via the SINGLE encoder (VideoRecordDTO)
/// — the same bytes CatalogStore writes.
@MainActor
private func recordJSON(_ r: VideoRecord) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    enc.dateEncodingStrategy = .iso8601
    let data = (try? enc.encode(VideoRecordDTO(r))) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: Plan / apply / undo

@MainActor
@Suite("Tidy Catalog — plan, apply, undo")
struct TidyCatalogTests {

    /// Mixed catalog: 1 video, 1 extensionless, 1 still, 1 music,
    /// 1 linked wav (same dir + duration as the video), 1 unlinked wav,
    /// 1 pair-protected audio.
    private func mixedModel() -> VideoScanModel {
        let model = VideoScanModel()
        let video = rec("family_1987.mov", stream: .videoOnly, duration: 300)
        let extless = rec("AvidEssence", stream: .ffprobeFailed)
        let still = rec("IMG_0042.cr3", stream: .videoOnly)
        let music = rec("song.mp3", stream: .audioOnly)
        let linkedWav = rec("unrelated_take.wav", stream: .audioOnly, duration: 300.2)
        let unlinkedWav = rec("scratch.wav", stream: .audioOnly,
                              dir: "/Volumes/T/music", duration: 42)
        let pairedAudio = rec("half.mxf", stream: .audioOnly, dir: "/Volumes/T/avid")
        let pairedVideo = rec("halfV.mxf", stream: .videoOnly, dir: "/Volumes/T/avid2")
        pairedAudio.pairedWith = pairedVideo
        pairedAudio.pairGroupID = UUID()
        pairedVideo.pairedWith = pairedAudio
        model.records = [video, extless, still, music, linkedWav, unlinkedWav,
                         pairedAudio, pairedVideo]
        return model
    }

    @Test("dry-run counts by category; kept tallies are honest")
    func dryRunCounts() async {
        let model = mixedModel()
        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.stillCount == 1)
        #expect(plan.musicCount == 1)
        #expect(plan.unlinkedAudioCount == 1)
        #expect(plan.keptLinkedAudio == 1)
        // BOTH pair members count: the invariant exits before
        // classification, so the paired video is tallied here too (it
        // would have been kept as .video regardless).
        #expect(plan.keptPairProtected == 2)
        #expect(plan.rows.count == 3)
        // Dry run mutates NOTHING.
        #expect(model.records.allSatisfy { $0.setAsideReason == nil })
    }

    @Test("sensor: apply mutates ONLY setAsideReason — byte oracle + count invariant")
    func applyMutatesOnlyTheField() async {
        let model = mixedModel()
        let countBefore = model.records.count
        let bytesBefore = model.records.map { recordJSON($0) }

        let plan = await model.computeTidyCatalogPlan()
        let applied = model.applyTidyCatalog(plan)
        #expect(applied == 3)
        #expect(model.records.count == countBefore)          // never adds/removes records

        let plannedIDs = Set(plan.rows.map(\.id))
        for (i, r) in model.records.enumerated() {
            if plannedIDs.contains(r.id) {
                // Byte-identical except the ONE field: stripping the
                // setAsideReason key from the after-JSON must reproduce
                // the before-JSON exactly.
                let after = recordJSON(r)
                let stripped = after.replacingOccurrences(
                    of: ",\"setAsideReason\":\"\(r.setAsideReason ?? "")\"", with: "")
                    .replacingOccurrences(
                        of: "\"setAsideReason\":\"\(r.setAsideReason ?? "")\",", with: "")
                #expect(stripped == bytesBefore[i], "record \(r.filename) changed beyond setAsideReason")
                #expect(r.setAsideReason != nil)
            } else {
                #expect(recordJSON(r) == bytesBefore[i], "untouched record \(r.filename) must be byte-identical")
            }
        }

        // Undo → the WHOLE catalog is byte-identical to before.
        #expect(model.undoLastTidyCatalog())
        #expect(model.records.map { recordJSON($0) } == bytesBefore)
        #expect(model.lastTidyBatch == nil)
    }

    @Test("sensor: pair-protection re-checked at APPLY time — a correlate between dry-run and confirm wins")
    func applyTimeInvariantRecheck() async {
        let model = mixedModel()
        let plan = await model.computeTidyCatalogPlan()
        // Between dry-run and confirm, the unlinked wav gets paired
        // (user ran Correlate / Find A/V Pair).
        let wav = model.records.first { $0.filename == "scratch.wav" }!
        let video = model.records.first { $0.filename == "family_1987.mov" }!
        wav.pairedWith = video
        wav.pairGroupID = UUID()
        video.pairedWith = wav

        let applied = model.applyTidyCatalog(plan)
        #expect(applied == 2)                       // still + music only
        #expect(wav.setAsideReason == nil, "paired audio must never be set aside")
    }

    @Test("idempotent: a second dry run after apply finds nothing")
    func secondDryRunEmpty() async {
        let model = mixedModel()
        let plan = await model.computeTidyCatalogPlan()
        model.applyTidyCatalog(plan)
        let second = await model.computeTidyCatalogPlan()
        #expect(second.rows.isEmpty)
    }

    @Test("individual restore clears the field and only the field")
    func individualRestore() async {
        let model = mixedModel()
        let plan = await model.computeTidyCatalogPlan()
        model.applyTidyCatalog(plan)
        let music = model.records.first { $0.filename == "song.mp3" }!
        let restored = model.restoreSetAsideRecords(ids: [music.id])
        #expect(restored == 1)
        #expect(music.setAsideReason == nil)
        // The other planned rows stay set aside.
        #expect(model.records.first { $0.filename == "IMG_0042.cr3" }!.setAsideReason != nil)
    }

    @Test("CSV export carries every planned row with friendly categories")
    func csvShape() async {
        let model = mixedModel()
        let plan = await model.computeTidyCatalogPlan()
        let csv = VideoScanModel.tidyPlanCSV(plan)
        let lines = csv.split(separator: "\n")
        #expect(lines.first == "Category,Filename,Path,SizeBytes")
        #expect(lines.count == 1 + plan.rows.count)
        #expect(csv.contains("Music files,song.mp3"))
        #expect(csv.contains("Photos and camera images,IMG_0042.cr3"))
        #expect(csv.contains("Audio with no matching video,scratch.wav"))
    }
}

// MARK: Visibility sensors

@MainActor
@Suite("Set-aside visibility")
struct SetAsideVisibilityTests {

    @Test("pfActiveRecords excludes set-aside; pfSetAsideRecords finds them")
    func activeExcludesSetAside() {
        let a = rec("video.mov")
        let s = rec("song.mp3", stream: .audioOnly, setAside: "music-format")
        let p = rec("gone.mov", purged: true)
        let active = pfActiveRecords([a, s, p])
        #expect(active.map(\.filename) == ["video.mov"])
        #expect(pfSetAsideRecords([a, s, p]).map(\.filename) == ["song.mp3"])
    }

    @Test("filter composition: toggles are independent")
    func filterComposition() {
        let a = rec("video.mov")
        let s = rec("song.mp3", stream: .audioOnly, setAside: "music-format")
        let p = rec("gone.mov", purged: true)
        let all = [a, s, p]
        // Default: only active.
        var out = pfApplySetAsideFilter(pfApplyPurgeFilter(all, showRemoved: false),
                                        showSetAside: false)
        #expect(out.map(\.filename) == ["video.mov"])
        // Show removed only: purged appears, set-aside stays hidden.
        out = pfApplySetAsideFilter(pfApplyPurgeFilter(all, showRemoved: true),
                                    showSetAside: false)
        #expect(Set(out.map(\.filename)) == ["video.mov", "gone.mov"])
        // Show set-aside only: set-aside appears, purged stays hidden.
        out = pfApplySetAsideFilter(pfApplyPurgeFilter(all, showRemoved: false),
                                    showSetAside: true)
        #expect(Set(out.map(\.filename)) == ["video.mov", "song.mp3"])
    }

    @Test("negative sensor: a set-aside record must NOT match a default search — but IS findable with the toggle")
    func setAsideInvisibleToDefaultSearch() {
        let model = VideoScanModel()
        let video = rec("donna_birthday.mov")
        let music = rec("donna_song.mp3", stream: .audioOnly, setAside: "music-format")
        model.records = [video, music]
        model.searchIndex.rebuild(records: model.records)

        // The default table pipeline: purge filter → set-aside filter →
        // search (computeFiltered order — search runs over the already-
        // narrowed set, so hidden rows can never match).
        let defaultPool = pfApplySetAsideFilter(
            pfApplyPurgeFilter(model.records, showRemoved: false),
            showSetAside: false)
        let defaultHits = model.searchIndex.filter(records: defaultPool, query: "donna")
        #expect(defaultHits.map(\.filename) == ["donna_birthday.mov"],
                "set-aside record matched a default search")

        // With the toggle on, the same search finds it.
        let browsePool = pfApplySetAsideFilter(
            pfApplyPurgeFilter(model.records, showRemoved: false),
            showSetAside: true)
        let browseHits = model.searchIndex.filter(records: browsePool, query: "donna")
        #expect(Set(browseHits.map(\.filename)) == ["donna_birthday.mov", "donna_song.mp3"])
    }

    @Test("set-aside audio is never offered to the correlator")
    func setAsideExcludedFromCorrelate() {
        // A video-only + audio-only pair that WOULD correlate (same stem,
        // same dir, same duration) — but the audio is set aside.
        let v = rec("Tape1V01.0000BBBB.mxf", stream: .videoOnly, duration: 100)
        let a = rec("Tape1A01.0000BBBB.mxf", stream: .audioOnly, duration: 100,
                    setAside: "unlinked-audio")
        Correlator.correlate(records: [v, a])
        #expect(v.pairedWith == nil, "correlator paired a set-aside record")
        #expect(a.pairedWith == nil)
    }

    @Test("sensor: rescan preservation carries setAsideReason — rescan never resurrects")
    func rescanPreservesSetAside() {
        let old = rec("song.mp3", stream: .audioOnly, setAside: "music-format")
        let snap = RescanPreservedFields(from: old)
        #expect(snap.isWorthRestoring)
        // The fresh instance a rescan creates at the same path.
        let fresh = rec("song.mp3", stream: .audioOnly)
        snap.apply(to: fresh)
        #expect(fresh.setAsideReason == "music-format")
    }

    @Test("legacy catalog JSON without the key decodes as in-scope")
    func legacyDecode() throws {
        let legacy = """
        {"id":"6F2E5799-9B95-4C07-AF15-FF40E5715664","filename":"old.mov",
         "ext":"MOV","streamTypeRaw":"Video+Audio"}
        """
        let r = try JSONDecoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.setAsideReason == nil)
        #expect(!r.isSetAside)
    }

    @Test("round-trip: set-aside survives encode/decode; clearing restores legacy bytes")
    func roundTrip() throws {
        let r = rec("song.mp3", stream: .audioOnly)
        let cleanJSON = recordJSON(r)
        r.setAsideReason = "music-format"
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(VideoRecordDTO(r))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.setAsideReason == "music-format")
        // Un-set-aside ⇒ byte-identical to before (delta-minimal encode).
        r.setAsideReason = nil
        #expect(recordJSON(r) == cleanJSON)
    }
}

// MARK: Scale

@MainActor
@Suite("Tidy Catalog — scale")
struct TidyCatalogScaleTests {

    @Test("dry run + apply + undo over 100k records within budget")
    func hundredKMigration() async {
        let model = VideoScanModel()
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        for i in 0..<100_000 {
            switch i % 5 {
            case 0:
                catalog.append(rec("Tape\(i % 400)V01.\(String(format: "%08X", i)).mxf",
                                   stream: .videoOnly,
                                   dir: "/Volumes/V\(i % 20)/OMFI",
                                   duration: Double(60 + i % 3600)))
            case 1:
                catalog.append(rec("IMG_\(i).cr3", stream: .videoOnly,
                                   dir: "/Volumes/Photos/\(i % 50)"))
            case 2, 3:
                catalog.append(rec("track_\(i).mp3", stream: .audioOnly,
                                   dir: "/Volumes/Music/\(i % 200)"))
            default:
                catalog.append(rec("session_\(i).wav", stream: .audioOnly,
                                   dir: "/Volumes/Sessions/\(i % 100)",
                                   duration: Double(i % 900)))
            }
        }
        model.records = catalog
        let countBefore = model.records.count

        let start = ContinuousClock.now
        let plan = await model.computeTidyCatalogPlan()
        let planned = start.duration(to: .now)

        #expect(plan.stillCount == 20_000)
        #expect(plan.musicCount == 40_000)
        #expect(plan.unlinkedAudioCount == 20_000)

        let applied = model.applyTidyCatalog(plan)
        #expect(applied == 80_000)
        #expect(model.records.count == countBefore)   // P0 sensor at scale

        #expect(model.undoLastTidyCatalog())
        #expect(model.records.allSatisfy { $0.setAsideReason == nil })

        let total = start.duration(to: .now)
        #expect(total < .seconds(15),
                "100k dry-run(\(planned)) + apply + undo took \(total) — budget 15s")
    }
}
