// AudioTroubleWords.swift
// What a stored "damaged" sound verdict really is, and the ONE table of its
// words (Rick 2026-11-25: "fix the wording — it helps when looking through
// vast numbers of files"). On the 1,043-file corpus sample 55 files read
// "damaged": 36 were QuickTime reference movies and 7 an old codec ffmpeg
// decodes. Neither is damage.
//
// Real damage stores "damaged" (red row); a reference movie or a sound that
// needs rebuilding stores "attention" (orange row; schema v1.16, DECISIONS
// 2026-11-27). All three meet the same gates: readiness, the copy-family
// pick, Repair…, and Promote's sound gate (refusal code sound-damaged) —
// `StoredAudioStatus.refusesLikeDamage`. The kind decides the WORDS and the
// tint only — the stored note, the Verify Audio sheet, the Check Media row,
// Promote's refusal detail, the Archive Angel line — so only real damage is
// called damaged, and only real damage is in the `notes:damaged` find.
// Rows stored "damaged" for the other two before 2026-11-27 stay red until
// the file is verified again.
//
// SEPARATOR RULE (VerifyAudioRules.damagedNotePrefix): a note is fragments
// joined by "; ", a lead's em dash separates it from its detail — so no
// detail here carries an em dash or a ";".
//
// Notes stored before 2026-11-25 ("Damaged audio — reference movie, media
// missing", "Damaged audio — invalid codec (qdm2)") are reworded where they
// are SHOWN (`displayNote`, `displaySoundSentence`); the stored data is
// untouched, so they stay in `notes:damaged` until the file is verified again.
// Only the reference-movie note is reworded: "invalid codec (<codec>)" is also
// what an old codec whose decode came up short is stored as TODAY (real
// damage), so it is shown as stored (Codex #372 closing).
//
// "Needs rebuilding" itself is only ever chosen after a COMPLETE decode
// (VerifyAudioRules.trouble(of:decodeComplete:)).
//
// Pure: strings in, strings out.

import Foundation

/// Worst first: in a mixed findings list the lowest case leads.
/// (For Rick: `Comparable` on the raw value ≈ an `enum class` with
/// `operator<` defined over its underlying int.)
enum AudioTrouble: Int, Sendable, Comparable, CaseIterable {
    /// Decoded and bad: the sound runs far shorter than the picture.
    case damaged
    /// A QuickTime reference movie: its picture and sound live in other files.
    case referenceMovie
    /// An old sound format Apple can't play that ffmpeg decodes:
    /// Rebuild Audio Track fixes it.
    case needsRebuild

    static func < (a: AudioTrouble, b: AudioTrouble) -> Bool { a.rawValue < b.rawValue }

    // MARK: The words table

    /// How the stored note leads (the `notes:` find keys on it).
    var noteLead: String {
        switch self {
        case .damaged: return "Damaged audio — "
        case .referenceMovie: return "Reference movie — "
        case .needsRebuild: return "Sound needs rebuilding — "
        }
    }

    /// What the file says about itself after the lead; nil for real damage,
    /// whose finding fragments follow instead. No em dash, no ";".
    func ownDetail(codec: String) -> String? {
        switch self {
        case .damaged:
            return nil
        case .referenceMovie:
            return "the picture and sound are stored in other files, so this file alone does not play"
        case .needsRebuild:
            return "\(codec.isEmpty ? "this sound format" : codec) does not play on Apple (Repair… ▸ Rebuild Audio Track fixes it)"
        }
    }

    /// The Verify Audio sheet's headline.
    var sheetHeadline: String {
        switch self {
        case .damaged:
            return "This file's audio is damaged — it's marked red in the catalog so you can find it again later."
        case .referenceMovie:
            return "This is a reference movie: its picture and sound are stored in other files, so this file alone does not play. Its row is marked orange in the catalog."
        case .needsRebuild:
            return "The sound needs rebuilding: it is stored in a format Apple can't play. Rebuild Audio Track below fixes it; its row stays orange in the catalog until then."
        }
    }

    /// Promote's refusal detail (the refusal CODE is sound-damaged for all
    /// three; PromoteSoundGate.decide). `what` is the gate's finding words.
    func refusalDetail(_ what: String) -> String {
        switch self {
        case .damaged:
            return "Not promoted — the sound is damaged: \(what). Right-click ▸ Repair… shows the fix. Nothing was copied."
        case .referenceMovie:
            return "Not promoted — this is a reference movie: \(what). Verify Audio lists the files it points to. Nothing was copied."
        case .needsRebuild:
            return "Not promoted — the sound needs rebuilding: \(what). Nothing was copied."
        }
    }

    /// Promote's path-free OUTCOME words.
    func refusalLog(_ what: String) -> String {
        switch self {
        case .damaged: return "damaged sound (\(what)); nothing written"
        case .referenceMovie: return "reference movie (\(what)); nothing written"
        case .needsRebuild: return "sound needs rebuilding (\(what)); nothing written"
        }
    }

    // MARK: Notes stored before 2026-11-25, as shown

    /// A stored note in today's words. A legacy "Damaged audio — " note
    /// whose leading trouble is a reference movie (and that carries no real
    /// damage) reads as one; every other note — "invalid codec (…)"
    /// included — is returned as stored. Display only.
    static func displayNote(_ stored: String) -> String {
        let prefix = AudioTrouble.damaged.noteLead
        guard stored.hasPrefix(prefix) else { return stored }
        var fragments = stored.dropFirst(prefix.count).components(separatedBy: "; ")
        guard !fragments.contains(where: { $0.hasPrefix(legacyShortAudioLead) }),
              let lead = legacyLead(fragments.removeFirst()) else { return stored }
        return ([lead] + fragments).joined(separator: "; ")
    }

    /// A Check Media Sound row sentence (or the card headline built from
    /// it, "Damaged sound: The sound is damaged: …") in today's words. Display only.
    static func displaySoundSentence(_ sentence: String) -> String {
        var body = sentence
        if body.hasPrefix(legacyCardHeadlineLead) { body.removeFirst(legacyCardHeadlineLead.count) }
        guard body.hasPrefix(legacySoundRowLead), body.hasSuffix(".") else { return sentence }
        let note = String(body.dropFirst(legacySoundRowLead.count).dropLast())
        let shown = displayNote(AudioTrouble.damaged.noteLead + note)
        return shown.hasPrefix(AudioTrouble.damaged.noteLead) ? sentence : shown + "."
    }

    /// The lead a legacy damage fragment becomes, or nil to show the note
    /// as stored. Only the reference movie: that fragment is unambiguous.
    /// "invalid codec (<codec>)" is NOT reworded — today's incomplete-decode
    /// note says exactly the same, so the words cannot tell a legacy note
    /// from real damage (Codex #372 closing): shown as stored until verified
    /// again.
    private static func legacyLead(_ fragment: String) -> String? {
        let reference = VerifyAudioRules.noteFragment(for: .referenceMovie(referencedPaths: []))
        return fragment == reference ? VerifyAudioRules.troubleLead(.referenceMovie(referencedPaths: [])) : nil
    }

    private static let legacyShortAudioLead = String(
        VerifyAudioRules.noteFragment(for: .durationMismatch(audioSeconds: 1, videoSeconds: 2)).prefix { $0 != "(" })
    /// How Check Media's Sound row names real damage (CheckMediaRules.checkSound).
    static let soundRowDamagedLead = "The sound is damaged: "
    private static let legacySoundRowLead = soundRowDamagedLead
    private static let legacyCardHeadlineLead = "Damaged sound: "
}
