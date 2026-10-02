// GedcomParseContentionSensorTests.swift — regression sensor (2026-10-02).
//
// `GedcomFamilyGraph(gedcomText:)` split its input with the key path
// `\.isNewline`. A key-path-as-function is ONE shared heap object that is
// retained and released per character, so every thread parsing at once
// hammers the same refcount cache line. Alone a parse was fine; with the
// whole Core suite running in parallel the 200k merge pipeline's parse took
// 45–70 s of THREAD CPU instead of ~3 s, and "G2 at scale" lost linear time.
// Probe (Debug, M4 Max, each thread with its own copy of the text):
//   key path  — 0.20 s alone, 33 s each on 16 threads
//   closure   — 0.09 s alone, 0.10 s each on 16 threads
//
// This pins the property, not the spelling: parses on several threads cost
// each thread about what one parse costs alone. Thread CPU time ignores
// waiting for a core, so a busy host does not trip it; contention on shared
// state does, because spinning on a contended cache line IS CPU time.
// (C++ analogy: a std::shared_ptr copied in an inner loop on 8 threads.)

import Foundation
import Testing
@testable import VideoScanCore

@Suite("GEDCOM parse — no cross-thread contention")
struct GedcomParseContentionSensorTests {

    /// Per-thread CPU seconds for `body(copy)` run on `copies.count` raw
    /// threads at once. Raw `Thread`s, so the measurement does not depend
    /// on GCD or the cooperative pool admitting workers.
    private static func cpuSecondsConcurrently(_ copies: [String],
                                               _ body: @escaping @Sendable (String) -> Void) -> [Double] {
        let lock = NSLock()
        var out: [Double] = []
        let group = DispatchGroup()
        for copy in copies {
            group.enter()
            Thread {
                let cpu = TimingBudget.measureThreadCPUTime { body(copy) }
                lock.withLock { out.append(TimingBudget.seconds(cpu)) }
                group.leave()
            }.start()
        }
        group.wait()
        return out
    }

    @Test(.timeLimit(.minutes(2)))
    func parsesOnEightThreadsEachCostAboutWhatOneCostsAlone() {
        let text = GedcomMergeTests.synthetic(offset: 0, count: 20_000).gedcomText(provenance: "sensor")
        // Distinct storage per thread, so the only thing shared is process
        // state inside the parser (what this sensor is about).
        let copies = (0..<8).map { _ in String(decoding: Array(text.utf8), as: UTF8.self) }
        let parse: @Sendable (String) -> Void = { _ = GedcomFamilyGraph(gedcomText: $0) }
        let parseDetails: @Sendable (String) -> Void = { _ = GedcomLifeDetails(gedcomText: $0) }

        for (label, body) in [("GedcomFamilyGraph", parse), ("GedcomLifeDetails", parseDetails)] {
            let alone = Self.cpuSecondsConcurrently([copies[0]], body)[0]
            let together = Self.cpuSecondsConcurrently(copies, body)
            let worst = together.max() ?? 0
            print("[gedcom-contention] \(label): alone \(String(format: "%.3f", alone)) s CPU; 8 at once worst \(String(format: "%.3f", worst)) s CPU (\(TimingBudget.loadDescription()))")
            // ×6 covers an efficiency core (slower clock = more CPU seconds)
            // and cache sharing; the key-path regression measured ×20–×160.
            // The 0.05 s floor keeps a very fast `alone` from making it noisy.
            #expect(worst < max(alone, 0.05) * 6,
                    "\(label): 8 concurrent parses cost \(worst) s CPU each vs \(alone) s alone — shared state is contended (\(TimingBudget.loadDescription()))")
        }
    }
}
