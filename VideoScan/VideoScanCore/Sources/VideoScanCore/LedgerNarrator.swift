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
    public static func sentence(for e: MediaLedgerEvent, dateText d: String) -> String {
        let d = d
        let who = who(e.by)
        let detail = e.detail
        switch e.event {
        case .cataloged:
            let vol = detail[MediaLedgerEvent.Detail.volume] ?? ""
            return vol.isEmpty ? "Cataloged on \(d)." : "Cataloged from \(vol) on \(d)."

        case .setAside:
            let reason = detail[MediaLedgerEvent.Detail.reason] ?? ""
            if reason == "removed-from-catalog" {
                return "\(who) removed it from the catalog on \(d) (file untouched)."
            }
            if let phrase = reasonPhrase(reason) {
                return "\(who) set it aside on \(d) — \(phrase)."
            }
            return "\(who) set it aside on \(d)."

        case .putBack:
            return "\(who) put it back in the catalog on \(d)."

        case .restored:
            return "\(who) restored it to the catalog on \(d)."

        case .archived:
            let archive = detail[MediaLedgerEvent.Detail.archive].flatMap { $0.isEmpty ? nil : $0 } ?? "the Master Archive"
            let verified = detail[MediaLedgerEvent.Detail.verified] == "true"
            var s = verified
                ? "Archived to \(archive) on \(d), read back and verified."
                : "Archived to \(archive) on \(d) (copy not yet verified)."
            if e.by == .angel { s += " (Archive Angel)" }
            return s

        case .copyTrashed:
            let vol = detail[MediaLedgerEvent.Detail.volume] ?? ""
            let whereText = vol.isEmpty ? "" : " (the copy on \(vol))"
            return "\(who) moved this copy to the Trash on \(d)\(whereText)."

        case .copyDeleted:
            let vol = detail[MediaLedgerEvent.Detail.volume] ?? ""
            let whereText = vol.isEmpty ? "" : " (the copy on \(vol))"
            return "\(who) deleted this copy permanently on \(d)\(whereText)."

        case .placeSet:
            let place = detail[MediaLedgerEvent.Detail.place] ?? ""
            if place.isEmpty { return "\(who) cleared the place on \(d)." }
            return "\(who) set the place to \(place) on \(d)\(confidenceSuffix(detail))."

        case .dateSet:
            let date = detail[MediaLedgerEvent.Detail.date] ?? ""
            if date.isEmpty { return "\(who) cleared the date on \(d)." }
            return "\(who) set the date to \(date) on \(d)\(confidenceSuffix(detail))."

        case .attestation:
            let kindRaw = detail[MediaLedgerEvent.Detail.kind] ?? ""
            let kindName = BackupAttestation.Kind(rawValue: kindRaw)?.displayName ?? (kindRaw.isEmpty ? "backup" : kindRaw)
            let answer = detail[MediaLedgerEvent.Detail.answer] ?? ""
            let label = detail[MediaLedgerEvent.Detail.label] ?? ""
            let labelText = label.isEmpty ? "" : " (\(label))"
            let art = article(kindName)
            switch answer {
            case "yes":       return "\(who) said there is \(art) \(kindName) copy\(labelText) on \(d)."
            case "no":        return "\(who) said there is no \(kindName) copy on \(d)."
            case "n/a", "notApplicable":
                              return "\(who) said \(art) \(kindName) copy does not apply on \(d)."
            default:          return "\(who) answered about \(art) \(kindName) copy on \(d)."
            }

        case .approval:
            let count = Int(detail[MediaLedgerEvent.Detail.count] ?? "") ?? 0
            let action = detail[MediaLedgerEvent.Detail.action].flatMap { $0.isEmpty ? nil : $0 } ?? "the Trash"
            let files = (detail[MediaLedgerEvent.Detail.files] ?? "")
                .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            let noun = count == 1 ? "copy" : "copies"
            var s = "\(who) approved \(count) \(noun) to \(action) on \(d)"
            if !files.isEmpty {
                let shown = files.prefix(5).joined(separator: ", ")
                let more = files.count > 5 ? " and \(files.count - 5) more" : ""
                s += ": \(shown)\(more)"
            }
            return s + "."
        }
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
