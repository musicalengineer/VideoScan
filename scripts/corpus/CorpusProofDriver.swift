// CorpusProofDriver.swift — lane `proof` of the real-data corpus harness.
// (How this file reaches a build, the seal and the privacy rule:
// CorpusDriverSupport.swift.)
//
// Laid over the testbed ONLY when the ref under test contains the
// balanced-copy proof engine (MediaOps/BalancedCopyProof*.swift); the Python
// side says "this ref has no proof engine" otherwise and builds nothing.
//
// Per "one-sided sound" corpus file:
//   balance  AudioBalanceProbe.analyze, then the app's own BalanceAudioJob
//            with `plannedOutput` under ~/corpus/work/<run>/ (the job's seam
//            for a chosen folder) — the corpus source is only read. The model
//            is a bare in-memory one in a test host: nothing is catalogued.
//   proof    BalancedCopyProof.measure(original:balanced:) → the outcome
//            word, the named difference kinds, the discarded channel's peak.
// The balanced copy is removed from work/ as soon as its proof is recorded,
// so at most one copy is on disk (worst case: the size of the largest
// one-sided corpus file plus its PCM sound).

import Foundation
import XCTest
import VideoScanCore
@testable import VideoScan

final class CorpusProofDriver: XCTestCase {

    @MainActor
    func testProofLane() async throws {
        let run: CorpusRun
        let records: [String: VideoRecord]
        do {
            run = try CorpusRun.open(lane: "proof")
            let loaded = try await run.loadCatalog()
            records = Dictionary(loaded.records.map { ($0.fullPath, $0) }, uniquingKeysWith: { first, _ in first })
        } catch let refusal as CorpusRefusal {
            return XCTFail("corpus harness refused: \(refusal.word)")
        }

        for item in run.config.pending {
            run.begin(item)
            guard let record = records[item.path] else {
                await run.engine(item, "balance") { ("no_record", []) }
                run.end(item)
                continue
            }
            var balanced: URL?
            await run.engine(item, "balance") {
                let analysis = try await AudioBalanceProbe.analyze(path: item.path)
                run.facts(item, ["container": CorpusWords.word(analysis.shape.containerFormat),
                                 "vcodec": CorpusWords.word(analysis.shape.videoCodec ?? "none"),
                                 "acodec": CorpusWords.word(analysis.shape.audioCodec.isEmpty ? "none" : analysis.shape.audioCodec),
                                 "duration": analysis.shape.durationSeconds])
                let classWord = analysis.classification.rawValue
                let stem = String(item.sha.prefix(12))
                let ext = URL(fileURLWithPath: item.path).pathExtension
                let named = run.config.work + "/" + stem + (ext.isEmpty ? "" : "." + ext)
                let planned = BalanceAudioFix.balancedOutputURL(forSourcePath: named,
                                                                containerFormat: analysis.shape.containerFormat)
                guard CorpusRun.isUnder(planned.path, run.config.work) else { return ("refused_by_harness", [classWord]) }
                let model = VideoScanModel()
                model.records = [record]
                let job = BalanceAudioJob(record: record, analysis: analysis, model: model, plannedOutput: planned)
                job.start()
                await job.task?.value
                if case .finished = job.state, let published = job.publishedURL,
                   CorpusRun.isUnder(published.path, run.config.work) {
                    balanced = published
                    return ("balanced", [classWord])
                }
                return (job.wasRefused ? "refused" : "failed", [classWord])
            }
            if let balanced {
                await run.engine(item, "proof") {
                    switch await BalancedCopyProof.measure(original: item.path, balanced: balanced.path) {
                    case .proven(let evidence):
                        if let peak = evidence.discarded?.peakDBFS, peak.isFinite { run.facts(item, ["peak_dbfs": peak]) }
                        return ("proven", [])
                    case .sameContent(let evidence, let differs):
                        if let peak = evidence.discarded?.peakDBFS, peak.isFinite { run.facts(item, ["peak_dbfs": peak]) }
                        return ("same_content", Array(Set(differs.map { $0.kind.rawValue })).sorted())
                    case .notProven(let why):
                        return ("not_proven", [CorpusWords.caseName(why)])
                    case .couldNotCheck:
                        return ("could_not_check", [])
                    }
                }
                try? FileManager.default.removeItem(at: balanced)
            }
            run.end(item)
        }
        run.done()
    }
}
