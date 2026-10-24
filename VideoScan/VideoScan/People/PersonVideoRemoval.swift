// PersonVideoRemoval.swift
// Right-click on a video in the People tab ▸ take it off this person
// (Rick 2026-10-23: "a simple right-click: do not show this video for this
// person, or simpler verbiage").
//
// Two ways a video reaches a person's page, so two words:
//   * "Remove from Donna's Page" — a hand pick (Show in People tab ▸).
//     Only the pick goes; her tags stay, so a tagged video moves down to
//     "More videos tagged Donna".
//   * "Donna Isn't in This Video" — the tags go too: a confirmed tag is
//     removed, a face match is recorded as Rejected so the next scan does
//     not put it back. The SAME engine as the Catalog's People ▸ uncheck
//     (VideoScanModel.setPerson), once per name she is known by.
//
// A row can stand for two records — a source and its Master Archive copy
// (PersonVideos folds them into one row). Both are changed, or the other
// one would bring the row straight back. Tags and picks are catalog and
// profile metadata; no file is touched.
//
// (For Rick: a caseless `enum` with statics ≈ a C++ namespace of free
// functions.)

import Foundation
import VideoScanCore

enum PersonVideoRemovalAction: Sendable, Equatable {
    case removeFromPage
    case notInVideo

    /// The menu words. `name` is the person's display name.
    func title(_ name: String) -> String {
        switch self {
        case .removeFromPage: return "Remove from \(name)\u{2019}s Page"
        case .notInVideo: return "\(name) Isn\u{2019}t in This Video"
        }
    }

    func help(_ name: String) -> String {
        switch self {
        case .removeFromPage:
            return "Take this video off \(name)\u{2019}s page. Tags for \(name) stay. No file is changed."
        case .notInVideo:
            return "Remove \(name)\u{2019}s tag from this video and mark a face match as wrong, "
                + "so a later scan does not add it back. No file is changed."
        }
    }
}

@MainActor
enum PersonVideoRemoval {

    /// The records one People row stands for: the row, its promotion
    /// source, its proven archive copy — each once. Pure.
    nonisolated static func records(_ rec: VideoRecord, source: VideoRecord?, copy: VideoRecord?) -> [VideoRecord] {
        var out: [VideoRecord] = []
        for r in [rec, source, copy].compactMap({ $0 }) where !out.contains(where: { $0 === r }) {
            out.append(r)
        }
        return out
    }

    /// Every name the person is tagged under (name, display name, aliases),
    /// trimmed, case-insensitively unique, in that order. Pure.
    nonisolated static func names(of profile: POIProfile) -> [String] {
        var out: [String] = []
        for raw in [profile.name, profile.displayName] + profile.aliases {
            let n = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty, !out.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) else { continue }
            out.append(n)
        }
        return out
    }

    /// The tag half of "Isn't in This Video": setPerson(present: false)
    /// for every name, on every record of the row.
    static func untag(_ recs: [VideoRecord], profile: POIProfile, model: VideoScanModel) {
        for name in names(of: profile) {
            model.setPerson(name, on: recs, present: false)
        }
    }

    /// Every record the People row for `rec` stands for: the row, its
    /// promotion source, its proven archive copy — and, for an archive-copy
    /// row, every live source the page FOLDED into it by the same rule the
    /// page uses (`PersonVideos.foldsIntoArchiveCopy` → `provenArchivedCopy`,
    /// which also matches by whole-file SHA-256, not only by `derivedFrom`;
    /// Codex P1 2026-10-24). One pass over the catalog on a click, never in
    /// a view body.
    static func rowRecords(_ rec: VideoRecord, in model: VideoScanModel) -> [VideoRecord] {
        let source = model.promotionSource(of: rec)
        let copy = model.isArchiveCopy(rec) ? nil : model.provenArchivedCopy(of: rec)
        var out = records(rec, source: source, copy: copy)
        let row = copy ?? rec
        guard model.isArchiveCopy(row) else { return out }
        for other in model.records where !other.isPurged && !model.isArchiveCopy(other)
            && !out.contains(where: { $0 === other }) && model.provenArchivedCopy(of: other) === row {
            out.append(other)
        }
        return out
    }

    /// Run `action` for the row whose record is `rec`.
    static func perform(_ action: PersonVideoRemovalAction, rec: VideoRecord, profile: POIProfile,
                        model: VideoScanModel) {
        let recs = rowRecords(rec, in: model)
        if action == .notInVideo { untag(recs, profile: profile, model: model) }
        FeaturedVideos.remove(resolvingTo: recs, for: profile.uuid, in: model)
        appLog.write("People tab: \(action.title(profile.displayName)) — \(rec.filename) (\(recs.count) record(s))")
    }
}
