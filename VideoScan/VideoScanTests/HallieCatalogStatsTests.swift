import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Catalog-wide numbers answered before translation (overnight cycle 2).
struct HallieCatalogStatsTests {

    @Test func typoForgivenessReachesVocabularyOnly() {
        #expect(HallieCatalogStats.detect("how mny videos are in the family catalog?") == .total)
        #expect(HallieCatalogStats.detect("how many are archved") == .archived)
        #expect(HallieCatalogStats.detect("how much disk spce") == .diskSpace)
        // A typo'd NAME must still fall through to a real search.
        #expect(HallieCatalogStats.detect("show me dona at the cape") == nil)
        #expect(HallieCatalogStats.detect("how many videos of dona") == nil)
        // Common names one edit from the closed vocabulary must remain
        // person-scoped searches, never whole-catalog totals.
        #expect(HallieCatalogStats.detect("how many videos of Mary") == nil)
        #expect(HallieCatalogStats.detect("how many files of Miles") == nil)
        #expect(HallieCatalogStats.detect("how many recordings of Carey") == nil)
    }

    // Eval ic006 (2026-09-01): "what do you know about our videos" fell
    // through to a presence search and declined for lack of a term.
    @Test func whatDoYouKnowAboutTheVideosIsTheOverview() {
        for text in ["what do you know about our videos", "What do you know about the archive?",
                     "what do you know about the collection", "what kind of videos do we have",
                     "what do you have in the catalog", "what's the overall picture of the archive",
                     "what do you know about the family videos"] {
            #expect(HallieCatalogStats.detect(text) == .overview, Comment(rawValue: text))
        }
        // A person, a place, a year, or a people question is not an overview.
        for text in ["what do you know about Donna", "what do you know about the family",
                     "what do you know about the Cape", "what videos do we have from 1994",
                     "what do you know", "who do you know"] {
            #expect(HallieCatalogStats.detect(text) == nil, Comment(rawValue: text))
        }
        // Every specific kind still wins over the overview (including the
        // pre-existing readings of "what's in the archive" and "what videos
        // do we have", which the closed vocabulary already claimed).
        #expect(HallieCatalogStats.detect("what's in the archive") == .archived)
        #expect(HallieCatalogStats.detect("what videos do we have") == .total)
        #expect(HallieCatalogStats.detect("how many videos do we have") == .total)
        #expect(HallieCatalogStats.detect("what years does the archive cover") == .years)
        #expect(HallieCatalogStats.detect("how many videos are archived") == .archived)
    }

    // Nightly reviewer, 2026-09-02: the guard counted verified + unverified
    // copies but the sentence reported only the verified ones, so two
    // unverified promotions read "0 have a verified copy".
    @Test func overviewNeverSaysZeroHaveAVerifiedCopy() {
        let unverifiedOnly = HallieCatalogStats.compute(records: [
            record("a.mov", bytes: 10, seconds: 60, year: 1994),
            record("b.mov", bytes: 10, seconds: 60, year: 1994, promoted: true),
            record("c.mov", bytes: 10, seconds: 60, year: 1994, promoted: true),
        ])
        let prose = HallieCatalogStats.answer(.overview, stats: unverifiedOnly).prose
        #expect(!prose.contains("0 have"), Comment(rawValue: prose))
        #expect(prose.contains("2 are promoted to the Master Archive but not yet verified"), Comment(rawValue: prose))

        let mixed = HallieCatalogStats.compute(records: [
            record("a.mov", bytes: 10, seconds: 60, year: 1994, fixity: true),
            record("b.mov", bytes: 10, seconds: 60, year: 1994, promoted: true),
        ])
        let mixedProse = HallieCatalogStats.answer(.overview, stats: mixed).prose
        #expect(mixedProse.contains("1 has a verified copy in the Master Archive, and 1 more is promoted but not yet verified."),
                Comment(rawValue: mixedProse))
    }

    @Test func overviewAnswersTheWholePictureThenInvitesAnAsk() {
        let stats = HallieCatalogStats.compute(records: [
            record("a.mov", bytes: 10, seconds: 3600, year: 1994),
            record("b.mov", bytes: 10, seconds: 3600, year: 2005),
            record("c.mov", bytes: 10, seconds: 60, year: 1994, fixity: true),
        ])
        let result = HallieCatalogStats.answer(.overview, stats: stats)
        #expect(result.route == .aggregate)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("There are 3 media files in the catalog across 1 volume"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("about 2.0 hours of footage"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("running from 1994 to 2005"), Comment(rawValue: result.prose))
        #expect(result.prose.contains("1 has a verified copy in the Master Archive"), Comment(rawValue: result.prose))
        #expect(result.prose.hasSuffix("Ask me for a person, a year, a place, or a word — “show me Donna in the 90s”."))
        #expect(result.queryDescription == "catalog-stats overview")
        #expect(HallieCatalogStats.answer(.overview, stats: HallieCatalogStats.compute(records: [])).prose
                == "The catalog is empty right now.")
    }

    @Test func promotedToArchivePhrasingDetects() {
        // Live miss 2026-08-24: "to" was outside the closed vocabulary and
        // the question became a 5,886-item generic search.
        #expect(HallieCatalogStats.detect("how many videos have been promoted to archive?") == .archived)
        #expect(HallieCatalogStats.detect("how many are reliably archived") == .archived)
        #expect(HallieCatalogStats.detect("how many have been promoted so far") == .archived)
        // A real search must still fall through.
        #expect(HallieCatalogStats.detect("show me videos promoted to archive in 1993") == nil)
        #expect(HallieCatalogStats.detect("donna going to the beach") == nil)
    }

    @Test func recognisesCatalogWideQuestionsAndNothingElse() {
        let cases: [(String, HallieCatalogStats.Question)] = [
            ("how many are archived", .archived),
            ("How many videos have been archived so far?", .archived),
            ("what percentage is archived", .archived),
            ("how many duplicates are there", .duplicates),
            ("how many duplicate files do we have?", .duplicates),
            ("How much disk space does the whole archive take up?", .diskSpace),
            ("how big is the catalog", .diskSpace),
            ("How much footage is there altogether?", .footage),
            ("how many hours of video do we have", .footage),
            ("how many years of footage do we have", .years),
            ("what years does the archive cover", .years),
            ("how many videos do we have", .total),
            ("How many files are in the catalog altogether?", .total),
        ]
        for (text, expected) in cases {
            #expect(HallieCatalogStats.detect(text) == expected, Comment(rawValue: text))
        }
        for text in ["how many videos of donna", "how many videos from 1995", "how many duplicates of this video",
                     "how many videos in westford", "how old is this tape", "show me the archive",
                     "how many videos have all four boys in them", "what's your source"] {
            #expect(HallieCatalogStats.detect(text) == nil, Comment(rawValue: text))
        }
    }

    private func record(_ name: String, bytes: Int64, seconds: Double, year: Int?,
                        fixity: Bool = false, promoted: Bool = false, md5: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/LaCie/\(name)"
        r.sizeBytes = bytes
        r.durationSeconds = seconds
        if let year {
            r.embeddedCreationDate = Calendar.current.date(from: DateComponents(year: year, month: 6, day: 1))
        }
        if let md5 { r.partialMD5 = md5 }
        if promoted { r.derivationKind = ArchivePromotion.derivationKind }
        if fixity {
            // Fixity only ever lands on a promoted archive COPY in production.
            r.derivationKind = ArchivePromotion.derivationKind
            r.archiveFixity = ArchiveFixity(digest: "abc", verifiedAt: Date(), sizeBytes: bytes)
        }
        return r
    }

    @Test func computesTheNumbersAndAnswersPlainly() {
        let records = [
            record("a.mov", bytes: 1_000_000_000, seconds: 3600, year: 1991, fixity: true),
            record("b.mov", bytes: 2_000_000_000, seconds: 1800, year: 2005),
            record("c.mov", bytes: 500_000_000, seconds: 600, year: nil),
        ]
        let stats = HallieCatalogStats.compute(records: records)
        #expect(stats.fileCount == 3)
        #expect(stats.archivedVerified == 1)
        #expect(stats.totalDurationSeconds == 6000)
        #expect(stats.earliestYear == 1991)
        #expect(stats.latestYear == 2005)

        #expect(HallieCatalogStats.answer(.years, stats: stats).prose
                == "The footage runs from 1991 to 2005 — about 15 years of the family's life. (Undated files aren't counted here.)")
        #expect(HallieCatalogStats.answer(.footage, stats: stats).prose.hasPrefix("About 1.7 hours of footage altogether, in 3 files"))
        let archived = HallieCatalogStats.answer(.archived, stats: stats)
        #expect(archived.prose.hasPrefix("1 file has a verified copy in the Master Archive — "))
        #expect(archived.route == .aggregate)
        #expect(archived.outcome == .answered)
        #expect(archived.answerPlan?.isComposable == false, "numbers are never re-phrased by the model")
        #expect(HallieCatalogStats.answer(.total, stats: stats).prose.hasPrefix("There are 3 media files in the catalog"))
        #expect(HallieCatalogStats.answer(.diskSpace, stats: stats).prose.hasPrefix("Everything in the catalog takes up"))
    }

    @Test func emptyCatalogAnswersHonestly() {
        let stats = HallieCatalogStats.compute(records: [])
        #expect(HallieCatalogStats.answer(.total, stats: stats).prose == "The catalog is empty right now.")
        #expect(HallieCatalogStats.answer(.years, stats: stats).prose.hasPrefix("I can't put years to the footage yet"))
        #expect(HallieCatalogStats.answer(.archived, stats: stats).prose.hasPrefix("Nothing has a verified copy"))
    }

    @Test func preTranslationAnswersLocallyOnlyWhenTheSnapshotIsSupplied() {
        let stats = HallieCatalogStats.compute(records: [record("a.mov", bytes: 10, seconds: 10, year: 1999)])
        let withStats = HallieTurnExecutor.preTranslation(
            question: "how many are archived", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false }, catalogStats: stats)
        guard case .answer(let result) = withStats else { Issue.record("should answer locally"); return }
        #expect(result.queryDescription == "catalog-stats archived")

        let without = HallieTurnExecutor.preTranslation(
            question: "how many are archived", playAfterAnswer: false,
            memory: .init(), isKnownPerson: { _ in false })
        guard case .translate = without else { Issue.record("without a snapshot it must fall through"); return }
    }

    // Live miss 2026-08-27 03:27Z: "how many items have been promoted to
    // archive master?" — "items" is .total's word, and outside .archived's
    // closed set the whole question fell through to a presence keyword
    // search that answered "one video file … DonnaRock&Piano.mov".
    @Test func archiveMasterPhrasingsAllReachTheArchivedCount() {
        let phrasings = [
            "how many items have been promoted to archive master?",
            "how many items have been promoted",
            "how many files are promoted",
            "how many videos are archived",
            "how many are in the master archive",
            "how many items are in the master archive?",
            "how many are on FamilyArchive",
            "what's archived",
            "whats archived so far",
            "how much is archived",
            "how much has been archived",
            "how many are not yet archived",
            "how many videos are still not archived",
            "how many items are left to promote",
            "how many are verified",
            "how many verified copies are there",
            "what percent of the total has been archived",
        ]
        for text in phrasings {
            #expect(HallieCatalogStats.detect(text) == .archived, Comment(rawValue: text))
        }
        // Content words still make it a real search, never a catalog total.
        for text in ["how many items of donna were promoted", "show me what was promoted in 1994",
                     "which items were promoted last week", "how many items have been promoted from westford"] {
            #expect(HallieCatalogStats.detect(text) == nil, Comment(rawValue: text))
        }
    }

    // SENSOR: the live question must be answered before translation — the
    // presence route only exists after `.translate`, so a local `.answer`
    // here is the proof it can never reach a keyword search again.
    @Test func liveArchiveMasterQuestionNeverReachesTranslation() {
        let stats = HallieCatalogStats.compute(records: [
            record("a.mov", bytes: 10, seconds: 10, year: 1999, fixity: true),
            record("b.mov", bytes: 10, seconds: 10, year: 2001),
        ])
        for text in ["how many items have been promoted to archive master?",
                     "how many are not yet archived", "how many verified"] {
            let outcome = HallieTurnExecutor.preTranslation(
                question: text, playAfterAnswer: false,
                memory: .init(), isKnownPerson: { _ in false }, catalogStats: stats)
            guard case .answer(let result) = outcome else {
                Issue.record("\(text) fell through to translation"); continue
            }
            #expect(result.route == .aggregate, Comment(rawValue: text))
            #expect(result.queryDescription == "catalog-stats archived", Comment(rawValue: text))
            #expect(result.prose == "1 file has a verified copy in the Master Archive — 50% of the 2 unique media files. 1 is still to be promoted.")
            #expect(result.basisLine.contains("catalog totals"))
        }
    }

    // SCALE: Hallie's number is the Archive tab's number — same predicate
    // as ArchivePromotionIndex.totals on a 100k synthetic model, including
    // the edge rows (fixity on a non-copy, purged copies) that would make
    // two hand-rolled counts drift apart.
    @Test @MainActor func archivedCountEqualsTheArchiveTabTotalsAtScale() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = record("f\(i).mov", bytes: 1_000_000, seconds: 60, year: 1980 + (i % 40))
            switch i % 1000 {
            case 0:      // verified promoted copy
                r.derivationKind = ArchivePromotion.derivationKind
                r.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: Date(), sizeBytes: 1_000_000)
            case 1:      // promoted but unverified
                r.derivationKind = ArchivePromotion.derivationKind
            case 2:      // purged copy — neither side counts it
                r.derivationKind = ArchivePromotion.derivationKind
                r.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: Date(), sizeBytes: 1_000_000)
                r.purgedAt = Date()
            case 3:      // stray fixity on a source — not an archive copy
                r.archiveFixity = ArchiveFixity(digest: "d", verifiedAt: Date(), sizeBytes: 1_000_000)
            default: break
            }
            records.append(r)
        }
        let index = ArchivePromotionIndex()
        let totals = index.totals(in: records, version: RecordsVersion(count: records.count, revision: 1))
        let start = Date()
        let stats = HallieCatalogStats.compute(records: records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(totals.verified == 100)
        #expect(totals.unverified == 100)
        #expect(stats.archivedVerified == totals.verified)
        #expect(stats.archivedUnverified == totals.unverified)
        let tab = ArchiveProgress.from(totals: totals, storage: CatalogStorageTotalsCalculator.compute(records: records))
        #expect(stats.archiveProgress.total == tab.total, "Hallie's arithmetic IS the Archive tab's")
        #expect(stats.archiveProgress.remaining == tab.remaining)
        #expect(stats.archiveProgress.percentText == tab.percentText)
        #expect(HallieCatalogStats.answer(.archived, stats: stats).prose.hasPrefix("200 files have been promoted to the Master Archive, of which 100 are verified"))
        #expect(elapsed < 3.0, "took \(elapsed)s")
    }

    // MARK: codex #717/#718 — promoted vs verified, and arithmetic that cannot pass 100%

    private func stats(verified: Int, unverified: Int, unique: Int) -> HallieCatalogStats {
        HallieCatalogStats(fileCount: unique, uniqueFileCount: unique, grossBytes: 0, uniqueBytes: 0,
                           duplicateFiles: 0, duplicateBytes: 0, volumeCount: 1,
                           archivedVerified: verified, archivedUnverified: unverified,
                           totalDurationSeconds: 0, earliestYear: nil, latestYear: nil)
    }

    @Test func promotedAndVerifiedAreBothAnsweredAndRemainingSubtractsBoth() {
        let both = HallieCatalogStats.answer(.archived, stats: stats(verified: 3, unverified: 2, unique: 10)).prose
        #expect(both == "5 files have been promoted to the Master Archive, of which 3 are verified — 30% of the 10 unique media files verified; 2 are copied but not yet verified. 5 are still to be promoted.", Comment(rawValue: both))
        // The old answer said "7 are still to be promoted" — it ignored the two unverified copies.
        #expect(!both.contains("7 are still"))
        // "how many verified" and "how many promoted" both reach .archived and both figures are in the one answer.
        #expect(HallieCatalogStats.detect("how many are verified") == .archived)
        #expect(HallieCatalogStats.detect("how many have been promoted") == .archived)
        #expect(both.contains("5 files have been promoted") && both.contains("3 are verified"))
        // Unverified only: no verified copy yet, but not "nothing promoted".
        let unverifiedOnly = HallieCatalogStats.answer(.archived, stats: stats(verified: 0, unverified: 4, unique: 10)).prose
        #expect(unverifiedOnly == "4 files have been promoted to the Master Archive, of which 0 are verified — 0% of the 10 unique media files verified; 4 are copied but not yet verified. 6 are still to be promoted.", Comment(rawValue: unverifiedOnly))
    }

    @Test func percentageCannotExceedOneHundred() {
        // verified + unverified > uniqueTotal (archived junk, or a unique
        // count that excludes what was promoted): the denominator grows,
        // the percentage caps, remaining is zero, not negative.
        let over = HallieCatalogStats.answer(.archived, stats: stats(verified: 12, unverified: 3, unique: 10)).prose
        #expect(over.contains("80% of the 15 unique media files verified"), Comment(rawValue: over))
        #expect(over.hasSuffix("Nothing is left to promote."))
        #expect(!over.contains("120%") && !over.contains("-"))
        let allVerified = HallieCatalogStats.answer(.archived, stats: stats(verified: 12, unverified: 0, unique: 10)).prose
        #expect(allVerified == "12 files have a verified copy in the Master Archive — 100% of the 12 unique media files. Nothing is left to promote.", Comment(rawValue: allVerified))
        // Nearly done never rounds to a false finish.
        let nearly = HallieCatalogStats.answer(.archived, stats: stats(verified: 999, unverified: 0, unique: 1000)).prose
        #expect(nearly.contains("over 99% of the 1,000"), Comment(rawValue: nearly))
        let tiny = HallieCatalogStats.answer(.archived, stats: stats(verified: 1, unverified: 0, unique: 1000)).prose
        #expect(tiny.contains("under 1% of the 1,000"), Comment(rawValue: tiny))
    }

    // codex #725 poisoned-row sensor: a manually-deleted row (hidden by the
    // catalog view, excluded from the footer) must not move Hallie's
    // footage total or earliest year either — one population for every figure.
    @Test func manuallyDeletedRowsMoveNoFigure() {
        let clean = [
            record("a.mov", bytes: 1_000, seconds: 3600, year: 1991),
            record("b.mov", bytes: 2_000, seconds: 1800, year: 2005),
        ]
        let poison = record("ghost.mov", bytes: 5_000_000_000_000, seconds: 9_000_000, year: 1800)
        poison.archiveStage = .manuallyDeleted
        let before = HallieCatalogStats.compute(records: clean)
        let after = HallieCatalogStats.compute(records: clean + [poison])
        #expect(after == before, "a hidden row changed a catalog-wide answer")
        #expect(after.totalDurationSeconds == 5400)
        #expect(after.earliestYear == 1991)
        #expect(after.fileCount == 2 && after.grossBytes == 3_000)
        // The footer's own population agrees, by construction.
        let storage = CatalogStorageTotalsCalculator.compute(records: clean + [poison])
        #expect(storage.fileCount == 2 && storage.manuallyDeletedFiles == 1)
        #expect(HallieCatalogStats.compute(records: clean + [poison], storage: storage) == after)
        // Set-aside / purged / superseded rows are outside the population too.
        let aside = record("aside.mov", bytes: 7, seconds: 7_000_000, year: 1801)
        aside.setAsideReason = "test"
        #expect(HallieCatalogStats.compute(records: clean + [aside]) == before)
    }

    @Test func grammarFollowsTheCount() {
        #expect(HallieCatalogStats.answer(.archived, stats: stats(verified: 1, unverified: 0, unique: 2)).prose
                == "1 file has a verified copy in the Master Archive — 50% of the 2 unique media files. 1 is still to be promoted.")
        #expect(HallieCatalogStats.answer(.archived, stats: stats(verified: 2, unverified: 0, unique: 4)).prose
                == "2 files have a verified copy in the Master Archive — 50% of the 4 unique media files. 2 are still to be promoted.")
        #expect(HallieCatalogStats.answer(.archived, stats: stats(verified: 1, unverified: 1, unique: 4)).prose
                == "2 files have been promoted to the Master Archive, of which 1 is verified — 25% of the 4 unique media files verified; 1 is copied but not yet verified. 2 are still to be promoted.")
        #expect(HallieCatalogStats.answer(.archived, stats: stats(verified: 0, unverified: 0, unique: 4)).prose
                == "Nothing has a verified copy in the Master Archive yet — of 4 unique media files.")
    }

    @Test func hundredThousandRecordsComputeWithinBudget() {
        let records = (0..<100_000).map { i in
            record("f\(i).mov", bytes: 1_000_000, seconds: 60, year: 1980 + (i % 40), fixity: i % 50 == 0)
        }
        let start = Date()
        let stats = HallieCatalogStats.compute(records: records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(stats.fileCount == 100_000)
        #expect(stats.archivedVerified == 2_000)
        #expect(elapsed < 3.0, "took \(elapsed)s")
    }
}
