// CaptionOrchestrator+DegenerateRefusal.swift
// GH #402: the one gate between a runner's output and the catalog
// writeback. A degenerate generation (the 3B captioner's `!!!!…` loop) is
// not an observation (rule 1): it is counted as schemaInvalid, logged by
// count, and never handed to applyCaptions / applyDossier. The rule itself
// is pure and lives in Core (`CaptionTextQuality`).
//
// Stamp semantics are unchanged on purpose: the file still goes through
// the writeback with whatever survived, so a file whose every date reading
// was refused is stamped `dossierProcessedAt` exactly like one whose model
// answered "NONE" (the runner already drops NONE). A refused generation
// therefore never makes a batch retry the file forever.
//
// Memory: one filtered copy of the file's caption arrays (≤ frames × 3
// small strings); nothing retained past the call.

import Foundation

extension CaptionOrchestrator {

    /// The dossier extraction with every degenerate caption removed, on all
    /// three channels. Logs ONE line per file when anything was refused.
    func refuseDegenerate(_ extraction: DossierExtraction,
                          filename: String, modelID: String) -> DossierExtraction {
        let scenes = CaptionTextQuality.partition(extraction.scenes)
        let dates = CaptionTextQuality.partition(extraction.dates)
        let texts = CaptionTextQuality.partition(extraction.texts)
        let refused: [(kind: String, frames: Int)] = [
            ("scene", scenes.refused), ("ocrDate", dates.refused), ("ocrText", texts.refused),
        ].filter { $0.frames > 0 }
        guard !refused.isEmpty else { return extraction }
        noteRefused(refused, filename: filename, modelID: modelID)
        return DossierExtraction(scenes: scenes.kept, dates: dates.kept, texts: texts.kept)
    }

    /// The single-prompt pass's scene captions with degenerate ones removed.
    func refuseDegenerate(_ captions: [SceneCaption],
                          filename: String, modelID: String) -> [SceneCaption] {
        let scenes = CaptionTextQuality.partition(captions)
        guard scenes.refused > 0 else { return captions }
        noteRefused([("scene", scenes.refused)], filename: filename, modelID: modelID)
        return scenes.kept
    }

    private func noteRefused(_ refused: [(kind: String, frames: Int)], filename: String, modelID: String) {
        liveDegenerateRefused += refused.reduce(0) { $0 + $1.frames }
        appLog.write(Self.degenerateRefusalLine(refused, modelID: modelID, filename: filename))
    }

    /// The per-file log line. Counts and kinds only — never the refused text
    /// (log privacy, same rule as the coverage line). `nonisolated static`
    /// so tests can pin it without a batch. (≈ a C++ free function.)
    nonisolated static func degenerateRefusalLine(_ refused: [(kind: String, frames: Int)],
                                                  modelID: String, filename: String) -> String {
        let parts = refused.map { "kind=\($0.kind) frames=\($0.frames)" }.joined(separator: ", ")
        return "[captions] degenerate output refused — \(parts) model=\(modelID) — \(filename)"
    }
}
