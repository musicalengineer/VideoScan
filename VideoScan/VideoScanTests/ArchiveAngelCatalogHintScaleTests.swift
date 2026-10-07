// ArchiveAngelCatalogHintScaleTests.swift
// "Ready for archive" in the Catalog (Rick 2026-10-06) at production scale:
// 100k records, every one an Angel pick. Pins the budgets of the two halves
// of the hint build (the main-actor snapshot and the off-main assessment)
// and that the façade's row read gives the right words afterwards.
// (Feature agent's required SCALE test; the testing agent owns the rest.)

import Foundation
import Testing
@testable import VideoScan

@Suite("Archive Angel — Catalog \"Ready for archive\" hints at 100k", .serialized)
@MainActor
struct ArchiveAngelCatalogHintScaleTests {

    static let count = 100_000

    /// i % 4: 0,1 ready (sound checked, your date); 2 sound never checked;
    /// 3 undated. All are grade A picks (score 120 → `.ready` class).
    private static func records() -> [VideoRecord] {
        (0..<count).map { i in
            let r = VideoRecord()
            // Digit-free names: "Tape 1994.mov" would date itself from the
            // filename and stop being "undated".
            let name = "Tape " + String(String(i).map { Character(UnicodeScalar(UInt8(97) + UInt8($0.wholeNumberValue ?? 0))) }) + ".mov"
            r.filename = name
            r.fullPath = "/Volumes/T/Tapes/" + name
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.videoCodec = "prores"
            r.audioCodec = "pcm_s16le"
            if i % 4 != 2 { r.audioVerifyStatus = "ok" }
            if i % 4 != 3 { r.userDate = "1994-07-04"; r.userDateConfidence = "sure" }
            return r
        }
    }

    private static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    @Test("SCALE: 100k picks — snapshot < 1 s on main, build < 4 s off main (Debug); rows read the right words",
          .timeLimit(.minutes(2)))
    func hundredThousandPicks() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-catalog-hints")
        defer { try? FileManager.default.removeItem(at: sb.root) }
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let recs = Self.records()
        model.records = recs
        let now = Date()
        var evidence: [UUID: ArchiveAngelEvidenceRecord] = [:]
        evidence.reserveCapacity(Self.count)
        for r in recs {
            evidence[r.id] = .init(score: 120, lines: [.init(points: 120, line: "You rated it best (★★★)")],
                                   rejection: nil, useCount: 0, lastUsed: nil, computedAt: now)
        }
        let angel = model.archiveAngel
        // The recount runs synchronously here and schedules the hint build.
        angel.store.replace(with: ArchiveAngelEvidenceFile(computedAt: now, records: evidence))
        #expect(angel.recommendations.ranked.count == Self.count)

        let clock = ContinuousClock()
        var inputs: [ArchiveAngelCatalogHint.Input] = []
        let snap = clock.measure { inputs = angel.catalogHintInputs() }
        var built: [UUID: ArchiveAngelCatalogHint] = [:]
        let build = await clock.measure { built = await ArchiveAngel.buildCatalogHintsOffMain(inputs) }
        print("[catalog-hints] 100k snapshot \(String(format: "%.3f", Self.seconds(snap))) s, build \(String(format: "%.3f", Self.seconds(build))) s")
        #expect(inputs.count == Self.count)
        #expect(built.count == Self.count)
        #expect(built.values.filter(\.isReady).count == Self.count / 2)
        #expect(snap < PerformanceLane.debugCeiling(.seconds(1)), "main-actor snapshot of 100k took \(snap)")
        #expect(build < PerformanceLane.debugCeiling(.seconds(4)), "off-main build of 100k took \(build)")

        // The façade's own build has landed: rows read one dictionary entry.
        await angel.catalogHintsSettled()
        #expect(angel.catalogHints.byID.count == Self.count)
        let ready = angel.catalogBadge(for: recs[0].id)
        #expect(ready?.text == "Ready for archive")
        #expect(ready?.style == .readyCapsule)
        #expect(ready?.help.contains("the date you entered") == true)
        #expect(ready?.help.contains("You rated it best") == true)
        let unchecked = angel.catalogBadge(for: recs[2].id)
        #expect(unchecked?.text == "Angel pick")
        #expect(unchecked?.help.contains("audio checked") == true)
        let undated = angel.catalogBadge(for: recs[3].id)
        #expect(undated?.text == "Angel pick")
        #expect(undated?.help.contains("a date") == true)

        // 100k row reads (what a full scroll would ask) stay cheap.
        let reads = clock.measure { for r in recs { _ = angel.catalogBadge(for: r.id) } }
        print("[catalog-hints] 100k row reads \(String(format: "%.3f", Self.seconds(reads))) s")
        #expect(reads < PerformanceLane.debugCeiling(.seconds(2)), "100k row reads took \(reads)")
    }
}
