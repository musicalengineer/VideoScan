// HallieGalleryAnswer.swift
// The gallery answer itself (2026-09-10, "show all photos of X"): every
// photo and document the family's folders hold for one person, as
// attachments, with honest counts in the prose and a folder to reveal.
// Shared by the tree path (HallieLineageAnswer.personPhoto) and the
// People-tab path (HallieTurnExecutor.photoAsk). Attachments are
// presentation, never evidence; the basis line says where they came from.

import Foundation
import VideoScanCore

enum HallieGalleryAnswer {
    /// Photos shown in one chat answer. Beyond this the prose says so and
    /// points at the folder — 24 grid cells is the Mac view's bound too.
    static let photoCap = 24

    /// "1 photo" / "3 photos" — numerals with English plurals.
    static func countPhrase(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// One photo and nothing else keeps the old portrait line; anything
    /// more says what is there, and the cap when it applies.
    static func prose(name: String, photos: Int, documents: Int) -> String {
        if photos == 1, documents == 0 { return "Here\u{2019}s \(name)." }
        var parts: [String] = []
        if photos > 0 { parts.append(countPhrase(photos, "photo")) }
        if documents > 0 { parts.append(countPhrase(documents, "document")) }
        let total = photos + documents
        var line = "\(total == 1 ? "Here is" : "Here are") \(parts.joined(separator: " and ")) of \(name)"
        if photos > photoCap {
            line += " \u{2014} showing the first \(photoCap); the rest are in the folder."
        } else {
            line += "."
        }
        return line
    }

    /// "Show folder in Finder" for one folder; named when there are several.
    static func revealOffers(_ folders: [URL]) -> [HallieTurnExecutor.OfferedAction] {
        if folders.count == 1 { return [.revealFolder(url: folders[0], label: "Show folder in Finder")] }
        return folders.map { .revealFolder(url: $0, label: "Show folder in Finder: \($0.lastPathComponent)") }
    }

    /// The answer. `photos` is expected in the store's order (chosen /
    /// portrait first); only the first `photoCap` become attachments.
    /// `source` names where the files came from for the basis line.
    static func result(personName: String,
                       gedcomID: String?,
                       photos: [URL],
                       documents: [URL],
                       folders: [URL],
                       route: HallieTurnExecutor.Route,
                       source: String,
                       offeredActions: [HallieTurnExecutor.OfferedAction] = []) -> HallieTurnExecutor.Result {
        var attachments: [HallieAttachment] = photos.prefix(photoCap).map {
            .photo(HalliePhotoAttachment(personName: personName, fileURL: $0, personGedcomID: gedcomID))
        }
        attachments += documents.map { .document(HallieDocumentAttachment(personName: personName, fileURL: $0)) }
        let counts = "\(countPhrase(photos.count, "photo")) and \(countPhrase(documents.count, "document"))"
        return HallieTurnExecutor.Result(
            route: route, outcome: .answered,
            prose: prose(name: personName, photos: photos.count, documents: documents.count),
            basisLine: "Basis: \(counts) from \(source) for this person.",
            queryDescription: "photo: \(personName)",
            citations: [], catalogPersonName: personName,
            offeredActions: offeredActions + revealOffers(folders),
            attachments: attachments)
    }

    /// "the Master Archive's 40_Family_Tree/People folder(s)".
    static func archiveSource(folderCount: Int) -> String {
        "the Master Archive\u{2019}s 40_Family_Tree/People folder\(folderCount == 1 ? "" : "s")"
    }
}
