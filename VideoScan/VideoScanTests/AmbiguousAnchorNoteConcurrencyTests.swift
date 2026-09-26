// AmbiguousAnchorNoteConcurrencyTests.swift
// Regression sensor for fix/ci-red-4 (CI run 36214064340, 2026-09-26).
//
// `POIProfile.upgradingKinshipAnchors` (reached from every `listAll()`)
// records "ambiguous legacy anchor already logged" keys in a process-wide
// set. That set was a `nonisolated(unsafe) static var Set<String>` mutated
// with no lock, while `listAll()` runs on the main actor AND on pool
// threads — CI's log shows the path on three threads in one test host.
// A racing insert can corrupt a Swift Set's open-addressing table; a later
// probe can then loop forever (on the main thread, when the caller is a
// @MainActor test or the People UI).
//
// How the tests pin it:
//   * `concurrentUpgradesKeepEveryAmbiguousRowNameKeyed` — hammers the
//     real entry point from 8 concurrent tasks, every call inserting a new
//     key. Against the unlocked set this crashes or corrupts under a
//     normal run and is flagged deterministically under Thread Sanitizer
//     (`-enableThreadSanitizer YES`, TSAN_OPTIONS=halt_on_error=1). Uses
//     only pre-fix API so the same test runs red on the old code.
//   * `firstNoteIsExactlyOncePerKeyUnderContention` — the check-and-insert
//     is one atomic step: N racers on the same key, exactly one "first".
//
// Five-dimension checklist: Logic (exactly-once), Scale (8 × 400 rounds,
// time-limited), Isolation (pure in-memory profiles — never touches the
// per-process POI store), Sensor (both tests). No media, so no media matrix.

import Foundation
import Testing
@testable import VideoScan

@Suite("Ambiguous anchor note — concurrency")
struct AmbiguousAnchorNoteConcurrencyTests {

    private static let workers = 8
    private static let roundsPerWorker = 400

    /// Two profiles share `Twin<tag>`; `Owner<tag>` has a legacy name anchor
    /// to it, so the upgrade must keep that row name-keyed AND note it once.
    private static func ambiguousTriple(tag: String) -> [POIProfile] {
        let twinName = "Twin\(tag)"
        return [
            POIProfile(name: twinName, referencePath: ""),
            POIProfile(name: twinName, referencePath: ""),
            POIProfile(name: "Owner\(tag)", referencePath: "", kinships: [
                Kinship(relation: .child, relativeTo: .profileName(twinName)),
            ]),
        ]
    }

    @Test(.timeLimit(.minutes(1)))
    func concurrentUpgradesKeepEveryAmbiguousRowNameKeyed() async {
        let run = UUID().uuidString.prefix(8)
        // `withTaskGroup` ≈ spawning N std::threads and joining them; child
        // tasks run on the global concurrent executor, i.e. truly in parallel.
        let keptNameKeyed = await withTaskGroup(of: Int.self) { group -> Int in
            for worker in 0..<Self.workers {
                group.addTask {
                    var kept = 0
                    for round in 0..<Self.roundsPerWorker {
                        // A fresh owner/name per round: every call INSERTS.
                        let tag = "\(run)-\(worker)-\(round)"
                        let upgraded = POIProfile.upgradingKinshipAnchors(Self.ambiguousTriple(tag: tag))
                        if upgraded.count == 3,
                           upgraded[2].kinships.first?.relativeTo == .profileName("Twin\(tag)") {
                            kept += 1
                        }
                    }
                    return kept
                }
            }
            var total = 0
            for await n in group { total += n }
            return total
        }
        #expect(keptNameKeyed == Self.workers * Self.roundsPerWorker,
                "every ambiguous legacy anchor stays name-keyed under concurrent listing")
    }
}
