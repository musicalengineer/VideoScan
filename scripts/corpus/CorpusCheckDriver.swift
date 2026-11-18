// CorpusCheckDriver.swift — lane `check` of the real-data corpus harness.
// (How this file reaches a build, the seal and the privacy rule:
// CorpusDriverSupport.swift.)
//
// Per corpus file, the app's own READ-ONLY engines, called as the jobs call
// them — nothing is re-implemented here and nothing is stored:
//   probe   CheckMediaProbe.facts            the header probe → MediaFacts
//   check   CheckMediaProbe.quick, then the rule calls CheckMediaJob makes
//           for the quick tier (quickChecks + fullRowsNotRun,
//           applyingSoundPresence with the record's context, card) → the
//           report card's verdict word, and the rows that are not OK
//   audio   VerifyAudioProbe.diagnose        → verdict word + finding kinds
// The record comes from the sealed corpus catalog; a file the catalog has no
// record for is `no_record`.

import Foundation
import XCTest
import VideoScanCore
@testable import VideoScan

final class CorpusCheckDriver: XCTestCase {

    func testCheckLane() async throws {
        let run: CorpusRun
        do {
            run = try CorpusRun.open(lane: "check")
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }
        let contexts: [String: SoundPresenceContext]
        do {
            let loaded = try await run.loadCatalog()
            contexts = Dictionary(loaded.records.map { ($0.fullPath, $0.soundPresenceContext) },
                                  uniquingKeysWith: { first, _ in first })
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }

        for item in run.config.pending {
            run.begin(item)
            guard let context = contexts[item.path] else {
                await run.engine(item, "probe") { ("no_record", []) }
                run.end(item)
                continue
            }
            await run.engine(item, "probe") {
                switch await CheckMediaProbe.facts(path: item.path) {
                case .success(let facts):
                    run.facts(item, ["container": CorpusWords.word(facts.formatName),
                                     "vcodec": CorpusWords.word(facts.video?.codec ?? "none"),
                                     "acodec": CorpusWords.word(facts.audio?.codec ?? "none"),
                                     "duration": facts.durationSeconds ?? 0,
                                     "audio_streams": facts.audioStreams.count,
                                     "bytes": facts.sizeBytes ?? 0])
                    return ("probed", [])
                case .failure:
                    return ("unopenable", [])
                }
            }
            await run.engine(item, "check") {
                switch try await CheckMediaProbe.quick(path: item.path) {
                case .unopenable:
                    return ("unopenable", [])
                case .measured(let quick):
                    var checks = CheckMediaRules.quickChecks(quick) + CheckMediaRules.fullRowsNotRun()
                    checks = CheckMediaRules.applyingSoundPresence(checks, facts: quick.facts,
                                                                   soundMeasuredSilent: nil, context: context)
                    let card = CheckMediaRules.card(tier: .quick, checks: checks, quick: quick, at: Date())
                    let flagged = card.checks.filter { $0.verdict.rank >= 2 }
                        .map { "\($0.kind.rawValue):\($0.verdict.word)" }
                    return (card.verdict.word, flagged)
                }
            }
            await run.engine(item, "audio") {
                let diagnosis = try await VerifyAudioProbe.diagnose(path: item.path)
                let kinds = diagnosis.findings.map { CorpusWords.caseName($0) }
                switch diagnosis.verdict {
                case .ok: return (diagnosis.isHealthy ? "healthy" : "ok_with_findings", kinds)
                case .damaged: return ("damaged", kinds)
                case .notChecked: return ("not_checked", kinds)
                }
            }
            run.end(item)
        }
        run.done()
    }
}
