// FamilyMusicShelf.swift
// Family Music (Rick 2026-09-23) — the pure half: which records are on the
// shelf, how a row reads, in what order, how the mark sheet is prefilled,
// and how a row plays. No SwiftUI, no model: headless-testable.
//
// "I definitely don't mean iTunes or bought music — I mean my family
// music." The shelf holds ONLY records Rick marked by hand
// (`VideoRecord.familyMusic`); nothing here infers membership from an
// extension, a folder or a tag. A purchased-music path that nobody marked
// can never appear (sensor: FamilyMusicTests.unmarkedPurchasedMusicNeverAppears).
//
// Cost: `build` is ONE O(records) pass that does a nil check per record;
// everything else (date resolve, archive status) runs only for the marked
// handful (~25). It is called once per RecordsVersion from inside
// ArchiveCategorySnapshot.compute, never from a view body.
// Memory: one small value struct per MARKED record — a few KB total.

import Foundation
import VideoScanCore

// MARK: - A row

/// One line on the shelf. A value snapshot — the view never touches the
/// VideoRecord (C++ analogy: a flattened row DTO copied out of the table).
struct FamilyMusicItem: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The mark's title, or the filename when the mark has none.
    let title: String
    let performer: String?
    let year: Int?
    let durationSeconds: Double
    /// False = an audio recording (plays in place); true = a video of
    /// someone playing (opens in the app's usual player).
    let isVideo: Bool
    /// A byte-verified Master Archive copy exists.
    let isArchived: Bool
    let fullPath: String
    let filename: String

    /// "3:07" / "1:02:15"; "" when the length is unknown.
    var lengthText: String {
        guard durationSeconds > 0, durationSeconds.isFinite else { return "" }
        let total = Int(durationSeconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

// MARK: - Building + ordering

enum FamilyMusicShelf {

    /// Every marked record → one row, in shelf order. `isArchived` answers
    /// "has a verified Master Archive copy" (O(1) via the promotion index);
    /// `skip` drops rows the caller represents elsewhere (an archive copy
    /// whose marked source is also on the shelf). Both closures run only
    /// for MARKED records.
    static func build(from records: [VideoRecord],
                      isArchived: (VideoRecord) -> Bool,
                      skip: (VideoRecord) -> Bool = { _ in false }) -> [FamilyMusicItem] {
        var out: [FamilyMusicItem] = []
        for rec in records {
            guard let mark = rec.familyMusic else { continue }   // the only gate: Rick's mark
            if skip(rec) { continue }
            out.append(item(for: rec, mark: mark, isArchived: isArchived(rec)))
        }
        return sorted(out)
    }

    static func item(for rec: VideoRecord, mark: FamilyMusicInfo, isArchived: Bool) -> FamilyMusicItem {
        // clean() again: a hand-edited or older catalog can carry "" that
        // the initializer never allows — a blank title shows the filename.
        FamilyMusicItem(id: rec.id,
                        title: FamilyMusicInfo.clean(mark.title) ?? rec.filename,
                        performer: FamilyMusicInfo.clean(mark.performer),
                        year: year(of: rec),
                        durationSeconds: rec.durationSeconds,
                        isVideo: isVideo(rec),
                        isArchived: isArchived,
                        fullPath: rec.fullPath,
                        filename: rec.filename)
    }

    /// Audio-only records are recordings; anything with a picture is video.
    static func isVideo(_ rec: VideoRecord) -> Bool {
        rec.streamType != .audioOnly
    }

    /// The year the archive would file it under — the SAME resolver the
    /// promote flow uses. nil when only a decade (or nothing) is known.
    static func year(of rec: VideoRecord) -> Int? {
        let r = RecordDateResolver.resolve(userDate: rec.userDate,
                                           userDateConfidence: rec.userDateConfidence,
                                           embeddedCreationDate: rec.embeddedCreationDate,
                                           originMake: rec.originMake,
                                           originModel: rec.originModel,
                                           originEncoder: rec.originEncoder,
                                           inferredRecordDate: rec.inferredRecordDate,
                                           inferredDateConfidence: rec.inferredDateConfidence,
                                           filename: rec.filename.isEmpty ? nil : rec.filename)
        return r.precision <= .year ? r.year : nil
    }

    /// Performer, then title, then year (Rick's spec). Case- and
    /// number-aware ("Tim 2" before "Tim 10"); rows with no performer
    /// after those with one, no year after a year; the path breaks ties so
    /// the order is deterministic.
    static func sorted(_ items: [FamilyMusicItem]) -> [FamilyMusicItem] {
        items.sorted { a, b in
            switch compareOptional(a.performer, b.performer) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }
            switch a.title.localizedStandardCompare(b.title) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: break
            }
            if a.year != b.year {
                guard let ya = a.year else { return false }
                guard let yb = b.year else { return true }
                return ya < yb
            }
            return a.fullPath < b.fullPath
        }
    }

    private static func compareOptional(_ a: String?, _ b: String?) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil): return .orderedSame
        case (nil, _):   return .orderedDescending   // blanks last
        case (_, nil):   return .orderedAscending
        case let (x?, y?): return x.localizedStandardCompare(y)
        }
    }
}

// MARK: - Mark sheet prefill

enum FamilyMusicPrefill {

    /// "tim_guitar-solo_1998.m4a" → "tim guitar solo 1998". Extension off,
    /// separators to spaces, runs of spaces collapsed.
    static func title(fromFilename name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let spaced = stem.map { "_-.".contains($0) ? " " : String($0) }.joined()
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// The people Rick confirmed on the record (then the engine's detected
    /// names), deduped case-insensitively — "Tim, Matt". Suspected ("?")
    /// names are never offered: the performer is a fact, not a guess.
    static func performer(for rec: VideoRecord) -> String {
        var seen: Set<String> = []
        var names: [String] = []
        for n in rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople {
            let key = n.lowercased()
            // "Family" is the everyone-wildcard tag, not a performer.
            if key.isEmpty || key == "family" { continue }
            if seen.insert(key).inserted { names.append(n) }
        }
        return names.joined(separator: ", ")
    }

    /// For a multi-selection: the performer every file shares, else "".
    static func commonPerformer(for recs: [VideoRecord]) -> String {
        let each = Set(recs.map { $0.familyMusic?.performer ?? performer(for: $0) })
        return each.count == 1 ? (each.first ?? "") : ""
    }
}

// MARK: - Playback route

/// How one row plays. Decided from the row alone (extension + kind +
/// reachability) — no probing, no I/O.
enum FamilyMusicPlayRoute: Equatable, Sendable {
    /// AVPlayer, in place, inside the Family Music pane.
    case inlineAudio(URL)
    /// The app's usual smart opener (MediaOpener — QuickTime or VLC), the
    /// same one the Archive timeline cards use.
    case externalPlayer
    /// The drive is not connected.
    case offline
}

enum FamilyMusicPlayback {

    /// Audio containers AVFoundation plays natively. Anything else that is
    /// audio-only (an Avid MXF audio essence, OGG, WMA…) goes to the
    /// external player, which knows how to route it to VLC.
    static let inlineAudioExtensions: Set<String> =
        ["mp3", "m4a", "m4b", "aac", "wav", "wave", "aif", "aiff", "aifc", "caf", "flac"]

    static func route(for item: FamilyMusicItem, isOnline: Bool, isViewer: Bool = false) -> FamilyMusicPlayRoute {
        guard isOnline else { return .offline }
        // Remote viewer: the file lives on the master; MediaOpener knows
        // how to resolve its stream. Inline playback is master-local only.
        if item.isVideo || isViewer { return .externalPlayer }
        let ext = (item.fullPath as NSString).pathExtension.lowercased()
        guard inlineAudioExtensions.contains(ext) else { return .externalPlayer }
        return .inlineAudio(URL(fileURLWithPath: item.fullPath))
    }
}
