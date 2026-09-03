import Foundation
import Testing
@testable import VideoScan

/// Which record a named file means (2026-09-02): exact beats near, case
/// does not matter, a real tie is a which-one with its true count, an
/// explicit path is exact or nothing (and its fold keeps diacritics —
/// codex #1020 item 4), the memo never answers for a renamed or replaced
/// row (codex #976) and is COMPLETE after a same-buffer rename that
/// creates a tie (codex #987 item 1) or a same-buffer row replacement by
/// a prebuilt record (codex #1020 item 1, through the model's didSet), a
/// typed name is NEVER trimmed to fit — a miss OFFERS the tail files by
/// their own names (codex #1020 item 2), "this video" lets the selection
/// break a tie (codex #987 item 5), and the whole thing stays within
/// budget over a 100k-record catalog.
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
        if case .notFound(let found, _, _) = resolution { return name == nil || found == name }
        return false
    }

    /// The did-you-mean ids and total of a miss; nil for anything else.
    private func similar(_ resolution: ArchivistRecordReferenceResolver.Resolution) -> (ids: [UUID], total: Int)? {
        if case .notFound(_, let list, let total) = resolution { return (list.map(\.id), total) }
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

    /// codex #1020 item 4 (verbatim: "explicit-path fallback uses
    /// normalizedPhrase, which strips diacritics, so requested /A/Café.mov
    /// can silently resolve /A/Cafe.mov"): the path fold is canonical
    /// Unicode normalisation plus case folding ONLY. The accented and the
    /// plain spelling are two different files; a request for the one the
    /// catalog lacks is pathNotFound by the TYPED path, and the other may
    /// be offered — by its own exact name. Composition (NFC vs NFD) and
    /// case never matter.
    @Test func pathFallbackFoldsCaseAndCompositionButKeepsDiacritics() {
        let plain = record("/A/Cafe.mov")
        let other = record("/A/Other.mov")
        let records = [plain, other]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: 2, revision: 1)
        let decomposedCafe = "/A/Cafe\u{0301}.mov"   // e + combining acute = "Café" in NFD

        for (typed, catalog) in [("/A/Café.mov", records), (decomposedCafe, records), ("/A/CAFÉ.MOV", records)] {
            for resolution in [
                ArchivistRecordReferenceResolver.resolve(file: typed, in: catalog),
                ArchivistRecordReferenceResolver.resolve(file: typed, in: catalog, index: index, version: version),
            ] {
                guard case .pathNotFound(let path, let sameName, let total) = resolution else {
                    Issue.record("\(typed) must not resolve /A/Cafe.mov, got \(resolution)"); return
                }
                #expect(path == typed, "the miss names the path as typed")
                // The plain file may be OFFERED — labelled by its own name.
                #expect(sameName.map(\.filename) == ["Cafe.mov"], Comment(rawValue: typed))
                #expect(total == 1)
            }
        }
        // And the mirror image: the catalog holds the accented name (in
        // NFD, as an HFS+ volume would hand it back); the plain request
        // misses, the accented one hits in every case and composition.
        let accented = record(decomposedCafe)
        let mirror = [accented, other]
        let mirrorIndex = ArchivistRecordReferenceIndex()
        #expect({ if case .pathNotFound = ArchivistRecordReferenceResolver.resolve(file: "/A/Cafe.mov", in: mirror) { return true }; return false }())
        #expect({ if case .pathNotFound = ArchivistRecordReferenceResolver.resolve(
            file: "/A/cafe.mov", in: mirror, index: mirrorIndex, version: version) { return true }; return false }())
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/A/Café.mov", in: mirror)) == accented.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(file: "/a/CAFÉ.mov", in: mirror)) == accented.id)
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "/A/Café.mov", in: mirror, index: mirrorIndex, version: version)) == accented.id)
        // The key itself, pinned.
        #expect(ArchivistRecordReferenceResolver.pathKey("/A/CAFÉ.MOV") == ArchivistRecordReferenceResolver.pathKey(decomposedCafe))
        #expect(ArchivistRecordReferenceResolver.pathKey("/A/Café.mov") != ArchivistRecordReferenceResolver.pathKey("/A/Cafe.mov"))
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

    // MARK: - A name is never trimmed (codex #1020 item 2)

    @Test func similarSuffixesAreTheShorterWordSuffixesLongestFirst() {
        #expect(ArchivistRecordReferenceResolver.similarSuffixes(of: "the christmas tape.mov")
                == ["christmas tape.mov", "tape.mov"])
        #expect(ArchivistRecordReferenceResolver.similarSuffixes(of: "tape.mov") == [])
        #expect(ArchivistRecordReferenceResolver.similarSuffixes(of: "New Hampshire") == ["Hampshire"])
        // Capped: an eight-word run probes five tails.
        let long = ArchivistRecordReferenceResolver.similarSuffixes(of: "a b c d e f g h.mov")
        #expect(long.count == ArchivistRecordReferenceResolver.maxSimilarSuffixes)
        #expect(long.first == "b c d e f g h.mov")
        #expect(long.last == "f g h.mov")
    }

    /// codex #1020 item 2 (verbatim: "'who is in Unknown Tape.mov'
    /// silently resolves existing Tape.mov instead of notFound"): the
    /// typed name is the name. A run the catalog has resolves; a run it
    /// lacks is NOT FOUND by that name even when a shorter tail of it is a
    /// file — the tail files travel with the miss as did-you-mean
    /// candidates under their own names, longest tail first, exact before
    /// stem, with the true count. Linear and memo forms agree.
    @Test func aNameIsNeverTrimmedToFitAndAMissOffersTheTailFilesByName() {
        let rickAndDonna = record("/Volumes/A/rick and donna.mov")
        let donna = record("/Volumes/A/donna.mov")
        let christmasTape = record("/Volumes/A/christmas tape.mov")
        let tape = record("/Volumes/A/Tape.mov")
        let records = [rickAndDonna, donna, christmasTape, tape]
        let index = ArchivistRecordReferenceIndex()
        let version = RecordsVersion(count: records.count, revision: 1)
        func both(_ typed: String) -> [(String, ArchivistRecordReferenceResolver.Resolution)] {
            [("linear", ArchivistRecordReferenceResolver.resolve(file: typed, in: records)),
             ("memo", ArchivistRecordReferenceResolver.resolve(file: typed, in: records, index: index, version: version))]
        }

        // The whole run is the file.
        for (form, hit) in both("rick and donna.mov") {
            #expect(resolvedID(hit) == rickAndDonna.id, Comment(rawValue: form))
        }
        // The codex sentence: nothing is called "Unknown Tape.mov"; Tape.mov
        // is offered, never substituted.
        for (form, miss) in both("Unknown Tape.mov") {
            #expect(isNotFound(miss, name: "Unknown Tape.mov"), Comment(rawValue: "\(form): \(miss)"))
            #expect(similar(miss)?.ids == [tape.id], Comment(rawValue: form))
            #expect(similar(miss)?.total == 1, Comment(rawValue: form))
        }
        // A swallowed sentence word: "the christmas tape.mov" is not
        // "christmas tape.mov"; that file is the did-you-mean.
        for (form, miss) in both("the christmas tape.mov") {
            #expect(isNotFound(miss, name: "the christmas tape.mov"), Comment(rawValue: "\(form): \(miss)"))
            #expect(similar(miss)?.ids == [christmasTape.id], Comment(rawValue: form))
        }
        // The stem form of a tail counts too: no file is "the Christmas
        // Tape" in any tier, and the longest tail "Christmas Tape" is the
        // stem of christmas tape.mov — offered, and Tape.mov (the shorter
        // tail) is not, because the longest fitting tail wins.
        for (form, miss) in both("the Christmas Tape") {
            #expect(isNotFound(miss, name: "the Christmas Tape"), Comment(rawValue: "\(form): \(miss)"))
            #expect(similar(miss)?.ids == [christmasTape.id], Comment(rawValue: form))
        }
        // The token tier is unchanged and applies to the WHOLE name only:
        // "and donna" is every token of "rick and donna.mov" (tier 4), so
        // that is a real hit, not a trim.
        for (form, hit) in both("and donna.mov") {
            #expect(resolvedID(hit) == rickAndDonna.id, Comment(rawValue: form))
        }
        // Nothing fits any tail: not found, no offers.
        for (form, miss) in both("nothing like it.mov") {
            #expect(isNotFound(miss, name: "nothing like it.mov"), Comment(rawValue: form))
            #expect(similar(miss)?.ids == [], Comment(rawValue: form))
            #expect(similar(miss)?.total == 0, Comment(rawValue: form))
        }
        // A tail is NEVER token-matched: "old name.mov" reaches nothing
        // through "name.mov" (the memo rename test relies on it).
        let newName = record("/Volumes/A/New Name.mov")
        for resolution in [
            ArchivistRecordReferenceResolver.resolve(file: "old name.mov", in: records + [newName]),
            ArchivistRecordReferenceResolver.resolve(
                file: "old name.mov", in: records + [newName], index: ArchivistRecordReferenceIndex(),
                version: RecordsVersion(count: 5, revision: 9)),
        ] {
            #expect(isNotFound(resolution, name: "old name.mov"))
            #expect(similar(resolution)?.total == 0)
        }
        // Two files fit the tail: both offered, true count kept.
        let secondTape = record("/Volumes/B/Tape.mov")
        let widened = records + [secondTape]
        let miss = ArchivistRecordReferenceResolver.resolve(file: "Unknown Tape.mov", in: widened)
        #expect(isNotFound(miss, name: "Unknown Tape.mov"))
        #expect(similar(miss)?.ids == [tape.id, secondTape.id])
        #expect(similar(miss)?.total == 2)
        let memoMiss = ArchivistRecordReferenceResolver.resolve(
            file: "Unknown Tape.mov", in: widened, index: ArchivistRecordReferenceIndex(),
            version: RecordsVersion(count: widened.count, revision: 1))
        #expect(similar(memoMiss)?.ids == [tape.id, secondTape.id])
        #expect(similar(memoMiss)?.total == 2)
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
        // A purged file is not a did-you-mean either.
        #expect(similar(ArchivistRecordReferenceResolver.resolve(file: "the purged.mov", in: records))?.total == 0)
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

    // MARK: - Memo completeness (codex #1020 item 1) — the model's didSet

    /// codex #1020 item 1 (verbatim: "identityGeneration only bumps field
    /// observers; decoded/prebuilt record assignment does not …
    /// VideoScanModel.records didSet invalidates recordIndex/pathIndex but
    /// not hallieRecordIndex. After index [foo,bar], replace element with
    /// prebuilt/decoded newFoo under same storage/version: old foo bucket
    /// fully validates and returns unique, missing newFoo").
    ///
    /// Through the MODEL, with its own memo and version: the replacement
    /// records are built BEFORE the table (no identity write afterwards),
    /// the element write is in place (same count, same revision), and the
    /// only signal is `records`' didSet. Element 0 replaced by a prebuilt
    /// foo → the memo answers with the NEW record's id; element 1 replaced
    /// by a second prebuilt foo → a which-one of both, never "unique foo".
    @Test func theModelInvalidatesTheMemoWhenARowIsReplacedByAPrebuiltRecord() {
        let foo = record("/Volumes/A/foo.mov")
        let bar = record("/Volumes/B/bar.mov")
        let newFoo = record("/Volumes/C/foo.mov")       // prebuilt: no field write after this line
        let secondFoo = record("/Volumes/D/foo.mov")    // prebuilt
        let model = VideoScanModel()
        model.records = [foo, bar]
        func resolve(_ name: String) -> ArchivistRecordReferenceResolver.Resolution {
            ArchivistRecordReferenceResolver.resolve(
                file: name, in: model.records, index: model.hallieRecordIndex,
                version: RecordsVersion(count: model.records.count, revision: model.volumeAggregatesRevision))
        }
        #expect(resolvedID(resolve("foo.mov")) == foo.id)
        #expect(model.hallieRecordIndex.isBuilt)
        let revisionBefore = model.volumeAggregatesRevision

        // Element 0 → a prebuilt record of the same name: the memo is
        // dropped by the didSet, and the answer is the NEW record.
        model.records[0] = newFoo
        #expect(!model.hallieRecordIndex.isBuilt, "records' didSet must invalidate the Hallie memo")
        #expect(model.records.count == 2)
        #expect(model.volumeAggregatesRevision == revisionBefore, "the element write bumps no version")
        let replaced = resolve("foo.mov")
        #expect(resolvedID(replaced) == newFoo.id, "the memo must see the new record, got \(replaced)")
        #expect(model.hallieRecordIndex.isBuilt)

        // Element 1 → a second prebuilt foo: the "foo" bucket that held
        // only newFoo would validate in full and answer "unique"; the
        // didSet is what makes it a which-one.
        model.records[1] = secondFoo
        #expect(!model.hallieRecordIndex.isBuilt)
        let tie = resolve("foo.mov")
        #expect(candidateIDs(tie) == [newFoo.id, secondFoo.id], "the second foo must be seen, got \(tie)")
        #expect(ambiguousTotal(tie) == 2)
        // The stem table too.
        #expect(ambiguousTotal(resolve("foo")) == 2)
        // bar is gone with its row.
        #expect(isNotFound(resolve("bar.mov"), name: "bar.mov"))

        // A whole-array replacement at the same count is dropped the same way.
        let gamma = record("/Volumes/E/gamma.mov")
        model.records = [gamma, secondFoo]
        #expect(!model.hallieRecordIndex.isBuilt)
        #expect(resolvedID(resolve("foo.mov")) == secondFoo.id)
        #expect(resolvedID(resolve("gamma.mov")) == gamma.id)
    }

    // MARK: - Scale

    /// 100k records: fifty named-file lookups through the memo do ONE table
    /// build and stay under budget; the linear form (the shell) is budgeted
    /// per call. The token tier is the worst case (a miss on every exact
    /// tier), so it is the one timed here — and a memo MISS runs the same
    /// linear tiers, so it is timed through the memo too, with the
    /// did-you-mean probes of a multi-word miss on top. The generation is
    /// pinned so a parallel suite constructing records cannot add rebuilds
    /// to the count.
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
        // for a two-word name.
        let tokenHit = ArchivistRecordReferenceResolver.resolve(file: "clip 73421", in: records)
        #expect(resolvedID(tokenHit) == target.id)
        // A multi-word miss: the token tier AND the did-you-mean pass.
        let linearMiss = ArchivistRecordReferenceResolver.resolve(file: "the clip_73421.mov", in: records)
        #expect(isNotFound(linearMiss, name: "the clip_73421.mov"))
        #expect(similar(linearMiss)?.ids == [target.id])
        let linear = ContinuousClock.now - linearStart
        #expect(linear < .seconds(3), "three linear resolutions over 100k records took \(linear)")

        // The same misses through the memo: the linear token tier, no
        // rebuild; the did-you-mean probes are memo lookups — a five-word
        // run that fits nothing (and whose tails fit nothing) and a
        // two-word run whose tail is a file.
        let memoMissStart = ContinuousClock.now
        #expect(resolvedID(ArchivistRecordReferenceResolver.resolve(
            file: "clip 73421", in: records, index: index, version: version)) == target.id)
        let fiveWords = ArchivistRecordReferenceResolver.resolve(
            file: "the one called clip 73421", in: records, index: index, version: version)
        #expect(isNotFound(fiveWords, name: "the one called clip 73421"))
        #expect(similar(fiveWords)?.total == 0)
        let memoMiss = ArchivistRecordReferenceResolver.resolve(
            file: "the clip_73421.mov", in: records, index: index, version: version)
        #expect(isNotFound(memoMiss, name: "the clip_73421.mov"))
        #expect(similar(memoMiss)?.ids == [target.id])
        let memoMissElapsed = ContinuousClock.now - memoMissStart
        #expect(index.rebuildCount == 1)
        #expect(memoMissElapsed < .seconds(3), "three memo misses over 100k records took \(memoMissElapsed)")

        // A new version rebuilds once more; the same version never does.
        _ = ArchivistRecordReferenceResolver.resolve(
            file: "clip_1.mov", in: records, index: index, version: RecordsVersion(count: records.count, revision: 2))
        #expect(index.rebuildCount == 2)
    }
}
