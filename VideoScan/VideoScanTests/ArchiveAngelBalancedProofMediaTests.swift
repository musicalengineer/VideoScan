// ArchiveAngelBalancedProofMediaTests.swift
// MEDIA MATRIX for Prepare's report-only proof stage (2026-11-18): generated
// one-sided originals (tones, no family media — BalancedCopyProofMedia's
// fixtures) taken through the REAL ArchiveAngelJob — Verify Audio, Balance
// Audio, the access copy — and then the REAL BalancedCopyProof engine:
//
//   raw .dv (16-bit PCM, left only)  → a .mov copy: SAME CONTENT, the copy's
//                                      timecode track, container, track flags
//                                      and tags named
//   mov / ProRes + 16-bit PCM        → SAME CONTENT, tags and track flags named
//   mp4 / H.264 + AAC                → NOT PROVEN: the sound was re-encoded
//
// For each: the row is ready, its line is the outcome's line, the log has the
// engine's one START and one OUTCOME line, and the buffer's bytes after the
// proof are the bytes Prepare left before it (the proof writes nothing).
// The job's own outcome lines are printed for the record ("PROOF-LINE").

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — the proof after Prepare on real generated media", .serialized)
@MainActor
struct ArchiveAngelBalancedProofMediaTests {
    typealias B = BalancedProofBench
    typealias Media = BalancedCopyProofMedia

    struct Cell: Sendable, CustomTestStringConvertible {
        let wrapper: Media.Wrapper
        let videoCodec: String
        let audioCodec: String
        let verdict: String
        let line: String
        var testDescription: String { wrapper.rawValue }
    }

    nonisolated static let cells: [Cell] = [
        .init(wrapper: .rawDV, videoCodec: "dvvideo", audioCodec: "pcm_s16le", verdict: "same content",
              line: "Balanced copy: same content — differs in: track, container, playback instructions, metadata"),
        .init(wrapper: .movProResPCM16, videoCodec: "prores", audioCodec: "pcm_s16le", verdict: "same content",
              line: "Balanced copy: same content — differs in: playback instructions, metadata"),
        .init(wrapper: .mp4H264AAC, videoCodec: "h264", audioCodec: "aac", verdict: "not proven",
              line: "Balanced copy: not proven: the sound was re-encoded (aac) — the original is kept"),
    ]

    @Test("MATRIX: Prepare balances a one-sided file and the real proof reports on the copy — the row ready, the bytes untouched",
          .enabled(if: BalanceAudioTestMedia.toolsAvailable), .timeLimit(.minutes(6)), arguments: cells)
    func realProofAfterRealPrepare(_ cell: Cell) async throws {
        let b = try B.bench("proofmedia_\(cell.wrapper.rawValue)"); defer { b.sb.cleanup() }
        let path = try Media.original(in: b.sb.sources, cell.wrapper)
        let rec = B.record(path, videoCodec: cell.videoCodec, audioCodec: cell.audioCodec)
        b.model.records = [rec]
        let probe = BalancedProofProbe()
        let engine: ArchiveAngelBalancedProof.Prover = { original, balanced in
            let batchDir = URL(fileURLWithPath: balanced).deletingLastPathComponent().deletingLastPathComponent().path
            await probe.called(original, balanced, buffer: B.bufferDigest(batchDir))
            return try await ArchiveAngelBalancedProof.engine(original, balanced)
        }
        let job = await B.run(b, rec, customProver: engine)
        guard case .finished = job.state else { Issue.record("\(cell.wrapper): \(job.state) — \(job.plan.log.suffix(6))"); return }
        let entry = try #require(job.plan.entries.first)
        #expect(entry.status == .ready, "\(entry.status) \(entry.failure ?? "")")
        #expect(entry.step(.balanceAudio).state == .done, "\(entry.step(.balanceAudio).note)")
        let call = try #require(await probe.calls.first, "the proof never ran: \(job.plan.log.suffix(6))")
        #expect(call.original == path)
        #expect(URL(fileURLWithPath: call.balanced).pathExtension == (cell.wrapper == .rawDV ? "mov" : cell.wrapper.ext))
        #expect(entry.balancedCopyProof?.verdict == cell.verdict, "\(entry.balancedCopyProof?.line ?? "no line")")
        #expect(entry.balancedCopyProof?.line == cell.line)
        let proofLines = job.plan.log.filter { $0.hasPrefix("balanced copy proof:") }
        #expect(proofLines.count == 2 && proofLines.first == BalancedCopyProof.startLine(original: call.original, balanced: call.balanced))
        for line in proofLines { print("PROOF-LINE \(cell.wrapper.rawValue): \(line)") }
        print("PROOF-LINE \(cell.wrapper.rawValue) review: \(entry.balancedCopyProof?.line ?? "-")")
        let before = try #require(await probe.bufferBefore)
        #expect(!before.isEmpty && B.bufferDigest(job.plan.batchDir) == before, "the proof changed what Prepare wrote")
    }
}
