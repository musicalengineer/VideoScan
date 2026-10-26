// FindMasterAnswer.swift — Provenance ▸ Find Master (by sound), the WORDS.
// Design: docs/design/provenance_retroactive_2026_10_26.md §Phase A.
//
// ONE SENTENCE: every sentence and log line the job shows or writes, as pure
// functions of the evidence, so the truth tests can read them directly.
//
// Rules the sentences keep (truth tests: FindMasterAnswerTests):
//   • every positive answer carries its verdict, the time span, the offset,
//     the coverage, the matching-landmark count and "sound" as the proof;
//   • geometry only — "inside", "contains", "same recording", "shares".
//     Never which copy is the original or "the master" (ruling 2026-09-23:
//     similarity never creates lineage; the menu name is Rick's to change);
//   • a negative says what was searched, and how many contents could not
//     be (no sound track, not fingerprinted);
//   • a refusal names its reason and the action that would lift it.

import Foundation
import VideoScanCore

enum FindMasterAnswer {

    // MARK: Refusals

    static func refusal(_ reason: FindMasterRefusalReason) -> String {
        switch reason {
        case .notHashed:
            return "Not hashed yet — run Fill In Full Hashes; a sampled hash is not identity."
        case .noSoundPrint:
            return "No sound print yet — run Fingerprint Sound."
        case .noSound:
            return "No sound to match. Picture matching comes with the picture timeline (Phase B)."
        case .tooLittleSound(let landmarks):
            return "Too little sound to match (\(landmarks) landmarks; \(AudioMatchPolicy.default.minMatchedLandmarks) needed)."
        case .olderRecipe:
            return "Its sound print is from an older recipe — re-run Fingerprint Sound."
        }
    }

    /// A refusal the finder made after the print was loaded.
    static func reason(for refusal: AudioMasterRefusal) -> FindMasterRefusalReason {
        switch refusal {
        case .otherRecipe: return .olderRecipe
        case .tooLittleSound(let landmarks): return .tooLittleSound(landmarks: landmarks)
        }
    }

    // MARK: Negatives

    static func noneFound(searched: Int, noSoundTrack: Int, notFingerprinted: Int) -> String {
        "No content shares its sound (searched \(searched.formatted()) sounded contents; "
            + "\(noSoundTrack.formatted()) have no sound track; \(notFingerprinted.formatted()) not fingerprinted)."
    }

    // MARK: Positives

    /// One found content, in words. `other` names it ("Cape-1993.mkv"),
    /// with its removal state when it is not live.
    static func sentence(_ c: AudioMasterCandidate, other: String) -> String {
        let m = c.match
        let e = m.evidence
        let evidence = String(format: "offset %.1f s, coverage %.2f, %@ matching landmarks; proof: sound",
                              e.offsetSeconds, e.coverage, m.matchedLandmarks.formatted())
        switch m.verdict {
        case .sameRecording:
            return "Same recording as \(other), \(span(0, e.queryDurationSeconds)) (\(evidence))."
        case .containedInMaster:
            return "This file's sound is inside \(other) from \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) (\(evidence))."
        case .masterContainedInQuery:
            // The other file's sound, placed on THIS file's timeline.
            let start = m.spanStartInMasterSeconds - e.offsetSeconds, end = m.spanEndInMasterSeconds - e.offsetSeconds
            return "Contains the sound of \(other), here from \(span(start, end)) (\(evidence))."
        case .overlap(_, let seconds):
            return "Shares \(Int(seconds.rounded())) s of sound with \(other), at \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) of it (\(evidence))."
        case .inconclusive(let reason):
            return "Sound lines up with \(other) at \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) of it, but no verdict can be given — \(words(reason)) (\(evidence))."
        case .different:
            return "Different from \(other) (\(evidence))."
        }
    }

    /// How a found content is named: its label, or its digest when no
    /// record in the catalog list carries it.
    static func name(of key: AudioFingerprintStore.Key, label: FindMasterLabel?) -> String {
        guard let label else { return "\(shortDigest(key.contentDigest)) (not in the catalog list)" }
        var parts = [label.name]
        if label.isArchived { parts.append("archived") }
        switch label.removal {
        case .inTrash?: parts.append("In the Trash")
        case .missing?: parts.append("Missing")
        case .removedFromCatalog?: parts.append("removed from the catalog")
        case nil: break
        }
        return parts.count == 1 ? label.name : "\(label.name) (\(parts.dropFirst().joined(separator: ", ")))"
    }

    static func words(_ reason: AudioMatchInconclusiveReason) -> String {
        switch reason {
        case .incompatibleRecipe: return "the two prints were made by different recipes"
        case .queryIncomplete: return "only part of this file was analysed"
        case .masterIncomplete: return "only part of the other file was analysed"
        case .bothIncomplete: return "only part of each file was analysed"
        }
    }

    /// "00:12:40–00:13:20".
    static func span(_ start: Double, _ end: Double) -> String {
        "\(timecode(start))–\(timecode(end))"
    }

    static func timecode(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func shortDigest(_ digest: String) -> String {
        String(digest.prefix(15)) + "…"
    }

    /// Short verdict word for the detail list's chip.
    static func chip(_ verdict: AudioMatchVerdict) -> String {
        switch verdict {
        case .sameRecording: return "same recording"
        case .containedInMaster: return "inside"
        case .masterContainedInQuery: return "contains"
        case .overlap: return "shares"
        case .inconclusive: return "inconclusive"
        case .different: return "different"
        }
    }

    // MARK: Log lines (the one sink: catalog.log, videoscan.log, OSLog)

    static func startLine(files: Int) -> String {
        "START find master — \(files.formatted()) file(s); sound index from \(AudioFingerprintStore.fileName)"
    }

    static func indexLine(_ r: AudioCatalogIndex.BuildReport, seconds: Double) -> String {
        String(format: "find master: sound index — %@ contents, %@ landmarks, %.1f s (skipped: %@ sampled-hash keys, %@ older recipe, %@ too little sound, %@ unreadable)",
               r.indexed.formatted(), r.landmarks.formatted(), seconds, r.notWholeFileKey.formatted(),
               r.otherRecipe.formatted(), r.tooFewLandmarks.formatted(), r.unreadable.formatted())
    }

    static func queryLine(name: String, key: AudioFingerprintStore.Key, answer: String) -> String {
        "find master: \(name) \(shortDigest(key.contentDigest)) → \(answer)"
    }

    static func refusalLine(name: String, reason: FindMasterRefusalReason) -> String {
        "find master: \(name) → refused — \(refusal(reason))"
    }

    struct Tally: Equatable, Sendable {
        var searched = 0, inside = 0, same = 0, contains = 0, shares = 0, inconclusive = 0, none = 0
        var refused = 0, notStarted = 0
        var stopped = false
    }

    /// The one-line summary (row subtitle, OUTCOME line).
    static func summary(_ t: Tally, seconds: Double) -> String {
        var parts = ["\(t.searched) searched", "\(t.inside) found inside another", "\(t.same) same recording"]
        if t.contains > 0 { parts.append("\(t.contains) contain another") }
        if t.shares > 0 { parts.append("\(t.shares) share sound") }
        if t.inconclusive > 0 { parts.append("\(t.inconclusive) inconclusive") }
        parts.append("\(t.none) none found")
        parts.append("\(t.refused) refused")
        if t.stopped { parts.append("\(t.notStarted) not started") }
        let head = t.stopped ? "stopped — " : ""
        return head + parts.joined(separator: " · ") + String(format: " · %.1f s", seconds)
    }

    static func outcomeLine(_ t: Tally, seconds: Double) -> String {
        "OUTCOME find master — " + summary(t, seconds: seconds)
    }
}
