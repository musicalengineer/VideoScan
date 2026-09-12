// PlaceInheritanceSensorTests.swift
// codex #1370 P0 (2026-09-12): Rick's hand-entered place rides EVERY
// same-footage inheritance path the date rides, and counts in the keeper
// election. One sensor per production path, named for the path:
//
//   repairInheritanceCarriesRicksPlace       applyHumanMetadataInheritance
//   repairInheritanceNeverClobbersRepairsPlace          (same, the other way)
//   confirmUndoRestoresRepairsOwnPlace       confirmRepairs / undoConfirmRepair
//   keeperPolicyScoresPlacedCopy             DuplicateKeeperPolicy.humanMetadataScore
//   duplicateDeleteCarriesRicksPlaceOntoKeeper   deleteDuplicates → inheritance
//   externalRepairAdoptionInheritsRicksPlace adoptExternalRepair
//   promotedCopyInheritsRicksPlace           registerPromotedCopy (via Promote)
//   trimJobInheritsRicksPlace                TrimJob.catalogTrimOutput
//   balanceAudioJobInheritsRicksPlace        BalanceAudioJob.catalogBalanceOutput
//   rebuildAudioJobInheritsRicksPlace        RebuildAudioJob.catalogRebuildOutput
//
// Media-bearing sensors run real ffmpeg on synthetic fixtures (gated on
// tool availability, as their sibling suites are). Isolation: temp dirs
// and isolated catalog stores only — never App Support.
//
// 2026-09-12 (Rick's promote-and-prune ruling): every sensor has a
// BACKUP-ATTESTATION twin — the user's word on cloud / off-site copies
// rides the same paths (merge rule: union by kind, latest wins, the
// target's own answer wins a tie, a "no" / "n/a" is never dropped). The
// media-bearing sensors carry the twin assertions inline (one ffmpeg run
// each); the pure paths get their own twin tests at the bottom.

import Foundation
import Testing
@testable import VideoScan

@Suite("Place inheritance sensors (codex #1370 P0)", .serialized)
@MainActor
struct PlaceInheritanceSensorTests {

    private func tempDir(_ label: String) -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PlaceInherit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // Attestation fixtures shared by the twins (whole-second dates so
    // the manifest's ISO-8601 round trip compares equal).
    private let attestedAt = Date(timeIntervalSince1970: 1_757_700_000)
    private var cloudYes: BackupAttestation { BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud", attestedAt: attestedAt) }
    private var offsiteNo: BackupAttestation { BackupAttestation(kind: .offsite, answer: .no, attestedAt: attestedAt) }
    private var familyWord: [BackupAttestation] { [cloudYes, offsiteNo] }

    /// An original + an awaiting-confirmation repair copy in one model.
    private func makePair(model: VideoScanModel) -> (VideoRecord, VideoRecord) {
        let original = VideoRecord()
        original.filename = "tape.mov"; original.fullPath = "/Volumes/T/tape.mov"; original.directory = "/Volumes/T"
        let repair = VideoRecord()
        repair.filename = "tape_RepairedAudio.mov"; repair.fullPath = "/Volumes/T/tape_RepairedAudio.mov"; repair.directory = "/Volumes/T"
        repair.derivedFrom = original.id
        repair.derivationKind = RebuildAudioFix.derivationKind
        model.records = [original, repair]
        return (original, repair)
    }

    // MARK: applyHumanMetadataInheritance

    @Test func repairInheritanceCarriesRicksPlace() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.userPlace = "Franklin, MA"
        original.userPlaceConfidence = "known"
        let carried = model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(repair.userPlace == "Franklin, MA")
        #expect(repair.userPlaceConfidence == "known")
        #expect(carried.contains("place"))
    }

    @Test func repairInheritanceNeverClobbersRepairsPlace() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.userPlace = "Franklin, MA"; original.userPlaceConfidence = "known"
        repair.userPlace = "Cape Cod"; repair.userPlaceConfidence = "estimated"
        let carried = model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(repair.userPlace == "Cape Cod")
        #expect(repair.userPlaceConfidence == "estimated", "the repair's own hand-entered place wins")
        #expect(!carried.contains("place"))
    }

    // MARK: confirmRepairs / undoConfirmRepair

    @Test func confirmUndoRestoresRepairsOwnPlace() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.userPlace = "Westford"; original.userPlaceConfidence = "known"
        #expect(repair.isAwaitingConfirmation)

        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.userPlace == "Westford", "confirm inherits the place")
        #expect(repair.userPlaceConfidence == "known")

        #expect(model.undoConfirmRepair())
        #expect(repair.userPlace == nil, "undo restores the repair's pre-confirm (empty) place exactly")
        #expect(repair.userPlaceConfidence == nil)
        #expect(original.supersededByID == nil)

        // And a place the repair already had survives a confirm + undo verbatim.
        repair.userPlace = "Cape Cod"; repair.userPlaceConfidence = "estimated"
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.userPlace == "Cape Cod")
        #expect(model.undoConfirmRepair())
        #expect(repair.userPlace == "Cape Cod" && repair.userPlaceConfidence == "estimated")
    }

    // MARK: AssessCopiesFamilyStamp (Archive Helper promote — codex #1374)

    @Test func archiveHelperPromoteStampsFamilyPlaceIfMissing() {
        func rec(_ name: String, place: String? = nil, confidence: String? = nil) -> VideoRecord {
            let r = VideoRecord(); r.filename = name; r.fullPath = "/Volumes/T/\(name)"
            r.userPlace = place; r.userPlaceConfidence = confidence
            return r
        }
        // Selection: known beats estimated; precise beats coarse; ties lexicographic.
        #expect(AssessCopiesFamilyStamp.bestUserPlace(among: [rec("a.mov"), rec("b.mov")]) == nil)
        let guessedCoarse = rec("c.mov", place: "Franklin", confidence: "estimated")
        let guessedPrecise = rec("d.mov", place: "Franklin, MA", confidence: "estimated")
        let knownCoarse = rec("e.mov", place: "Cape Cod", confidence: "known")
        var best = AssessCopiesFamilyStamp.bestUserPlace(among: [guessedCoarse, guessedPrecise])
        #expect(best?.place == "Franklin, MA" && best?.confidence == "estimated")
        best = AssessCopiesFamilyStamp.bestUserPlace(among: [guessedPrecise, knownCoarse])
        #expect(best?.place == "Cape Cod" && best?.confidence == "known", "known beats a more precise guess")
        best = AssessCopiesFamilyStamp.bestUserPlace(among: [rec("f.mov", place: "Norwood"), rec("g.mov", place: "Ashland")])
        #expect(best?.place == "Ashland", "equal length, equal confidence → lexicographic")

        // Stamp: only records without a place; the family's confidence rides along.
        let master = rec("master.mov")
        let copy = rec("copy.mov", place: "Montana", confidence: "estimated")
        let family = (place: "Cape Cod", confidence: "known")
        #expect(AssessCopiesFamilyStamp.stampPlaceIfMissing(family, onto: [master, copy]).map(\.filename) == ["master.mov"])
        #expect(master.userPlace == "Cape Cod" && master.userPlaceConfidence == "known")
        #expect(copy.userPlace == "Montana" && copy.userPlaceConfidence == "estimated", "a record's own place is never clobbered")
        #expect(AssessCopiesFamilyStamp.stampPlaceIfMissing(family, onto: [master, copy]).isEmpty, "second pass changes nothing")
    }

    // codex #1380 (3): indexed-vs-canonical agreement — the search index
    // answers the inherited place IMMEDIATELY after the Archive Helper stamp.
    @Test func archiveHelperStampReindexesInheritedPlace() {
        let model = VideoScanModel()
        let master = VideoRecord(); master.filename = "master.mov"; master.fullPath = "/Volumes/T/master.mov"
        let other = VideoRecord(); other.filename = "other.mov"; other.fullPath = "/Volumes/T/other.mov"
        model.records = [master, other]
        model.searchIndex.rebuild(records: model.records)   // stale-able entries exist
        #expect(model.searchIndex.filter(records: model.records, query: "cape").isEmpty)

        let changed = AssessCopiesFamilyStamp.stampPlaceIfMissing((place: "Cape Cod", confidence: "known"), onto: [master])
        AssessCopiesFamilyStamp.announce(changed)   // record-scoped posts → model re-indexes each

        #expect(pfCatalogTokenMatches(.substring("cape"), master), "canonical matcher sees the place")
        #expect(model.searchIndex.filter(records: model.records, query: "cape").map(\.id) == [master.id],
                "the index must agree with the canonical matcher at once")
    }

    // MARK: DuplicateKeeperPolicy.humanMetadataScore

    @Test func keeperPolicyScoresPlacedCopy() {
        let bare = VideoRecord()
        let placed = VideoRecord()
        placed.userPlace = "Cape Cod"
        placed.userPlaceConfidence = "estimated"
        #expect(DuplicateKeeperPolicy.humanMetadataScore(bare) == 0)
        #expect(DuplicateKeeperPolicy.humanMetadataScore(placed) > 0, "a placed copy must not tie a bare twin")
        // Same weight as the date — the two are siblings.
        let dated = VideoRecord(); dated.userDate = "1992"
        #expect(DuplicateKeeperPolicy.humanMetadataScore(placed) == DuplicateKeeperPolicy.humanMetadataScore(dated))
    }

    // MARK: deleteDuplicates → inheritance onto the keeper

    @Test func duplicateDeleteCarriesRicksPlaceOntoKeeper() async throws {
        let dir = tempDir("dup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bytes = (0..<150_000).map { UInt8($0 % 241) }
        let keeperURL = dir.appendingPathComponent("Reel12.mov")
        let extraURL = dir.appendingPathComponent("Reel12 copy.mov")
        FileManager.default.createFile(atPath: keeperURL.path, contents: Data(bytes))
        FileManager.default.createFile(atPath: extraURL.path, contents: Data(bytes))

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        let group = UUID()
        func dup(_ path: String, _ disposition: DuplicateDisposition) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = path; r.filename = (path as NSString).lastPathComponent
            r.sizeBytes = 150_000; r.partialMD5 = "m"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = disposition; r.duplicateConfidence = .high
            return r
        }
        let keeper = dup(keeperURL.path, .keep)
        let extra = dup(extraURL.path, .extraCopy)
        extra.userPlace = "Cape Cod"; extra.userPlaceConfidence = "known"   // only the extra carries it
        extra.backupAttestations = familyWord                                // ...and the family's word
        model.records = [keeper, extra]

        model.searchIndex.rebuild(records: model.records)   // keeper indexed WITHOUT a place
        #expect(model.searchIndex.filter(records: [keeper], query: "cape").isEmpty)

        let result = await model.deleteDuplicates(onVolume: dir.path)
        #expect(result.deleted == 1)
        #expect(model.records.count == 1 && model.records.first === keeper)
        #expect(keeper.userPlace == "Cape Cod", "the deleted extra's place folds into the keeper")
        #expect(keeper.userPlaceConfidence == "known")
        #expect(keeper.backupAttestations == familyWord, "twin: the deleted extra's attestations fold into the keeper")
        // codex #1380 (3): indexed-vs-canonical agreement right after the fold.
        #expect(pfCatalogTokenMatches(.substring("cape"), keeper))
        #expect(model.searchIndex.filter(records: model.records, query: "cape").map(\.id) == [keeper.id],
                "the keeper's inherited place is searchable immediately")
    }

    // MARK: adoptExternalRepair

    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable))
    func externalRepairAdoptionInheritsRicksPlace() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("adopt_place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_Recovered_place.mov",
            videoCodec: "prores_ks", extraVideoArgs: ["-profile:v", "1"],
            audioCodec: "pcm_s16le")
        let model = VideoScanModel()
        let original = VideoRecord()
        original.filename = "JustPatsHouse.mov"; original.fullPath = "/Volumes/T/JustPatsHouse.mov"; original.directory = "/Volumes/T"
        original.streamTypeRaw = StreamType.videoAndAudio.rawValue
        original.audioVerifyStatus = "damaged"
        original.userPlace = "Framingham, MA"; original.userPlaceConfidence = "estimated"
        original.backupAttestations = familyWord
        model.records.append(original)

        let adopted = try await model.adoptExternalRepair(originalID: original.id, fileURL: URL(fileURLWithPath: path))
        #expect(adopted.userPlace == "Framingham, MA", "same footage — the hand-entered place carries")
        #expect(adopted.userPlaceConfidence == "estimated")
        #expect(adopted.backupAttestations == familyWord, "twin: the adopted repair carries the family's word")
    }

    // MARK: registerPromotedCopy (through a real Promote)

    @Test(.enabled(if: CleanupTestMedia.toolsAvailable), .timeLimit(.minutes(2)))
    func promotedCopyInheritsRicksPlace() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("place")
        defer { sb.cleanup() }
        let src = try CleanupTestMedia.generate(into: sb.sources, name: "test_promote_place.mov", duration: 1.0,
                                                size: "320x240", rate: "25", videoCodec: "libx264",
                                                extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac")
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src, userDate: "1992-07-15", starRating: 1)
        rec.userPlace = "North Conway, NH"; rec.userPlaceConfidence = "known"
        rec.backupAttestations = familyWord
        model.records = [rec]

        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        guard case .finished = job.state else { Issue.record("promote did not finish: \(job.state)"); return }
        let copy = try #require(model.masterArchiveCopy(of: rec))
        #expect(copy.userDate == "1992-07-15")
        #expect(copy.userPlace == "North Conway, NH", "the archive copy carries Rick's place")
        #expect(copy.userPlaceConfidence == "known")
        #expect(copy.backupAttestations == familyWord, "twin: the archive copy carries the family's word")
        let row = try #require(MasterArchiveTestSupport.manifestRows(sb).first)
        #expect(row[ArchiveManifestCSV.userPlaceColumn] == "North Conway, NH")
        #expect(BackupAttestation.fromJSONString(row[ArchiveManifestCSV.backupAttestationsColumn]) == familyWord)
    }

    // MARK: TrimJob

    @Test(.enabled(if: CleanupTestMedia.toolsAvailable), .timeLimit(.minutes(2)))
    func trimJobInheritsRicksPlace() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("trim_place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try CleanupTestMedia.generate(
            into: dir, name: "test_trim_place.mkv", duration: 6.0, size: "320x240", rate: "25",
            videoCodec: "ffv1", extraVideoArgs: ["-g", "1"], audioCodec: "pcm_s16le")
        let model = VideoScanModel()
        let record = makeTrimSourceRecord(path: src, durationSeconds: 6.0, videoCodec: "ffv1")
        record.userPlace = "Cape Cod"; record.userPlaceConfidence = "estimated"
        record.backupAttestations = familyWord
        model.records = [record]
        let job = TrimJob(record: record, range: TrimRange(inSeconds: 1.0, outSeconds: 4.0), model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("trim did not finish: \(job.state)"); return }
        let derived = try #require(model.records.first { $0.derivedFrom == record.id })
        #expect(derived.derivationKind == TrimPlan.derivationKind)
        #expect(derived.userPlace == "Cape Cod", "a trimmed master is the same footage — the place carries")
        #expect(derived.userPlaceConfidence == "estimated")
        #expect(derived.backupAttestations == familyWord, "twin: the trimmed master carries the family's word")
    }

    // MARK: BalanceAudioJob

    @Test(.enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(2)))
    func balanceAudioJobInheritsRicksPlace() async throws {
        let dir = try BalanceAudioTestMedia.makeScratchDir("balance_place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try BalanceAudioTestMedia.generate(into: dir, channelCase: .leftOnly, wrapper: .mp4H264Aac)
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path, durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        record.userPlace = "Westford"; record.userPlaceConfidence = "known"
        record.backupAttestations = familyWord
        model.records = [record]
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("balance did not finish: \(job.state) — \(job.subtitle)"); return }
        let published = try #require(job.publishedURL)
        let derived = try #require(model.records.first { $0.fullPath == published.path })
        #expect(derived.derivedFrom == record.id)
        #expect(derived.userPlace == "Westford", "a balanced copy is the same footage — the place carries")
        #expect(derived.userPlaceConfidence == "known")
        #expect(derived.backupAttestations == familyWord, "twin: the balanced copy carries the family's word")
    }

    // MARK: RebuildAudioJob

    @Test(.enabled(if: VerifyAudioTestMedia.toolsAvailable), .timeLimit(.minutes(2)))
    func rebuildAudioJobInheritsRicksPlace() async throws {
        let dir = try VerifyAudioTestMedia.makeScratchDir("rebuild_place")
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = try VerifyAudioTestMedia.generate(
            into: dir, name: "test_rebuild_place.mov",
            videoCodec: "libx264", extraVideoArgs: ["-preset", "ultrafast"],
            audioCodec: "aac", videoDuration: 4.0)
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path, durationSeconds: d.shape.containerDurationSeconds,
                                             audioCodec: d.shape.audioCodec)
        record.userPlace = "Montana"; record.userPlaceConfidence = "estimated"
        record.backupAttestations = familyWord
        model.records = [record]
        let job = RebuildAudioJob(record: record, reason: "test", shape: d.shape, model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("rebuild did not finish: \(job.state) — \(job.subtitle)"); return }
        let published = try #require(job.publishedURL)
        let derived = try #require(model.records.first { $0.fullPath == published.path })
        #expect(derived.derivedFrom == record.id)
        #expect(derived.userPlace == "Montana", "a rebuilt copy is the same footage — the place carries")
        #expect(derived.userPlaceConfidence == "estimated")
        #expect(derived.backupAttestations == familyWord, "twin: the rebuilt copy carries the family's word")
    }

    // MARK: - Attestation twins for the pure paths (Rick 2026-09-12)

    @Test func repairInheritanceCarriesAttestations() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.backupAttestations = familyWord
        let carried = model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(repair.backupAttestations == familyWord)
        #expect(carried.contains("backup attestations"))
        // Idempotent: a second pass carries nothing new.
        #expect(!model.applyHumanMetadataInheritance(from: original, to: repair).contains("backup attestations"))
    }

    @Test func repairInheritanceMergesByKindLatestWinsAndNeverDropsANo() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        let later = Date(timeIntervalSince1970: 1_757_800_000)
        original.backupAttestations = [cloudYes, offsiteNo]                                   // older cloud=yes, offsite=no
        repair.backupAttestations = [BackupAttestation(kind: .cloud, answer: .no, attestedAt: later)]   // the repair's own, newer
        let carried = model.applyHumanMetadataInheritance(from: original, to: repair)
        #expect(repair.backupAttestation(for: .cloud)?.answer == .no, "the repair's newer answer wins")
        #expect(repair.backupAttestation(for: .offsite)?.answer == .no, "the original's 'no' is added, never dropped")
        #expect(carried.contains("backup attestations"))
    }

    @Test func confirmUndoRestoresRepairsOwnAttestations() {
        let model = VideoScanModel()
        let (original, repair) = makePair(model: model)
        original.backupAttestations = familyWord
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.backupAttestations == familyWord, "confirm inherits the family's word")
        #expect(model.undoConfirmRepair())
        #expect(repair.backupAttestations.isEmpty, "undo restores the repair's pre-confirm (empty) list exactly")

        let own = [BackupAttestation(kind: .drive, answer: .yes, label: "MyBook", attestedAt: attestedAt)]
        repair.backupAttestations = own
        #expect(model.confirmRepair(repairID: repair.id))
        #expect(repair.backupAttestations == [cloudYes, offsiteNo, own[0]], "merged in kind order")
        #expect(model.undoConfirmRepair())
        #expect(repair.backupAttestations == own, "undo restores the repair's own list verbatim")
    }

    @Test func archiveHelperPromoteStampsFamilyAttestationsIfMissing() {
        func rec(_ name: String, _ atts: [BackupAttestation] = []) -> VideoRecord {
            let r = VideoRecord(); r.filename = name; r.fullPath = "/Volumes/T/\(name)"
            r.backupAttestations = atts
            return r
        }
        #expect(AssessCopiesFamilyStamp.familyAttestations(among: [rec("a.mov"), rec("b.mov")]).isEmpty)
        let later = Date(timeIntervalSince1970: 1_757_800_000)
        let newerCloudNo = BackupAttestation(kind: .cloud, answer: .no, attestedAt: later)
        let family = AssessCopiesFamilyStamp.familyAttestations(among: [rec("c.mov", [cloudYes]), rec("d.mov", [newerCloudNo, offsiteNo])])
        #expect(family == [newerCloudNo, offsiteNo], "union by kind, latest per kind")

        let master = rec("master.mov")
        let own = rec("own.mov", [BackupAttestation(kind: .cloud, answer: .yes, label: "Dropbox", attestedAt: Date(timeIntervalSince1970: 1_757_900_000))])
        #expect(AssessCopiesFamilyStamp.stampAttestationsIfMissing(family, onto: [master, own]).map(\.filename) == ["master.mov", "own.mov"])
        #expect(master.backupAttestations == family)
        #expect(own.backupAttestation(for: .cloud)?.label == "Dropbox", "a record's own newer answer is never clobbered")
        #expect(own.backupAttestation(for: .offsite)?.answer == .no, "...but the family's 'no' is added")
        #expect(AssessCopiesFamilyStamp.stampAttestationsIfMissing(family, onto: [master, own]).isEmpty, "second pass changes nothing")
    }

    @Test func keeperPolicyScoresAttestedCopy() {
        let bare = VideoRecord()
        let attested = VideoRecord(); attested.backupAttestations = [offsiteNo]
        #expect(DuplicateKeeperPolicy.humanMetadataScore(bare) == 0)
        #expect(DuplicateKeeperPolicy.humanMetadataScore(attested) > 0, "an attested copy (even a 'no') must not tie a bare twin")
        let placed = VideoRecord(); placed.userPlace = "Cape Cod"
        #expect(DuplicateKeeperPolicy.humanMetadataScore(attested) == DuplicateKeeperPolicy.humanMetadataScore(placed),
                "same weight as the place — siblings")
    }
}
