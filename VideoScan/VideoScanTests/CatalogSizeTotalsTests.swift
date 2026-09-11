// CatalogSizeTotalsTests.swift
// The Catalog's TOTAL CATALOG · ARCHIVED · UNIQUE line (Rick 2026-09-11).
//
// Five-dimension coverage (CLAUDE.md checklist):
//   Logic     — each definition, the group-key precedence, the
//               largest-member rule, the not-yet-hashed tooltip condition,
//               and the display string.
//   Scale     — 100k synthetic records with mixed groups under an explicit
//               time budget (the pass runs on every catalog-change trigger).
//   Isolation — pure functions over constructed records; the archived
//               predicate is an injected closure. No UserDefaults, no real
//               paths, no model, no shared caches.
//   Sensor    — UNIQUE ≤ TOTAL and ARCHIVED ≤ TOTAL over a seeded random
//               catalog at production scale; N identical copies collapse
//               to ONE copy's bytes.
// Media matrix: N/A — pure catalog metadata, no file is ever opened.
//
// Plus one env-gated, read-only report over a COPY of a real catalog.json
// (never the live file) so the figures Rick sees can be reproduced here.

import Foundation
import Testing
@testable import VideoScan

private let GB: Int64 = 1_000_000_000

/// Builder. `hash` = contentHash, `md5` = partialMD5, `dup` = duplicateGroupID.
private func szRec(
    _ name: String,
    bytes: Int64 = 1 * GB,
    dup: UUID? = nil,
    hash: String = "",
    md5: String = "",
    purged: Bool = false,
    setAside: String? = nil
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.directory = "/Volumes/T"
    r.fullPath = "/Volumes/T/\(name)"
    r.sizeBytes = bytes
    r.duplicateGroupID = dup
    r.contentHash = hash
    r.partialMD5 = md5
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    r.setAsideReason = setAside
    return r
}

private func entry(_ bytes: Int64 = 1 * GB, dup: UUID? = nil, hash: String = "",
                   md5: String = "", archived: Bool = false) -> CatalogSizeTotals.Entry {
    CatalogSizeTotals.Entry(id: UUID(), sizeBytes: bytes, duplicateGroupID: dup,
                            contentHash: hash, partialMD5: md5, isArchived: archived)
}

private let never: (VideoRecord) -> Bool = { _ in false }

// MARK: - Logic

@Suite("Catalog size line — definitions")
struct CatalogSizeTotalsDefinitionTests {

    @Test func totalIsEveryActiveByteAndNothingElseIsRespected() {
        let recs = [
            szRec("a.mov", bytes: 4 * GB),
            szRec("b.mov", bytes: 3 * GB, hash: "h1"),
            szRec("c.mov", bytes: 2 * GB, purged: true),          // out
            szRec("d.mov", bytes: 1 * GB, setAside: "photo"),     // out
        ]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.totalBytes == 7 * GB)
        #expect(t.recordCount == 2)
        #expect(t.archivedBytes == 0)
    }

    @Test func archivedSumsEachActiveRecordOnceViaTheInjectedPredicate() {
        let recs = [
            szRec("orig.mov", bytes: 5 * GB, hash: "same"),
            szRec("archive-copy.mov", bytes: 5 * GB, hash: "same"),
            szRec("other.mov", bytes: 2 * GB),
            szRec("gone.mov", bytes: 9 * GB, purged: true),
        ]
        let archivedNames: Set<String> = ["orig.mov", "archive-copy.mov", "gone.mov"]
        let t = CatalogSizeTotals.compute(records: recs) { archivedNames.contains($0.filename) }
        // Original AND its copy both count (each record once, own size);
        // the purged one never reaches the predicate.
        #expect(t.archivedBytes == 10 * GB)
        #expect(t.archivedCount == 2)
        #expect(t.totalBytes == 12 * GB)
        #expect(t.uniqueBytes == 7 * GB)   // "same" collapses to one 5 GB
    }

    @Test func groupKeyPrecedenceIsDupGroupThenContentHashThenByteTwinThenSolo() {
        let g = UUID()
        #expect(CatalogSizeTotals.groupKey(for: entry(dup: g, hash: "h", md5: "m")) == .duplicateGroup(g))
        #expect(CatalogSizeTotals.groupKey(for: entry(hash: "h", md5: "m")) == .contentHash("h"))
        #expect(CatalogSizeTotals.groupKey(for: entry(7, md5: "m")) == .byteTwin(md5: "m", sizeBytes: 7))
        let solo = entry()
        #expect(CatalogSizeTotals.groupKey(for: solo) == .solo(solo.id))
        #expect(CatalogSizeTotals.groupKey(for: solo).isSolo)
        #expect(!CatalogSizeTotals.groupKey(for: entry(hash: "h")).isSolo)
    }

    @Test func duplicateGroupIDWinsEvenWhenContentHashesDiffer() {
        let g = UUID()
        // A dup group whose members were hashed differently (a transcode
        // in the same group) still collapses on the group ID.
        let recs = [
            szRec("a.mov", bytes: 6 * GB, dup: g, hash: "x"),
            szRec("b.mov", bytes: 2 * GB, dup: g, hash: "y"),
        ]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.uniqueBytes == 6 * GB)
        #expect(t.uniqueCount == 1)
    }

    @Test func contentHashGroupsWhenNoDupGroup() {
        let recs = [
            szRec("a.mov", bytes: 3 * GB, hash: "h"),
            szRec("b.mov", bytes: 3 * GB, hash: "h", md5: "different-md5"),
            szRec("c.mov", bytes: 1 * GB, hash: "other"),
        ]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.uniqueBytes == 4 * GB)
        #expect(t.uniqueCount == 2)
    }

    @Test func partialMD5TwinsRequireTheSameByteLength() {
        let recs = [
            szRec("a.mov", bytes: 3 * GB, md5: "m"),
            szRec("b.mov", bytes: 3 * GB, md5: "m"),   // twin
            szRec("c.mov", bytes: 2 * GB, md5: "m"),   // same prefix hash, different length — NOT a twin
        ]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.uniqueBytes == 5 * GB)
        #expect(t.uniqueCount == 2)
    }

    @Test func uniqueTakesTheLargestMemberOfEachGroup() {
        let g = UUID()
        let recs = [
            szRec("transcode.mp4", bytes: 1 * GB, dup: g),
            szRec("original.mov", bytes: 9 * GB, dup: g),
            szRec("cleaned.mov", bytes: 4 * GB, dup: g),
        ]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.uniqueBytes == 9 * GB)
        #expect(t.totalBytes == 14 * GB)
    }

    @Test func unhashedRecordsCountAsUniqueAndDriveTheTooltip() {
        let hashedOnly = [szRec("a.mov", hash: "h"), szRec("b.mov", md5: "m")]
        let t0 = CatalogSizeTotals.compute(records: hashedOnly, isArchived: never)
        #expect(t0.unhashedCount == 0)
        #expect(!t0.uniqueIsUpperBound)
        #expect(t0.unhashedTooltip == nil)
        #expect(!t0.uniqueTooltip.contains("upper bound"))

        let mixed = hashedOnly + [szRec("x.mov", bytes: 2 * GB), szRec("y.mov", bytes: 3 * GB)]
        let t1 = CatalogSizeTotals.compute(records: mixed, isArchived: never)
        #expect(t1.unhashedCount == 2)
        #expect(t1.uniqueIsUpperBound)
        #expect(t1.unhashedTooltip == "2 files not yet hashed — UNIQUE is an upper bound")
        #expect(t1.uniqueBytes == 7 * GB)   // every solo counted at full size
        #expect(t1.uniqueTooltip.contains("2 files not yet hashed"))

        let one = CatalogSizeTotals.compute(records: [szRec("solo.mov")], isArchived: never)
        #expect(one.unhashedTooltip == "1 file not yet hashed — UNIQUE is an upper bound")
    }

    @Test func negativeSizesAreCorruptMetadataNotCredits() {
        let recs = [szRec("a.mov", bytes: 3 * GB), szRec("bad.mov", bytes: -5 * GB)]
        let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
        #expect(t.totalBytes == 3 * GB)
        #expect(t.uniqueBytes == 3 * GB)
    }

    @Test func emptyCatalogIsEmptyAndHidesTheBox() {
        let t = CatalogSizeTotals.compute(records: [], isArchived: never)
        #expect(t == CatalogSizeTotals())
        #expect(t.isEmpty)
        let onlyInactive = CatalogSizeTotals.compute(records: [szRec("p.mov", purged: true)], isArchived: never)
        #expect(onlyInactive.isEmpty)
    }

    @Test func displayLineUsesTheAppWideDecimalFormatter() {
        var t = CatalogSizeTotals()
        t.totalBytes = 10_690_000_000_000
        t.archivedBytes = 2_140_000_000_000
        t.uniqueBytes = 6_300_000_000_000
        t.recordCount = 3
        #expect(t.line == "TOTAL CATALOG 10.7 TB · ARCHIVED 2.1 TB · UNIQUE 6.3 TB")
        #expect(t.totalDisplay == MediaBytes.display(t.totalBytes))
        var small = CatalogSizeTotals()
        small.totalBytes = 150 * GB
        #expect(small.totalDisplay == "150 GB")
    }
}

// MARK: - Isolation

@Suite("Catalog size line — isolation")
struct CatalogSizeTotalsIsolationTests {

    /// The archived predicate is the ONLY hook into the model, and it is
    /// asked exactly once per active record — never for purged / set-aside
    /// rows. Pins the contract the main-actor projection relies on.
    @Test func predicateIsAskedOncePerActiveRecordOnly() {
        let recs = [
            szRec("a.mov"), szRec("b.mov"),
            szRec("purged.mov", purged: true),
            szRec("aside.mov", setAside: "music"),
        ]
        var asked: [String] = []
        let entries = CatalogSizeTotals.project(recs) { asked.append($0.filename); return false }
        #expect(asked == ["a.mov", "b.mov"])
        #expect(entries.count == 2)
        #expect(CatalogSizeTotals.compute(entries).recordCount == 2)
    }

    /// The two halves compose to the one-call form exactly.
    @Test func projectThenComputeEqualsTheConvenienceForm() {
        let g = UUID()
        let recs = [szRec("a.mov", bytes: 2 * GB, dup: g), szRec("b.mov", bytes: 5 * GB, dup: g),
                    szRec("c.mov", hash: "h"), szRec("d.mov")]
        let arch: (VideoRecord) -> Bool = { $0.filename.hasPrefix("a") }
        let split = CatalogSizeTotals.compute(CatalogSizeTotals.project(recs, isArchived: arch))
        #expect(split == CatalogSizeTotals.compute(records: recs, isArchived: arch))
    }
}

// MARK: - Scale + sensors

/// Deterministic generator so the sensor catalog is the same every run.
/// (A tiny LCG ≈ C's rand(); `SystemRandomNumberGenerator` is unseeded.)
private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

/// 100k records shaped like the real catalog: ~20% in dup groups of 2–4,
/// ~35% hashed loners, ~25% MD5-only with twins, ~20% not yet hashed.
private func syntheticCatalog(count: Int, seed: UInt64) -> [VideoRecord] {
    var rng = SeededRNG(state: seed)
    var out: [VideoRecord] = []
    out.reserveCapacity(count)
    var i = 0
    while out.count < count {
        let roll = Int(rng.next() % 100)
        let bytes = Int64(rng.next() % 8_000_000_000) + 1
        if roll < 20 {
            let g = UUID()
            let members = 2 + Int(rng.next() % 3)
            for k in 0..<members where out.count < count {
                out.append(szRec("g\(i)-\(k).mov", bytes: bytes / Int64(k + 1), dup: g, hash: "H\(i)"))
            }
        } else if roll < 55 {
            out.append(szRec("h\(i).mov", bytes: bytes, hash: "H\(i)"))
        } else if roll < 80 {
            out.append(szRec("m\(i).mov", bytes: bytes, md5: "M\(i)"))
            if roll < 65, out.count < count {
                out.append(szRec("m\(i)-twin.mov", bytes: bytes, md5: "M\(i)"))
            }
        } else {
            out.append(szRec("u\(i).mov", bytes: bytes))
        }
        i += 1
    }
    return out
}

@Suite("Catalog size line — scale and sensors")
struct CatalogSizeTotalsScaleTests {

    /// Scale (checklist dimension 2): both halves over 100k mixed records
    /// inside the budget. The projection runs on the main actor on every
    /// catalog-change trigger, so its share of this is a UI cost.
    @Test func hundredThousandRecordsStayUnderBudget() {
        let recs = syntheticCatalog(count: 100_000, seed: 42)
        #expect(recs.count == 100_000)
        let t0 = Date()
        let entries = CatalogSizeTotals.project(recs) { $0.filename.hasSuffix("3.mov") }
        let t1 = Date()
        let totals = CatalogSizeTotals.compute(entries)
        let t2 = Date()
        let projectMS = t1.timeIntervalSince(t0) * 1000
        let computeMS = t2.timeIntervalSince(t1) * 1000
        #expect(t2.timeIntervalSince(t0) < 0.5,
                "project \(Int(projectMS)) ms + compute \(Int(computeMS)) ms for 100k records")
        #expect(totals.recordCount == 100_000)
        #expect(totals.unhashedCount > 10_000 && totals.unhashedCount < 30_000)
    }

    /// Sensor: the two inequalities that must hold for ANY catalog. Run
    /// over several seeds at production scale so a future rule change
    /// that double-counts (or subtracts) shows up here first.
    @Test func uniqueAndArchivedNeverExceedTotal() {
        for seed: UInt64 in [1, 7, 2026] {
            let recs = syntheticCatalog(count: 20_000, seed: seed)
            var rng = SeededRNG(state: seed &+ 99)
            let flags = recs.map { _ in rng.next() % 3 == 0 }
            var idx = 0
            let t = CatalogSizeTotals.compute(records: recs) { _ in
                defer { idx += 1 }
                return flags[idx]
            }
            #expect(t.uniqueBytes <= t.totalBytes, "seed \(seed)")
            #expect(t.archivedBytes <= t.totalBytes, "seed \(seed)")
            #expect(t.uniqueCount <= t.recordCount, "seed \(seed)")
            #expect(t.archivedCount <= t.recordCount, "seed \(seed)")
            #expect(t.unhashedCount <= t.uniqueCount, "seed \(seed)")
        }
    }

    /// Sensor: N identical copies are ONE copy. Pinned for every grouping
    /// signal, because this is the whole reason the line exists — the
    /// archive copy and the cleaned version must not inflate UNIQUE.
    @Test func nIdenticalCopiesCollapseToOneCopy() {
        let n = 1_000
        let g = UUID()
        let byGroup = (0..<n).map { szRec("g\($0).mov", bytes: 3 * GB, dup: g) }
        let byHash  = (0..<n).map { szRec("h\($0).mov", bytes: 3 * GB, hash: "same") }
        let byTwin  = (0..<n).map { szRec("m\($0).mov", bytes: 3 * GB, md5: "same") }
        for (label, recs) in [("dup group", byGroup), ("content hash", byHash), ("byte twin", byTwin)] {
            let t = CatalogSizeTotals.compute(records: recs, isArchived: never)
            let why = Comment(rawValue: label)
            #expect(t.totalBytes == Int64(n) * 3 * GB, why)
            #expect(t.uniqueBytes == 3 * GB, why)
            #expect(t.uniqueCount == 1, why)
            #expect(t.unhashedCount == 0, why)
        }
    }
}

// MARK: - Read-only report over a catalog COPY (env-gated)

/// Reproduce the line for a real catalog snapshot — a COPY, never the
/// live file — so the figures Rick sees can be checked here. Run with
/// `TEST_RUNNER_VIDEOSCAN_SIZE_TOTALS_CATALOG=/path/to/copy.json`.
///
/// The archived predicate here is a stand-in for `model.isArchived`
/// (which needs a live model): promoted copies, files inside the
/// designated root, sources a copy was promoted from, and records whose
/// contentHash matches an archive copy's. It omits the model's
/// high-confidence dup-group clause, so ARCHIVED can read slightly LOW
/// versus the app. TOTAL and UNIQUE are exact.
@Suite("Catalog size line — report over a catalog copy",
       .enabled(if: ProcessInfo.processInfo.environment["VIDEOSCAN_SIZE_TOTALS_CATALOG"] != nil))
struct CatalogSizeTotalsReportTests {

    @Test func reportTheThreeFigures() throws {
        let path = try #require(ProcessInfo.processInfo.environment["VIDEOSCAN_SIZE_TOTALS_CATALOG"])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        // Same decoder shape as CatalogStore.decode(url:) — the app's
        // own snapshot type, ISO-8601 dates.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snap = try decoder.decode(CatalogSnapshot.self, from: data)
        let root = snap.masterArchive?.rootPath

        func isCopy(_ r: VideoRecord) -> Bool {
            r.derivationKind == ArchivePromotion.derivationKind
                || (root.map { ArchivePathResolver.isInside(path: r.fullPath, root: $0) } ?? false)
        }
        let copies = snap.records.filter { !$0.isPurged && !$0.isSetAside && isCopy($0) }
        let promotedSourceIDs = Set(copies.compactMap(\.derivedFrom))
        let copyHashes = Set(copies.map(\.contentHash).filter { !$0.isEmpty })

        let t = CatalogSizeTotals.compute(records: snap.records) { r in
            isCopy(r) || promotedSourceIDs.contains(r.id)
                || (!r.contentHash.isEmpty && copyHashes.contains(r.contentHash))
        }
        print("""
        SIZE-TOTALS REPORT \(path)
          records (all): \(snap.records.count)  active: \(t.recordCount)
          \(t.line)
          archived files: \(t.archivedCount)  content groups: \(t.uniqueCount)  not yet hashed: \(t.unhashedCount)
          master root: \(root ?? "none")
        """)
        #expect(t.totalBytes > 0)
        #expect(t.uniqueBytes <= t.totalBytes)
        #expect(t.archivedBytes <= t.totalBytes)
    }
}
