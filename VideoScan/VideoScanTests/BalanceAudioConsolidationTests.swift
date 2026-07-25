// BalanceAudioConsolidationTests.swift
// LOGIC + SENSOR dimensions for the GH #137 consolidation: Verify Audio
// is the single audio-examination entry point, and Balance dispatches
// from the Verification Results sheet via
// `startBalanceAudio(record:fromDiagnosis:model:plannedOutput:)`.
//
//   * The dispatch consumes the diagnosis's ALREADY-COMPUTED analysis —
//     the created job carries it verbatim, so a fresh decode is
//     structurally impossible (the seam has no probe to call; pinned by
//     comparing the job's analysis to the cached one).
//   * A diagnosis WITHOUT a balance analysis (reference movie /
//     no-audio / undecodable track) starts NOTHING — the model-layer
//     twin of the sheet never showing the button.
//   * The Center's duplicate guard covers this entry point too.
//   * The planned output honors the container rule (raw DV → .mov)
//     when the caller lets the job compute it — the destination the
//     results sheet displays and the one the job plans can't diverge.
//
// (The retirement of the standalone "Balance Audio…" context-menu verb
// has no unit seam — the menu is a ViewBuilder — and is pinned by
// Gauntlet04BalanceAudioUITests instead.)

import Testing
import Foundation
@testable import VideoScan

// MARK: - Helpers

@MainActor
private func makeRecord(name: String, path: String? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = path ?? "/Volumes/T/\(name)"
    r.directory = (r.fullPath as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

/// A canned actionable analysis — left-only stereo PCM in QuickTime,
/// the classic one-sided tape ingest.
private func leftOnlyAnalysis(containerFormat: String = "mov,mp4,m4a,3gp,3g2,mj2")
    -> AudioBalanceAnalysis {
    var shape = AudioBalanceStreamShape(
        videoCodec: "h264",
        totalStreams: 2,
        videoStreams: 1,
        audioStreams: 1,
        audioCodec: "pcm_s16le",
        audioChannels: 2,
        audioBitRate: nil,
        durationSeconds: 2.0,
        audioStreamInfos: [AudioBalanceStreamInfo(
            absoluteIndex: 1, codec: "pcm_s16le", channels: 2, bitRate: nil)])
    shape.containerFormat = containerFormat
    return AudioBalanceAnalysis(
        classification: .leftOnly,
        measurements: AudioBalanceMeasurements(
            channels: [AudioChannelLevels(rmsDBFS: -18, peakDBFS: -6),
                       AudioChannelLevels(rmsDBFS: -.infinity, peakDBFS: -.infinity)],
            differenceRMSDBFS: nil),
        shape: shape,
        programStreamCount: 1,
        programStreamIndex: 1,
        droppedStreamIndices: [])
}

/// The diagnosis a completed VerifyAudioJob would cache for that file:
/// one channel-imbalance finding + the analysis it computed.
private func imbalanceDiagnosis(analysis: AudioBalanceAnalysis) -> AudioVerifyDiagnosis {
    var shape = AudioVerifyShape()
    shape.audioStreams = 1
    shape.audioCodec = "pcm_s16le"
    shape.audioChannels = 2
    shape.containerDurationSeconds = 2.0
    return AudioVerifyDiagnosis(
        findings: [.channelImbalance(analysis.classification)],
        shape: shape,
        balanceAnalysis: analysis)
}

/// A diagnosis with NOTHING measurable (reference movie) — the class
/// of verdict that must never reach a balance render.
private func analysislessDiagnosis() -> AudioVerifyDiagnosis {
    AudioVerifyDiagnosis(
        findings: [.referenceMovie(referencedPaths: ["/Avid MediaFiles/x.omf"])],
        shape: AudioVerifyShape(), balanceAnalysis: nil)
}

// MARK: - Dispatch from a diagnosis (the consolidation seam)

@Suite("Balance consolidation — dispatch from diagnosis")
@MainActor
struct BalanceFromDiagnosisTests {

    @Test func dispatchCarriesTheCachedAnalysisVerbatim() async throws {
        // GH #137 sensor: the render job must consume the diagnosis's
        // ALREADY-COMPUTED analysis — byte-for-byte the one Verify
        // cached — so opening/confirming Balance performs no decode.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "one_sided.mov")
        model.records = [rec]
        let analysis = leftOnlyAnalysis()
        let diagnosis = imbalanceDiagnosis(analysis: analysis)
        center.storeVerifyDiagnosis(diagnosis, forRecordID: rec.id)

        let job = center.startBalanceAudio(record: rec,
                                           fromDiagnosis: diagnosis,
                                           model: model)
        #expect(job != nil, "an imbalance diagnosis with an analysis must dispatch a render")
        #expect(job?.analysis == analysis,
                "the job's analysis must be the cached one — any difference means something re-analyzed")
        #expect(job?.kind == .balanceAudio)
        // Let the job settle (its source path doesn't exist, so it
        // fails fast — the dispatch contract, not the render, is under
        // test; render coverage lives in BalanceAudioJobTests).
        await job?.task?.value
    }

    @Test func diagnosisWithoutAnalysisStartsNothing() async throws {
        // Reference movie / no-audio / undecodable verdicts carry no
        // analysis — the sheet shows no button, and the model layer
        // refuses independently (defense in depth).
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "pointer.mov")
        model.records = [rec]

        let job = center.startBalanceAudio(record: rec,
                                           fromDiagnosis: analysislessDiagnosis(),
                                           model: model)
        #expect(job == nil)
        #expect(center.jobs.isEmpty, "a refused dispatch must not park a job row")
    }

    @Test func duplicateDispatchFromDiagnosisIsRefused() async throws {
        // The Center's duplicate guard must cover the consolidation
        // entry point too: a freshly-dispatched job is `.running`
        // before its task gets a turn, so the immediate re-dispatch
        // deterministically sees an active twin.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "one_sided.mov")
        model.records = [rec]
        let diagnosis = imbalanceDiagnosis(analysis: leftOnlyAnalysis())

        let first = center.startBalanceAudio(record: rec,
                                             fromDiagnosis: diagnosis,
                                             model: model)
        #expect(first != nil)
        let second = center.startBalanceAudio(record: rec,
                                              fromDiagnosis: diagnosis,
                                              model: model)
        #expect(second == nil,
                "the Center must refuse a duplicate balance for the same record")
        await first?.task?.value
    }

    @Test func rawDVDiagnosisPlansAQuickTimeDestination() async throws {
        // The container rule survives the consolidation: raw DV can't
        // hold the balanced sound, so the planned output is
        // <stem>_balanced.mov even though the source is .dv.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "clip28.dv", path: "/Volumes/T/clip28.dv")
        model.records = [rec]
        var analysis = leftOnlyAnalysis(containerFormat: "dv")
        analysis.shape.videoCodec = "dvvideo"
        analysis.shape.videoRFrameRate = "30000/1001"
        let diagnosis = imbalanceDiagnosis(analysis: analysis)

        let job = center.startBalanceAudio(record: rec,
                                           fromDiagnosis: diagnosis,
                                           model: model)
        #expect(job?.outputURL.lastPathComponent == "clip28_balanced.mov",
                "raw DV must plan a QuickTime (.mov) balanced copy")
        await job?.task?.value
    }

    @Test func verifyJobThenBalanceDispatchEndToEndUsesOneAnalysis() async throws {
        // The full consolidated path at the model layer: a VerifyAudioJob
        // (diagnose override — no I/O) caches its diagnosis; Balance
        // dispatches FROM that cache entry. Exactly one analysis object
        // flows through the whole chain.
        let center = MediaFileOperationsCenter()
        let model = VideoScanModel()
        let rec = makeRecord(name: "one_sided.mov")
        model.records = [rec]
        let analysis = leftOnlyAnalysis()
        let verify = center.startVerifyAudio(
            record: rec, model: model,
            diagnoseOverride: { _ in imbalanceDiagnosis(analysis: analysis) })
        await verify?.task?.value

        let cached = center.verifyDiagnosis(forRecordID: rec.id)
        #expect(cached?.balanceAnalysis == analysis,
                "verify must cache the diagnosis including its balance analysis")

        guard let cached else { return }
        let job = center.startBalanceAudio(record: rec,
                                           fromDiagnosis: cached,
                                           model: model)
        #expect(job?.analysis == analysis,
                "the render's analysis must be the very one verify computed")
        await job?.task?.value
    }
}
