// DossierFailureNotes.swift
// Why a file's analysis failed, in the decoder's own words, kept just long
// enough for the per-file Analyze job to put it on its MFO row and OUTCOME
// line (2026-11-06: Analyze reads legacy codecs through ffmpeg; a file
// nothing can decode is reported per file with the decoder's reason, never
// "run Reformat first").
//
// The dossier loop records a note when a file's extraction throws; the
// AnalyzeJob that owns that file takes it once its single-file batch
// settles. Keyed by path because the loop and the job share nothing else.
//
// Bounded: at most `capacity` notes; the oldest is dropped first, so a long
// volume batch of failures (which no job takes) cannot grow it. Worst case
// ≈ capacity × (path + one reason line) ≈ 256 × ~1 KB = ~256 KB.
// (A plain value type: ≈ a C++ struct holding a small FIFO + map.)

import Foundation

struct DossierFailureNotes {
    let capacity: Int
    private var reasons: [String: String] = [:]
    private var order: [String] = []

    init(capacity: Int = 256) {
        self.capacity = max(1, capacity)
    }

    var count: Int { reasons.count }

    /// Remember why `path` failed (replaces an older note for the same path).
    mutating func record(path: String, reason: String) {
        if reasons.updateValue(reason, forKey: path) != nil {
            order.removeAll { $0 == path }
        }
        order.append(path)
        while order.count > capacity {
            reasons[order.removeFirst()] = nil
        }
    }

    /// The note for `path`, removed — a note is reported once.
    mutating func take(path: String) -> String? {
        guard let reason = reasons.removeValue(forKey: path) else { return nil }
        order.removeAll { $0 == path }
        return reason
    }
}
