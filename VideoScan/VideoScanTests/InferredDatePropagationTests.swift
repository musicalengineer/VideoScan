import Testing
import Foundation
@testable import VideoScan

// MARK: - InferredDatePropagationTests (Rick 2026-09-12, the NV12 case)
//
// Two byte-identical copies of /Converted_VHS_Tapes_2026/1991/NV12.mkv
// carried the same OCR burn-in "JUN.21 1991 PM11:29"; only one had an
// inferred date. Dossier propagation copied the EVIDENCE between
// partialMD5 siblings but never the CONCLUSION, and nothing re-derived
// it. VideoScanModel+DateInference adds three rules:
//   1. catch-up: evidence but no date → infer from the stored evidence
//   2. propagation: a dated sibling → every undated same-content sibling
//   3. folder-year: "/1991/" → 0.30 placeholder when nothing else spoke
//
// Five dimensions (docs/testing_retrospective_2026_07_05.md):
//   logic      every rule, every never-overwrite case
//   scale      100k records / 5k groups inside a budget
//   isolation  scratch CatalogStore — the real App Support is never written
//   sensors    sameContentTwoPathsShareTheInferredDate (NV12 exactly),
//              catchUpInfersFromExistingOCRCandidates
//   media      n/a — no media file is opened; the pass reads stored fields

@MainActor
@Suite("InferredDatePropagation — catch-up, propagation, folder-year")
struct InferredDatePropagationTests {

    // MARK: - Fixtures

    /// Noon-UTC 1991-06-21, the shape pfParseOcrDate produces.
    static let june21_1991: Date = {
        var dc = DateComponents()
        dc.year = 1991; dc.month = 6; dc.day = 21; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc)!  // swiftlint:disable:this force_unwrapping
    }()

    static let nv12OCR = SceneCaption(timestamp: 192.99665, text: "JUN.21 1991 PM11:29")

    private func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InferredDatePropagationTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A model whose saves land in scratch, never in ~/Library/Application Support.
    private func makeModel(_ dir: URL) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        return model
    }

    private func makeRecord(
        path: String,
        md5: String = "",
        size: Int64 = 0,
        contentHash: String = "",
        groupID: UUID? = nil,
        ocr: [SceneCaption] = [],
        transcript: String? = nil,
        captions: [SceneCaption] = [],
        inferred: Date? = nil,
        confidence: Float? = nil,
        source: String? = nil,
        userDate: String? = nil,
        embedded: Date? = nil,
        streamType: StreamType = .videoAndAudio,
        dossierProcessedAt: Date? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.partialMD5 = md5
        r.sizeBytes = size
        r.contentHash = contentHash
        r.duplicateGroupID = groupID
        r.streamTypeRaw = streamType.rawValue
        r.ocrDateCandidates = ocr
        r.audioTranscript = transcript
        r.sceneCaptions = captions
        r.inferredRecordDate = inferred
        r.inferredDateConfidence = confidence
        r.inferredDateSource = source
        r.userDate = userDate
        r.embeddedCreationDate = embedded
        r.dossierProcessedAt = dossierProcessedAt
        return r
    }

    private func year(_ d: Date?) -> Int? {
        guard let d else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        return cal.component(.year, from: d)
    }

    // MARK: - SENSORS

    /// NV12 exactly: two records, same partialMD5 + size, same OCR
    /// candidate, one inferred → both inferred, same date, same
    /// confidence. This is the production shape the bug shipped in.
    @Test func sameContentTwoPathsShareTheInferredDate() throws {
        let dir = try scratchDir("nv12")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)

        let projects = makeRecord(
            path: "/Volumes/Projects/_staging_from_MediaExpansion/Converted_VHS_Tapes_2026/1991/NV12.mkv",
            md5: "33f3a67a70d4f531bc0ea0313d9ddd65", size: 31_142_257_366,
            ocr: [Self.nv12OCR],
            inferred: Self.june21_1991, confidence: 0.75,
            dossierProcessedAt: Date(timeIntervalSince1970: 1_784_081_580))
        let mediaExpansion = makeRecord(
            path: "/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/1991/NV12.mkv",
            md5: "33f3a67a70d4f531bc0ea0313d9ddd65", size: 31_142_257_366,
            ocr: [Self.nv12OCR])
        // The copy that fell through to the 2026 conversion date.
        mediaExpansion.dateModifiedRaw = Date(timeIntervalSince1970: 1_783_800_000)
        model.records = [projects, mediaExpansion]

        let result = model.catchUpInferredDates(trigger: "test")

        #expect(mediaExpansion.inferredRecordDate == projects.inferredRecordDate,
                "Same bytes, same evidence → same date")
        #expect(mediaExpansion.inferredDateConfidence == projects.inferredDateConfidence)
        #expect(year(mediaExpansion.inferredRecordDate) == 1991,
                "The MediaExpansion copy must read 1991, never the 2026 mtime")
        #expect(mediaExpansion.inferredDateSource != nil,
                "A date the record did not derive in its own dossier pass carries provenance")
        // The Projects copy — its own pass — is untouched.
        #expect(projects.inferredDateSource == nil)
        #expect(projects.inferredDateConfidence == 0.75)
        #expect(result.total == 1)
        // Idempotent: a second pass finds nothing to do.
        #expect(model.catchUpInferredDates(trigger: "test").total == 0)
    }

    /// A record with a stored OCR candidate and no date gets one from
    /// that candidate — no sibling required.
    @Test func catchUpInfersFromExistingOCRCandidates() throws {
        let dir = try scratchDir("catchup")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/tape.mkv", md5: "abc", size: 10,
                             ocr: [Self.nv12OCR])
        model.records = [rec]

        let result = model.catchUpInferredDates(trigger: "test")

        #expect(rec.inferredRecordDate == Self.june21_1991)
        #expect(rec.inferredDateConfidence == 0.75, "one uncorroborated OCR frame = 0.75, the dossier pass's own tier")
        #expect(rec.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
        #expect(result.inferredFromEvidence == 1)
        #expect(result.examined == 1)
        #expect(model.catchUpInferredDates(trigger: "test").total == 0, "idempotent")
    }

    // MARK: - Rule 1: catch-up from stored evidence

    @Test func catchUp_transcriptAndCaptionAgreeingYear_isYearPrecisionBelowTheResolverFloor() throws {
        let dir = try scratchDir("mentions")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/a.mov", md5: "m", size: 1,
                             transcript: "This is Christmas 1997 at Crescent Street.",
                             captions: [SceneCaption(timestamp: 0, text: "A banner reads 1997")])
        model.records = [rec]
        model.catchUpInferredDates(trigger: "test")
        #expect(year(rec.inferredRecordDate) == 1997)
        #expect(rec.inferredDateConfidence == 0.58)
        #expect(rec.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
    }

    @Test func catchUp_ambiguousYearMentions_produceNothing() throws {
        let dir = try scratchDir("ambiguous")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/a.mov", md5: "m", size: 1,
                             transcript: "born in 1962, and this is 1997 now")
        model.records = [rec]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(rec.inferredRecordDate == nil, "two spoken years date nothing")
        #expect(result.examined == 1)
        #expect(result.total == 0)
    }

    @Test func catchUp_noiseOnlyOCR_isExaminedButNotDated() throws {
        let dir = try scratchDir("noise")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/a.mov", md5: "m", size: 1,
                             ocr: [SceneCaption(timestamp: 1, text: "PM 11:30"),
                                   SceneCaption(timestamp: 2, text: "NONE")])
        model.records = [rec]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(rec.inferredRecordDate == nil)
        #expect(result.examined == 1 && result.total == 0)
    }

    @Test func catchUp_neverUsesTheFileMtime() throws {
        let dir = try scratchDir("mtime")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/a.mov", md5: "m", size: 1,
                             captions: [SceneCaption(timestamp: 0, text: "a kitchen")])
        rec.dateModifiedRaw = Date(timeIntervalSince1970: 1_783_800_000)   // 2026
        rec.dateCreatedRaw = rec.dateModifiedRaw
        model.records = [rec]
        model.catchUpInferredDates(trigger: "test")
        #expect(rec.inferredRecordDate == nil, "the copy date is not evidence about the footage")
    }

    @Test func catchUp_neverOverwritesAnExistingInference_evenWhenEvidenceDisagrees() throws {
        let dir = try scratchDir("keep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let stamp2007 = Date(timeIntervalSince1970: 1_180_000_000)
        let rec = makeRecord(path: "/Volumes/X/Clip 01.dv", md5: "m", size: 1,
                             ocr: [SceneCaption(timestamp: 1, text: "JUN 21 '97")],
                             inferred: stamp2007, confidence: 0.30)
        model.records = [rec]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(rec.inferredRecordDate == stamp2007, "an existing inference heals on the next dossier pass, not here")
        #expect(rec.inferredDateSource == nil)
        #expect(result.examined == 0 && result.total == 0)
    }

    @Test func catchUp_skipsPurgedSetAsideSupersededAndUnreadableRows() throws {
        let dir = try scratchDir("lifecycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let purged = makeRecord(path: "/V/p.mov", ocr: [Self.nv12OCR])
        purged.purgedAt = Date()
        let aside = makeRecord(path: "/V/s.mov", ocr: [Self.nv12OCR])
        aside.setAsideReason = "junk"
        let superseded = makeRecord(path: "/V/u.mov", ocr: [Self.nv12OCR])
        superseded.supersededByID = UUID()
        let failed = makeRecord(path: "/V/f.mov", ocr: [Self.nv12OCR], streamType: .ffprobeFailed)
        model.records = [purged, aside, superseded, failed]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.total == 0 && result.examined == 0)
        #expect([purged, aside, superseded, failed].allSatisfy { $0.inferredRecordDate == nil })
    }

    @Test func catchUp_limitBoundsTheEvidenceScans_andReportsTruncation() throws {
        let dir = try scratchDir("limit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        model.records = (0..<5).map { i in
            makeRecord(path: "/V/\(i).mov", ocr: [Self.nv12OCR])
        }
        let first = model.catchUpInferredDates(limit: 2, trigger: "test")
        #expect(first.examined == 2 && first.inferredFromEvidence == 2 && first.truncated)
        let second = model.catchUpInferredDates(limit: 10, trigger: "test")
        #expect(second.inferredFromEvidence == 3 && !second.truncated, "the rest catch up next pass")
    }

    // MARK: - Rule 2: propagation across a content group

    // MARK: - Identity (codex #1413): heuristic groups are not content identity

    /// A DuplicateDetector heuristic group (timecode / stem / duration)
    /// can hold rows whose FULL hashes conflict. A strong OCR date must
    /// never cross that line in either direction — each row keeps (or
    /// derives) its own.
    @Test func identity_heuristicGroupWithConflictingHashes_neverPropagatesEitherWay() throws {
        let dir = try scratchDir("heuristic-group")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let g = UUID()
        // Same heuristic group, different bytes, different burn-ins.
        let strong = makeRecord(path: "/V/tape.mov", md5: "one", size: 1, contentHash: "v1:aaaa",
                                groupID: g, ocr: [Self.nv12OCR, Self.nv12OCR, Self.nv12OCR],
                                inferred: Self.june21_1991, confidence: 0.95)
        strong.duplicateConfidence = .medium
        let other = makeRecord(path: "/W/tape.mov", md5: "two", size: 2, contentHash: "v1:bbbb",
                               groupID: g, ocr: [SceneCaption(timestamp: 0, text: "DEC 25 1997")])
        other.duplicateConfidence = .medium
        let bare = makeRecord(path: "/X/tape.mov", md5: "three", size: 3, contentHash: "v1:cccc", groupID: g)
        bare.duplicateConfidence = .high
        model.records = [strong, other, bare]

        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.propagated == 0, "a duplicateGroupID is never identity")
        #expect(year(other.inferredRecordDate) == 1997, "its OWN burn-in dates it")
        #expect(other.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
        #expect(bare.inferredRecordDate == nil, "different bytes, no evidence → stays undated")
        #expect(strong.inferredRecordDate == Self.june21_1991 && strong.inferredDateConfidence == 0.95)

        // Reverse direction: make the 1997 row the only donor.
        let strong2 = makeRecord(path: "/V/t2.mov", md5: "one", size: 1, contentHash: "v1:aaaa", groupID: g)
        let other2 = makeRecord(path: "/W/t2.mov", md5: "two", size: 2, contentHash: "v1:bbbb", groupID: g,
                                inferred: Date(timeIntervalSince1970: 883_000_000), confidence: 0.95)
        model.records = [strong2, other2]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(strong2.inferredRecordDate == nil)
        #expect(VideoScanModel.contentGroupKey(strong2) != VideoScanModel.contentGroupKey(other2))
        #expect(!VideoScanModel.haveVerifiedSameContent(strong2, other2))
    }

    /// Same partialMD5 + size (same head, tail and length) but the
    /// segmented hashes CONFLICT: the pair shares a bucket and is still
    /// rejected — a conflicting full hash outranks a matching partial.
    @Test func identity_conflictingContentHashRejectsEvenAPartialMD5Twin() throws {
        let dir = try scratchDir("hash-conflict")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let g = UUID()
        let donor = makeRecord(path: "/V/a.mxf", md5: "m", size: 100, contentHash: "v1:aaaa", groupID: g,
                               inferred: Self.june21_1991, confidence: 0.95)
        let padded = makeRecord(path: "/W/a.mxf", md5: "m", size: 100, contentHash: "v1:bbbb", groupID: g)
        let unhashed = makeRecord(path: "/X/a.mxf", md5: "m", size: 100, groupID: g)
        model.records = [donor, padded, unhashed]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(VideoScanModel.contentGroupKey(donor) == VideoScanModel.contentGroupKey(padded), "same bucket …")
        #expect(!VideoScanModel.haveVerifiedSameContent(donor, padded), "… but not the same bytes")
        #expect(padded.inferredRecordDate == nil, "conflicting full hashes never exchange a date")
        #expect(unhashed.inferredRecordDate == Self.june21_1991,
                "no content hash to conflict: partialMD5 + size is the verified identity")
        #expect(result.propagated == 1)
        #expect(!VideoScanModel.propagateInferredDate(from: donor, to: padded), "the single-write guard agrees")
    }

    /// Within one bucket, a recipient takes the best donor whose bytes
    /// are VERIFIED its own, not the best donor overall.
    @Test func identity_recipientTakesTheBestVERIFIEDDonorInABucket() throws {
        let dir = try scratchDir("best-verified")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let stronger = makeRecord(path: "/V/a.mov", md5: "m", size: 100, contentHash: "v1:other",
                                  inferred: Date(timeIntervalSince1970: 883_000_000), confidence: 0.95)
        let weaker = makeRecord(path: "/W/a.mov", md5: "m", size: 100, contentHash: "v1:same",
                                inferred: Self.june21_1991, confidence: 0.75)
        let twin = makeRecord(path: "/X/a.mov", md5: "m", size: 100, contentHash: "v1:same")
        model.records = [stronger, weaker, twin]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 1)
        #expect(twin.inferredRecordDate == Self.june21_1991)
        #expect(twin.inferredDateSource == "propagated from \(weaker.id.uuidString)")
    }

    /// The duplicate group is irrelevant in BOTH directions: a verified
    /// byte-twin pair propagates whether or not the detector grouped it,
    /// and a group ID adds nothing to an unverified pair.
    @Test func identity_duplicateGroupIDIsNeitherNecessaryNorSufficient() throws {
        let dir = try scratchDir("groupid-irrelevant")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let g = UUID()
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1, groupID: g,
                               inferred: Self.june21_1991, confidence: 0.95)
        let grouped = makeRecord(path: "/W/a.mov", md5: "m", size: 1, groupID: g)
        let ungrouped = makeRecord(path: "/X/a.mov", md5: "m", size: 1)
        let groupedOnly = makeRecord(path: "/Y/a.mov", md5: "n", size: 1, groupID: g)
        model.records = [donor, grouped, ungrouped, groupedOnly]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 2)
        #expect(grouped.inferredRecordDate == Self.june21_1991)
        #expect(ungrouped.inferredRecordDate == Self.june21_1991, "verified twins share without a group")
        #expect(groupedOnly.inferredRecordDate == nil, "a group alone is not identity")
        // The key is never the group.
        if case .duplicateGroup = VideoScanModel.contentGroupKey(donor) {
            Issue.record("contentGroupKey must never be a duplicateGroup")
        }
    }

    // MARK: - codex #1433: a propagated date never donates again

    /// A/B/C share partialMD5 + size; A (hash aaaa) has its own .95 date,
    /// B is unhashed, C (hash bbbb) conflicts with A. Pass 1: A→B, A↛C.
    /// Pass 2 must NOT reach C through B: B's date is borrowed, and
    /// borrowed dates never donate.
    @Test func identity_propagatedIntermediaryNeverDonatesAcrossAConflict_secondPass() throws {
        let dir = try scratchDir("intermediary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let a = makeRecord(path: "/V/a.mxf", md5: "m", size: 100, contentHash: "v1:aaaa",
                           inferred: Self.june21_1991, confidence: 0.95)
        let b = makeRecord(path: "/W/a.mxf", md5: "m", size: 100)
        let c = makeRecord(path: "/X/a.mxf", md5: "m", size: 100, contentHash: "v1:bbbb")
        model.records = [a, b, c]

        let first = model.catchUpInferredDates(trigger: "test")
        #expect(first.propagated == 1 && b.inferredRecordDate == Self.june21_1991 && c.inferredRecordDate == nil)
        #expect(!VideoScanModel.canDonateInferredDate(b), "a borrowed date is not a donor")

        let second = model.catchUpInferredDates(trigger: "test")
        #expect(second.propagated == 0, "second pass: B must not carry A's date to C")
        #expect(c.inferredRecordDate == nil)
        // Nor via the direct single-write guard.
        #expect(!VideoScanModel.propagateInferredDate(from: b, to: c))
        // A catch-up date IS a donor (own evidence), a folder-year is not.
        let own = makeRecord(path: "/Y/a.mov", md5: "n", size: 1, inferred: Self.june21_1991, confidence: 0.75,
                             source: VideoScanModel.InferredDateSource.catchUp)
        #expect(VideoScanModel.canDonateInferredDate(own))
    }

    // MARK: - codex #1434: an idempotent bucket is linear, not quadratic

    @Test("perf: a bucket of 4,000 already-dated copies costs N predicate reads, not N² guard calls",
          .timeLimit(.minutes(1)))
    func perf_allAlreadyDatedBucketIsLinear() throws {
        let dir = try scratchDir("n2")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let n = 4_000
        model.records = (0..<n).map { i in
            let r = makeRecord(path: "/V/\(i).mov", md5: "same", size: 1,
                               ocr: [Self.nv12OCR], inferred: Self.june21_1991, confidence: 0.95)
            if i % 2 == 1 { r.userDate = "1991" }
            return r
        }
        let clock = SuspendingClock()
        var result = VideoScanModel.InferredDateCatchUpResult()
        let elapsed = clock.measure { result = model.catchUpInferredDates(trigger: "test") }
        #expect(result.total == 0 && result.examined == 0)
        // 4,000 donors × 4,000 recipients × an evidence regex per guard call
        // is tens of seconds; the prefiltered pass is milliseconds.
        #expect(elapsed < .seconds(1), "all-dated bucket took \(elapsed)")
    }

    // MARK: - Unwind (codex #1413 repair): reversible, idempotent, exact

    /// The shape the 20:18 load pass left behind, plus the rows the unwind
    /// must NOT touch. Shared by the unwind sensors.
    private func unwindFixture(_ model: VideoScanModel) -> (donor: VideoRecord, verified: VideoRecord, heuristic: VideoRecord,
                                                            orphan: VideoRecord, own: VideoRecord, folder: VideoRecord,
                                                            userDated: VideoRecord) {
        let g = UUID()
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1, contentHash: "v1:dddd", groupID: g,
                               inferred: Self.june21_1991, confidence: 0.95)
        let verified = makeRecord(path: "/W/a.mov", md5: "m", size: 1, groupID: g,
                                  inferred: Self.june21_1991, confidence: 0.95,
                                  source: "propagated from \(donor.id.uuidString)")
        let heuristic = makeRecord(path: "/X/a.mkv", md5: "x", size: 30, contentHash: "v1:xxxx", groupID: g,
                                   inferred: Self.june21_1991, confidence: 0.95,
                                   source: "propagated from \(donor.id.uuidString)")
        heuristic.duplicateConfidence = .high
        let orphan = makeRecord(path: "/Y/a.mov", md5: "y", size: 2,
                                inferred: Self.june21_1991, confidence: 0.85,
                                source: "propagated from \(UUID().uuidString)")
        let own = makeRecord(path: "/Z/a.mov", md5: "z", size: 3,
                             inferred: Self.june21_1991, confidence: 0.75, source: "catch-up")
        let folder = makeRecord(path: "/F/1991/a.mov", md5: "f", size: 4,
                                inferred: pfJanuaryFirst(of: 1991), confidence: 0.30,
                                source: VideoScanModel.InferredDateSource.folderYear)
        let userDated = makeRecord(path: "/U/a.mov", md5: "u", size: 30, groupID: g,
                                   inferred: Self.june21_1991, confidence: 0.95,
                                   source: "propagated from \(donor.id.uuidString)", userDate: "1992")
        model.records = [donor, verified, heuristic, orphan, own, folder, userDated]
        return (donor, verified, heuristic, orphan, own, folder, userDated)
    }

    @Test func unwindClearsOnlyUnverifiedPropagated() throws {
        let dir = try scratchDir("unwind")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let f = unwindFixture(model)

        let r = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(r.unwound == 3, "heuristic + orphan + the user-dated row's MACHINE date")
        #expect(r.conflictingHashes == 1, "only the heuristic row has a hash that conflicts with its donor")
        #expect(f.verified.inferredRecordDate == Self.june21_1991, "verified twin keeps its date")
        #expect(f.heuristic.inferredRecordDate == nil && f.heuristic.inferredDateConfidence == nil
                && f.heuristic.inferredDateSource == nil, "heuristic-group date is cleared")
        #expect(f.orphan.inferredRecordDate == nil, "no donor to verify against → cleared")
        #expect(f.own.inferredRecordDate == Self.june21_1991 && f.own.inferredDateSource == "catch-up", "own evidence untouched")
        #expect(f.donor.inferredRecordDate == Self.june21_1991 && f.donor.inferredDateSource == nil, "own dossier pass untouched")
        #expect(f.folder.inferredDateSource == VideoScanModel.InferredDateSource.folderYear, "folder-year untouched")

        // The next verified pass does not put the bad date back.
        let after = model.catchUpInferredDates(trigger: "test")
        #expect(after.propagated == 0 && f.heuristic.inferredRecordDate == nil)
        #expect(r.sidecar?.path.hasPrefix(dir.path) == true, "sidecar lands in the injected catalog directory")
    }

    @Test func unwindIsIdempotent() throws {
        let dir = try scratchDir("unwind-idem")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        _ = unwindFixture(model)
        let first = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(first.unwound == 3 && first.sidecar != nil)
        let sidecarsAfterFirst = try FileManager.default.contentsOfDirectory(atPath: model.dateInferenceSidecarDirectory.path)
        func unwoundLines() -> Int {
            let text = (try? String(contentsOf: model.dashboard.catalogLog.url, encoding: .utf8)) ?? ""
            return text.components(separatedBy: "\n").filter { $0.contains("date inference: unwound") }.count
        }
        let linesAfterFirst = unwoundLines()
        #expect(linesAfterFirst >= 1, "the audit line reached catalog.log (synchronous write)")
        let second = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(second == VideoScanModel.UnwindResult(), "nothing to unwind, no sidecar")
        let sidecarsAfterSecond = try FileManager.default.contentsOfDirectory(atPath: model.dateInferenceSidecarDirectory.path)
        #expect(sidecarsAfterFirst.count == 1 && sidecarsAfterSecond == sidecarsAfterFirst, "a second load writes no second sidecar")
        #expect(unwoundLines() == linesAfterFirst, "a no-op unwind logs nothing")
    }

    @Test func unwindWritesReversibleSidecar() throws {
        let dir = try scratchDir("unwind-sidecar")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let f = unwindFixture(model)
        let stamp = Date(timeIntervalSince1970: 1_789_000_000)
        let r = model.unwindUnverifiedPropagatedDates(now: stamp, trigger: "test")
        let url = try #require(r.sidecar)
        #expect(url.lastPathComponent.hasPrefix("unwound-") && url.pathExtension == "json")
        #expect(url.deletingLastPathComponent().lastPathComponent == "date-inference")

        let payload = try VideoScanModel.unwoundSidecarDecoder()
            .decode(VideoScanModel.UnwoundDateSidecar.self, from: Data(contentsOf: url))
        #expect(payload.entries.count == 3 && payload.conflictingHashes == 1)
        let heuristicEntry = try #require(payload.entries.first { $0.recordID == f.heuristic.id })
        #expect(heuristicEntry.fullPath == "/X/a.mkv")
        #expect(heuristicEntry.inferredRecordDate == Self.june21_1991)
        #expect(heuristicEntry.inferredDateConfidence == 0.95)
        #expect(heuristicEntry.inferredDateSource == "propagated from \(f.donor.id.uuidString)")

        // Restore: the cleared rows come back exactly; the user-dated row
        // stays clear; a row a verified pass has since re-dated is kept.
        f.orphan.inferredRecordDate = Date(timeIntervalSince1970: 700_000_000)
        f.orphan.inferredDateConfidence = 0.75
        f.orphan.inferredDateSource = VideoScanModel.InferredDateSource.catchUp
        let restored = try VideoScanModel.reapplyUnwoundDates(from: url, to: model.records)
        #expect(restored.map(\.id) == [f.heuristic.id])
        #expect(f.heuristic.inferredRecordDate == Self.june21_1991 && f.heuristic.inferredDateConfidence == 0.95
                && f.heuristic.inferredDateSource == heuristicEntry.inferredDateSource)
        #expect(f.userDated.inferredRecordDate == nil, "never onto a user-dated row")
        #expect(f.orphan.inferredDateSource == VideoScanModel.InferredDateSource.catchUp, "a better-founded date since is kept")
        // Pure over entries: unknown ids are ignored.
        let stray = VideoScanModel.UnwoundDateEntry(recordID: UUID(), fullPath: "/nowhere", inferredRecordDate: Self.june21_1991,
                                                    inferredDateConfidence: 0.9, inferredDateSource: "propagated from x")
        #expect(VideoScanModel.reapplyUnwoundDates([stray], to: model.records).isEmpty)
    }

    @Test func unwindNeverTouchesUserDates() throws {
        let dir = try scratchDir("unwind-user")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let f = unwindFixture(model)
        _ = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(f.userDated.userDate == "1992", "Rick's date is never touched")
        #expect(f.userDated.inferredRecordDate == nil, "only the machine date under it goes")
        // A user-dated row whose propagated date IS verified keeps everything.
        let g = UUID()
        let donor = makeRecord(path: "/V/b.mov", md5: "q", size: 1, groupID: g, inferred: Self.june21_1991, confidence: 0.95)
        let both = makeRecord(path: "/W/b.mov", md5: "q", size: 1, groupID: g, inferred: Self.june21_1991, confidence: 0.95,
                              source: "propagated from \(donor.id.uuidString)", userDate: "1991-06")
        model.records = [donor, both]
        #expect(model.unwindUnverifiedPropagatedDates(trigger: "test").unwound == 0)
        #expect(both.userDate == "1991-06" && both.inferredRecordDate == Self.june21_1991)
    }

    /// codex #1439 (1): validate against the ORIGIN of the chain. A (aaaa,
    /// own) → B (bbbb, from A) → C (bbbb, from B): C's immediate donor B
    /// matches C's hash, but the date is A's and A/C conflict — both go.
    /// A verified chain A → B → C (all aaaa) stays.
    @Test func unwindClearsDependentDescendants_originDonorDecides() throws {
        let dir = try scratchDir("unwind-chain")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let a = makeRecord(path: "/V/a.mxf", md5: "m", size: 100, contentHash: "v1:aaaa",
                           inferred: Self.june21_1991, confidence: 0.95)
        let b = makeRecord(path: "/W/a.mxf", md5: "m", size: 100, contentHash: "v1:bbbb",
                           inferred: Self.june21_1991, confidence: 0.95, source: "propagated from \(a.id.uuidString)")
        let c = makeRecord(path: "/X/a.mxf", md5: "m", size: 100, contentHash: "v1:bbbb",
                           inferred: Self.june21_1991, confidence: 0.95, source: "propagated from \(b.id.uuidString)")
        let d = makeRecord(path: "/Y/a.mxf", md5: "m", size: 100, contentHash: "v1:bbbb",
                           inferred: Self.june21_1991, confidence: 0.95, source: "propagated from \(c.id.uuidString)")
        // A verified chain: E (aaaa, from A) → F (aaaa, from E).
        let e = makeRecord(path: "/V/e.mxf", md5: "m", size: 100, contentHash: "v1:aaaa",
                           inferred: Self.june21_1991, confidence: 0.95, source: "propagated from \(a.id.uuidString)")
        let f = makeRecord(path: "/W/e.mxf", md5: "m", size: 100, contentHash: "v1:aaaa",
                           inferred: Self.june21_1991, confidence: 0.95, source: "propagated from \(e.id.uuidString)")
        model.records = [a, b, c, d, e, f]
        let byID = Dictionary(uniqueKeysWithValues: model.records.map { ($0.id, $0) })
        #expect(VideoScanModel.originDonor(of: d, byID: byID) === a, "the chain resolves to A")
        #expect(VideoScanModel.originDonor(of: a, byID: byID) === a, "an own date is its own origin")

        let r = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(r.unwound == 3 && r.conflictingHashes == 3, "B, C and D — the whole dependent subtree")
        #expect(b.inferredRecordDate == nil && c.inferredRecordDate == nil && d.inferredRecordDate == nil)
        #expect(a.inferredRecordDate == Self.june21_1991 && a.inferredDateSource == nil)
        #expect(e.inferredRecordDate == Self.june21_1991 && f.inferredRecordDate == Self.june21_1991,
                "a chain whose origin is verified same bytes is kept")
        #expect(model.unwindUnverifiedPropagatedDates(trigger: "test").unwound == 0)
    }

    /// codex #1439 (1): a chain with a missing link, or a cycle, has no
    /// traceable origin — unverified by definition, cleared.
    @Test func unwindClearsCyclesAndMissingDonorChains() throws {
        let dir = try scratchDir("unwind-cycle")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        // Cycle: X from Y, Y from X — same bytes, nobody earned the date.
        let x = makeRecord(path: "/V/x.mov", md5: "m", size: 1, inferred: Self.june21_1991, confidence: 0.95)
        let y = makeRecord(path: "/W/x.mov", md5: "m", size: 1, inferred: Self.june21_1991, confidence: 0.95,
                           source: "propagated from \(x.id.uuidString)")
        x.inferredDateSource = "propagated from \(y.id.uuidString)"
        // Missing middle link: Q from a donor not in the catalog, P from Q — same bytes.
        let q = makeRecord(path: "/V/q.mov", md5: "n", size: 1, inferred: Self.june21_1991, confidence: 0.95,
                           source: "propagated from \(UUID().uuidString)")
        let pRec = makeRecord(path: "/W/q.mov", md5: "n", size: 1, inferred: Self.june21_1991, confidence: 0.95,
                              source: "propagated from \(q.id.uuidString)")
        // Unparseable provenance id.
        let junk = makeRecord(path: "/V/j.mov", md5: "j", size: 1, inferred: Self.june21_1991, confidence: 0.95,
                              source: "propagated from not-a-uuid")
        // Origin present but itself undated (its own date was cleared later).
        let hollow = makeRecord(path: "/V/h.mov", md5: "h", size: 1)
        let leaf = makeRecord(path: "/W/h.mov", md5: "h", size: 1, inferred: Self.june21_1991, confidence: 0.95,
                              source: "propagated from \(hollow.id.uuidString)")
        model.records = [x, y, q, pRec, junk, hollow, leaf]
        let byID = Dictionary(uniqueKeysWithValues: model.records.map { ($0.id, $0) })
        #expect(VideoScanModel.originDonor(of: x, byID: byID) == nil, "cycle")
        #expect(VideoScanModel.originDonor(of: pRec, byID: byID) == nil, "missing link")
        #expect(VideoScanModel.originDonor(of: leaf, byID: byID) == nil, "origin has no date")

        let r = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(r.unwound == 6 && r.conflictingHashes == 0)
        #expect([x, y, q, pRec, junk, leaf].allSatisfy { $0.inferredRecordDate == nil && $0.inferredDateSource == nil })
        #expect(model.unwindUnverifiedPropagatedDates(trigger: "test").unwound == 0, "terminates and is idempotent")
    }

    /// codex #1439 (2): an undo file is never replaced — two unwinds in
    /// the same second produce two sidecars.
    @Test func unwindNeverClobbersAnEarlierSidecar_sameSecond() throws {
        let dir = try scratchDir("unwind-clobber")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let stamp = Date(timeIntervalSince1970: 1_789_000_000)
        let f = unwindFixture(model)
        let first = model.unwindUnverifiedPropagatedDates(now: stamp, trigger: "test")
        // Re-poison one row and unwind again inside the same second.
        f.heuristic.inferredRecordDate = Self.june21_1991
        f.heuristic.inferredDateConfidence = 0.95
        f.heuristic.inferredDateSource = "propagated from \(f.donor.id.uuidString)"
        let second = model.unwindUnverifiedPropagatedDates(now: stamp, trigger: "test")
        let u1 = try #require(first.sidecar), u2 = try #require(second.sidecar)
        #expect(u1 != u2 && u1.lastPathComponent.hasPrefix("unwound-20260910") && u2.lastPathComponent.hasPrefix("unwound-20260910"))
        let files = try FileManager.default.contentsOfDirectory(atPath: model.dateInferenceSidecarDirectory.path)
        #expect(files.count == 2, "two undo files, both kept")
        let p1 = try VideoScanModel.unwoundSidecarDecoder().decode(VideoScanModel.UnwoundDateSidecar.self, from: Data(contentsOf: u1))
        let p2 = try VideoScanModel.unwoundSidecarDecoder().decode(VideoScanModel.UnwoundDateSidecar.self, from: Data(contentsOf: u2))
        #expect(p1.entries.count == 3 && p2.entries.count == 1, "the first undo file is intact")
        // The writer itself refuses to overwrite an existing name.
        let existing = dir.appendingPathComponent("date-inference/taken.json")
        try Data("x".utf8).write(to: existing)
        #expect(throws: (any Error).self) { try Data("y".utf8).write(to: existing, options: .withoutOverwriting) }
    }

    /// Isolation: a model on the SHARED store (the real App Support path)
    /// under a test host must refuse — no sidecar there, and because the
    /// sidecar is the undo record, no clearing either.
    @Test func unwindRefusesTheRealAppSupportUnderATestHost() throws {
        let model = VideoScanModel()   // catalogStore = .shared
        let f = unwindFixture(model)
        #expect(VideoScanModel.sidecarDirectoryIsRealAppSupportUnderTests(model.dateInferenceSidecarDirectory))
        let r = model.unwindUnverifiedPropagatedDates(trigger: "test")
        #expect(r.unwound == 0 && r.sidecar == nil)
        #expect(f.heuristic.inferredRecordDate == Self.june21_1991, "nothing cleared without a sidecar")
        // An injected directory elsewhere is fine even on the shared store.
        let dir = try scratchDir("unwind-injected")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(model.unwindUnverifiedPropagatedDates(sidecarDirectory: dir, trigger: "test").unwound == 3)
    }

    // MARK: - Budget (codex #1415): a bounded pass never starves own evidence

    /// The exact reported sequence, limit = 1: an unparseable row spends
    /// the budget; the recipient's own DEC 25 1991 is deferred; the
    /// sibling's JUN 21 1991 @0.95 must NOT settle it. Next pass, the
    /// noise costs nothing and the recipient reads its own burn-in.
    @Test func budget_deferredRecipientIsNeverDatedByASibling_andTheNextPassAdvances() throws {
        let dir = try scratchDir("limit1")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let noise = makeRecord(path: "/V/0.mov", md5: "z", size: 1,
                               ocr: [SceneCaption(timestamp: 1, text: "PM 11:30")])
        let recipient = makeRecord(path: "/V/1.mov", md5: "m", size: 1,
                                   ocr: [SceneCaption(timestamp: 1, text: "DEC 25 1991")])
        let sibling = makeRecord(path: "/W/1.mov", md5: "m", size: 1,
                                 inferred: Self.june21_1991, confidence: 0.95)
        model.records = [noise, recipient, sibling]

        let first = model.catchUpInferredDates(limit: 1, trigger: "test")
        #expect(first.examined == 1 && first.truncated && first.deferred == 1)
        #expect(first.propagated == 0, "a row whose evidence was not read this pass never receives")
        #expect(recipient.inferredRecordDate == nil)

        let second = model.catchUpInferredDates(limit: 1, trigger: "test")
        #expect(second.alreadyClassified == 1, "the noise row is remembered and costs nothing")
        #expect(second.examined == 1 && !second.truncated && second.deferred == 0, "the pass advanced")
        #expect(second.inferredFromEvidence == 1 && second.propagated == 0)
        #expect(recipient.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
        let cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }()  // swiftlint:disable:this force_unwrapping
        let dc = cal.dateComponents([.year, .month, .day], from: recipient.inferredRecordDate ?? .distantPast)
        #expect(dc.year == 1991 && dc.month == 12 && dc.day == 25, "its own burn-in, not the sibling's")
        #expect(recipient.inferredDateConfidence == 0.75)

        #expect(model.catchUpInferredDates(limit: 1, trigger: "test").total == 0, "idempotent")
    }

    /// (b)+(d): repeated bounded passes walk PAST classified noise
    /// instead of re-reading the same prefix, and a changed transcript
    /// re-opens a classified row.
    @Test func budget_classifiedNoiseIsSkippedForFree_untilItsEvidenceChanges() throws {
        let dir = try scratchDir("cursor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let noise = (0..<3).map { i in
            makeRecord(path: "/V/n\(i).mov", md5: "n\(i)", size: 1,
                       ocr: [SceneCaption(timestamp: 1, text: "NONE")])
        }
        let dated = makeRecord(path: "/V/d.mov", md5: "d", size: 1, ocr: [Self.nv12OCR])
        model.records = noise + [dated]

        let first = model.catchUpInferredDates(limit: 2, trigger: "test")
        #expect(first.examined == 2 && first.truncated && first.deferred == 2 && first.total == 0)
        let second = model.catchUpInferredDates(limit: 2, trigger: "test")
        #expect(second.alreadyClassified == 2 && second.examined == 2 && !second.truncated)
        #expect(second.inferredFromEvidence == 1 && dated.inferredRecordDate == Self.june21_1991)
        let third = model.catchUpInferredDates(limit: 2, trigger: "test")
        #expect(third.examined == 0 && third.alreadyClassified == 3 && third.total == 0)

        // New evidence on a classified row: the fingerprint changes, the
        // row is examined again, and this time it dates.
        noise[0].audioTranscript = "Merry Christmas 1997!"
        let fourth = model.catchUpInferredDates(limit: 2, trigger: "test")
        #expect(fourth.examined == 1 && fourth.alreadyClassified == 2)
        #expect(year(noise[0].inferredRecordDate) == 1997)
    }

    /// (a) the other way round: a deferred row does not DONATE either,
    /// and a classified-no-date row (evidence read, nothing found) may
    /// still receive.
    @Test func budget_classifiedNoDateRowsStillReceive_deferredRowsNeverDonate() throws {
        let dir = try scratchDir("classified-receives")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let noisy = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               ocr: [SceneCaption(timestamp: 1, text: "PM 11:30")])
        let donor = makeRecord(path: "/W/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        model.records = [noisy, donor]
        let first = model.catchUpInferredDates(limit: 10, trigger: "test")
        #expect(first.examined == 1 && first.propagated == 1, "read, nothing found → may borrow")
        #expect(noisy.inferredDateSource == "propagated from \(donor.id.uuidString)")

        // A row whose own OCR would make it a donor, deferred by limit 0,
        // gives nothing to its twin this pass.
        let wouldDonate = makeRecord(path: "/V/b.mov", md5: "n", size: 1, ocr: [Self.nv12OCR, Self.nv12OCR, Self.nv12OCR])
        let twin = makeRecord(path: "/W/b.mov", md5: "n", size: 1)
        model.records = [wouldDonate, twin]
        let zero = model.catchUpInferredDates(limit: 0, trigger: "test")
        #expect(zero.deferred == 1 && zero.total == 0)
        #expect(wouldDonate.inferredRecordDate == nil && twin.inferredRecordDate == nil)
        let next = model.catchUpInferredDates(limit: 10, trigger: "test")
        #expect(next.inferredFromEvidence == 1 && next.propagated == 1)
        #expect(twin.inferredDateConfidence == 0.95)
    }

    /// (c) conflict detection reads the evidence at ITS precision: a
    /// burn-in day disagrees with a different day in the same year; a
    /// spoken year does not disagree with a burn-in in that year.
    @Test func budget_recipientConflictIsJudgedAtTheEvidencesPrecision() throws {
        let donorDay = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                                  inferred: Self.june21_1991, confidence: 0.95)
        let sameYearDifferentDay = makeRecord(path: "/W/a.mov", md5: "m", size: 1,
                                              ocr: [SceneCaption(timestamp: 0, text: "DEC 25 1991")])
        #expect(!VideoScanModel.canReceivePropagatedDate(sameYearDifferentDay, from: donorDay),
                "DEC 25 1991 is not JUN 21 1991 — year-only comparison was the bug")
        let sameDay = makeRecord(path: "/W/b.mov", md5: "m", size: 1, ocr: [Self.nv12OCR])
        #expect(VideoScanModel.canReceivePropagatedDate(sameDay, from: donorDay))
        let spokenYear = makeRecord(path: "/W/c.mov", md5: "m", size: 1,
                                    transcript: "Merry Christmas 1991 everybody")
        #expect(VideoScanModel.canReceivePropagatedDate(spokenYear, from: donorDay),
                "a year-precision claim cannot disagree with a day inside that year")
        let spokenOtherYear = makeRecord(path: "/W/d.mov", md5: "m", size: 1,
                                         transcript: "Merry Christmas 1992 everybody")
        #expect(!VideoScanModel.canReceivePropagatedDate(spokenOtherYear, from: donorDay))

        // A year-precision donor (0.55 placeholder) vs a burn-in day: the
        // recipient's own evidence is FINER — it must derive its own.
        let donorYear = makeRecord(path: "/V/e.mov", md5: "m", size: 1,
                                   inferred: pfJanuaryFirst(of: 1991), confidence: 0.55)
        #expect(!VideoScanModel.canReceivePropagatedDate(sameDay, from: donorYear))
        #expect(VideoScanModel.canReceivePropagatedDate(spokenYear, from: donorYear))

        #expect(pfInferredDatePrecision(confidence: 0.95) == .day)
        #expect(pfInferredDatePrecision(confidence: 0.75) == .day)
        #expect(pfInferredDatePrecision(confidence: 0.58) == .year)
        #expect(pfInferredDatePrecision(confidence: 0.55) == .year)
        #expect(pfInferredDatePrecision(confidence: 0.50) == .year)
        #expect(pfInferredDatePrecision(confidence: 0.30) == .day)
        #expect(pfDatesAgree(Self.june21_1991, pfJanuaryFirst(of: 1991) ?? .distantPast, at: .year))
        #expect(!pfDatesAgree(Self.june21_1991, pfJanuaryFirst(of: 1991) ?? .distantPast, at: .month))
    }

    @Test func propagation_byContentHash() throws {
        let dir = try scratchDir("chash")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", contentHash: "v1:abc",
                               inferred: Self.june21_1991, confidence: 0.85)
        let twin = makeRecord(path: "/W/a.mov", contentHash: "v1:abc")
        model.records = [donor, twin]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 1)
        #expect(twin.inferredRecordDate == Self.june21_1991)
    }

    @Test func propagation_byPartialMD5AndSize_sameHashDifferentSizeIsNotATwin() throws {
        let dir = try scratchDir("md5size")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 100,
                               inferred: Self.june21_1991, confidence: 0.85)
        let twin = makeRecord(path: "/W/a.mov", md5: "m", size: 100)
        let truncated = makeRecord(path: "/X/a.mov", md5: "m", size: 50)
        model.records = [donor, twin, truncated]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 1)
        #expect(twin.inferredRecordDate == Self.june21_1991)
        #expect(truncated.inferredRecordDate == nil, "same first 4 MB, different length — not the same footage")
    }

    @Test func propagation_emptyMD5AndNoOtherSignal_isSolo() throws {
        let dir = try scratchDir("solo")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", inferred: Self.june21_1991, confidence: 0.95)
        let other = makeRecord(path: "/W/a.mov")
        model.records = [donor, other]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(other.inferredRecordDate == nil)
    }

    @Test func propagation_neverTouchesARecordWithAUserDate() throws {
        let dir = try scratchDir("userdate")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        let dated = makeRecord(path: "/W/a.mov", md5: "m", size: 1, userDate: "1992")
        model.records = [donor, dated]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(dated.inferredRecordDate == nil)
        #expect(dated.userDate == "1992", "Rick's date is never touched")
    }

    @Test func propagation_neverOverwritesAnExistingInference() throws {
        let dir = try scratchDir("existing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let other = Date(timeIntervalSince1970: 900_000_000)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        let own = makeRecord(path: "/W/a.mov", md5: "m", size: 1, inferred: other, confidence: 0.30)
        model.records = [donor, own]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(own.inferredRecordDate == other)
        #expect(own.inferredDateConfidence == 0.30)
    }

    @Test func propagation_refusesWhenTheRecipientsOwnEvidenceDisagrees() throws {
        let dir = try scratchDir("disagree")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        // Its own transcript names 1997 — a single mention is not enough
        // to date it (ambiguity guard) but it IS enough to refuse 1991.
        let dissent = makeRecord(path: "/W/a.mov", md5: "m", size: 1,
                                 transcript: "born in 1962, this is 1997")
        model.records = [donor, dissent]
        let result = model.catchUpInferredDates(trigger: "test")
        // Two years mentioned → pfContentEvidenceYear is nil → no dissent.
        #expect(result.propagated == 1, "ambiguous evidence does not disagree")

        let dissent2 = makeRecord(path: "/X/a.mov", md5: "m", size: 1,
                                  transcript: "Let's go swimming.",
                                  captions: [SceneCaption(timestamp: 0, text: "Cape Cod 1997")])
        model.records = [donor, dissent2]
        // The caption alone names one year → catch-up dates it 1997 at
        // 0.55 first; then propagation must not replace that.
        model.catchUpInferredDates(trigger: "test")
        #expect(year(dissent2.inferredRecordDate) == 1997)
        #expect(dissent2.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)

        // Direct guard: evidence naming a different year refuses the donor.
        let dissent3 = makeRecord(path: "/Y/a.mov", md5: "m", size: 1,
                                  ocr: [SceneCaption(timestamp: 0, text: "DEC 25 1997")])
        #expect(!VideoScanModel.canReceivePropagatedDate(dissent3, from: donor))
    }

    @Test func propagation_donorMustBeContentBacked_mtimeTierAndFolderYearNeverTravel() throws {
        let dir = try scratchDir("floor")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let mtimeDonor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                                    inferred: Date(timeIntervalSince1970: 1_783_800_000), confidence: 0.30)
        let twinA = makeRecord(path: "/W/a.mov", md5: "m", size: 1)
        let folderDonor = makeRecord(path: "/V/1991/b.mov", md5: "n", size: 1,
                                     inferred: Self.june21_1991, confidence: 0.30,
                                     source: VideoScanModel.InferredDateSource.folderYear)
        let twinB = makeRecord(path: "/W/b.mov", md5: "n", size: 1)
        model.records = [mtimeDonor, twinA, folderDonor, twinB]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(twinA.inferredRecordDate == nil, "a copy date is a fact about one copy")
        #expect(twinB.inferredRecordDate == nil, "a folder prior is not evidence")
        #expect(!VideoScanModel.canDonateInferredDate(mtimeDonor))
        #expect(!VideoScanModel.canDonateInferredDate(folderDonor))
    }

    @Test func propagation_picksTheHighestConfidenceDonor() throws {
        let dir = try scratchDir("best")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let weak = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                              inferred: Date(timeIntervalSince1970: 700_000_000), confidence: 0.55)
        let strong = makeRecord(path: "/W/a.mov", md5: "m", size: 1,
                                inferred: Self.june21_1991, confidence: 0.95)
        let twin = makeRecord(path: "/X/a.mov", md5: "m", size: 1)
        model.records = [weak, strong, twin]
        model.catchUpInferredDates(trigger: "test")
        #expect(twin.inferredRecordDate == Self.june21_1991)
        #expect(twin.inferredDateSource == "propagated from \(strong.id.uuidString)")
        #expect(weak.inferredDateConfidence == 0.55, "an existing inference on a sibling is never replaced")
    }

    @Test func propagation_skipsInactiveAndUnreadableRecipients_andUnreadableDonors() throws {
        let dir = try scratchDir("recipients")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        let purged = makeRecord(path: "/W/a.mov", md5: "m", size: 1); purged.purgedAt = Date()
        let aside = makeRecord(path: "/X/a.mov", md5: "m", size: 1); aside.setAsideReason = "junk"
        let superseded = makeRecord(path: "/Y/a.mov", md5: "m", size: 1); superseded.supersededByID = UUID()
        let unreadable = makeRecord(path: "/Z/a.mov", md5: "m", size: 1, streamType: .ffprobeFailed)
        model.records = [donor, purged, aside, superseded, unreadable]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)

        let badDonor = makeRecord(path: "/V/b.mov", md5: "n", size: 1,
                                  inferred: Self.june21_1991, confidence: 0.95, streamType: .ffprobeFailed)
        let twin = makeRecord(path: "/W/b.mov", md5: "n", size: 1)
        model.records = [badDonor, twin]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 0)
        #expect(twin.inferredRecordDate == nil, "a smeared / unreadable row never donates")
    }

    @Test func propagation_ownEvidenceWinsOverASibling_whenBothApply() throws {
        let dir = try scratchDir("ownfirst")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        let withOCR = makeRecord(path: "/W/a.mov", md5: "m", size: 1, ocr: [Self.nv12OCR])
        model.records = [donor, withOCR]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.inferredFromEvidence == 1 && result.propagated == 0)
        #expect(withOCR.inferredDateSource == VideoScanModel.InferredDateSource.catchUp,
                "a record that can read its own burn-in does, rather than trusting a sibling")
        #expect(withOCR.inferredDateConfidence == 0.75)
    }

    // MARK: - Rule 3: bare-year folder prior

    @Test func folderYearPrior_pureParser() {
        #expect(pfBareYearFolderPrior(in: "/Volumes/MediaExpansion/Converted_VHS_Tapes_2026/1991/NV12.mkv") == 1991,
                "the deepest bare-year directory wins over an ancestor's year-bearing name")
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/Christmas2010/clip.mp4") == nil, "not a bare year")
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/1850/clip.mp4") == nil, "below 1900")
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/2031/clip.mp4") == nil, "above 2030")
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/2030/clip.mp4") == 2030)
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/1900/clip.mp4") == 1900)
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/1991.mov") == nil, "the filename is never a folder")
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/12345/clip.mp4") == nil)
        #expect(pfBareYearFolderPrior(in: "/Volumes/X/1995/2001/clip.mp4") == 2001, "deepest first")
    }

    @Test func folderYearPrior_datesAnEvidencelessRecordAt030_yearPrecision() throws {
        let dir = try scratchDir("folder")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let rec = makeRecord(path: "/Volumes/X/1991/tape.mkv")
        model.records = [rec]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.folderYear == 1)
        #expect(rec.inferredRecordDate == pfJanuaryFirst(of: 1991))
        #expect(rec.inferredDateConfidence == VideoScanModel.folderYearPriorConfidence)
        #expect(rec.inferredDateSource == VideoScanModel.InferredDateSource.folderYear)
        // Below the resolver floor: never files the archive, but no longer "undated".
        let res = RecordDateResolver.resolve(userDate: nil, embeddedCreationDate: nil,
                                             inferredRecordDate: rec.inferredRecordDate,
                                             inferredDateConfidence: rec.inferredDateConfidence,
                                             filename: rec.filename)
        #expect(res.source == .none && res.hadRejectedSignal)
        #expect(model.catchUpInferredDates(trigger: "test").total == 0, "idempotent")
    }

    @Test func folderYearPrior_onlyWhenNothingElseSpoke() throws {
        let dir = try scratchDir("folder-guard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let userDated = makeRecord(path: "/V/1991/a.mov", userDate: "1992")
        let stamped = makeRecord(path: "/V/1991/b.mov", embedded: Date(timeIntervalSince1970: 1_000_000_000))
        let withOCR = makeRecord(path: "/V/1985/c.mov", ocr: [Self.nv12OCR])
        let withTranscript = makeRecord(path: "/V/1991/d.mov", transcript: "no year spoken here")
        model.records = [userDated, stamped, withOCR, withTranscript]
        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.folderYear == 0)
        #expect(userDated.inferredRecordDate == nil)
        #expect(stamped.inferredRecordDate == nil)
        #expect(year(withOCR.inferredRecordDate) == 1991, "evidence wins over the folder")
        #expect(withOCR.inferredDateConfidence == 0.75)
        #expect(withTranscript.inferredRecordDate == nil,
                "evidence that names no year is still evidence — the folder stays silent")
    }

    @Test func folderYearPrior_isAPlaceholder_propagationReplacesIt() throws {
        let dir = try scratchDir("folder-upgrade")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let placeholder = makeRecord(path: "/V/1991/a.mov", md5: "m", size: 1,
                                     inferred: pfJanuaryFirst(of: 1991), confidence: 0.30,
                                     source: VideoScanModel.InferredDateSource.folderYear)
        let donor = makeRecord(path: "/W/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        model.records = [placeholder, donor]
        #expect(model.catchUpInferredDates(trigger: "test").propagated == 1)
        #expect(placeholder.inferredRecordDate == Self.june21_1991)
        #expect(placeholder.inferredDateConfidence == 0.95)
        #expect(placeholder.inferredDateSource == "propagated from \(donor.id.uuidString)")
    }

    @Test func folderYearPrior_isReplacedByTheRecordsOwnDossierPass() throws {
        let dir = try scratchDir("folder-dossier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let path = "/V/1991/a.mov"
        let rec = makeRecord(path: path, inferred: pfJanuaryFirst(of: 1991), confidence: 0.30,
                             source: VideoScanModel.InferredDateSource.folderYear)
        model.records = [rec]
        model.applyDossier(DossierExtraction(scenes: [], dates: [Self.nv12OCR], texts: []),
                           to: path, vlmModel: "qwen2.5-vl-3b-4bit", transcript: nil, whisperModel: nil)
        #expect(rec.inferredRecordDate == Self.june21_1991)
        #expect(rec.inferredDateSource == nil, "an own pass clears any inherited provenance")
    }

    // MARK: - Hooks: applyDossier + live reload

    @Test func applyDossier_sharesTheFreshDateWithTheContentGroup() throws {
        let dir = try scratchDir("hook-dossier")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let path = "/Volumes/Projects/1991/NV12.mkv"
        let target = makeRecord(path: path, md5: "m", size: 1)
        let twin = makeRecord(path: "/Volumes/MediaExpansion/1991/NV12.mkv", md5: "m", size: 1)
        let userDated = makeRecord(path: "/Volumes/LaCie/1991/NV12.mkv", md5: "m", size: 1, userDate: "1991-06")
        model.records = [target, twin, userDated]

        model.applyDossier(DossierExtraction(scenes: [], dates: [Self.nv12OCR, Self.nv12OCR], texts: []),
                           to: path, vlmModel: "qwen2.5-vl-3b-4bit", transcript: nil, whisperModel: nil)

        #expect(target.inferredRecordDate == Self.june21_1991 && target.inferredDateConfidence == 0.85)
        #expect(twin.inferredRecordDate == Self.june21_1991)
        #expect(twin.inferredDateConfidence == 0.85)
        #expect(twin.inferredDateSource == "propagated from \(target.id.uuidString)")
        #expect(userDated.inferredRecordDate == nil && userDated.userDate == "1991-06")
    }

    @Test func singleChannelWritebacks_deriveADateFromASpokenOrCaptionedYear_andShareIt() throws {
        let dir = try scratchDir("hook-channels")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let spoken = makeRecord(path: "/V/a.mov", md5: "m", size: 1)
        let spokenTwin = makeRecord(path: "/W/a.mov", md5: "m", size: 1)
        let captioned = makeRecord(path: "/V/b.mov", md5: "n", size: 1)
        let captionedTwin = makeRecord(path: "/W/b.mov", md5: "n", size: 1)
        model.records = [spoken, spokenTwin, captioned, captionedTwin]

        model.applyAudioTranscript("Merry Christmas 1997 everybody!", modelID: "whisper-medium", to: spoken)
        #expect(year(spoken.inferredRecordDate) == 1997 && spoken.inferredDateConfidence == 0.55)
        #expect(spoken.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
        // Dossier propagation already copied the transcript to the twin, so
        // the twin reads its OWN evidence rather than borrowing.
        #expect(year(spokenTwin.inferredRecordDate) == 1997)

        model.applyCaptions([SceneCaption(timestamp: 0, text: "A cake with candles reading 1985")],
                            to: "/V/b.mov", model: "qwen2.5-vl-3b-4bit")
        #expect(year(captioned.inferredRecordDate) == 1985 && captioned.inferredDateConfidence == 0.55)
        #expect(year(captionedTwin.inferredRecordDate) == 1985)
    }

    @Test func liveReload_mergedRowSharesItsDateWithSiblingsInMemory() throws {
        let dir = try scratchDir("hook-live")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let mem = makeRecord(path: "/Volumes/Projects/1991/NV12.mkv", md5: "m", size: 1)
        let twin = makeRecord(path: "/Volumes/MediaExpansion/1991/NV12.mkv", md5: "m", size: 1)
        model.records = [mem, twin]

        // What the external merger wrote to disk for ONE copy.
        let fresh = mem.snapshotClone()
        fresh.ocrDateCandidates = [Self.nv12OCR]
        fresh.inferredRecordDate = Self.june21_1991
        fresh.inferredDateConfidence = 0.75
        fresh.dossierProcessedAt = Date(timeIntervalSince1970: 1_784_081_580)
        fresh.dossierProcessedBy = "qwen2.5-vl-3b-4bit"

        let merged = model.mergeDossierFields(from: [fresh])
        #expect(merged == 1)
        #expect(mem.inferredRecordDate == Self.june21_1991)
        #expect(twin.inferredRecordDate == Self.june21_1991, "the sweep is where an external result lands — siblings follow at once")
        #expect(twin.inferredDateSource == "propagated from \(mem.id.uuidString)")
    }

    @Test func liveReload_carriesTheProvenanceField() throws {
        let dir = try scratchDir("hook-live-src")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let mem = makeRecord(path: "/V/a.mov")
        model.records = [mem]
        let fresh = mem.snapshotClone()
        fresh.inferredRecordDate = Self.june21_1991
        fresh.inferredDateConfidence = 0.75
        fresh.inferredDateSource = "propagated from \(UUID().uuidString)"
        fresh.dossierProcessedAt = Date()
        _ = model.mergeDossierFields(from: [fresh])
        #expect(mem.inferredDateSource == fresh.inferredDateSource)
    }

    // MARK: - Notifications + search index

    @Test func smallPass_postsARecordScopedMutationPerTouchedRow() throws {
        let dir = try scratchDir("notify")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let donor = makeRecord(path: "/V/a.mov", md5: "m", size: 1,
                               inferred: Self.june21_1991, confidence: 0.95)
        let twin = makeRecord(path: "/W/a.mov", md5: "m", size: 1)
        model.records = [donor, twin]

        final class Box: @unchecked Sendable { var objects: [AnyObject?] = [] }
        let box = Box()
        let token = NotificationCenter.default.addObserver(
            forName: .videoScanCatalogMutated, object: nil, queue: nil
        ) { note in box.objects.append(note.object as AnyObject?) }
        defer { NotificationCenter.default.removeObserver(token) }

        model.catchUpInferredDates(trigger: "test")
        #expect(box.objects.contains { ($0 as? VideoRecord) === twin },
                "the Inspector shape: the mutated record rides the notification")
        #expect(model.searchIndex.filter(records: model.records, query: "year:1991").contains { $0 === twin },
                "year: searches see the propagated date immediately")
    }

    @Test func bulkPass_postsOneUnscopedMutation() throws {
        let dir = try scratchDir("notify-bulk")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let n = VideoScanModel.inferredDatePerRecordNoticeCap + 10
        model.records = (0..<n).map { i in makeRecord(path: "/V/\(i).mov", ocr: [Self.nv12OCR]) }

        final class Counter: @unchecked Sendable { var scoped = 0; var unscoped = 0 }
        let c = Counter()
        let token = NotificationCenter.default.addObserver(
            forName: .videoScanCatalogMutated, object: nil, queue: nil
        ) { note in if note.object == nil { c.unscoped += 1 } else { c.scoped += 1 } }
        defer { NotificationCenter.default.removeObserver(token) }

        let result = model.catchUpInferredDates(trigger: "test")
        #expect(result.inferredFromEvidence == n)
        #expect(c.unscoped == 1 && c.scoped == 0)
        #expect(model.searchIndex.filter(records: model.records, query: "year:1991").count == n,
                "the bulk path refreshes the index itself before the single unscoped notice")
    }

}

// MARK: - Persistence, isolation, scale
//
// Same fixtures, second suite: keeps each type under SwiftLint's body
// limit and reads as "the field survives / nothing leaks / it scales".

@MainActor
@Suite("InferredDatePropagation — persistence, isolation, scale")
struct InferredDatePropagationPersistenceAndScaleTests {

    private func scratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("InferredDatePropagationTests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeModel(_ dir: URL) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir)
        return model
    }

    private func makeRecord(
        path: String, md5: String = "", size: Int64 = 0,
        ocr: [SceneCaption] = [], transcript: String? = nil,
        inferred: Date? = nil, confidence: Float? = nil, source: String? = nil,
        userDate: String? = nil
    ) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.partialMD5 = md5
        r.sizeBytes = size
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.ocrDateCandidates = ocr
        r.audioTranscript = transcript
        r.inferredRecordDate = inferred
        r.inferredDateConfidence = confidence
        r.inferredDateSource = source
        r.userDate = userDate
        return r
    }

    static var june21_1991: Date { InferredDatePropagationTests.june21_1991 }
    static var nv12OCR: SceneCaption { InferredDatePropagationTests.nv12OCR }

    // MARK: - Persistence of the provenance field

    @Test func inferredDateSource_roundTripsThroughTheDTO_andIsOmittedWhenNil() throws {
        let r = VideoRecord()
        r.inferredRecordDate = Self.june21_1991
        r.inferredDateConfidence = 0.75
        r.inferredDateSource = "propagated from \(UUID().uuidString)"
        let data = try JSONEncoder().encode(VideoRecordDTO(r))
        let decoded = try JSONDecoder().decode(VideoRecord.self, from: data)
        #expect(decoded.inferredDateSource == r.inferredDateSource)
        #expect(decoded.inferredRecordDate == r.inferredRecordDate)

        let bare = VideoRecord()
        bare.inferredRecordDate = Self.june21_1991
        let json = String(data: try JSONEncoder().encode(VideoRecordDTO(bare)), encoding: .utf8) ?? ""
        #expect(!json.isEmpty && !json.contains("inferredDateSource"), "own-pass records round-trip byte-identical")
        #expect(bare.snapshotClone().inferredDateSource == nil)
        r.inferredDateSource = "catch-up"
        #expect(r.snapshotClone().inferredDateSource == "catch-up")
    }

    @Test func rescanPreservation_carriesAPropagatedDateAndItsProvenance() {
        let original = makeRecord(path: "/V/a.mov", inferred: Self.june21_1991, confidence: 0.75,
                                  source: "propagated from \(UUID().uuidString)")
        let snap = RescanPreservedFields(from: original)
        #expect(snap.isWorthRestoring, "a propagated date on a record with no dossier stamp must survive a rescan")
        let fresh = makeRecord(path: "/V/a.mov")
        snap.apply(to: fresh)
        #expect(fresh.inferredRecordDate == Self.june21_1991)
        #expect(fresh.inferredDateConfidence == 0.75)
        #expect(fresh.inferredDateSource == original.inferredDateSource)
    }

    @Test func enrichmentInheritance_carriesTheProvenanceWithTheDate() throws {
        let dir = try scratchDir("enrich")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        let extra = makeRecord(path: "/V/a.mov", inferred: Self.june21_1991, confidence: 0.75,
                               source: VideoScanModel.InferredDateSource.catchUp)
        let master = makeRecord(path: "/W/a.mov")
        let carried = model.applyEnrichmentInheritance(from: extra, to: master)
        #expect(carried.contains("inferred date"))
        #expect(master.inferredDateSource == VideoScanModel.InferredDateSource.catchUp)
    }

    // MARK: - Isolation

    @Test func passNeverWritesOutsideTheScratchStore() throws {
        let dir = try scratchDir("isolation")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)
        model.records = [makeRecord(path: "/V/a.mov", ocr: [Self.nv12OCR])]
        model.catchUpInferredDates(trigger: "test")
        #expect(model.catalogStore.fileLocation.hasPrefix(dir.path),
                "every save this pass schedules lands in scratch")
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "~"
        #expect(!model.catalogStore.fileLocation.hasPrefix(appSupport))
    }

    // MARK: - Scale

    @Test("scale: 100k records / 5k content groups catch up inside budget",
          .timeLimit(.minutes(2)))
    func scale_100kRecords5kGroupsWithinBudget() throws {
        let dir = try scratchDir("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = makeModel(dir)

        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        // 5,000 groups of 4 (20k rows): one content-backed donor, one
        // undated twin, one with its own OCR, one user-dated.
        for g in 0..<5_000 {
            let md5 = String(format: "%032x", g + 1)
            records.append(makeRecord(path: "/V/g\(g)/a.mov", md5: md5, size: 1_000 + Int64(g),
                                      inferred: Self.june21_1991, confidence: 0.85))
            records.append(makeRecord(path: "/W/g\(g)/a.mov", md5: md5, size: 1_000 + Int64(g)))
            records.append(makeRecord(path: "/X/g\(g)/a.mov", md5: md5, size: 1_000 + Int64(g),
                                      ocr: [Self.nv12OCR]))
            records.append(makeRecord(path: "/Y/g\(g)/a.mov", md5: md5, size: 1_000 + Int64(g),
                                      userDate: "1991"))
        }
        // 80k solo rows: 10k with a transcript and no year, 10k under a
        // bare-year folder, 60k bare.
        for i in 0..<80_000 {
            let path: String
            var transcript: String?
            switch i % 8 {
            case 0: transcript = "We went to the beach and had a picnic with the kids and grandma."
                    path = "/S/\(i).mov"
            case 1: path = "/S/1992/\(i).mov"
            default: path = "/S/\(i).mov"
            }
            records.append(makeRecord(path: path, md5: "solo-\(i)", size: Int64(i), transcript: transcript))
        }
        model.records = records

        let clock = SuspendingClock()
        var result = VideoScanModel.InferredDateCatchUpResult()
        let elapsed = clock.measure {
            result = model.catchUpInferredDates(trigger: "scale")
        }
        #expect(result.inferredFromEvidence == 5_000)
        #expect(result.propagated == 5_000)
        #expect(result.folderYear == 10_000)
        #expect(result.examined == 15_000)
        // Bucketing 100k references + 15k regex scans + 5k group walks is
        // well under a second in Debug; 3 s only trips on a complexity
        // regression (e.g. an O(records) sibling search per group).
        #expect(elapsed < .seconds(3),
                "catch-up took \(elapsed) for 100k records / 5k groups")

        var second = VideoScanModel.InferredDateCatchUpResult()
        let again = clock.measure { second = model.catchUpInferredDates(trigger: "scale") }
        #expect(second.total == 0, "idempotent at scale")
        #expect(again < .seconds(3))
    }
}

// MARK: - Real-catalog REPORT (read-only; skipped where the catalog is absent)
//
// Same nondestructive shape as DateInferenceSensorTests: copy catalog.json
// to a temp dir, decode it through the production loader, run the pass on
// a model whose store points at ANOTHER temp dir. Nothing under
// ~/Library/Application Support is ever written. Prints the two numbers
// Rick asked for on 2026-09-12; asserts only the NV12 invariant.

private func realCatalogURL() -> URL {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return appSupport.appendingPathComponent("VideoScan", isDirectory: true)
        .appendingPathComponent("catalog.json")
}

@MainActor
@Suite("InferredDatePropagation — real catalog report", .enabled(if: FileManager.default.fileExists(atPath: realCatalogURL().path)))
struct InferredDatePropagationRealCatalogReport {

    @Test("REPORT: undated OCR-bearing records today, and what one catch-up pass would date")
    func report() throws {
        let src = FileManager.default.temporaryDirectory
            .appendingPathComponent("InferredDateReport-src-\(UUID().uuidString)", isDirectory: true)
        let dst = FileManager.default.temporaryDirectory
            .appendingPathComponent("InferredDateReport-dst-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dst, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: src)
            try? FileManager.default.removeItem(at: dst)
        }
        try FileManager.default.copyItem(at: realCatalogURL(), to: src.appendingPathComponent("catalog.json"))
        let records = CatalogStore(directory: src).load()

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dst)
        model.records = records

        let active = records.filter { VideoScanModel.isEligibleForDateInference($0) }
        let undatedOCR = active.filter { !$0.ocrDateCandidates.isEmpty && $0.inferredRecordDate == nil }
        let result = model.catchUpInferredDates(trigger: "report")

        print("""
        INFERRED-DATE REPORT (\(records.count) records, \(active.count) eligible):
          active records with ocrDateCandidates and NO inferredRecordDate today: \(undatedOCR.count)
          one catch-up pass would date: \(result.total) — \(result.inferredFromEvidence) from own evidence, \
        \(result.propagated) by propagation, \(result.folderYear) folder-year prior (\(result.examined) examined, \
        \(Int(result.elapsed * 1000)) ms)
        """)

        // The NV12 invariant on the real data: every content group with a
        // content-backed date has no undated, un-user-dated eligible member left.
        var byKey: [CatalogSizeTotals.GroupKey: [VideoRecord]] = [:]
        for rec in active { if let k = VideoScanModel.contentGroupKey(rec) { byKey[k, default: []].append(rec) } }
        var leftBehind = 0
        var unverifiedInBucket = 0
        for (_, members) in byKey where members.count >= 2 {
            let donors = members.filter { VideoScanModel.canDonateInferredDate($0) }
            guard !donors.isEmpty else { continue }
            for rec in members where rec.inferredRecordDate == nil && rec.userDate == nil {
                if donors.contains(where: { VideoScanModel.haveVerifiedSameContent($0, rec) }) {
                    leftBehind += 1
                } else {
                    unverifiedInBucket += 1
                }
            }
        }
        print("  undated rows sharing a bucket with a dated row but NOT verified same bytes (conflicting content hash): \(unverifiedInBucket)")
        #expect(leftBehind == 0, "\(leftBehind) undated verified copies remain in groups that have a content-backed date")

        // codex #1413 repair preview (scratch store — nothing real is written):
        // how many persisted propagated dates rest on unverified identity,
        // and how many of those a VERIFIED pass would date again.
        let unwound = model.unwindUnverifiedPropagatedDates(trigger: "report")
        let redated = model.catchUpInferredDates(trigger: "report-after-unwind")
        let again = model.unwindUnverifiedPropagatedDates(trigger: "report-2").unwound
        print("""
          LOAD PREVIEW — unwind clears: \(unwound.unwound) unverified propagated dates (\(unwound.conflictingHashes) with conflicting hashes)
          LOAD PREVIEW — then one verified pass re-dates: \(redated.total) — \(redated.inferredFromEvidence) own, \
        \(redated.propagated) propagated, \(redated.folderYear) folder-year (\(redated.examined) examined)
          LOAD PREVIEW — a second unwind finds: \(again)
        """)
        #expect(unwound.sidecar?.path.hasPrefix(dst.path) == true, "the report's sidecar lands in scratch, never App Support")
    }
}
