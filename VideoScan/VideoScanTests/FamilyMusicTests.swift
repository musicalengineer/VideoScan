// FamilyMusicTests.swift
// Family Music (Rick 2026-09-23) — the five feature-test dimensions:
//
//   1. Logic     — the additive field (legacy decode, write-only-when-present,
//                  clone), mark / unmark + Media Ledger lines, multi-mark
//                  rules, read-only refusal, prefill, shelf order (performer
//                  → title → year), snapshot counts, hidden-when-empty, the
//                  archive-copy dedupe, the archived seal, the ledger
//                  vocabulary + narrator, menu titles, the Archive-tab state
//                  machine's `.music` pick.
//   2. Scale     — 100k records, 25 marked: snapshot under budget, one
//                  compute per RecordsVersion.
//   3. Media     — playback route for synthetic `test_*` mp3 / m4a / wav /
//                  aiff (inline AVPlayer, asset playable — no audio output
//                  needed) and mp4 / mov video (external player).
//   4. Isolation — sandboxed catalog store + ledger (never App Support);
//                  poisoned marks (blank strings, inert records) cannot put
//                  junk on the shelf.
//   5. Sensor    — Update Catalog preserves the mark (field snapshot AND the
//                  model's snapshot → rescan → apply path); unmarked
//                  purchased-music paths never appear, even at scale.

import AVFoundation
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

@MainActor
private enum FM {
    static let archiveRoot = "/Volumes/TestArchive/Breen_Family_Archive"

    static func model(_ label: String) throws -> (VideoScanModel, MasterArchiveTestSupport.Sandbox) {
        let sb = try MasterArchiveTestSupport.makeSandbox("music_\(label)")
        let m = MasterArchiveTestSupport.makeModel(sb)
        m.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        m.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: archiveRoot)
        return (m, sb)
    }

    static func rec(_ name: String, dir: String = "/Volumes/Src/music",
                    stream: StreamType = .audioOnly, dur: Double = 187) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.streamTypeRaw = stream.rawValue
        r.durationSeconds = dur
        r.sizeBytes = 1_000
        return r
    }

    static func copy(of src: VideoRecord, rel: String, verified: Bool = true) -> VideoRecord {
        let c = VideoRecord()
        c.filename = (rel as NSString).lastPathComponent
        c.fullPath = archiveRoot + "/" + rel
        c.derivedFrom = src.id
        c.derivationKind = ArchivePromotion.derivationKind
        c.sizeBytes = src.sizeBytes
        c.streamTypeRaw = src.streamTypeRaw
        if verified { c.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: src.sizeBytes) }
        return c
    }

    static func snapshot(_ m: VideoScanModel) -> ArchiveCategorySnapshot {
        ArchiveCategorySnapshot.compute(active: pfActiveRecords(m.records), allRecords: m.records,
                                        model: m, volumeSearchPaths: [])
    }

    static func item(_ title: String, performer: String?, year: Int?, path: String? = nil) -> FamilyMusicItem {
        FamilyMusicItem(id: UUID(), title: title, performer: performer, year: year, durationSeconds: 60,
                        isVideo: false, isArchived: false,
                        fullPath: path ?? "/V/\(title)-\(performer ?? "")-\(year ?? 0).m4a", filename: title)
    }

    /// Paths shaped like bought / library music — none of them marked.
    static func purchasedMusic(_ i: Int) -> VideoRecord {
        let shapes = [
            ("/Users/rick/Music/iTunes/iTunes Media/Music/The Beatles/Help!", "0\(i % 9 + 1) Help.m4a"),
            ("/Users/rick/Music/Music/Media.localized/Apple Music/Joni Mitchell/Blue", "Track \(i).m4p"),
            ("/Volumes/Src/Amazon MP3/Miles Davis/Kind of Blue", "So What \(i).mp3"),
            ("/Volumes/Src/CD Rips/Bach", "Goldberg Aria \(i).flac"),
        ]
        let (dir, name) = shapes[i % shapes.count]
        let r = rec(name, dir: dir)
        r.tags = ["music"]                  // even tagged "music" — tags are not the mark
        r.userNotes = "family music"        // nor are notes
        return r
    }
}

// MARK: - 1. Logic

@Suite("Family Music — logic")
@MainActor
struct FamilyMusicLogicTests {

    @Test("legacy record decodes nil and re-encodes WITHOUT the key; a mark round-trips and rides the clone")
    func additiveField() throws {
        let legacy = #"{"id":"11111111-2222-3333-4444-555555555555","filename":"a.m4a","fullPath":"/V/a.m4a"}"#
        let r = try JSONDecoder().decode(VideoRecord.self, from: Data(legacy.utf8))
        #expect(r.familyMusic == nil)
        let out = String(decoding: try JSONEncoder().encode(VideoRecordDTO(r)), as: UTF8.self)
        #expect(!out.contains("familyMusic"), "\(out)")

        r.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird",
                                        markedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(VideoRecord.self, from: enc.encode(VideoRecordDTO(r)))
        #expect(back.familyMusic == r.familyMusic)
        #expect(r.snapshotClone().familyMusic == r.familyMusic)
    }

    @Test("FamilyMusicInfo trims and turns blanks into nil")
    func infoCleaning() {
        let i = FamilyMusicInfo(performer: "  Tim ", title: " \n ")
        #expect(i.performer == "Tim")
        #expect(i.title == nil)
    }

    @Test("mark → field + one ledger line per file; unmark → cleared + ledger; unmarked files ignored")
    func markUnmark() async throws {
        let (m, sb) = try FM.model("mark"); defer { sb.cleanup() }
        let a = FM.rec("tim_blackbird.m4a"), b = FM.rec("plain.wav")
        m.records = [a, b]
        let rev0 = m.volumeAggregatesRevision
        await m.markFamilyMusic([a.id], performer: "Tim", title: "Blackbird")?.value
        #expect(a.familyMusic?.performer == "Tim")
        #expect(a.familyMusic?.title == "Blackbird")
        #expect(b.familyMusic == nil)
        #expect(m.volumeAggregatesRevision != rev0, "the Archive snapshot must see the change")

        var events = m.mediaLedger.events(forRecordID: a.id).filter { $0.event == .familyMusic }
        #expect(events.count == 1)
        #expect(events.first?.detail[MediaLedgerEvent.Detail.action] == "marked")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.performer] == "Tim")
        #expect(events.first?.detail[MediaLedgerEvent.Detail.title] == "Blackbird")
        #expect(events.first?.by == .rick)

        // Unmarking an unmarked file is a no-op: no task, no ledger line.
        #expect(m.unmarkFamilyMusic([b.id]) == nil)
        await m.unmarkFamilyMusic([a.id, b.id])?.value
        #expect(a.familyMusic == nil)
        events = m.mediaLedger.events(forRecordID: a.id).filter { $0.event == .familyMusic }
        #expect(events.map { $0.detail[MediaLedgerEvent.Detail.action] } == ["marked", "unmarked"])
        #expect(m.mediaLedger.events(forRecordID: b.id).isEmpty)
    }

    @Test("multi-mark: one performer for all, each keeps its own title; blank performer keeps each one's")
    func multiMark() async throws {
        let (m, sb) = try FM.model("multi"); defer { sb.cleanup() }
        let a = FM.rec("a.m4a"), b = FM.rec("b.m4a"), c = FM.rec("c.mov", stream: .videoAndAudio)
        a.familyMusic = FamilyMusicInfo(performer: "Matt", title: "Old Title")
        m.records = [a, b, c]
        await m.markFamilyMusic([a.id, b.id, c.id], performer: "Rick & Donna", title: nil)?.value
        #expect([a, b, c].allSatisfy { $0.familyMusic?.performer == "Rick & Donna" })
        #expect(a.familyMusic?.title == "Old Title", "a re-mark keeps the existing title")
        #expect(b.familyMusic?.title == nil, "no title → the list shows the filename")

        await m.markFamilyMusic([a.id, b.id], performer: "  ", title: nil)?.value
        #expect(a.familyMusic?.performer == "Rick & Donna", "blank multi performer keeps what each had")

        // A single-file mark with a blank performer CLEARS it (the sheet
        // shows the field; leaving it empty means "nobody named").
        await m.markFamilyMusic([a.id], performer: "", title: "New")?.value
        #expect(a.familyMusic?.performer == nil)
        #expect(a.familyMusic?.title == "New")
    }

    @Test("read-only (viewer) catalog refuses mark and unmark")
    func readOnly() throws {
        let (m, sb) = try FM.model("ro"); defer { sb.cleanup() }
        let a = FM.rec("a.m4a")
        m.records = [a]
        m.isReadOnly = true
        #expect(m.markFamilyMusic([a.id], performer: "Tim", title: nil) == nil)
        #expect(a.familyMusic == nil)
        a.familyMusic = FamilyMusicInfo(performer: "Tim")
        #expect(m.unmarkFamilyMusic([a.id]) == nil)
        #expect(a.familyMusic != nil)
    }

    @Test("prefill: title from the filename, performer from confirmed/detected people (no suspects, no 'Family')")
    func prefill() {
        #expect(FamilyMusicPrefill.title(fromFilename: "tim_guitar-solo__1998.m4a") == "tim guitar solo 1998")
        let r = FM.rec("x.m4a")
        r.detectedPeople = ["Tim", "Family", "tim"]
        r.suspectedPeople = ["Matt"]
        #expect(FamilyMusicPrefill.performer(for: r) == "Tim")

        let one = FamilyMusicSheetRequest.make(for: [r])
        #expect(one?.title == "x" && one?.performer == "Tim" && one?.isMulti == false)
        let s = FM.rec("y.m4a"); s.detectedPeople = ["Tim"]
        let both = FamilyMusicSheetRequest.make(for: [r, s])
        #expect(both?.isMulti == true && both?.performer == "Tim" && both?.subject == "2 files")
        let t = FM.rec("z.m4a"); t.detectedPeople = ["Matt"]
        #expect(FamilyMusicSheetRequest.make(for: [r, t])?.performer == "", "no common performer → blank")
        #expect(FamilyMusicSheetRequest.make(for: []) == nil)
    }

    @Test("shelf order: performer, then title, then year; blanks last; numbers read naturally")
    func sortOrder() {
        let items = [
            FM.item("Blackbird", performer: "Tim", year: 1999),
            FM.item("Anything", performer: nil, year: 1990),
            FM.item("Blackbird", performer: "Tim", year: 1995),
            FM.item("Song 10", performer: "Matt", year: nil),
            FM.item("Song 2", performer: "Matt", year: nil),
            FM.item("Blackbird", performer: "Tim", year: nil),
            FM.item("Aria", performer: "tim", year: 2001),
        ]
        let got = FamilyMusicShelf.sorted(items).map { "\($0.performer ?? "-")|\($0.title)|\($0.year.map(String.init) ?? "-")" }
        #expect(got == [
            "Matt|Song 2|-", "Matt|Song 10|-",
            "tim|Aria|2001",
            "Tim|Blackbird|1995", "Tim|Blackbird|1999", "Tim|Blackbird|-",
            "-|Anything|1990",
        ])
    }

    @Test("snapshot: count + rows, hidden when empty, filename when untitled, year and archived seal")
    func snapshotCounts() throws {
        let (m, sb) = try FM.model("snap"); defer { sb.cleanup() }
        let a = FM.rec("Tim_Blackbird_1998.m4a")
        let v = FM.rec("recital.mov", stream: .videoAndAudio)
        let plain = FM.rec("plain.m4a")
        m.records = [a, v, plain]
        var snap = FM.snapshot(m)
        #expect(!snap.showsMusicRow, "zero marked → the Music row is hidden")
        #expect(snap.count(for: .music) == 0)

        a.familyMusic = FamilyMusicInfo(performer: "Tim")
        v.familyMusic = FamilyMusicInfo(performer: "Matt", title: "Piano Recital")
        v.userDate = "2004"
        let vCopy = FM.copy(of: v, rel: "30_Video/2004/2004_recital.mov")
        m.records.append(vCopy)
        snap = FM.snapshot(m)
        #expect(snap.showsMusicRow)
        #expect(snap.count(for: .music) == 2)
        #expect(snap.familyMusic.map(\.title) == ["Piano Recital", "Tim_Blackbird_1998.m4a"])
        #expect(snap.records(for: .music).map(\.id) == [v.id, a.id], "records follow shelf order")
        let rv = snap.familyMusic[0], ra = snap.familyMusic[1]
        #expect(rv.isVideo && !ra.isVideo)
        #expect(rv.isArchived && !ra.isArchived)
        #expect(rv.year == 2004 && ra.year == 1998, "year from the date resolver (user date / filename)")
        #expect(ra.lengthText == "3:07")
    }

    @Test("an archive copy is represented by its marked source; a copy of an unmarked source shows itself")
    func copyDedupe() throws {
        let (m, sb) = try FM.model("dedupe"); defer { sb.cleanup() }
        let src = FM.rec("song.m4a"); src.familyMusic = FamilyMusicInfo(performer: "Tim")
        let copy = FM.copy(of: src, rel: "20_Audio/song.m4a"); copy.familyMusic = src.familyMusic  // promote clones
        let src2 = FM.rec("other.m4a")
        let copy2 = FM.copy(of: src2, rel: "20_Audio/other.m4a"); copy2.familyMusic = FamilyMusicInfo(performer: "Matt")
        m.records = [src, copy, src2, copy2]
        let snap = FM.snapshot(m)
        #expect(Set(snap.familyMusic.map(\.id)) == [src.id, copy2.id])
        #expect(snap.familyMusic.allSatisfy { $0.isArchived })
    }

    @Test("ledger vocabulary appends familyMusic LAST; narrator reads both actions")
    func ledgerVocabulary() {
        #expect(MediaLedgerEvent.Kind.allCases.last == .familyMusic)
        #expect(MediaLedgerEvent.Kind.familyMusic.rawValue == "familyMusic")
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let marked = MediaLedgerEvent(at: at, event: .familyMusic, recordID: UUID(), contentKey: "", filename: "a.m4a",
                                      fullPath: "/V/a.m4a", by: .rick, batchID: nil,
                                      detail: ["action": "marked", "performer": "Tim", "title": "Blackbird"])
        let s = LedgerNarrator.sentence(for: marked, dateText: "today")
        #expect(s.contains("family music") && s.contains("Blackbird") && s.contains("Tim"), "\(s)")
        let un = MediaLedgerEvent(at: at, event: .familyMusic, recordID: UUID(), contentKey: "", filename: "a.m4a",
                                  fullPath: "/V/a.m4a", by: .rick, batchID: nil, detail: ["action": "unmarked"])
        #expect(LedgerNarrator.sentence(for: un, dateText: "today").contains("off the Family Music shelf"))
    }

    @Test("menu titles: ellipsis only where a sheet opens")
    func menuTitles() {
        #expect(FamilyMusicMenu.markTitle == "Mark as Family Music\u{2026}")
        #expect(FamilyMusicMenu.unmarkTitle == "Unmark Family Music")
    }

    @Test("Archive tab: Music is the LAST category; a sidebar pick is a plain list — no detour, no timeline")
    func stateMachine() {
        #expect(ArchiveCategory.allCases.last == .music)
        let s = ArchiveHomeState.sidebarPick(.music, viewMode: .timeline)
        #expect(s.category == .music && s.viewMode == .files && s.detour == nil && s.selectedIDs.isEmpty)
        #expect(!s.isHome)
        #expect(ArchiveHomeState.backToArchive() == .home)
    }
}

// MARK: - 2. Scale

@Suite("Family Music — scale")
@MainActor
struct FamilyMusicScaleTests {

    @Test("100k records, 25 marked: one snapshot compute under budget, memo hits free", .timeLimit(.minutes(1)))
    func scale() async throws {
        let (m, sb) = try FM.model("scale"); defer { sb.cleanup() }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = FM.rec("clip_\(i).mov", dir: "/Volumes/Src\(i % 4)", stream: i % 5 == 0 ? .audioOnly : .videoAndAudio)
            if i % 4_000 == 7 { r.familyMusic = FamilyMusicInfo(performer: "P\(i % 3)", title: "Song \(i)") }
            records.append(r)
        }
        m.records = records
        #expect(records.filter { $0.familyMusic != nil }.count == 25)

        // The shelf pass alone (the new work inside the snapshot).
        let t0 = CFAbsoluteTimeGetCurrent()
        let shelf = FamilyMusicShelf.build(from: records, isArchived: { _ in false })
        let shelfMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        #expect(shelf.count == 25)
        #expect(shelfMs < 250, "shelf pass over 100k took \(Int(shelfMs)) ms — budget 250 ms")

        let memo = RenderMemo<ArchiveCategoryKey, ArchiveCategorySnapshot>()
        let t1 = CFAbsoluteTimeGetCurrent()
        let snap = ArchiveCategorySnapshot.cached(in: memo, model: m, volumeSearchPaths: [])
        let computeMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000
        #expect(snap.count(for: .music) == 25)
        #expect(computeMs < 2_000, "snapshot at 100k took \(Int(computeMs)) ms — budget 2 s")

        for _ in 0..<1_000 { _ = ArchiveCategorySnapshot.cached(in: memo, model: m, volumeSearchPaths: []) }
        #expect(memo.computeCount == 1, "1,000 renders must not recompute")

        // A mark bumps the revision → exactly one more compute, and the count follows.
        await m.markFamilyMusic([records[1].id], performer: "Tim", title: nil)?.value
        #expect(ArchiveCategorySnapshot.cached(in: memo, model: m, volumeSearchPaths: []).count(for: .music) == 26)
        #expect(memo.computeCount == 2)
    }
}

// MARK: - 3. Media matrix

@Suite("Family Music — media matrix (playback route)", .serialized)
@MainActor
struct FamilyMusicMediaMatrixTests {

    private func generate(_ name: String, in dir: URL, args: [String]) throws -> String {
        let out = dir.appendingPathComponent(name).path
        try CleanupTestMedia.runFFmpeg(args, output: out)
        return out
    }

    private func audioArgs(_ codec: String) -> [String] {
        ["-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1", "-c:a", codec]
    }

    private func videoArgs(_ vcodec: String) -> [String] {
        ["-f", "lavfi", "-i", "testsrc=duration=1:size=320x240:rate=25",
         "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=1",
         "-map", "0:v:0", "-map", "1:a:0", "-c:v", vcodec, "-c:a", "aac", "-shortest"]
    }

    private func route(path: String, stream: StreamType) -> FamilyMusicPlayRoute {
        let r = FM.rec((path as NSString).lastPathComponent, dir: (path as NSString).deletingLastPathComponent,
                       stream: stream)
        r.familyMusic = FamilyMusicInfo(performer: "Tim")
        let item = FamilyMusicShelf.item(for: r, mark: r.familyMusic!, isArchived: false)
        return FamilyMusicPlayback.route(for: item, isOnline: VolumeReachability.isVolumeReachable(path: path))
    }

    @Test("mp3 / m4a / wav / aiff audio → inline AVPlayer on a playable asset", arguments: [
        ("test_music.mp3", "libmp3lame"),
        ("test_music.m4a", "aac"),
        ("test_music.wav", "pcm_s16le"),
        ("test_music.aiff", "pcm_s16be"),
    ])
    func audio(name: String, codec: String) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe required")
        let dir = try CleanupTestMedia.makeScratchDir("music")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try generate(name, in: dir, args: audioArgs(codec))
        let r = route(path: path, stream: .audioOnly)
        #expect(r == .inlineAudio(URL(fileURLWithPath: path)), "\(name): \(r)")
        // What AVPlayer would be handed can actually play (no audio device needed).
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        #expect(try await asset.load(.isPlayable), "\(name) must be playable by AVFoundation")
        #expect(try await asset.load(.duration).seconds > 0.5)
    }

    @Test("mp4 / mov video → the app's external player (MediaOpener), never inline", arguments: [
        ("test_music.mp4", "libx264"),
        ("test_music.mov", "prores_ks"),
    ])
    func video(name: String, vcodec: String) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe required")
        let dir = try CleanupTestMedia.makeScratchDir("music")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try generate(name, in: dir, args: videoArgs(vcodec))
        #expect(route(path: path, stream: .videoAndAudio) == .externalPlayer)
    }

    @Test("audio AVFoundation can't play (MXF essence, OGG) → external; offline → offline; viewer → external")
    func edgeRoutes() {
        let mxf = FM.item("a", performer: nil, year: nil, path: "/Volumes/Src/A01.mxf")
        #expect(FamilyMusicPlayback.route(for: mxf, isOnline: true) == .externalPlayer)
        let ogg = FM.item("b", performer: nil, year: nil, path: "/Volumes/Src/b.ogg")
        #expect(FamilyMusicPlayback.route(for: ogg, isOnline: true) == .externalPlayer)
        let m4a = FM.item("c", performer: nil, year: nil, path: "/Volumes/Src/c.M4A")
        #expect(FamilyMusicPlayback.route(for: m4a, isOnline: true) == .inlineAudio(URL(fileURLWithPath: "/Volumes/Src/c.M4A")))
        #expect(FamilyMusicPlayback.route(for: m4a, isOnline: false) == .offline)
        #expect(FamilyMusicPlayback.route(for: m4a, isOnline: true, isViewer: true) == .externalPlayer)
    }
}

// MARK: - 4. Isolation

@Suite("Family Music — isolation")
@MainActor
struct FamilyMusicIsolationTests {

    @Test("the model under test writes its ledger and catalog only inside the sandbox")
    func sandboxed() async throws {
        let (m, sb) = try FM.model("iso"); defer { sb.cleanup() }
        let a = FM.rec("a.m4a")
        m.records = [a]
        await m.markFamilyMusic([a.id], performer: "Tim", title: nil)?.value
        let ledgerDir = sb.root.appendingPathComponent("ledger", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: ledgerDir, includingPropertiesForKeys: nil)) ?? []
        let text = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.joined()
        #expect(text.contains("\"familyMusic\""), "the ledger line landed in the sandbox")
        #expect(sb.root.path.hasPrefix(FileManager.default.temporaryDirectory.path))
    }

    @Test("poisoned marks: blank strings show the filename and no performer; inert records never show")
    func poisonedState() throws {
        let (m, sb) = try FM.model("poison"); defer { sb.cleanup() }
        // A hand-edited / older catalog could carry blanks the initializer never allowed.
        let json = #"{"id":"11111111-2222-3333-4444-555555555555","filename":"odd.m4a","fullPath":"/V/odd.m4a","streamTypeRaw":"Audio only","familyMusic":{"performer":"","title":"","markedAt":0}}"#
        let odd = try JSONDecoder().decode(VideoRecord.self, from: Data(json.utf8))
        let purged = FM.rec("purged.m4a"); purged.purgedAt = Date(); purged.familyMusic = FamilyMusicInfo(performer: "X")
        let aside = FM.rec("aside.m4a"); aside.setAsideReason = "junk"; aside.familyMusic = FamilyMusicInfo(performer: "X")
        let sup = FM.rec("sup.m4a"); sup.supersededByID = UUID(); sup.familyMusic = FamilyMusicInfo(performer: "X")
        m.records = [odd, purged, aside, sup]
        let snap = FM.snapshot(m)
        #expect(snap.familyMusic.map(\.id) == [odd.id])
        let row = try #require(snap.familyMusic.first)
        #expect(row.title == "odd.m4a", "a blank title shows the filename, never an empty line")
        #expect(row.performer == nil, "a blank performer is no performer")
    }
}

// MARK: - 5. Sensors

@Suite("Family Music — sensors")
@MainActor
struct FamilyMusicSensorTests {

    @Test("Update Catalog keeps the mark: field snapshot is worth restoring and applies onto a fresh record")
    func familyMusicMarkSurvivesRescan() {
        let old = FM.rec("song.m4a")
        old.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird")
        let snap = RescanPreservedFields(from: old)
        #expect(snap.isWorthRestoring, "a mark alone must be snapshotted")
        let fresh = FM.rec("song.m4a")
        _ = snap.apply(to: fresh)
        #expect(fresh.familyMusic == old.familyMusic)
    }

    @Test("Update Catalog keeps the mark end to end: snapshot → records wiped → fresh scan → apply")
    func familyMusicMarkSurvivesModelRescan() throws {
        let (m, sb) = try FM.model("rescan"); defer { sb.cleanup() }
        let target = CatalogScanTarget(searchPath: "/Volumes/Src")
        let old = FM.rec("song.m4a")
        old.familyMusic = FamilyMusicInfo(performer: "Tim", title: "Blackbird")
        m.records = [old]
        m.scanTargets = [target]
        m.snapshotPreservedFieldsForRescan(of: target)
        m.records.removeAll()
        let fresh = FM.rec("song.m4a")
        #expect(fresh.id != old.id)
        #expect(m.applyPreservedFieldsAfterRescan(of: target, onto: [fresh]) == 1)
        #expect(fresh.familyMusic?.performer == "Tim" && fresh.familyMusic?.title == "Blackbird")
        m.records = [fresh]
        #expect(FM.snapshot(m).count(for: .music) == 1, "still on the shelf after Update Catalog")
    }

    @Test("unmarked purchased / library music NEVER appears — 10k of it beside 25 marked family files")
    func unmarkedPurchasedMusicNeverAppears() throws {
        let (m, sb) = try FM.model("bought"); defer { sb.cleanup() }
        var records = (0..<10_000).map { FM.purchasedMusic($0) }
        m.records = records
        #expect(FM.snapshot(m).showsMusicRow == false,
                "no marks → no Music row, however much music is cataloged")
        var family: Set<UUID> = []
        for i in 0..<25 {
            let r = FM.rec("family_\(i).m4a", dir: "/Volumes/Src/Family")
            r.familyMusic = FamilyMusicInfo(performer: "Tim")
            family.insert(r.id)
            records.append(r)
        }
        m.records = records
        let snap = FM.snapshot(m)
        #expect(Set(snap.familyMusic.map(\.id)) == family)
        #expect(!snap.familyMusic.contains { $0.fullPath.contains("/Music/") || $0.fullPath.contains("Amazon MP3") })
    }
}
