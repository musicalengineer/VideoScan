// StoredAudioStatus.swift
// THE reading of a record's stored sound verdict (`audioVerifyStatus`) —
// every gate, row tint and sentence asks this, never the raw string
// (DECISIONS 2026-11-27, schema v1.16 `v12_audio_status`; GH #518).
//
//   ""            never verified (no row)
//   "ok"          measured in full, nothing that makes the sound unusable
//   "damaged"     real damage (sound far shorter than the picture)        RED
//   "attention"   a reference movie, or sound that needs rebuilding       ORANGE
//                 — not damage, but not usable as it stands: every gate
//                 (Promote readiness, Archive Angel, the keeper choice,
//                 Repair…) refuses it EXACTLY as it refuses "damaged"
//   "unverified"  a pre-fix "ok" WITHDRAWN by a re-measure that found the
//                 sound pass's filter graph rebuilt mid-stream: read as
//                 NEVER VERIFIED everywhere (a bound row, so the imported
//                 catalog.json "ok" cannot come back at relaunch)
//   anything else a value this build cannot read (a poisoned or newer
//                 catalog.json): FAIL CLOSED — never "verified", never shown
//                 as damage it may not be; it reads as never verified, so
//                 Prepare / Verify checks it again.
//
// Rows stored "damaged" for a reference movie or a needs-rebuild sound before
// 2026-11-27 stay as stored (red) until the file is verified again; a
// re-verify stores "attention". Their notes already name their own trouble.
//
// Pure: a string in, a value out.
// (For Rick: an `enum` parsed once from the stored text ≈ a C++ enum class
// with a from_string() factory; the predicates are the one switch every
// reader shares, so a new word cannot be half-handled.)

import VideoScanCore

enum StoredAudioStatus: Sendable, Equatable {
    case neverVerified
    case ok
    case damaged
    case attention
    case unverified
    /// A stored word this build does not know (kept for the log).
    case unreadable(String)

    init(_ stored: String) {
        switch stored {
        case "": self = .neverVerified
        case CatalogDDL.AudioCheckStatus.ok.rawValue: self = .ok
        case CatalogDDL.AudioCheckStatus.damaged.rawValue: self = .damaged
        case CatalogDDL.AudioCheckStatus.attention.rawValue: self = .attention
        case CatalogDDL.AudioCheckStatus.unverified.rawValue: self = .unverified
        default: self = .unreadable(stored)
        }
    }

    /// The stored words (the writer's side).
    static let okWord = CatalogDDL.AudioCheckStatus.ok.rawValue
    static let damagedWord = CatalogDDL.AudioCheckStatus.damaged.rawValue
    static let attentionWord = CatalogDDL.AudioCheckStatus.attention.rawValue
    static let unverifiedWord = CatalogDDL.AudioCheckStatus.unverified.rawValue

    /// Not usable as it stands: every gate refuses it as damage. "damaged"
    /// and "attention" alike — the WORDS differ (the note names the trouble),
    /// the gate does not.
    var refusesLikeDamage: Bool { self == .damaged || self == .attention }

    /// The ONE "this sound was checked and stands" answer: only "ok".
    var isVerifiedOK: Bool { self == .ok }

    /// A verdict a measurement stands behind (ok, damaged, attention).
    /// "unverified" and anything unreadable are not — they read as never
    /// verified.
    var isMeasuredVerdict: Bool { self == .ok || refusesLikeDamage }

    /// Reads as never verified: no row, withdrawn, or unreadable.
    var readsAsNeverVerified: Bool { !isMeasuredVerdict }

    /// The row tint tier: red for damage, orange for attention.
    enum Tint: Sendable, Equatable { case none, attention, damaged }
    var tint: Tint {
        switch self {
        case .damaged: return .damaged
        case .attention: return .attention
        case .neverVerified, .ok, .unverified, .unreadable: return .none
        }
    }

    /// The status word File Journey prints ("Sound check: <word> — <note>").
    var journeyWord: String {
        switch self {
        case .neverVerified: return "not verified"
        case .ok: return "ok"
        case .damaged: return "damaged"
        case .attention: return "needs attention"
        case .unverified: return "withdrawn"
        case .unreadable(let word): return "unreadable value (\(word))"
        }
    }

    /// The catalog row tooltip's sound line, or nil when the status says
    /// nothing worth a warning. A "damaged" / "attention" note is shown in
    /// today's words (`AudioTrouble.displayNote`; an "attention" note names
    /// its own trouble); a withdrawn verdict says it is not verified.
    func tooltipLine(note: String) -> String? {
        switch self {
        case .damaged, .attention: return note.isEmpty ? "Damaged audio" : AudioTrouble.displayNote(note)
        case .unverified: return Self.unverifiedWords
        case .neverVerified, .ok, .unreadable: return nil
        }
    }

    /// What a reader shows for a withdrawn verdict (Catalog tooltip, File
    /// Journey, Archive Angel): it is NOT verified. No em dash, no ";".
    static let unverifiedWords = "Sound not verified: an earlier check said ok, but a re-measure found the sound changes partway, so Verify Audio checks it again"
}
