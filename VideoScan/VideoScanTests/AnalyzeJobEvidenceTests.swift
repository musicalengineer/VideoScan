// AnalyzeJobEvidenceTests.swift — Codex sweep 2026-11-09 (cycle #262):
//   F4 P0  Generate Scene Captions, then Transcribe Audio: the second job is
//          skipped ("already analyzed" — any dossier stamp) and its row said
//          "Transcribe complete — transcript banked." with no transcript.
//   F3 P0  a transcription that failed still banked the dossier stamp and
//          the row said "transcript banked".
// The row's last words now come from what THIS run wrote (AnalyzeJobEvidence).
// LOGIC (a table) + TRUTH (each claim checked against the record's dates).
// Scale / media matrix: not applicable (three dates, two flags; no media read).

import Foundation
import Testing
@testable import VideoScan

@Suite("Analyze row — the last words come from this run's evidence (Codex sweep 11/09 F3/F4)")
struct AnalyzeJobEvidenceTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var before: Date { start.addingTimeInterval(-86_400) }
    private var during: Date { start.addingTimeInterval(30) }

    private func facts(dossier: Date? = nil, captions: Date? = nil, transcript: Date? = nil,
                       noAudio: Bool = false, noVideo: Bool = false) -> AnalyzeJobEvidence.Facts {
        AnalyzeJobEvidence.Facts(dossierProcessedAt: dossier, sceneCaptionDate: captions, audioTranscriptDate: transcript,
                                 hasNoAudio: noAudio, hasNoVideo: noVideo)
    }

    private func verdict(_ stages: Set<AnalyzeStage>, _ f: AnalyzeJobEvidence.Facts?, reason: String? = nil) -> AnalyzeJobEvidence.Verdict {
        AnalyzeJobEvidence.verdict(stages: stages, startedAt: start, facts: f, decoderReason: reason)
    }

    @Test("RED F4: Transcribe Audio on a file captioned EARLIER (skipped, no transcript) never says 'transcript banked'")
    func skippedTranscribeIsNotBanked() {
        let v = verdict([.transcript], facts(dossier: before, captions: before))
        guard case .failed(let words) = v else { Issue.record("said success: \(v)"); return }
        #expect(words.contains("did not run") && words.contains("transcript"), Comment(rawValue: words))
    }

    @Test("RED F4: Generate Scene Captions on a file transcribed EARLIER (skipped) never says 'scene captions banked'")
    func skippedCaptionsAreNotBanked() {
        let v = verdict([.captions], facts(dossier: before, transcript: before))
        guard case .failed(let words) = v else { Issue.record("said success: \(v)"); return }
        #expect(words.contains("did not run") && words.contains("scene captions"), Comment(rawValue: words))
    }

    @Test("RED F3: the transcriber failed this run (dossier stamped, no transcript) → failed, never 'transcript banked'")
    func failedTranscriptionIsNotBanked() {
        let v = verdict([.transcript], facts(dossier: during, captions: during), reason: nil)
        guard case .failed(let words) = v else { Issue.record("said success: \(v)"); return }
        #expect(words.contains("no transcript"), Comment(rawValue: words))
        // Analyze (both): captions made, transcript not — says exactly that, never "captions and transcript banked".
        let both = verdict(AnalyzeStage.all, facts(dossier: during, captions: during))
        #expect(both == .success("Analyze complete — scene captions banked; no transcript — see the log for why."), "\(both)")
    }

    @Test("success only on this run's writes; a stream with nothing to do says so")
    func successNeedsThisRunsWrites() {
        #expect(verdict([.transcript], facts(dossier: during, transcript: during)) == .success("Transcribe complete — transcript banked."))
        #expect(verdict([.captions], facts(dossier: during, captions: during)) == .success("Captions complete — scene captions banked."))
        #expect(verdict(AnalyzeStage.all, facts(dossier: during, captions: during, transcript: during))
                == .success("Analyze complete — captions and transcript banked."))
        // Audio-only file: captions do not apply; a transcript written now is the whole job.
        #expect(verdict(AnalyzeStage.all, facts(dossier: during, transcript: during, noVideo: true))
                == .success("Analyze complete — transcript banked (an audio file has no picture to caption)."))
        // Video-only file: nothing to transcribe — said, not "banked".
        let silent = verdict([.transcript], facts(dossier: before, captions: before, noAudio: true))
        #expect(silent == .success("Transcribe: nothing to transcribe — the file has no audio track."))
    }

    @Test("the decoder's reason and the empty batch keep their words; a vanished row is no success")
    func failuresKeepTheirWords() {
        #expect(verdict([.captions], facts(), reason: "dvvideo codec type mismatch")
                == .failed("Captions could not read this file — dvvideo codec type mismatch"))
        #expect(verdict([.transcript], facts()) == .failed("Transcribe finished but no dossier was banked — see the log for why."))
        #expect(verdict(AnalyzeStage.all, nil) == .failed("Analyze finished but no dossier was banked — see the log for why."))
    }
}
