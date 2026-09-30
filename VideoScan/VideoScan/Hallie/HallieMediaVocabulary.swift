// HallieMediaVocabulary.swift
// ONE shared vocabulary of catalog-media words (design §5, "tree mode
// declines a legitimate translator presence for a sentence with an
// unusual media word"). The mode gate's media-noun escape reads this
// union so a sentence such as "the Christmas tape" is recognised as a
// catalog ask in tree mode. The three producers it unions —
// ArchivistFollowUpResolver+Refinement.mediaNouns, HallieAggregateFallback
// .mediaWords and HallieCatalogStats' overview keys — keep their own
// narrower sets on purpose: each of those decides a different question
// (is this fragment a sentence? does this anchor want video?) and
// widening them would change those answers.

import Foundation

enum HallieMediaVocabulary {
    /// Things one plays, reveals, counts or searches in the catalog.
    static let nouns: Set<String> = [
        "video", "videos", "clip", "clips", "movie", "movies", "footage",
        "recording", "recordings", "tape", "tapes", "film", "films", "reel",
        "reels", "mxf", "transcript", "transcripts", "caption", "captions",
        "file", "files", "media", "audio", "soundtrack",
    ]

    /// Photo words: a catalog item too, but "photo(s) of <tree person>" is
    /// the portrait road (HallieTurnExecutor.photoAsk), which is a TREE
    /// answer. The classifier treats these separately; the gate's escape
    /// counts them as media.
    static let photoNouns: Set<String> = [
        "photo", "photos", "photograph", "photographs", "picture", "pictures",
        "portrait", "portraits", "image", "images", "snapshot", "snapshots",
    ]

    /// Words that name the WHOLE collection rather than one item.
    static let scopeWords: Set<String> = [
        "archive", "archives", "catalog", "catalogue", "collection", "library",
    ]

    /// Every word the gate's media escape honours.
    static let all: Set<String> = nouns.union(photoNouns).union(scopeWords)

    /// Lower-cased alphanumeric tokens (apostrophes kept inside words).
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "-" })
            .map(String.init)
    }

    /// True when the sentence names a catalog item or the collection.
    static func containsMediaWord(_ text: String) -> Bool {
        words(text).contains { all.contains($0) }
    }

    /// True when the sentence names a catalog ITEM (not a photo, not the
    /// collection) — the reading under which a tree person plus a media
    /// noun is a catalog search ("videos of nathaniel parker").
    static func containsItemNoun(_ text: String) -> Bool {
        words(text).contains { nouns.contains($0) }
    }

    static func containsPhotoNoun(_ text: String) -> Bool {
        words(text).contains { photoNouns.contains($0) }
    }
}
