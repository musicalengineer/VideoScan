import Foundation
import Testing
@testable import VideoScan

/// Which record a named file means (2026-09-02): exact beats near, case
/// does not matter, a real tie is a which-one with its true count, an
/// explicit path is exact or nothing, the memo never answers for a
/// renamed or replaced row (codex #976), and the whole thing stays within
/// budget over a 100k-record catalog.
@MainActor
@Suite("Family Archivist record reference resolver", .serialized)
struct ArchivistRecordReferenceResolverTests {
    private func record(_ path: String) -> VideoRecord {
        let value = VideoRecord()
        value.fullPath = path
        value.directory = (path as NSString).deletingLastPathComponent
        value.filename = (path as NSString).lastPathComponent
        value.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return value
    }

    private func resolvedID(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> UUID? {
        if case .resolved(let record) = resolution { return record.id }
        return nil
    }

    private func candidates(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> [String]? {
        if case .ambiguous(let list, _) = resolution { return list.map(\.filename) }
        return nil
    }

    private func ambiguousTotal(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> Int? {
        if case .ambiguous(_, let total) = resolution { return total }
        return nil
    }

    private func isNotFound(_ resolution: ArchivistRecordReferenceResolver.Resolution, name: String? = nil) -> Bool {
        if case .notFound(let found) = resolution { return name == nil || found == name }
        return false
    }

    @Test func exactFilenameBeatsALongerNameThatContainsIt() {
        let exact = record("/Volumes/A/New Hampshire.mov")
        let longer = record("/Volumes/A/Long Sequence - New Hampshire Christmas .mov")
        let photos = record("/Volumes/A/ChristmasNewHampshirePhotos.mov")
        let records = [longer, photos, exact]

        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "New Hampshire.mov", in: records)) == exact.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "new hampshire.MOV", in: records)) == exact.id)
        // The stem tier: no extension typed.
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "New Hampshire", in: records)) == exact.id)
        // Whole-token tier: "Hampshire" alone is in all three → which-one.
        let tokenTie = ArchivistRecordReferenceResolver.resolve(file: "Hampshire", in: records)
        #expect(candidates(tokenTie)?.count == 3)
        #expect(ambiguousTotal(tokenTie) == 3)
    }

    @Test func fullPathIsExactFirstThenCaseInsensitive() {
        let a = record("/Volumes/A/tape.mov")
        let b = record("/Volumes/B/tape.mov")
        let records = [a, b]
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/Volumes/B/tape.mov", in: records)) == b.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/volumes/b/TAPE.MOV", in: records)) == b.id)
        // Same filename on two volumes, no path typed → which-one, both listed.
        #expect(candidates(ArchivistRecordReferenceResolver.resolve(file: "tape.mov", in: records)) == ["tape.mov", "tape.mov"])
    }

    /// codex #976 item 3: a path nobody has is NEVER silently swapped for
    /// a same-named file elsewhere; the same-basename files are offered.
    @Test func anExplicitPathResolvesExactlyOrFailsWithSameNameOffers() {
        let a = record("/Volumes/A/tape.mov")
        let b = record("/Volumes/B/tape.mov")
        let other = record("/Volumes/B/other.mov")
        let records = [a, b, other]

        let miss = ArchivistRecordReferenceResolver.resolve(file: "/Volumes/C/tape.mov", in: records)
        guard case .pathNotFound(let path, let sameName, let total) = miss else {
            Issue.record("a missing path must be pathNotFound, got \(miss)"); return
        }
        #expect(path == "/Volumes/C/tape.mov")
        #expect(sameName.map(\.fullPath) == ["/Volumes/A/tape.mov", "/Volumes/B/tape.mov"])
        #expect(total == 2)

        // Nothing is called that: pathNotFound with no offers, never the
        // token tier ("tape" is a token of both tape.mov files).
        let nothing = ArchivistRecordReferenceResolver.resolve(file: "/Volumes/C/tape 2.mov", in: records)
        guard case .pathNotFound(_, let none, let noneTotal) = nothing else {
            Issue.record("expected pathNotFound, got \(nothing)"); return
        }
        #expect(none.isEmpty)
        #expect(noneTotal == 0)

        // The memo form obeys the same rule.
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: records.count, revision: 1)
        let memoMiss = ArchivistRecordReferenceResolver.resolve(
            file: "/Volumes/C/tape.mov", in: records, index: index, version: version)
        guard case .pathNotFound(_, let memoSameName, let memoTotal) = memoMiss else {
            Issue.record("memo path miss must be pathNotFound, got \(memoMiss)"); return
        }
        #expect(memoSameName.map(\.id) == [a.id, b.id])
        #expect(memoTotal == 2)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "/Volumes/B/tape.mov", in: records, index: index, version: version)) == b.id)
    }

    @Test func stemMatchesAcrossContainersAndAmbiguityKeepsTheTrueCount() {
        let mov = record("/Volumes/A/Christmas.mov")
        let mkv = record("/Volumes/A/Christmas.mkv")
        let others = (1...7).map { record("/Volumes/A/Christmas_199\($0).mkv") }
        let records = [mov, mkv] + others

        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "Christmas.mkv", in: records)) == mkv.id)
        // "Christmas" as a stem: two exact stems → which-one of those two only.
        let stems = ArchivistRecordReferenceResolver.resolve(file: "Christmas", in: records)
        #expect(candidates(stems) == ["Christmas.mov", "Christmas.mkv"])
        #expect(ambiguousTotal(stems) == 2)
        // A token shared by nine files: five offered, nine counted (item 6).
        let capped = ArchivistRecordReferenceResolver.resolve(file: "Christmas_199", in: records)
        #expect(isNotFound(capped), "tokens '199' are not whole tokens of any filename? got \(capped)")
        let token = ArchivistRecordReferenceResolver.resolve(file: "Christmas 1991", in: records)
        #expect(resolvedID(token) == others[0].id)
        let many = ArchivistRecordReferenceResolver.resolve(file: "mkv", in: records)
        #expect(candidates(many)?.count == ArchivistRecordReferenceResolver.maxCandidates)
        #expect(ambiguousTotal(many) == 8)
        #expect(candidates(many) == ["Christmas.mkv", "Christmas_1991.mkv", "Christmas_1992.mkv", "Christmas_1993.mkv", "Christmas_1994.mkv"])
    }

    /// codex #976 item 6: identical basenames get the volume in their chip
    /// label, the parent folder when the volume is shared too; distinct
    /// basenames keep the bare filename.
    @Test func chipLabelsDisambiguateCollidingBasenames() {
        let labels = ArchivistRecordReferenceResolver.chipLabels(for: [
            .init(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/LaCie/1994/tape.mov"),
            .init(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/MyBook/1994/tape.mov"),
            .init(id: UUID(), filename: "other.mov", fullPath: "/Volumes/LaCie/1994/other.mov"),
        ])
        #expect(labels == ["tape.mov (LaCie)", "tape.mov (MyBook)", "other.mov"])
        let sameVolume = ArchivistRecordReferenceResolver.chipLabels(for: [
            .init(id: UUID(), filename: "Tape.mov", fullPath: "/Volumes/LaCie/1994/Tape.mov"),
            .init(id: UUID(), filename: "tape.mov", fullPath: "/Volumes/LaCie/1995/tape.mov"),
        ])
        #expect(sameVolume == ["Tape.mov (1994)", "tape.mov (1995)"])
        #expect(ArchivistRecordReferenceResolver.chipLabels(for: [
            .init(id: UUID(), filename: "x.mov", fullPath: "/Users/rick/Movies/x.mov"),
            .init(id: UUID(), filename: "x.mov", fullPath: "/Volumes/LaCie/x.mov"),
        ]) == ["x.mov (Users)", "x.mov (LaCie)"])
    }

    @Test func purgedRecordsNeverMatchAndNothingIsNotFound() {
        let live = record("/Volumes/A/live.mov")
        let purged = record("/Volumes/A/purged.mov")
        purged.purgedAt = Date()
        let records = [live, purged]
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(file: "purged.mov", in: records), name: "purged.mov"),
                "a purged record must not resolve")
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(file: "nothing like this.mov", in: records)))
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(file: "   ", in: records)), "blank is notFound")
    }

    @Test func selectionReferenceUsesTheLookupAndHonoursPurge() {
        let live = record("/Volumes/A/live.mov")
        let purged = record("/Volumes/A/purged.mov")
        purged.purgedAt = Date()
        let byID = [live.id: live, purged.id: purged]
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            .currentSelection, selectedRecordID: live.id, records: [live, purged], recordForID: { byID[$0] })) == live.id)
        if case .noSelection = ArchivistRecordReferenceResolver.resolve(
            .currentSelection, selectedRecordID: purged.id, records: [live, purged], recordForID: { byID[$0] }) {} else {
            Issue.record("a purged selection is no selection")
        }
        if case .noSelection = ArchivistRecordReferenceResolver.resolve(
            .currentSelection, selectedRecordID: nil, records: [live], recordForID: { byID[$0] }) {} else {
            Issue.record("nil is no selection")
        }
    }

    @Test func shellSelectPrefersTheExactFileAndKeepsTheSubstringFallback() {
        let first = record("/Volumes/A/Xmas 1994 part 2.mov")
        let exact = record("/Volumes/A/1994.mov")
        let records = [first, exact]
        // Exact filename wins over the first substring hit.
        #expect(HallieShellCLI.selectRecord(matchingFilename: "1994.mov", in: records)?.id == exact.id)
        // The old substring rule still serves corpus fragments.
        #expect(HallieShellCLI.selectRecord(matchingFilename: "xmas", in: records)?.id == first.id)
        #expect(HallieShellCLI.selectRecord(matchingFilename: "part 2", in: records)?.id == first.id)
    }

    // MARK: - Memo staleness (codex #976 item 1)

    /// A record renamed in place between two resolves, with NOTHING
    /// bumping the version: the old name must not resolve any more and the
    /// new one must — the memo's hit is revalidated against the live row.
    @Test func memoNeverAnswersForARenamedRecord() {
        let tape = record("/Volumes/A/Old Name.mov")
        let other = record("/Volumes/A/Other.mov")
        let records = [tape, other]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 2, revision: 7)

        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "Old Name.mov", in: records, index: index, version: version)) == tape.id)
        #expect(index.rebuildCount == 1)

        // Rename in place (what VideoScanModel+Rename does), same version.
        tape.filename = "New Name.mov"
        tape.fullPath = "/Volumes/A/New Name.mov"

        let stale = ArchivistRecordReferenceResolver.resolve(
            file: "Old Name.mov", in: records, index: index, version: version)
        #expect(isNotFound(stale, name: "Old Name.mov"), "the old name must not resolve after a rename, got \(stale)")
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "New Name.mov", in: records, index: index, version: version)) == tape.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "New Name", in: records, index: index, version: version)) == tape.id)
        // The stale hit rebuilt the table once; the later hits used it.
        #expect(index.rebuildCount == 2)
    }

    /// `records` replaced by a same-count array (a rescan commit) at the
    /// same version: an old filename must not resolve to the unrelated
    /// row now sitting at its index, and the new rows must resolve.
    @Test func memoNeverAnswersForAReplacedRecordsArray() {
        let first = [record("/Volumes/A/alpha.mov"), record("/Volumes/A/beta.mov")]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 2, revision: 3)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "alpha.mov", in: first, index: index, version: version)) == first[0].id)

        // Same count, same revision, different rows — "alpha" now lives at
        // index 1 and index 0 is an unrelated file.
        let second = [record("/Volumes/A/gamma.mov"), record("/Volumes/A/alpha.mov")]
        let hit = ArchivistRecordReferenceResolver.resolve(
            file: "alpha.mov", in: second, index: index, version: version)
        #expect(resolvedID(hit) == second[1].id, "alpha must be the NEW alpha row, got \(hit)")
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "gamma.mov", in: second, index: index, version: version)) == second[0].id)
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(
            file: "beta.mov", in: second, index: index, version: version), name: "beta.mov"))
        // A replacement row at the same index (a job's `records[i] = new`)
        // with the same buffer: still never the stale row.
        var third = second
        third[1] = record("/Volumes/A/delta.mov")
        let replaced = ArchivistRecordReferenceResolver.resolve(
            file: "alpha.mov", in: third, index: index, version: version)
        #expect(isNotFound(replaced, name: "alpha.mov"), "a replaced row must not answer for its predecessor, got \(replaced)")
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "delta.mov", in: third, index: index, version: version)) == third[1].id)
    }

    /// A purge between resolves is a stale hit too (purged rows never
    /// match); an ambiguity gains and loses members with the live rows.
    @Test func memoRevalidatesPurgesAndAmbiguityMembership() {
        let a = record("/Volumes/A/tape.mov")
        let b = record("/Volumes/B/tape.mov")
        let records = [a, b]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 2, revision: 1)
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            file: "tape.mov", in: records, index: index, version: version)) == 2)
        b.purgedAt = Date()
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "tape.mov", in: records, index: index, version: version)) == a.id)
        #expect(index.rebuildCount == 2)
        // Restored (the model bumps the revision for that): both again.
        b.purgedAt = nil
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            file: "tape.mov", in: records, index: index, version: RecordsVersion(count: 2, revision: 2))) == 2)
        #expect(index.rebuildCount == 3)
    }

    // MARK: - Scale

    /// 100k records: fifty named-file lookups through the memo do ONE table
    /// build and stay under budget; the linear form (the shell) is budgeted
    /// per call. The token tier is the worst case (a miss on every exact
    /// tier), so it is the one timed here — and a memo MISS runs the same
    /// linear tiers, so it is timed through the memo too.
    @Test func oneHundredThousandRecordsResolveWithinBudgetAndRebuildOnce() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for index in 0..<100_000 {
            records.append(record("/Volumes/Scale/vol\(index % 7)/clip_\(index).mov"))
        }
        let target = records[73_421]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: records.count, revision: 1)

        let started = ContinuousClock.now
        for _ in 0..<50 {
            let hit = ArchivistRecordReferenceResolver.resolve(
                file: "clip_73421.mov", in: records, index: index, version: version)
            #expect(resolvedID(hit) == target.id)
        }
        let elapsed = ContinuousClock.now - started
        #expect(index.rebuildCount == 1)
        #expect(elapsed < .seconds(2), "50 memoised lookups over 100k records took \(elapsed)")

        let linearStart = ContinuousClock.now
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "clip_73421.mov", in: records)) == target.id)
        // A miss on every exact tier: the token scan over all filenames.
        let tokenHit = ArchivistRecordReferenceResolver.resolve(file: "clip 73421", in: records)
        #expect(resolvedID(tokenHit) == target.id)
        let linear = ContinuousClock.now - linearStart
        #expect(linear < .seconds(2), "two linear resolutions over 100k records took \(linear)")

        // The same miss through the memo: the linear tiers, no rebuild.
        let memoMissStart = ContinuousClock.now
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "clip 73421", in: records, index: index, version: version)) == target.id)
        let memoMiss = ContinuousClock.now - memoMissStart
        #expect(index.rebuildCount == 1)
        #expect(memoMiss < .seconds(1), "a memo miss over 100k records took \(memoMiss)")

        // A new version rebuilds once more; the same version never does.
        _ = ArchivistRecordReferenceResolver.resolve(
            file: "clip_1.mov", in: records, index: index, version: RecordsVersion(count: records.count, revision: 2))
        #expect(index.rebuildCount == 2)
    }
}
