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
//   audio   VerifyAudioProbe.diagnose        → verdict word + finding kinds (a channel
//           imbalance says its side, `channelImbalance:leftOnly`: the proof lane
//           picks its one-sided files from these)
//   pair    the record's A/V pair link as the catalog loaded it (carried by
//           `prepare` since transform 2): `unpaired`, `paired_partner_in_corpus`
//           or `paired_partner_absent`, and whether the app counts the row as
//           a pair half (CatalogPairGroups.isHalf) and names a sound partner
//           for it (the sound-presence rule's own input) — no file is read
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
        let pairs: [String: PairFacts]
        do {
            let loaded = try await run.loadCatalog()
            contexts = Dictionary(loaded.records.map { ($0.fullPath, $0.soundPresenceContext) },
                                  uniquingKeysWith: { first, _ in first })
            pairs = CorpusCheckDriver.pairFacts(loaded.records)
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }

        // N files in flight (the config's `jobs`; 1 = one after another): the engines are
        // `@concurrent` statics over ProcessRunner, with no shared mutable state.
        await run.each { item in
            run.begin(item)
            guard let context = contexts[item.path] else {
                await run.engine(item, "probe") { ("no_record", []) }
                run.end(item)
                return
            }
            await run.engine(item, "probe") {
                switch await CheckMediaProbe.facts(path: item.path) {
                case .success(let facts):
                    // The audio engine's work is linear in the media's length: its deadline grows with it.
                    run.mediaDuration(item, seconds: facts.durationSeconds)
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
                let kinds = diagnosis.findings.map { finding -> String in
                    if case .channelImbalance(let side) = finding { return "channelImbalance:" + CorpusWords.caseName(side) }
                    return CorpusWords.caseName(finding)
                }
                switch diagnosis.verdict {
                case .ok: return (diagnosis.isHealthy ? "healthy" : "ok_with_findings", kinds)
                case .damaged:
                    // Rick 2026-11-25: the same stored status, but only real damage is "damaged"; a reference movie and
                    // an old codec that needs rebuilding are doubts (corpus_run.py DOUBT_WORDS["audio"]).
                    switch diagnosis.trouble {
                    case .referenceMovie?: return ("reference_movie", kinds)
                    case .needsRebuild?: return ("needs_rebuild", kinds)
                    case .damaged?, nil: return ("damaged", kinds)
                    }
                case .notChecked: return ("not_checked", kinds)
                }
            }
            await run.engine(item, "pair") {
                guard let facts = pairs[item.path] else { return ("no_record", []) }
                return (facts.word, facts.kinds)
            }
            run.end(item)
        }
        run.done()
    }

    struct PairFacts: Sendable {
        let word: String
        let kinds: [String]
    }

    /// Each record's pair link as loaded, by path. A link is a pair group or a partner id; the
    /// partner is "in the corpus" when another loaded record shares the group or is the partner.
    static func pairFacts(_ records: [VideoRecord]) -> [String: PairFacts] {
        var groupSizes: [UUID: Int] = [:]
        for record in records {
            if let group = record.pairGroupID { groupSizes[group, default: 0] += 1 }
        }
        var facts: [String: PairFacts] = [:]
        for record in records where facts[record.fullPath] == nil {
            let linked = record.pairGroupID != nil || record.pairedWith != nil || record.pendingPairedWithID != nil
            let partnerHere = record.pairedWith != nil || (record.pairGroupID.map { (groupSizes[$0] ?? 0) > 1 } ?? false)
            var kinds = [CatalogPairGroups.isHalf(record) ? "counted_as_a_half" : "not_counted_as_a_half"]
            if record.soundPresenceContext.soundPartnerName != nil { kinds.append("sound_partner_named") }
            facts[record.fullPath] = PairFacts(word: !linked ? "unpaired" : partnerHere ? "paired_partner_in_corpus" : "paired_partner_absent",
                                               kinds: kinds)
        }
        return facts
    }
}
