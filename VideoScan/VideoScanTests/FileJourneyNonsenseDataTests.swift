// FileJourneyNonsenseDataTests.swift
// The File Journey against data that makes no sense (Rick 2026-11-14:
// "tests with known wrong or nonsense data and see if your logic handles
// things gracefully").
//
// One seeded generator builds 1,000 small catalogs of deliberately broken
// records — empty and enormous notes, CRLF and NUL bytes, half-written
// stamps, dates in 1970 and in the future, a record that is its own source,
// a source that is not in the catalog, paths that are empty or are the
// archive root itself, MD5 and garbage digests, a disk that answers
// differently for every path. For each, the sheet is built and checked
// against rules written HERE, independently of the builder:
//
//   * it builds, and the timeline is origin … current state, in order;
//   * Archived is green only when the test's own oracle finds a copy that
//     the (fake) disk says is present AND that carries a whole-file SHA-256;
//   * "read back and matched" is said only of a copy Promote made;
//   * Reviewed is green only when the oracle finds an act of the person's;
//   * Offsite is there only when a cloud / off-site answer of yes or no is;
//   * no date is outside 2000…now, no machine text reaches the timeline,
//     and building twice gives the same sheet.
//
// Deterministic: the seed is fixed, so a failure names a case that can be
// replayed (`FileJourneyNonsenseDataTests.replay(case:)`).

import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

/// SplitMix64 — a tiny seeded generator (the standard library's is unseedable).
private struct Chaos: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
    mutating func chance(_ percent: UInt64) -> Bool { next() % 100 < percent }
}

@MainActor
private enum Nonsense {
    static let now = Date(timeIntervalSince1970: 1_794_700_000)   // 2026-11-14
    static let root = "/Volumes/FamilyArchive/Breen_Family_Archive"
    static let sha = String(repeating: "ab", count: 32)
    static let neutral: VolumeSafetyResolver = { _ in VolumeSafety.unknown }

    static let dates: [Date?] = [
        nil, nil, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -5),
        Date(timeIntervalSince1970: 946_684_799), Date(timeIntervalSince1970: 946_684_800),
        now.addingTimeInterval(-86_400 * 90), now.addingTimeInterval(-86_400 * 30), now.addingTimeInterval(-3_600),
        now, now.addingTimeInterval(1), now.addingTimeInterval(86_400 * 500),
        Date.distantPast, Date.distantFuture,
    ]

    static let paths: [String] = [
        "", "/", "x.mov", root, root + "/", root + "2/30_Video/x.mov", root + "/30_Video/1984/x.mov",
        root + "/30_Video/1984/y.mov", "/Volumes/Projects/Movies/x.mov", "/Volumes/Projects/Movies/y.mov",
        "/Users/rickb/Movies/x.mov", "/Volumes/\u{0}/x.mov", "/Volumes/FamilyArchive", "///",
        "/Volumes/Projects/" + String(repeating: "deep/", count: 200) + "x.mov",
    ]

    static let noteLines: [String] = [
        "", " ", "\u{0}", "\u{FFFD}\u{FFFD}", "🎬📼", String(repeating: "A", count: 20_000),
        "ffprobe: [mov,mp4,m4a,3gp,3g2,mj2 @ 0xb21034000] UDTA parsing failed retrying raw",
        "[aac @ 0x7ac800a80] Last message repeated 2 times", "scan: probe timed out",
        "Promote 2026-09-23T17:47:00Z: promoted from /Volumes/Projects/Movies/x.mov · sha256 abab · readiness: audio verified",
        "Promote 2026-09-23T17:47:00Z: promoted to Master Archive as 30_Video/1984/x.mov",
        "Promote not-a-date: promoted to Master Archive as x.mov", "Promote ", "Promote : ",
        "promote: Update 2026-10-30T14:00:00Z: Name: A → B · a.mov → b.mov · sha256 verified before and after",
        "promote: Update : ", "promote: Update garbage", "promote: Update 2026-10-30T14:00:00Z:  · ",
        "promote: Promote 2026-09-23T17:47:00Z: date 1984 (estimated)",
        "Reconcile 2026-05-30T10:00:00Z: source file not found", "Reconcile 2026-13-45T99:99:99Z: source-side move detected",
        "Reconcile 2026-05-30T10:00:00Z: reason=dup-on-other-volume witnesses=[\"/Volumes/X/c.bin\"] totalWitnesses=1",
        "Reconcile", "Migrate 2026-06-01T00:00:00Z: salvage — failed", "Relocate ::::", "Combined: a + b", "Combined: ",
        "Reformat 2026-06-14T12:00:00Z: Reformatted to HEVC as x.mov", " · readiness: ", "Dad and the boys",
    ]
    static let separators = ["\n", "\r\n", "\n\n", "\r", "\u{2028}"]

    static func notes(_ rng: inout Chaos) -> String {
        let count = Int(rng.next() % 6)
        return (0..<count).map { _ in rng.pick(noteLines) }.joined(separator: rng.pick(separators))
    }

    static func record(_ rng: inout Chaos, id: UUID = UUID()) -> VideoRecord {
        let r = VideoRecord(id: id)
        r.fullPath = rng.pick(paths)
        r.filename = (r.fullPath as NSString).lastPathComponent
        r.streamTypeRaw = rng.pick([StreamType.videoAndAudio.rawValue, StreamType.audioOnly.rawValue, "", "garbage"])
        r.sizeBytes = rng.pick([0, -1, 4096, Int64.max])
        r.notes = notes(&rng)
        r.userNotes = rng.pick(["", " \n ", "Dad's 50th, the porch", noteLines[6], noteLines[6] + "\nOur note", "\u{0}"])
        r.dateModifiedRaw = rng.pick(dates)
        r.dateCreatedRaw = rng.pick(dates)
        r.scanContext.scannedAt = rng.pick(dates)
        r.contentHashAt = rng.pick(dates)
        r.dupAnalyzedAt = rng.pick(dates)
        r.sceneCaptionDate = rng.pick(dates)
        r.audioTranscriptDate = rng.pick(dates)
        r.audioTranscript = rng.pick([nil, "", "hello"])
        r.dossierProcessedAt = rng.pick(dates)
        r.audioVerifyDate = rng.pick(dates)
        r.audioVerifyStatus = rng.pick(["", "ok", "damaged", "💥"])
        r.archivedAt = rng.pick(dates)
        r.repairConfirmedDate = rng.chance(10) ? rng.pick(dates) : nil
        r.originalFullPath = rng.chance(40) ? rng.pick(paths) : nil
        r.originVolume = rng.pick([nil, "", "Projects"])
        r.contentHash = rng.pick(["", "v1:" + sha, "garbage"])
        r.derivationKind = rng.pick([nil, nil, ArchivePromotion.derivationKind, ArchivePromotion.derivationKind, "trim", "", "garbage"])
        r.archiveStage = rng.pick([.none, .masterAssigned, .archived, .manuallyDeleted])
        r.starRating = Int(rng.next() % 4)
        if rng.chance(60) {
            r.archiveFixity = ArchiveFixity(algorithm: rng.pick(["sha256", "sha256", "md5", ""]),
                                            digest: rng.pick([sha, sha, sha, "d41d8cd98f00b204e9800998ecf8427e", "", "zz"]),
                                            verifiedAt: rng.pick(dates) ?? now, sizeBytes: rng.pick([0, 4096]))
        }
        if rng.chance(30) {
            r.contentFixity = ContentFixity(digest: rng.pick([sha, "nope"]), byteCount: rng.pick([4096, 1]),
                                            stamp: FileIdentityStamp(device: 1, inode: 1, size: 4096, mtimeNs: 1),
                                            computedAt: rng.pick(dates) ?? now)
        }
        if rng.chance(15) { r.userDate = rng.pick(["1984", "1984-07-04", "not a date", ""]) }
        if rng.chance(15) {
            r.confirmedByUserPeople = [ConfirmedTag(name: rng.pick(["Dad", "", "🎬"]), confirmedAt: rng.pick(dates) ?? now)]
        }
        if rng.chance(15) {
            r.footageDecisions = [FootageDecision(otherID: UUID(), verdict: rng.pick([.same, .notSame]), decidedAt: rng.pick(dates) ?? now)]
        }
        if rng.chance(25) {
            r.backupAttestations = [BackupAttestation(kind: rng.pick([.cloud, .offsite, .drive]),
                                                      answer: rng.pick([.yes, .no, .notApplicable]),
                                                      label: rng.pick([nil, "", "iCloud"]), attestedAt: rng.pick(dates) ?? now)]
        }
        return r
    }

    /// One case: the row the sheet opens on, the rest of its little catalog,
    /// the root the model would hand over, and a disk that answers by path.
    struct Case {
        let rec: VideoRecord
        let all: [VideoRecord]
        let root: String?
        let presence: [JourneyPresence]
        func probe(_ path: String) -> JourneyPresence {
            // A stable hash (String.hashValue is seeded per process): the case replays the same on any run.
            presence[Int(path.utf8.reduce(UInt(7)) { $0 &* 31 &+ UInt($1) } % UInt(presence.count))]
        }
    }

    static func make(_ index: Int) -> Case {
        var rng = Chaos(state: 0xF11E_0000 &+ UInt64(index))
        let rec = record(&rng)
        var all: [VideoRecord] = []
        for _ in 0..<Int(rng.next() % 4) { all.append(record(&rng)) }
        // Links, sane and not: itself, a neighbour, nobody; neighbours that point back.
        rec.derivedFrom = rng.pick([nil, rec.id, all.first?.id, UUID()])
        for other in all where rng.chance(50) {
            other.derivedFrom = rng.pick([rec.id, other.id, UUID()])
        }
        if rng.chance(20) { all.first?.purgedAt = now }
        if rng.chance(80) { all.insert(rec, at: Int(rng.next() % UInt64(all.count + 1))) }   // 1 in 5: rec is not in the catalog
        // Half the answers are "a regular file is there", so the provable cases are reached too.
        let presence: [JourneyPresence] = [.regularFile, .regularFile, .regularFile, .regularFile, .regularFile, .regularFile,
                                           .regularFile, .regularFile, .missing, .volumeOffline(volume: "FamilyArchive"),
                                           .unknown(reason: "Permission denied"), .notAFile, .brokenLink(target: "/gone"),
                                           .linkToFile(target: "/there"), .linkTargetUnknown(target: "/x", reason: "Input/output error"),
                                           .regularFileThroughLink(at: "/Users/rickb/Movies")]
        var order = presence
        order.shuffle(using: &rng)
        return Case(rec: rec, all: all, root: rng.pick([root, root, root + "/", nil, "", "/"]), presence: order)
    }

    static func build(_ c: Case) -> FileJourney {
        var extras = FileJourneyBuilder.Extras()
        extras.archiveRootPath = c.root
        extras.archiveName = "FamilyArchive"
        extras.now = now
        return VideoScanModel.buildFileJourney(for: c.rec, allRecords: c.all, resolveVolumeSafety: neutral,
                                               extras: extras, probe: c.probe)
    }

    // MARK: The oracle (written here, not borrowed from the builder)

    static func isPromoted(_ r: VideoRecord) -> Bool { r.derivationKind == "archivePromotion" }

    /// The copy in the archive, by the design's rule: the row itself when it
    /// is a promoted copy or sits under the root (and is not purged); else
    /// the first promoted row made from it — if that row is not purged and
    /// its bytes are not provably other bytes.
    static func copy(_ c: Case) -> VideoRecord? {
        if isPromoted(c.rec) || VideoScanModel.isInsideMasterArchive(path: c.rec.fullPath, root: c.root) {
            return c.rec.purgedAt == nil ? c.rec : nil
        }
        guard let made = c.all.first(where: { $0.derivedFrom == c.rec.id && isPromoted($0) }),
              made.purgedAt == nil, sameBytes(c.rec, made) else { return nil }
        return made
    }

    static func sha256(_ r: VideoRecord) -> String? {
        func good(_ algorithm: String, _ digest: String) -> Bool {
            algorithm == "sha256" && digest.count == 64 && digest.allSatisfy(\.isHexDigit)
        }
        if let a = r.archiveFixity, good(a.algorithm, a.digest) { return a.digest.lowercased() }
        if let f = r.contentFixity, good(f.algorithm, f.digest) { return f.digest.lowercased() }
        return nil
    }

    /// The archive fixity and a later whole-file read both name a SHA-256, and not the same one.
    static func contradicts(_ r: VideoRecord) -> Bool {
        func hex(_ algorithm: String, _ digest: String) -> String? {
            algorithm == "sha256" && digest.count == 64 && digest.allSatisfy(\.isHexDigit) ? digest.lowercased() : nil
        }
        guard let a = r.archiveFixity.flatMap({ hex($0.algorithm, $0.digest) }),
              let f = r.contentFixity.flatMap({ hex($0.algorithm, $0.digest) }) else { return false }
        return a != f
    }

    /// Both hashes known: equal. Otherwise: not already different in size.
    /// A row that contradicts itself is the same bytes as nothing but itself.
    static func sameBytes(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        if a.id == b.id { return true }
        if contradicts(a) || contradicts(b) { return false }
        if let x = sha256(a), let y = sha256(b) { return x == y }
        return a.sizeBytes == b.sizeBytes
    }

    static func plausible(_ date: Date?) -> Bool {
        guard let date else { return false }
        return date <= now && date.timeIntervalSince1970 >= 946_684_800
    }

    static func hasWholeFileSHA256(_ r: VideoRecord) -> Bool { sha256(r) != nil }

    static func family(_ c: Case) -> [VideoRecord] {
        var out = [c.rec]
        if let copy = copy(c), copy.id != c.rec.id { out.append(copy) }
        if isPromoted(c.rec), let source = c.all.first(where: { $0.id == c.rec.derivedFrom }),
           sameBytes(c.rec, source), !out.contains(where: { $0.id == source.id }) {
            out.append(source)
        }
        return out
    }

    /// A well-formed Update line: a readable ISO date and a reason.
    static func hasUpdateLine(_ notes: String) -> Bool {
        notes.split(whereSeparator: \.isNewline).contains { line in
            guard line.hasPrefix("promote: Update ") else { return false }
            let rest = line.dropFirst("promote: Update ".count)
            guard let colon = rest.range(of: ": "),
                  plausible(ISO8601DateFormatter().date(from: String(rest[..<colon.lowerBound]))) else { return false }
            let body = rest[colon.upperBound...]
            let reason = body.range(of: " · ").map { body[..<$0.lowerBound] } ?? body
            return !reason.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func personActed(_ c: Case) -> Bool {
        let members = family(c)
        if members.contains(where: pfRecordHasConfirmedDate) { return true }
        if members.contains(where: { $0.userPlaceStatus != .unplaced }) { return true }
        if members.contains(where: { !$0.confirmedByUserPeople.isEmpty || !$0.footageDecisions.isEmpty }) { return true }
        // A repair's confirmation is recorded only as its date: the first one found must be a real date.
        if let first = members.compactMap(\.repairConfirmedDate).first(where: plausible) { _ = first; return true }
        if members.contains(where: { r in
            r.userNotes.split(whereSeparator: \.isNewline)
                .contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && !MachineNote.isMachineLine($0) }
        }) { return true }
        var notes = [c.rec.notes]
        if let copy = copy(c), copy.id != c.rec.id { notes.append(copy.notes) }
        return notes.contains(where: hasUpdateLine)
    }

    static func offsiteAnswered(_ c: Case) -> Bool {
        var latest: [BackupAttestation.Kind: BackupAttestation] = [:]
        for a in family(c).flatMap(\.backupAttestations) where a.kind == .cloud || a.kind == .offsite {
            if let have = latest[a.kind], !BackupAttestation.prefers(a, over: have) { continue }
            latest[a.kind] = a
        }
        return latest.values.contains { $0.answer == .yes || $0.answer == .no }
    }
}

@Suite("File Journey — nonsense data: 1,000 broken catalogs, the sheet stays true", .serialized)
@MainActor
struct FileJourneyNonsenseDataTests {

    static let cases = 1_000

    /// Rebuild one case by number (for a failure's message).
    static func replay(case index: Int) -> FileJourney { Nonsense.build(Nonsense.make(index)) }

    @Test("ISOLATION: every broken catalog builds a sheet whose timeline is origin … current state, in date order")
    func itBuildsAndIsOrdered() {
        for index in 0..<Self.cases {
            let journey = Self.replay(case: index)
            #expect(journey.events.count >= 2, "case \(index)")
            #expect(journey.events.first?.kind == .origin, "case \(index)")
            let last = journey.events.last?.kind
            #expect(last == .currentState || last == .notAtPath || last == .presenceUnknown, "case \(index): \(String(describing: last))")
            let middle = journey.events.dropFirst().dropLast()
            let stamps = middle.map(\.timestamp)
            var seenUndated = false
            var previous = Date.distantPast
            for (offset, stamp) in stamps.enumerated() {
                guard let stamp else { seenUndated = true; continue }
                #expect(!seenUndated, "case \(index): a dated event after an undated one at \(offset)")
                #expect(stamp >= previous, "case \(index): out of order at \(offset)")
                previous = stamp
            }
            #expect(journey.events.allSatisfy { !$0.sentence.isEmpty && !$0.icon.isEmpty }, "case \(index)")
        }
    }

    @Test("TRUTH: Archived is green only when the oracle finds a copy on the disk with a whole-file SHA-256")
    func archivedOnlyWhenProven() throws {
        var green = 0
        for index in 0..<Self.cases {
            let c = Nonsense.make(index)
            let journey = Nonsense.build(c)
            let archived = try #require(journey.preservation.first { $0.kind == .archived }, "case \(index)")
            let copy = Nonsense.copy(c)
            // The bytes themselves at that path — a link to them elsewhere is not a copy in the archive.
            let proven = copy.map {
                c.probe($0.fullPath) == .regularFile && Nonsense.hasWholeFileSHA256($0) && !Nonsense.contradicts($0)
            } ?? false
            #expect(archived.done == proven, "case \(index): done=\(archived.done) oracle=\(proven) todo=\(archived.todo)")
            if archived.done { green += 1 } else { #expect(!archived.todo.isEmpty, "case \(index): an open step with no door") }
            // "Read back and matched" is Promote's read-back, never a lone fingerprint.
            for event in journey.events where event.sentence.contains("read back and matched") {
                let promoted = copy.map(Nonsense.isPromoted) ?? false
                let readBack = copy?.archiveFixity.map {
                    $0.algorithm == "sha256" && $0.digest.count == 64 && $0.digest.allSatisfy(\.isHexDigit)
                } ?? false
                #expect(promoted && readBack, "case \(index): \(event.sentence)")
            }
            // The date under Archived is an archive day the copy itself carries — never a check's date.
            if let date = archived.date, let copy {
                #expect(date == copy.archivedAt || date == VideoRecord.promoteStamp(inNotes: copy.notes), "case \(index)")
            }
        }
        #expect(green > 20 && green < Self.cases - 20, "the generator must reach both answers: \(green) green of \(Self.cases)")
    }

    @Test("TRUTH: Reviewed is green only when the oracle finds an act of the person's; Offsite only when they answered")
    func reviewedAndOffsiteOnlyOnThePersonsWord() throws {
        var reviewedCount = 0, offsiteCount = 0
        for index in 0..<Self.cases {
            let c = Nonsense.make(index)
            let journey = Nonsense.build(c)
            let reviewed = try #require(journey.preservation.first { $0.kind == .reviewed }, "case \(index)")
            #expect(reviewed.done == Nonsense.personActed(c), "case \(index): done=\(reviewed.done) detail=\(reviewed.detail)")
            if reviewed.done { reviewedCount += 1 }
            let offsite = journey.preservation.first { $0.kind == .offsite }
            #expect((offsite != nil) == Nonsense.offsiteAnswered(c), "case \(index)")
            if let offsite {
                offsiteCount += 1
                #expect(!offsite.done, "case \(index): the person's word drawn as a proven tick")
            }
            let tally = PreservationChecklist.tally(journey.preservation)
            #expect(tally.done <= tally.of && tally.of >= 4, "case \(index)")
            #expect(journey.preservation.first?.kind == .catalogued && journey.preservation.first?.done == true, "case \(index)")
        }
        #expect(reviewedCount > 20 && reviewedCount < Self.cases - 20, "both answers reached: \(reviewedCount)")
        #expect(offsiteCount > 20, "Offsite reached: \(offsiteCount)")
    }

    @Test("TRUTH: no date outside 2000…now, no machine text in the timeline, and the same sheet twice")
    func datesTextAndDeterminism() {
        let floor = Date(timeIntervalSince1970: 946_684_800)
        for index in 0..<Self.cases {
            let journey = Self.replay(case: index)
            if let catalogued = journey.preservation.first?.date {
                #expect(catalogued >= floor && catalogued <= Nonsense.now, "case \(index): catalogued \(catalogued)")
            }
            for event in journey.events.dropFirst().dropLast() {   // the origin's date is the file's own clock, whatever it says
                if let at = event.timestamp {
                    #expect(at >= floor && at <= Nonsense.now, "case \(index): \(event.kind) \(at)")
                }
                #expect(!event.sentence.contains("ffprobe:") && !event.sentence.contains("0xb21034000")
                        && !event.sentence.contains("sha256"), "case \(index): \(event.sentence.prefix(120))")
                #expect(event.sentence.count < 5_000, "case \(index): a 20,000-character note became a sentence")
            }
            let again = Self.replay(case: index)
            #expect(again.preservation == journey.preservation, "case \(index)")
            #expect(again.events.map(\.sentence) == journey.events.map(\.sentence), "case \(index)")
            #expect(again.details == journey.details, "case \(index)")
        }
    }

    @Test("SCALE: the 1,000 nonsense sheets build inside 2 s")
    func theyBuildQuickly() {
        let elapsed = ContinuousClock().measure {
            for index in 0..<Self.cases { _ = Self.replay(case: index) }
        }
        #expect(elapsed < .seconds(2), "took \(elapsed)")
    }
}
