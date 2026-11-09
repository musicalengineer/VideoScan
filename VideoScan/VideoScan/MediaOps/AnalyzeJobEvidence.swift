// AnalyzeJobEvidence.swift — how an Analyze / Transcribe Audio / Generate
// Scene Captions row ends: from what THIS run left on the record, never from
// a stamp an earlier run wrote (CLAUDE.md rule 1; Codex sweep 2026-11-09,
// cycle #262 F3/F4).
//
// One sentence: the row says "transcript banked" only when a transcript was
// written by this run, "scene captions banked" only when captions were.
//
// Pure: the record's three dates and two stream facts in, the row's last
// words out — a table test (AnalyzeJobEvidenceTests). Memory: a few values.
// (For Rick: an enum with only static funcs ≈ a C++ namespace of free functions.)

import Foundation

enum AnalyzeJobEvidence {

    /// The record's evidence, read once when the batch settles.
    struct Facts: Equatable {
        var dossierProcessedAt: Date?
        var sceneCaptionDate: Date?
        var audioTranscriptDate: Date?
        /// Video-only stream: nothing to transcribe.
        var hasNoAudio: Bool
        /// Audio-class file: no picture to caption.
        var hasNoVideo: Bool

        init(dossierProcessedAt: Date?, sceneCaptionDate: Date?, audioTranscriptDate: Date?, hasNoAudio: Bool, hasNoVideo: Bool) {
            self.dossierProcessedAt = dossierProcessedAt
            self.sceneCaptionDate = sceneCaptionDate
            self.audioTranscriptDate = audioTranscriptDate
            self.hasNoAudio = hasNoAudio
            self.hasNoVideo = hasNoVideo
        }

        @MainActor
        init(_ record: VideoRecord) {
            self.init(dossierProcessedAt: record.dossierProcessedAt, sceneCaptionDate: record.sceneCaptionDate,
                      audioTranscriptDate: record.audioTranscriptDate, hasNoAudio: record.streamType == .videoOnly,
                      hasNoVideo: CaptionOrchestrator.isAudioClass(record))
        }
    }

    enum Verdict: Equatable {
        case success(String)
        case failed(String)
    }

    static func badge(_ stages: Set<AnalyzeStage>) -> String {
        switch stages {
        case [.transcript]: return "Transcribe"
        case [.captions]: return "Captions"
        default: return "Analyze"
        }
    }

    /// The channels a run of `stages` must leave on this file (a channel
    /// that does not apply — captions on an audio file, a transcript on a
    /// video-only one — is not asked), and which of them this run wrote.
    struct Asked {
        let captions: Bool
        let transcript: Bool

        init(_ stages: Set<AnalyzeStage>, _ f: Facts) {
            captions = stages.contains(.captions) && !f.hasNoVideo
            transcript = stages.contains(.transcript) && !f.hasNoAudio
        }

        var isEmpty: Bool { !captions && !transcript }

        /// The asked channels whose date is (`written`) / is not at or after `start`.
        func channels(_ f: Facts, since start: Date, written: Bool) -> [String] {
            let thisRun = { (d: Date?) in (d.map { $0 >= start } ?? false) == written }
            return (captions && thisRun(f.sceneCaptionDate) ? ["scene captions"] : [])
                + (transcript && thisRun(f.audioTranscriptDate) ? ["transcript"] : [])
        }
    }

    static func verdict(stages: Set<AnalyzeStage>, startedAt: Date, facts: Facts?, decoderReason: String?) -> Verdict {
        let badge = badge(stages)
        let empty = Verdict.failed("\(badge) finished but no dossier was banked — see the log for why.")
        guard let f = facts else { return empty }
        let asked = Asked(stages, f)
        if asked.isEmpty {
            // The file has nothing this verb can read: said, never "banked".
            return .success(f.hasNoAudio ? "\(badge): nothing to transcribe — the file has no audio track."
                                         : "\(badge): nothing to caption — an audio file has no picture.")
        }
        let missing = asked.channels(f, since: startedAt, written: false)
        if missing.isEmpty { return .success(successWords(stages, facts: f)) }
        if let decoderReason { return .failed("\(badge) could not read this file — \(decoderReason)") }
        return unfinished(badge: badge, missing: missing, made: asked.channels(f, since: startedAt, written: true),
                          dossier: f.dossierProcessedAt, startedAt: startedAt) ?? empty
    }

    /// Some asked channel is missing. Skipped by an earlier run's dossier
    /// (F4), or banked this run without it (F3: the transcriber failed or is
    /// not installed) — what WAS made is said; nothing made is a failure.
    private static func unfinished(badge: String, missing: [String], made: [String], dossier: Date?, startedAt: Date) -> Verdict? {
        guard let dossier else { return nil }
        let what = missing.joined(separator: " or ")
        if dossier < startedAt {
            return .failed("\(badge) did not run — the file already has a dossier from "
                           + "\(dossier.formatted(date: .abbreviated, time: .shortened)), so it was skipped; no \(what) was made.")
        }
        if !made.isEmpty {
            return .success("\(badge) complete — \(made.joined(separator: " and ")) banked; no \(what) — see the log for why.")
        }
        return .failed("\(badge) finished with no \(what) — see the log for why.")
    }

    private static func successWords(_ stages: Set<AnalyzeStage>, facts f: Facts) -> String {
        switch stages {
        case [.transcript]: return "Transcribe complete — transcript banked."
        case [.captions]: return "Captions complete — scene captions banked."
        default:
            if f.hasNoVideo { return "Analyze complete — transcript banked (an audio file has no picture to caption)." }
            if f.hasNoAudio { return "Analyze complete — scene captions banked (the file has no audio track)." }
            return "Analyze complete — captions and transcript banked."
        }
    }
}
