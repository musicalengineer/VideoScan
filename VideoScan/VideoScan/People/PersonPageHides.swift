// PersonPageHides.swift
// "Remove from Donna's Page" on ANY row of a person's page — a neutral
// hide (Rick 2026-10-24: "sometimes a video is shown for the wrong person
// and I just want to remove it from the list… We're not saying it is or is
// not this person, just don't show this video for this person").
//
// What a hide is, and is not:
//   * It hides the video from THIS person's page only. Tags, face matches,
//     rejections and the file are untouched — "Donna Isn't in This Video"
//     (PersonVideoRemoval) stays the separate, stronger claim.
//   * A hide of a pick also drops the pick (the page's own list).
//   * Stored by CONTENT identity: the whole-file SHA-256, so every byte
//     copy of the video stays hidden across volumes and rescans; the
//     record id only for a file with no full digest yet. Never the sampled
//     `v1:` hash (GH #327).
//   * Stored in the person's profile.json (`POIProfile.hiddenVideos`),
//     through the same one writer as the picks: reload from disk, mutate,
//     `save(writingFeaturedVideos: true)`, post `FeaturedVideos.changed`.
//   * Put Back is the inverse through the same engine; each writes one log
//     line (PersonVideoRemoval.perform).
//
// (For Rick: a caseless `enum` with statics ≈ a C++ namespace of free
// functions.)

import Foundation
import VideoScanCore

/// One video hidden from a person's page.
struct HiddenVideo: Codable, Equatable, Hashable, Sendable {
    /// The whole-file SHA-256 (lowercase) — THE identity when present.
    var fullDigest: String?
    /// Identity only when `fullDigest` is nil; kept for the record otherwise.
    var recordID: UUID
    /// For the person reading profile.json and the log; never matched on.
    var filename: String
    var hiddenAt: Date
}

enum PersonPageHides {

    /// What one hide / put-back changed.
    struct Outcome: Equatable, Sendable {
        var entriesChanged = 0
        var picksDropped = 0
    }

    /// The entry for `rec`: its whole-file digest, else its record id.
    nonisolated static func entry(for rec: VideoRecord, at date: Date = Date()) -> HiddenVideo {
        HiddenVideo(fullDigest: VideoScanModel.storedFullDigest(rec)?.lowercased(), recordID: rec.id,
                    filename: rec.filename, hiddenAt: date)
    }

    /// Does `entry` name the file with this digest / id? Digest entries
    /// match by digest only (a byte copy anywhere is the same video); an
    /// id entry matches that record only. Pure.
    nonisolated static func matches(_ entry: HiddenVideo, digest: String?, id: UUID) -> Bool {
        if let d = entry.fullDigest, !d.isEmpty {
            guard let digest, !digest.isEmpty else { return false }
            return d.caseInsensitiveCompare(digest) == .orderedSame
        }
        return entry.recordID == id
    }

    /// The entries as two sets, so a page of thousands of rows checks each
    /// in O(1). Same rule as `matches`. (C++: two unordered_sets.)
    struct Lookup: Sendable, Equatable {
        var digests: Set<String> = []
        var ids: Set<UUID> = []

        init(_ entries: [HiddenVideo]) {
            for e in entries {
                if let d = e.fullDigest, !d.isEmpty { digests.insert(d.lowercased()) } else { ids.insert(e.recordID) }
            }
        }

        func hides(_ row: PersonVideoRow) -> Bool {
            if ids.contains(row.id) { return true }
            guard let d = row.digest, !d.isEmpty else { return false }
            return digests.contains(d.lowercased())
        }
    }

    nonisolated static func isHidden(_ row: PersonVideoRow, in entries: [HiddenVideo]) -> Bool {
        Lookup(entries).hides(row)
    }

    /// Hide (`hidden`) or put back `recs` in an entry list; returns how
    /// many entries were added or removed. Pure.
    nonisolated static func apply(_ recs: [VideoRecord], hidden: Bool, to entries: inout [HiddenVideo],
                                  at date: Date = Date()) -> Int {
        var changed = 0
        for rec in recs {
            let digest = VideoScanModel.storedFullDigest(rec)
            let present = entries.contains { matches($0, digest: digest, id: rec.id) }
            if hidden, !present {
                entries.append(entry(for: rec, at: date))
                changed += 1
            } else if !hidden, present {
                let before = entries.count
                entries.removeAll { matches($0, digest: digest, id: rec.id) }
                changed += before - entries.count
            }
        }
        return changed
    }

    /// The ONE writer for a hide or a put-back on a person's page: reload
    /// the profile from disk, change the hidden list (a hide also drops any
    /// pick that resolves to these records), save through the page writer,
    /// notify. nil (and a log line) when the profile is gone or the save
    /// failed; otherwise what changed (possibly nothing).
    @MainActor @discardableResult
    static func set(_ recs: [VideoRecord], hidden: Bool, for profileUUID: UUID,
                    in model: VideoScanModel) -> Outcome? {
        guard var profile = POIProfile.listAll().first(where: { $0.uuid == profileUUID }) else {
            appLog.write("People tab: could not find that person's profile — nothing changed")
            return nil
        }
        var out = Outcome()
        out.entriesChanged = apply(recs, hidden: hidden, to: &profile.hiddenVideos)
        if hidden {
            out.picksDropped = FeaturedVideos.removePicks(resolvingTo: recs, from: &profile.featuredVideos, in: model)
        }
        guard out.entriesChanged + out.picksDropped > 0 else { return out }
        do {
            try profile.save(writingFeaturedVideos: true)
        } catch {
            appLog.write("People tab: could not save \(profile.displayName)'s page — \(error.localizedDescription)")
            return nil
        }
        NotificationCenter.default.post(name: FeaturedVideos.changed, object: profileUUID)
        return out
    }

    /// Decode a stored hidden list ROW BY ROW (the picks' rule, codex
    /// 2026-10-04 P1): an unreadable row — or a value that is not a list —
    /// is kept verbatim in `quarantined` and written back, never dropped.
    nonisolated static func decodeRows(_ raw: JSONValue?) -> (readable: [HiddenVideo], quarantined: [JSONValue]) {
        guard let raw else { return ([], []) }
        guard case .array(let rows) = raw else { return ([], [raw]) }
        var readable: [HiddenVideo] = []
        var quarantined: [JSONValue] = []
        for row in rows {
            if let data = try? JSONEncoder().encode(row),
               let entry = try? JSONDecoder().decode(HiddenVideo.self, from: data) {
                readable.append(entry)
            } else {
                quarantined.append(row)
            }
        }
        return (readable, quarantined)
    }
}
