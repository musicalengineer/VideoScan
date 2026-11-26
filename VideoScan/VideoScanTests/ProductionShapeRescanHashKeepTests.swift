// ProductionShapeRescanHashKeepTests.swift
// GH #434 at PRODUCTION SHAPE: Rick's real catalog (a sqlite .backup copy,
// ProductionShapeScene) and the merge's own rule,
// RescanPreservedFields.carriedContentFixity. NO FILE IS OPENED OR STAT'ED:
// the test host is not the app, and opening a file on a removable volume
// from it waits on a macOS privacy prompt (found 2026-11-25 on the first
// version of this test, which stamped the real files).
//
// For every live row with a whole-file digest, the test plays the two
// rescans that matter, from the row's own stored stamp:
//   * the file UNCHANGED since it was hashed (the probe's stamp equals the
//     stored one) — the rule must keep the digest exactly when the stored
//     fixity can vouch for bytes at all (sha256, ctime, volume UUID, not
//     racily clean): the 2026-11-05 incident, 5,395 of 5,395 held rows
//     unchanged, is this case;
//   * the file TOUCHED (same everything, ctime one tick later) — the rule
//     must never keep it.
// It reports how many of Rick's digests can be kept across a rescan and how
// many are legacy stamps that cannot (those are re-hashed once, then keep).
// PRIVACY: counts only.
//
// ISOLATION: reads the real catalog (read-only .backup) — skipped where it is
// absent; runs in scripts/run_catalog_tests.sh and the nightly all-tests pass
// on Rick's Mac.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Production-shape rescan hash keep (GH #434) — ISOLATION: reads the real catalog",
       .serialized, .enabled(if: LiveCatalogCopy.present, LiveCatalogCopy.skipWords))
@MainActor
struct ProductionShapeRescanHashKeepTests {

    @Test("the live copy: every vouching digest survives an unchanged rescan; none survives a touched file")
    func theRuleKeepsExactlyTheUnchangedFiles() async throws {
        let shape = try await ProductionShapeScene.make("rescanhashkeep"); defer { shape.cleanup() }
        let model = shape.model
        var withDigest = 0, vouching = 0, keptUnchanged = 0, keptTouched = 0, legacy = 0, racy = 0
        for live in model.records where live.removal == nil {
            guard let fixity = live.contentFixity else { continue }
            withDigest += 1
            let canVouch = fixity.isUsableForVerification && !fixity.isRacilyAmbiguous
                && fixity.stamp.size == live.sizeBytes
            if canVouch { vouching += 1 }
            if !fixity.isUsableForVerification { legacy += 1 } else if fixity.isRacilyAmbiguous { racy += 1 }

            let unchanged = VideoRecord()
            unchanged.apply(ProbeOutcome(scanDerivedFrom: live))
            unchanged.scanIdentityStamp = fixity.stamp
            if RescanPreservedFields.carriedContentFixity(live: fixity, onto: unchanged) != nil { keptUnchanged += 1 }

            let s = fixity.stamp
            let touched = VideoRecord()
            touched.apply(ProbeOutcome(scanDerivedFrom: live))
            touched.scanIdentityStamp = FileIdentityStamp(device: s.device, inode: s.inode, size: s.size, mtimeNs: s.mtimeNs,
                                                          ctimeNs: s.ctimeNs &+ 1, volumeUUID: s.volumeUUID)
            if RescanPreservedFields.carriedContentFixity(live: fixity, onto: touched) != nil { keptTouched += 1 }
        }
        await shape.close()
        print("rescan hash keep (production shape): \(withDigest) live rows with a whole-file digest · "
              + "\(keptUnchanged) keep it across an unchanged rescan · \(legacy) legacy stamps (no ctime or volume UUID) "
              + "and \(racy) racily clean are re-hashed once")
        #expect(keptUnchanged == vouching, "a vouching digest was dropped (\(keptUnchanged) kept of \(vouching)) — Fill In Full Hashes would re-read it")
        #expect(keptTouched == 0, "\(keptTouched) digest(s) followed a file whose ctime moved")
        #expect(withDigest > 0, "the live copy has no whole-file digest at all — the test has lost its teeth")
    }
}
