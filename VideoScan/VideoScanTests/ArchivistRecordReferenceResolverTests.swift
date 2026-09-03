import Foundation
import Testing
@testable import VideoScan

/// Which record a named file means (2026-09-02): exact beats near, case
/// does not matter, a real tie is a which-one with its true count, an
/// explicit path is exact or nothing, the memo never answers for a
/// renamed or replaced row (codex #976) and is COMPLETE after a same-buffer
/// rename that creates a tie (codex #987 item 1), a long run of words is
/// settled against the catalog by its word-suffixes (codex #987 item 3),
/// "this video" lets the selection break a tie (item 5), and the whole
/// thing stays within budget over a 100k-record catalog.
///
/// `VideoRecord.identityGeneration` is process-wide, so tests that assert
/// an EXACT rebuild count pin the index to a frozen generation (which is
/// also what exercises the per-hit revalidation path on its own); the one
/// test of the generation key itself asserts behaviour and a lower bound.
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

    /// An index whose generation never moves: only the version, the
    /// storage identity and per-hit revalidation can rebuild it.
    private func frozenIndex() -> ArchivistRecordReferenceIndex {
        ArchivistRecordReferenceIndex(identityGeneration: { 0 })
    }

    private func resolvedID(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> UUID? {
        if case .resolved(let record) = resolution { return record.id }
        return nil
    }

    private func candidates(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> [String]? {
        if case .ambiguous(let list, _) = resolution { return list.map(\.filename) }
        return nil
    }

    private func candidateIDs(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> [UUID]? {
        if case .ambiguous(let list, _) = resolution { return list.map(\.id) }
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

    /// A path whose folders read like a sentence is still one exact path
    /// (codex #987 item 3): the resolver never splits it.
    @Test func aPathWithSentenceWordsInItsFoldersIsOneExactPath() {
        let tape = record("/Volumes/A/Who is This/tape.mov")
        let other = record("/Volumes/A/This/tape.mov")
        let records = [tape, other]
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/Volumes/A/Who is This/tape.mov", in: records)) == tape.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/volumes/a/who is this/TAPE.mov", in: records)) == tape.id)
        let index = ArchivistRecordReferenceIndex()
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "/Volumes/A/Who is This/tape.mov", in: records, index: index,
            version: RecordsVersion(count: 2, revision: 1))) == tape.id)
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

    // MARK: - Catalog-verified extraction (codex #987 item 3)

    @Test func nameCandidatesAreTheWordSuffixesLongestFirst() {
        #expect(ArchivistRecordReferenceResolver.nameCandidates("the christmas tape.mov")
                == ["the christmas tape.mov", "christmas tape.mov", "tape.mov"])
        #expect(ArchivistRecordReferenceResolver.nameCandidates("tape.mov") == ["tape.mov"])
        #expect(ArchivistRecordReferenceResolver.nameCandidates("New Hampshire") == ["New Hampshire", "Hampshire"])
        // Capped: an eight-word run tries six candidates.
        let long = ArchivistRecordReferenceResolver.nameCandidates("a b c d e f g h.mov")
        #expect(long.count == ArchivistRecordReferenceResolver.maxNameCandidates)
        #expect(long.first == "a b c d e f g h.mov")
        #expect(long.last == "f g h.mov")
    }

    /// The longest run wins when it IS a file; a run that swallowed a
    /// sentence word settles to the first shorter suffix the catalog has,
    /// in both the linear and the memo form.
    @Test func aLongRunSettlesToTheFirstSuffixTheCatalogHas() {
        let rickAndDonna = record("/Volumes/A/rick and donna.mov")
        let donna = record("/Volumes/A/donna.mov")
        let christmasTape = record("/Volumes/A/christmas tape.mov")
        let records = [rickAndDonna, donna, christmasTape]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: records.count, revision: 1)

        for (typed, expected) in [
            ("rick and donna.mov", rickAndDonna),          // the whole run is the file
            ("and donna.mov", donna),                       // no such file; "donna.mov" is
            ("the christmas tape.mov", christmasTape),      // a swallowed "the"
            ("examine christmas tape.mov", christmasTape),  // a swallowed verb
            ("Christmas Tape", christmasTape),              // stem, then suffix stems
        ] as [(String, VideoRecord)] {
            #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: typed, in: records)) == expected.id,
                    Comment(rawValue: "linear: \(typed)"))
            #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
                file: typed, in: records, index: index, version: version)) == expected.id,
                    Comment(rawValue: "memo: \(typed)"))
        }
        // Nothing fits any suffix: not found, reported by the LONGEST run.
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(file: "nothing like it.mov", in: records), name: "nothing like it.mov"))
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(
            file: "nothing like it.mov", in: records, index: index, version: version), name: "nothing like it.mov"))
        // The stem tier of a shorter suffix beats the token tier of the
        // whole run: "donna" is the stem of donna.mov even though "rick and
        // donna.mov" carries every token of "and donna".
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "and donna", in: records)) == donna.id)
        // A suffix is NEVER token-matched: "old name.mov" reaches nothing
        // through its tail "name.mov" (the memo rename test relies on it).
        let newName = record("/Volumes/A/New Name.mov")
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(file: "old name.mov", in: records + [newName]), name: "old name.mov"))
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(
            file: "old name.mov", in: records + [newName], index: ArchivistRecordReferenceIndex(),
            version: RecordsVersion(count: 4, revision: 9)), name: "old name.mov"))
        // Ambiguity on a suffix stays honest.
        let secondDonna = record("/Volumes/B/donna.mov")
        let tie = ArchivistRecordReferenceResolver.resolve(file: "and donna.mov", in: records + [secondDonna])
        #expect(candidateIDs(tie) == [donna.id, secondDonna.id])
        #expect(ambiguousTotal(tie) == 2)
    }

    // MARK: - Deictic tie-break (codex #987 item 5)

    /// Same-named files on two volumes are a which-one — unless the
    /// question said "this video" (deictic) AND the selected row is one
    /// of them; a selection outside the tie, or no selection, changes nothing.
    @Test func thisVideoLetsTheSelectionBreakATieOnlyWhenItIsOneOfTheCandidates() {
        let a = record("/Volumes/A/New Hampshire.mov")
        let b = record("/Volumes/B/New Hampshire.mov")
        let other = record("/Volumes/B/Other.mov")
        let records = [a, b, other]
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        let reference = ArchivistQueryAST.Record.Reference.file(name: "New Hampshire.mov")

        // Not deictic: honest ambiguity even with b selected.
        let plain = ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: b.id, records: records, recordForID: { byID[$0] })
        #expect(candidateIDs(plain) == [a.id, b.id])
        #expect(ambiguousTotal(plain) == 2)
        // Deictic and b selected: b.
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: b.id, records: records, recordForID: { byID[$0] }, deictic: true)) == b.id)
        // Deictic and a selected: a.
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: a.id, records: records, recordForID: { byID[$0] }, deictic: true)) == a.id)
        // Deictic but the selection is not in the tie: still a which-one.
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: other.id, records: records, recordForID: { byID[$0] }, deictic: true)) == 2)
        // Deictic with nothing selected: still a which-one.
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: nil, records: records, recordForID: { byID[$0] }, deictic: true)) == 2)
        // A single hit never consults the selection.
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            .file(name: "Other.mov"), selectedRecordID: a.id, records: records, recordForID: { byID[$0] }, deictic: true)) == other.id)

        // The memo form, same rules.
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 3, revision: 1)
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: b.id, records: records, recordForID: { byID[$0] },
            index: index, version: version)) == 2)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: b.id, records: records, recordForID: { byID[$0] },
            index: index, version: version, deictic: true)) == b.id)
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            reference, selectedRecordID: other.id, records: records, recordForID: { byID[$0] },
            index: index, version: version, deictic: true)) == 2)
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

    // MARK: - Memo staleness (codex #976 item 1) — frozen generation

    /// A record renamed in place between two resolves, with NOTHING
    /// bumping the version and the generation pinned: the old name must
    /// not resolve any more and the new one must — the memo's hit is
    /// revalidated against the live row.
    @Test func memoNeverAnswersForARenamedRecord() {
        let tape = record("/Volumes/A/Old Name.mov")
        let other = record("/Volumes/A/Other.mov")
        let records = [tape, other]
        let index = frozenIndex()
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
        let index = frozenIndex()
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
    }

    /// A replacement row at the same index (a job's `records[i] = new`)
    /// in the SAME buffer, same version, generation pinned: the cached
    /// "alpha.mov" bucket is a real hit whose entry now points at delta —
    /// revalidation must refuse it and rebuild. The array is mutated in
    /// place through its only reference, and the buffer address is checked
    /// so the test cannot pass by a copy-on-write replacement (codex #987
    /// item 1 on the previous form of this test).
    @Test func memoRevalidatesAReplacedRowInTheSameBuffer() {
        var records = [record("/Volumes/A/gamma.mov"), record("/Volumes/A/alpha.mov")]
        let index = frozenIndex()
        let version = RecordsVersion(count: 2, revision: 3)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "alpha.mov", in: records, index: index, version: version)) == records[1].id)
        #expect(index.rebuildCount == 1)

        let storageBefore = ArchivistRecordReferenceIndex.storageIdentity(of: records)
        let delta = record("/Volumes/A/delta.mov")
        records[1] = delta
        #expect(ArchivistRecordReferenceIndex.storageIdentity(of: records) == storageBefore,
                "the in-place write must keep the buffer (no copy-on-write)")

        let replaced = ArchivistRecordReferenceResolver.resolve(
            file: "alpha.mov", in: records, index: index, version: version)
        #expect(isNotFound(replaced, name: "alpha.mov"), "a replaced row must not answer for its predecessor, got \(replaced)")
        #expect(index.rebuildCount == 2, "the stale bucket hit must have rebuilt the table once")
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "delta.mov", in: records, index: index, version: version)) == delta.id)
        #expect(index.rebuildCount == 2)
    }

    /// A purge between resolves is a stale hit too (purged rows never
    /// match); an ambiguity gains and loses members with the live rows.
    @Test func memoRevalidatesPurgesAndAmbiguityMembership() {
        let a = record("/Volumes/A/tape.mov")
        let b = record("/Volumes/B/tape.mov")
        let records = [a, b]
        let index = frozenIndex()
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

    // MARK: - Memo completeness (codex #987 item 1) — live generation

    /// [foo, bar] → [foo, foo] in the SAME buffer at the SAME version: the
    /// cached "foo" bucket holds only the first foo and every entry in it
    /// still validates, so revalidation alone would resolve the first foo.
    /// The identity generation (bumped by bar's rename) invalidates the
    /// table before the bucket is read, and the answer is the which-one
    /// it should be. Behaviour and a LOWER bound on rebuilds are asserted:
    /// the generation is process-wide and other suites may bump it.
    @Test func aSameBufferRenameThatCreatesATieIsAWhichOne() {
        let foo = record("/Volumes/A/foo.mov")
        let bar = record("/Volumes/B/bar.mov")
        let records = [foo, bar]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 2, revision: 5)
        let storageBefore = ArchivistRecordReferenceIndex.storageIdentity(of: records)

        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "foo.mov", in: records, index: index, version: version)) == foo.id)
        let rebuildsBefore = index.rebuildCount

        bar.filename = "foo.mov"
        bar.fullPath = "/Volumes/B/foo.mov"
        #expect(ArchivistRecordReferenceIndex.storageIdentity(of: records) == storageBefore)

        let tie = ArchivistRecordReferenceResolver.resolve(
            file: "foo.mov", in: records, index: index, version: version)
        #expect(candidateIDs(tie) == [foo.id, bar.id], "the second foo must be seen, got \(tie)")
        #expect(ambiguousTotal(tie) == 2)
        #expect(index.rebuildCount > rebuildsBefore, "the generation key must have rebuilt the table")
        // The stem table too: "foo" is now two files.
        #expect(ambiguousTotal(ArchivistRecordReferenceResolver.resolve(
            file: "foo", in: records, index: index, version: version)) == 2)
        // And back: renaming bar away makes foo unique again, same buffer,
        // same version.
        bar.filename = "bar.mov"
        bar.fullPath = "/Volumes/B/bar.mov"
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "foo.mov", in: records, index: index, version: version)) == foo.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "bar.mov", in: records, index: index, version: version)) == bar.id)
    }

    // MARK: - Scale

    /// 100k records: fifty named-file lookups through the memo do ONE table
    /// build and stay under budget; the linear form (the shell) is budgeted
    /// per call. The token tier is the worst case (a miss on every exact
    /// tier), so it is the one timed here — and a memo MISS runs the same
    /// linear tiers, so it is timed through the memo too. The generation is
    /// pinned so a parallel suite constructing records cannot add rebuilds
    /// to the count; the multi-word name exercises the suffix candidates.
    @Test func oneHundredThousandRecordsResolveWithinBudgetAndRebuildOnce() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for index in 0..<100_000 {
            records.append(record("/Volumes/Scale/vol\(index % 7)/clip_\(index).mov"))
        }
        let target = records[73_421]
        let index = frozenIndex()
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
        // A miss on every exact tier: the token scan over all filenames,
        // for a two-word name (two suffix candidates).
        let tokenHit = ArchivistRecordReferenceResolver.resolve(file: "clip 73421", in: records)
        #expect(resolvedID(tokenHit) == target.id)
        let linear = ContinuousClock.now - linearStart
        #expect(linear < .seconds(2), "two linear resolutions over 100k records took \(linear)")

        // The same miss through the memo: the linear tiers, no rebuild —
        // and a five-word run (five suffix candidates on the exact tiers,
        // then the token tier for the whole run only) that fits nothing.
        let memoMissStart = ContinuousClock.now
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "clip 73421", in: records, index: index, version: version)) == target.id)
        #expect(isNotFound(ArchivistRecordReferenceResolver.resolve(
            file: "the one called clip 73421", in: records, index: index, version: version),
            name: "the one called clip 73421"))
        let memoMiss = ContinuousClock.now - memoMissStart
        #expect(index.rebuildCount == 1)
        #expect(memoMiss < .seconds(2), "two memo misses over 100k records took \(memoMiss)")

        // A new version rebuilds once more; the same version never does.
        _ = ArchivistRecordReferenceResolver.resolve(
            file: "clip_1.mov", in: records, index: index, version: RecordsVersion(count: records.count, revision: 2))
        #expect(index.rebuildCount == 2)
    }
}
