// ProductionShapeRescanCarryTests.swift
// GH #478 (DECISIONS 2026-11-27 (1)) at PRODUCTION SHAPE: Rick's real catalog
// (a sqlite .backup copy, ProductionShapeScene) and the carry door the merges
// call. NO MEDIA FILE IS OPENED OR STAT'ED (the test host is not the app; a
// removable volume waits on a privacy prompt): the "rescan" is played from
// each row's own stored facts.
//
// It reports, counts only (privacy):
//   * how many live rows hold Rick's curated values (date, place, disposition,
//     tags, notes, people, stars, music mark, attestations) — each would be
//     carried WITH A NOTE if a rescan found a different file at its path;
//   * how many of those are archived themselves (left as before);
//   * how many would carry on the NEXT rescan already — the catalog's own
//     evidence says the file at the path changed after it was hashed (the
//     stored stat size differs from the whole-file digest's byte count);
//   * how many curated rows' new file would be a copy of archived content
//     (date left as filed) — 0 by construction here: an unhashed probe has no
//     digest; the twin rule is pinned by RescanCarryWithNoteTests.
// Then it carries for real on a sample of the copy (re-encoded probes, size
// + 1), commits, relaunches: every sampled new row has the note and the
// values, every earlier row is kept as replacedAtPath history; one Undo Carry
// round-trips too.
//
// ISOLATION: reads the real catalog (read-only .backup) — skipped where it is
// absent; runs in scripts/run_catalog_tests.sh and the nightly all-tests pass
// on Rick's Mac. Writes only to the copy.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape rescan carry with a note (GH #478) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeRescanCarryTests {

    static let sampleSize = 25

    /// "/Volumes/Name" (or the first two components of any other path).
    static func volumeRoot(_ path: String) -> String {
        "/" + path.split(separator: "/").prefix(2).joined(separator: "/")
    }

    @Test("the live copy: how many rows would carry today; a sample carries with the note, keeps its history row, and survives a relaunch and an undo")
    func countAndCarryASample() async throws {
        let shape = try await ProductionShapeScene.make("rescancarry478"); defer { shape.cleanup() }
        let model = shape.model
        var curated = 0, archivedItself = 0, changedAlready = 0
        var byVolume: [String: [VideoRecord]] = [:]   // the merge's root is a volume, never "/"
        for r in model.records where r.removal == nil && RescanCuratedGroup.holdsAny(r) {
            curated += 1
            if model.isDateReadOnlyItself(r) { archivedItself += 1; continue }
            if let f = r.contentFixity, f.byteCount > 0, r.sizeBytes > 0, f.byteCount != r.sizeBytes { changedAlready += 1 }
            byVolume[Self.volumeRoot(r.fullPath), default: []].append(r)
        }
        let (root, rows) = byVolume.max { $0.value.count < $1.value.count } ?? ("", [])
        let sample = Array(rows.prefix(Self.sampleSize))
        print("rescan carry (production shape): \(model.records.count) rows · \(curated) live rows hold Rick's values "
              + "(\(archivedItself) archived themselves, left as before) · \(curated - archivedItself) would carry with a "
              + "note if their file changed · \(changedAlready) would carry on the next rescan already (stored size differs "
              + "from the whole-file digest's)")
        try #require(!sample.isEmpty, "the copy has no curated live row — the test has lost its teeth")

        // Play the rescan on the sample: the probe (scan-derived facts, new
        // id, one byte longer), the live re-read, then the carry door.
        var fresh: [VideoRecord] = []
        for old in sample {
            let probe = VideoRecord()
            probe.apply(ProbeOutcome(scanDerivedFrom: old))
            probe.sizeBytes = old.sizeBytes + 1
            probe.contentFixity = nil                       // an unhashed probe: no whole-file digest yet
            RescanPreservedFields(from: old).apply(to: probe)
            fresh.append(probe)
        }
        let paths = Set(sample.map(\.fullPath))
        let result = RescanCarryWithNote(model: model).carry(root: root, newPaths: paths, fresh: fresh, alreadyKept: [])
        #expect(result.carried == sample.count, "every sampled curated row is carried with a note")
        #expect(result.kept.count == sample.count, "every earlier row is kept as history")
        model.records.append(contentsOf: fresh)
        #expect(model.saveCatalogNow(), "the carry commits to the copy")

        let back = try await shape.relaunchedModel()
        var noted = 0, history = 0, valuesKept = 0
        for (old, new) in zip(sample, fresh) {
            if let n = back.records.first(where: { $0.id == new.id }),
               RescanCarryNote.active(in: n.notes)?.earlierID == old.id { noted += 1 }
            if let h = back.records.first(where: { $0.id == old.id }), h.removal?.reason == .replacedAtPath {
                history += 1
                if let n = back.records.first(where: { $0.id == new.id }),
                   RescanCuratedGroup.allCases.allSatisfy({ $0 == .date && back.isDateReadOnly(n) || $0.same(n, h) }) {
                    valuesKept += 1
                }
            }
        }
        print("rescan carry (production shape): sample \(sample.count) · after relaunch \(noted) new rows carry the note · "
              + "\(history) earlier rows kept as history · \(valuesKept) new rows show the history row's values")
        #expect(noted == sample.count && history == sample.count && valuesKept == sample.count)

        // One Undo Carry round-trip on the relaunched copy.
        let target = try #require(back.records.first { $0.id == fresh[0].id })
        guard case .undone = RescanCarryWithNote(model: back).undoCarry(on: target) else {
            Issue.record("undo on the relaunched copy was refused"); await ProductionShapeScene.close(back); return
        }
        #expect(back.saveCatalogNow())
        #expect(RescanCarryNote.active(in: target.notes) == nil)
        await ProductionShapeScene.close(back)
    }
}
