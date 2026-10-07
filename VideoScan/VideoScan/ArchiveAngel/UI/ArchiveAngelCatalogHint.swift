// ArchiveAngelCatalogHint.swift
// "Ready for archive" in the Catalog's file list (Rick 2026-10-06): a file
// the Archive Angel has picked AND that is ready to go shows a light-green
// capsule; a file it picked that still needs something shows a neutral
// "Angel pick" capsule whose tooltip says what is missing.
//
// WHAT "READY" MEANS — nothing new is judged here; it is exactly what the
// Angel's own list calls "Ready to archive" (ArchiveAngelStatusWords.isReady),
// so the Catalog and the Archive tab can never disagree:
//   1. the EFFECTIVE class is `.ready` (ArchiveAngelRecommendationSummary.
//      effective): the rules picked it (passes the floors — rules v15's
//      `noSound` among them: no sound track, silent or damaged audio is
//      never picked unless the policy allows silent footage — someone vouched
//      or grade A, dated to the rule's precision), it is NOT in a prepared
//      batch, NOT promoted by a batch, and live-recommendable right now —
//      not purged / set aside / superseded, and Promote would not refuse it
//      (`isRecommendableNow` → `promoteWouldRefusePermanently`: not already
//      an archive copy, not inside the Master Archive, no archive copy yet);
//   2. no needs (ArchiveAngelStatusWords.needs over ArchiveReadiness.assess):
//      sound verified (or no sound track), not damaged, picture not broken
//      or flagged, and the date is not missing.
//
// PURE and nonisolated: the façade snapshots `Input`s on the main actor
// (O(picks) field copies) and calls `build` OFF the main actor
// (ArchiveAngel+CatalogHints.swift). Never called from a view body.
// Worst case at 100k picks: one ~200-byte Hint (two short strings) per pick
// in the result dictionary, ~25 MB transient for the inputs — bounded by the
// pick set, never by media size; no file is opened.
//
// (For Rick: `Sendable` ≈ "safe to hand to another thread by value" — the
// compiler checks every field is a value or immutable, like a POD struct you
// can memcpy across threads.)

import Foundation
import VideoScanCore

/// One Catalog row's Angel hint, computed off the main actor.
struct ArchiveAngelCatalogHint: Equatable, Sendable {
    /// The effective class this hint was computed under. The façade only
    /// shows the hint while the record's class still matches (a purge or a
    /// Prepare between recount and hint never shows a stale "Ready").
    let kind: ArchiveAngelRecommendationClass
    /// Ready for archive (see the file header for the exact rule).
    let isReady: Bool
    /// The tooltip — why it is ready, or what it still needs. Family words.
    let help: String

    static let readyText = "Ready for archive"
    static let pickText = "Angel pick"

    var text: String { isReady ? Self.readyText : Self.pickText }

    /// What the façade snapshots from a live record, on the main actor.
    struct Input: Sendable {
        var id: UUID
        var kind: ArchiveAngelRecommendationClass
        var filename: String
        var readiness: ArchiveReadiness.Inputs
        var videoVerifyStatus: String = ""
        var videoVerifyNote: String = ""
        /// The Angel's own why-lines ("You rated it best (★★★)", "Donna (confirmed)").
        var pickLines: [String] = []
    }

    // MARK: Pure build

    /// One hint per input, keyed by record id. O(n), off the main actor.
    static func build(_ inputs: [Input]) -> [UUID: ArchiveAngelCatalogHint] {
        var out: [UUID: ArchiveAngelCatalogHint] = [:]
        out.reserveCapacity(inputs.count)
        for input in inputs { out[input.id] = make(input) }
        return out
    }

    static func make(_ i: Input) -> ArchiveAngelCatalogHint {
        let readiness = ArchiveReadiness.assess(i.readiness)
        var f = ArchiveAngelRowFacts(id: i.id, filename: i.filename, fullPath: "", kind: i.kind)
        f.audio = readiness.audio
        f.audioVerifyStatus = i.readiness.audioVerifyStatus
        f.audioVerifyNote = i.readiness.audioVerifyNote
        f.date = readiness.date
        f.videoVerifyStatus = i.videoVerifyStatus
        f.videoVerifyNote = i.videoVerifyNote
        let needs = ArchiveAngelStatusWords.needs(f)
        let ready = ArchiveAngelStatusWords.isReady(kind: i.kind, needs: needs)
        let help = ready
            ? readyHelp(i, audio: readiness.audio)
            : pickHelp(i, words: ArchiveAngelStatusWords.words(f, needs: needs))
        return ArchiveAngelCatalogHint(kind: i.kind, isReady: ready, help: help)
    }

    // MARK: Words

    /// "Ready for archive — Archive Angel picked this one." + why, date, sound.
    static func readyHelp(_ i: Input, audio: ArchiveReadiness.Audio) -> String {
        var lines = ["Ready for archive — Archive Angel picked this one and it has everything it needs."]
        if let why = whyLine(i) { lines.append(why) }
        lines.append(dateLine(i.readiness))
        lines.append(audio == .noAudioTrack ? "Sound: this file has no sound track." : "Sound: checked.")
        lines.append("Not in the family archive yet — Promote to Archive copies it in; the original is never changed.")
        return lines.joined(separator: "\n")
    }

    /// "Angel pick — Archive Angel picked this one, but it is not ready yet."
    static func pickHelp(_ i: Input, words: String) -> String {
        var lines = ["Angel pick — Archive Angel picked this one, but it is not ready yet.",
                     "Still to do: " + stillToDo(words) + "."]
        if let why = whyLine(i) { lines.append(why) }
        return lines.joined(separator: "\n")
    }

    /// "Needs a date and audio checked" → "a date and audio checked"; a
    /// "Needs a look" pick reads "a look from you".
    static func stillToDo(_ words: String) -> String {
        let body = words.hasPrefix("Needs ") ? String(words.dropFirst("Needs ".count)) : words
        return body == "a look" ? "a look from you" : body
    }

    static func whyLine(_ i: Input) -> String? {
        let why = i.pickLines.prefix(3).joined(separator: " · ")
        return why.isEmpty ? nil : "Why: " + why
    }

    /// "Date: July 1994, from the camera's own date stamp."
    static func dateLine(_ r: ArchiveReadiness.Inputs) -> String {
        let res = RecordDateResolver.resolve(userDate: r.userDate,
                                             userDateConfidence: r.userDateConfidence,
                                             embeddedCreationDate: r.embeddedCreationDate,
                                             originMake: r.originMake,
                                             originModel: r.originModel,
                                             originEncoder: r.originEncoder,
                                             inferredRecordDate: r.inferredRecordDate,
                                             inferredDateConfidence: r.inferredDateConfidence,
                                             inferredDateRange: r.inferredDateRange,
                                             filename: r.filename.isEmpty ? nil : r.filename)
        guard res.precision != .unknown else { return "Date: not known yet." }
        return "Date: \(UserDateEntry.friendlyDisplay(res.isoString)), \(dateSourceWords(res.source))."
    }

    static func dateSourceWords(_ source: RecordDateResolution.Source) -> String {
        switch source {
        case .userDate: return "the date you entered"
        case .embedded: return "from the camera's own date stamp"
        case .inferred: return "worked out from the clues around it"
        case .filename: return "from the file's name"
        case .none: return "source unknown"
        }
    }
}
