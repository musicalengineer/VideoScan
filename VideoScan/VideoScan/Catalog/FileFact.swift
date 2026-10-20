// FileFact.swift
// The truth contract (GH #327; docs/design/integrity_first_2026_10_16.md §5):
// a fact a surface shows about a file carries the evidence it came from and
// when that evidence was taken. "Unknown" is a legal value; a guess is not.
//
//   FileFact { value, evidence, asOf }
//   evidence ∈ stat · sha256 · archiveFixity · soundPrint · ffprobe ·
//              avfoundation · catalogField (unverified)
//
// `CatalogFileFacts` is the catalog table's Stream and Size columns (and the
// inspector's stream chip) built on it: the column text is `value`, the
// tooltip is `help` — which always names the evidence word. Pure, O(1) per
// record, safe in a cell.
//
// (For Rick: a struct of three fields ≈ a C++ POD; the enum's raw value is
// a fixed string, like an `enum class` with a name table.)

import Foundation
import VideoScanCore

struct FileFact: Equatable, Sendable {

    /// Where the value came from.
    enum Evidence: String, CaseIterable, Sendable {
        case stat, sha256, archiveFixity, soundPrint, ffprobe, avfoundation, catalogField

        /// The words a tooltip uses for this evidence.
        var word: String {
            switch self {
            case .stat: return "checked on disk"
            case .sha256: return "whole-file SHA-256"
            case .archiveFixity: return "archive fixity (SHA-256)"
            case .soundPrint: return "the sound print"
            case .ffprobe: return "ffprobe at scan"
            case .avfoundation: return "AVFoundation"
            case .catalogField: return "catalog record, not re-checked on disk"
            }
        }
    }

    let value: String
    let evidence: Evidence
    /// When the evidence was taken; nil = the catalog does not know.
    let asOf: Date?

    /// "<value> — <evidence word>, <date>" — what a tooltip shows. Every
    /// shown FileFact names its evidence; this is the one place that says it.
    var help: String {
        let when = asOf.map { ", " + Self.day.string(from: $0) } ?? ""
        return "\(value) — \(evidence.word)\(when)"
    }

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

enum CatalogFileFacts {

    /// The Stream column / inspector chip. The header's stream layout is an
    /// ffprobe fact; it never says "has sound" on its own (§2 rule 4). When
    /// the row's sound print — made from THIS file (same size) — heard
    /// nothing, the value says so and the evidence is the sound print.
    static func stream(_ rec: VideoRecord) -> FileFact {
        let header = rec.streamType == .ffprobeFailed ? rec.isPlayable : rec.streamTypeRaw
        let scanned = rec.scanContext.scannedAt
        guard rec.streamType == .videoAndAudio || rec.streamType == .audioOnly,
              let stamp = rec.audioFingerprint, stamp.sizeBytes == rec.sizeBytes,
              let silence = silenceWords(stamp) else {
            return FileFact(value: header, evidence: .ffprobe, asOf: scanned)
        }
        return FileFact(value: "\(header) · \(silence)", evidence: .soundPrint, asOf: stamp.computedAt)
    }

    /// The Size column: the bytes the scan recorded. Not a stat now.
    static func size(_ rec: VideoRecord) -> FileFact {
        FileFact(value: rec.sizeDisplay, evidence: .catalogField, asOf: rec.scanContext.scannedAt)
    }

    /// True when the stream fact says the sound print heard nothing.
    static func isSilent(_ fact: FileFact) -> Bool {
        fact.evidence == .soundPrint
    }

    /// What the stamp heard, when it contradicts an audio header; nil when
    /// it heard sound or cannot say. Only MEASURED silence is "silent"
    /// (`AudioFingerprintStamp.Hearing.measuredSilence`: stamp rule 4, every
    /// analysed second quiet). A pre-4 zero-landmark print may have heard
    /// real sound too short to print (8 AVCHD clips, 2026-10-20), and a
    /// `.noAudio` stamp on an audio header is never read as silence either
    /// (an engine-2 one may be a failed decode) — both say nothing here.
    static func silenceWords(_ stamp: AudioFingerprintStamp) -> String? {
        // Only reached for an audio header (see `stream`), so headerHasAudio.
        stamp.hearing(headerHasAudio: true) == .measuredSilence ? "silent" : nil
    }
}
