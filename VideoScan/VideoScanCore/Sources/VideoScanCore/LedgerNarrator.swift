// LedgerNarrator.swift
// Media Ledger lines → dated sentences (Rick's amendment 2, 2026-09-12):
//
//   "You deleted MyFavoriteVideo.mov on Sep 12 2026", "Archived XYZ
//    16-Sep-2026", "You approved N copies be deleted: file1, file2 … <date>"
//
// TEMPLATE ONLY — no model, no phrasing pass. The inspector's History
// section reads these; the Hallie record route (NOT built here) will read
// the same sentences. Pure: the date formatter's locale is fixed
// (en_US_POSIX) and the time zone is injectable, so a sentence is the
// same string on every Mac and in every test.
//
// (For Rick: a switch over the event kind that fills a string template;
// the actor becomes "You" / "Tidy" / "Archive Angel" / "VideoScan".)

import Foundation

/// The ledger's detail-key namespace, spelled once for the templates below.
private typealias Detail = MediaLedgerEvent.Detail

public enum LedgerNarrator {

    /// The sentences for `events`, NEWEST FIRST by default (ties keep
    /// their input order). One sentence per event, never empty.
    public static func sentences(for events: [MediaLedgerEvent],
                                 newestFirst: Bool = true,
                                 timeZone: TimeZone = .current) -> [String] {
        let ordered = ordered(events, newestFirst: newestFirst)
        let formatter = dateFormatter(timeZone: timeZone)
        return ordered.map { sentence(for: $0, dateText: formatter.string(from: $0.at)) }
    }

    /// Stable sort by `at` (ties keep file order; newest-first reverses
    /// the order of equal timestamps too, so "the last line written wins
    /// the top spot").
    public static func ordered(_ events: [MediaLedgerEvent], newestFirst: Bool) -> [MediaLedgerEvent] {
        let indexed = events.enumerated().map { ($0.offset, $0.element) }
        let sorted = indexed.sorted { a, b in
            if a.1.at != b.1.at { return newestFirst ? a.1.at > b.1.at : a.1.at < b.1.at }
            return newestFirst ? a.0 > b.0 : a.0 < b.0
        }
        return sorted.map { $0.1 }
    }

    /// "Sep 12, 2026" — fixed locale, injectable zone.
    public static func dateFormatter(timeZone: TimeZone) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "MMM d, yyyy"
        return f
    }

    /// The actor as the subject of a sentence.
    public static func who(_ actor: MediaLedgerEvent.Actor) -> String {
        switch actor {
        case .rick:    return "You"
        case .tidy:    return "Tidy"
        case .promote: return "Promote"
        case .angel:   return "Archive Angel"
        case .app:     return "VideoScan"
        }
    }

    /// Friendly text for a set-aside reason key (CatalogScopePolicy raw
    /// values, mirrored here so the narrator stays Foundation-only).
    /// nil for an unknown or empty reason.
    public static func reasonPhrase(_ reason: String?) -> String? {
        switch reason ?? "" {
        case "still-image":           return "a photo, not a video"
        case "music-format":          return "a music file"
        case "unlinked-audio":        return "audio with no matching video"
        case "live-photo-complement": return "a Live Photo movie half"
        case "removed-by-user":       return nil
        default:                      return nil
        }
    }

    /// One event → one sentence. `dateText` is already formatted so the
    /// template layer never touches a formatter.
    ///
    /// The switch is only the dispatch — a jump table over `Kind`, kept
    /// exhaustive so a new kind is a compile error until it has words. Each
    /// kind's words live in a template function below, named for the kind
    /// (2026-10-10: the one-case-per-kind split that `familyMusicSentence`
    /// and friends had started).
    public static func sentence(for e: MediaLedgerEvent, dateText d: String) -> String {
        let who = who(e.by)
        let detail = e.detail
        switch e.event {
        case .cataloged:
            return catalogedSentence(dateText: d, detail: detail)
        case .setAside:
            return setAsideSentence(who: who, dateText: d, detail: detail)
        case .putBack:
            return "\(who) put it back in the catalog on \(d)."
        case .restored:
            return "\(who) restored it to the catalog on \(d)."
        case .archived:
            return archivedSentence(by: e.by, dateText: d, detail: detail)
        case .copyTrashed, .copyDeleted:
            return copyRemovedSentence(e.event, who: who, dateText: d, detail: detail)
        case .placeSet:
            return fieldSetSentence(field: "place", value: detail[Detail.place] ?? "", who: who, dateText: d, detail: detail)
        case .dateSet:
            return fieldSetSentence(field: "date", value: detail[Detail.date] ?? "", who: who, dateText: d, detail: detail)
        case .attestation:
            return attestationSentence(who: who, dateText: d, detail: detail)
        case .approval:
            return approvalSentence(who: who, dateText: d, detail: detail)
        case .angelProposed, .angelSkipped, .angelCleared:
            return angelAttentionSentence(e.event, who: who, dateText: d, detail: detail)
        case .footageDecided:
            return footageDecidedSentence(who: who, dateText: d, detail: detail)
        case .familyMusic:
            return familyMusicSentence(who: who, dateText: d, detail: detail)
        case .archiveUpdated, .archiveUpdateRolledBack:
            return archiveUpdateSentence(e.event, who: who, dateText: d, detail: detail)
        }
    }

    // MARK: Templates, one per kind (the words; `sentence` only dispatches)

    static func catalogedSentence(dateText d: String, detail: [String: String]) -> String {
        let vol = detail[Detail.volume] ?? ""
        return vol.isEmpty ? "Cataloged on \(d)." : "Cataloged from \(vol) on \(d)."
    }

    static func setAsideSentence(who: String, dateText d: String, detail: [String: String]) -> String {
        let reason = detail[Detail.reason] ?? ""
        if reason == "removed-from-catalog" {
            return "\(who) removed it from the catalog on \(d) (file untouched)."
        }
        if let phrase = reasonPhrase(reason) {
            return "\(who) set it aside on \(d) — \(phrase)."
        }
        return "\(who) set it aside on \(d)."
    }

    static func archivedSentence(by actor: MediaLedgerEvent.Actor, dateText d: String,
                                 detail: [String: String]) -> String {
        let archive = detail[Detail.archive].flatMap { $0.isEmpty ? nil : $0 } ?? "the Master Archive"
        let verified = detail[Detail.verified] == "true"
        var s = verified
            ? "Archived to \(archive) on \(d), read back and verified."
            : "Archived to \(archive) on \(d) (copy not yet verified)."
        if actor == .angel { s += " (Archive Angel)" }
        return s
    }

    /// Place and date share one shape: "set the <field> to <value>" with the
    /// confidence suffix, or "cleared the <field>" when the value is empty.
    static func fieldSetSentence(field: String, value: String, who: String, dateText d: String,
                                 detail: [String: String]) -> String {
        if value.isEmpty { return "\(who) cleared the \(field) on \(d)." }
        return "\(who) set the \(field) to \(value) on \(d)\(confidenceSuffix(detail))."
    }

    static func attestationSentence(who: String, dateText d: String, detail: [String: String]) -> String {
        let kindRaw = detail[Detail.kind] ?? ""
        let kindName = BackupAttestation.Kind(rawValue: kindRaw)?.displayName ?? (kindRaw.isEmpty ? "backup" : kindRaw)
        let answer = detail[Detail.answer] ?? ""
        let label = detail[Detail.label] ?? ""
        let labelText = label.isEmpty ? "" : " (\(label))"
        let art = article(kindName)
        switch answer {
        case "yes":       return "\(who) said there is \(art) \(kindName) copy\(labelText) on \(d)."
        case "no":        return "\(who) said there is no \(kindName) copy on \(d)."
        case "n/a", "notApplicable":
                          return "\(who) said \(art) \(kindName) copy does not apply on \(d)."
        default:          return "\(who) answered about \(art) \(kindName) copy on \(d)."
        }
    }

    static func approvalSentence(who: String, dateText d: String, detail: [String: String]) -> String {
        let count = Int(detail[Detail.count] ?? "") ?? 0
        let action = detail[Detail.action].flatMap { $0.isEmpty ? nil : $0 } ?? "the Trash"
        let files = (detail[Detail.files] ?? "")
            .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        let noun = count == 1 ? "copy" : "copies"
        var s = "\(who) approved \(count) \(noun) to \(action) on \(d)"
        if !files.isEmpty {
            let shown = files.prefix(5).joined(separator: ", ")
            let more = files.count > 5 ? " and \(files.count - 5) more" : ""
            s += ": \(shown)\(more)"
        }
        if let against = detail[Detail.barOverride], !against.isEmpty {
            s += " — against the bar: \(against)"
        }
        return s + "."
    }

    static func footageDecidedSentence(who: String, dateText d: String, detail: [String: String]) -> String {
        let other = detail[Detail.label] ?? ""
        let otherText = other.isEmpty ? "another file" : other
        switch detail[Detail.answer] ?? "" {
        case "same":
            return "\(who) said it is the same footage as \(otherText) on \(d)."
        case "notSame":
            return "\(who) said it is not the same footage as \(otherText) on \(d)."
        default:
            return "\(who) took back the footage answer about \(otherText) on \(d)."
        }
    }

    /// Archive Angel attention memory — split out (2026-09-27) with the
    /// copy-removed pair below, same text, to keep `sentence` under the
    /// lint complexity ceiling.
    static func angelAttentionSentence(_ kind: MediaLedgerEvent.Kind, who: String, dateText d: String,
                                       detail: [String: String]) -> String {
        switch kind {
        case .angelProposed:
            let score = detail[MediaLedgerEvent.Detail.score] ?? ""
            let scoreText = score.isEmpty ? "" : " (score \(score))"
            return "Archive Angel proposed it for the archive on \(d)\(scoreText)."
        case .angelSkipped:
            if (detail[MediaLedgerEvent.Detail.reason] ?? "") == "unchecked" {
                return "\(who) left it unchecked when the batch was promoted on \(d)."
            }
            return "\(who) passed on it (Archive Angel skip) on \(d)."
        default:
            return "\(who) cleared the Archive Angel batch it was in on \(d), undecided."
        }
    }

    /// A copy left the disk — split out (2026-09-27) to keep `sentence`
    /// under the lint complexity ceiling when Refile's kinds arrived.
    static func copyRemovedSentence(_ kind: MediaLedgerEvent.Kind, who: String, dateText d: String,
                                    detail: [String: String]) -> String {
        let vol = detail[MediaLedgerEvent.Detail.volume] ?? ""
        let whereText = vol.isEmpty ? "" : " (the copy on \(vol))"
        return kind == .copyTrashed
            ? "\(who) moved this copy to the Trash on \(d)\(whereText)."
            : "\(who) deleted this copy permanently on \(d)\(whereText)."
    }

    /// Update… (2026-09-27) — split out like Family Music.
    static func archiveUpdateSentence(_ kind: MediaLedgerEvent.Kind, who: String, dateText d: String,
                                      detail: [String: String]) -> String {
        let from = detail[MediaLedgerEvent.Detail.from] ?? ""
        let to = detail[MediaLedgerEvent.Detail.to] ?? ""
        let why = detail[MediaLedgerEvent.Detail.reason] ?? ""
        if kind == .archiveUpdateRolledBack {
            // Say what ACTUALLY happened (Archive Update review r2 #7).
            let place = from.isEmpty ? "its folder" : from
            var s: String
            switch detail[MediaLedgerEvent.Detail.outcome] ?? "" {
            case "rolledBack":
                s = "An archive update on \(d) was undone — the file stayed at \(place)"
            case "incompleteRecovery":
                s = "An archive update on \(d) failed; the file was put back at \(place), but the drive did not confirm it was saved"
            default:   // mixedState, or anything unknown: never claim an undo
                let at = detail[MediaLedgerEvent.Detail.location] ?? ""
                s = "An archive update on \(d) failed and could not be fully undone — "
                    + (at.isEmpty ? "where the file is could not be confirmed; see the log" : "the file is at \(at)")
            }
            if !why.isEmpty { s += " (\(why))" }
            return s + "."
        }
        var s = "\(who) updated it in the archive on \(d)"
        if !why.isEmpty { s += " — \(why)" }
        if !from.isEmpty && !to.isEmpty && from != to { s += ": \(from) → \(to)" }
        return s + "."
    }

    /// Family Music (2026-09-23) — split out so the big switch above gains
    /// one case, not four branches.
    static func familyMusicSentence(who: String, dateText d: String, detail: [String: String]) -> String {
        if detail[MediaLedgerEvent.Detail.action] == "unmarked" {
            return "\(who) took it off the Family Music shelf on \(d)."
        }
        let performer = detail[MediaLedgerEvent.Detail.performer] ?? ""
        let title = detail[MediaLedgerEvent.Detail.title] ?? ""
        var s = "\(who) marked it as family music on \(d)"
        if !title.isEmpty { s += " — \u{201C}\(title)\u{201D}" }
        if !performer.isEmpty { s += (title.isEmpty ? " — " : ", ") + "played by \(performer)" }
        return s + "."
    }

    /// "a cloud copy" / "an off-site copy".
    static func article(_ noun: String) -> String {
        guard let first = noun.lowercased().first else { return "a" }
        return "aeiou".contains(first) ? "an" : "a"
    }

    static func confidenceSuffix(_ detail: [String: String]) -> String {
        switch detail[MediaLedgerEvent.Detail.confidence] ?? "" {
        case "estimated": return " (best guess)"
        case "known":     return " (you're sure)"
        default:          return ""
        }
    }
}
