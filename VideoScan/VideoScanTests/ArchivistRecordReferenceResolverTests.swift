import Foundation
import Testing
@testable import VideoScan

/// Which record a named file means (2026-09-02): exact beats near, case
/// does not matter, a real tie is a which-one, and the whole thing stays
/// within budget over a 100k-record catalog.
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
        if case .ambiguous(let list) = resolution { return list.map(\.filename) }
        return nil
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
        #expect(candidates(ArchivistRecordReferenceResolver.resolve(file: "Hampshire", in: records))?.count == 3)
    }

    @Test func fullPathIsExactFirstThenCaseInsensitive() {
        let a = record("/Volumes/A/tape.mov")
        let b = record("/Volumes/B/tape.mov")
        let records = [a, b]
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/Volumes/B/tape.mov", in: records)) == b.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/volumes/b/TAPE.MOV", in: records)) == b.id)
        // Same filename on two volumes, no path typed → which-one, both listed.
        #expect(candidates(ArchivistRecordReferenceResolver.resolve(file: "tape.mov", in: records)) == ["tape.mov", "tape.mov"])
        // A path nobody has falls back to the filename tiers.
        #expect(candidates(ArchivistRecordReferenceResolver.resolve(file: "/Volumes/C/tape.mov", in: records))?.count == 2)
    }

    @Test func stemMatchesAcrossContainersAndAmbiguityIsCappedAtFive() {
        let mov = record("/Volumes/A/Christmas.mov")
        let mkv = record("/Volumes/A/Christmas.mkv")
        let others = (1...7).map { record("/Volumes/A/Christmas_199\($0).mkv") }
        let records = [mov, mkv] + others

        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "Christmas.mkv", in: records)) == mkv.id)
        // "Christmas" as a stem: two exact stems → which-one of those two only.
        #expect(candidates(ArchivistRecordReferenceResolver.resolve(file: "Christmas", in: records)) == ["Christmas.mov", "Christmas.mkv"])
        // A token shared by nine files: capped.
        let capped = ArchivistRecordReferenceResolver.resolve(file: "Christmas_199", in: records)
        if case .notFound = capped {} else { Issue.record("tokens '199' are not whole tokens of any filename? got \(capped)") }
        let token = ArchivistRecordReferenceResolver.resolve(file: "Christmas 1991", in: records)
        #expect(resolvedID(token) == others[0].id)
    }

    @Test func purgedRecordsNeverMatchAndNothingIsNotFound() {
        let live = record("/Volumes/A/live.mov")
        let purged = record("/Volumes/A/purged.mov")
        purged.purgedAt = Date()
        let records = [live, purged]
        if case .notFound(let name) = ArchivistRecordReferenceResolver.resolve(file: "purged.mov", in: records) {
            #expect(name == "purged.mov")
        } else {
            Issue.record("a purged record must not resolve")
        }
        if case .notFound = ArchivistRecordReferenceResolver.resolve(file: "nothing like this.mov", in: records) {} else {
            Issue.record("expected notFound")
        }
        if case .notFound = ArchivistRecordReferenceResolver.resolve(file: "   ", in: records) {} else {
            Issue.record("blank is notFound")
        }
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

    // MARK: - Scale

    /// 100k records: fifty named-file lookups through the memo do ONE table
    /// build and stay under budget; the linear form (the shell) is budgeted
    /// per call. The token tier is the worst case (a miss on every exact
    /// tier), so it is the one timed here.
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

        // A new version rebuilds once more; the same version never does.
        _ = ArchivistRecordReferenceResolver.resolve(
            file: "clip_1.mov", in: records, index: index, version: RecordsVersion(count: records.count, revision: 2))
        #expect(index.rebuildCount == 2)
    }
}
