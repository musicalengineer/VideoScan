// MediaPersonLinks.swift
// "Uncle Bill is on the Montana tape" (2026-08-31).
//
// The catalog can already say a face was DETECTED in a video, and the
// People tab knows POIs by name. Neither can say "this record is about
// this person in the family tree" — which is the thing a person actually
// wants to record, and the thing that makes a birth certificate findable
// from Martha Lamson's card.
//
// TWO KEYS, BOTH CHOSEN TO SURVIVE THE THINGS THAT CHANGE
//
// The person is keyed by FamilySearch ID, not by name and not by the
// local GEDCOM row. Rick re-pulls the tree from FamilySearch and the
// newest .ged wins, which renumbers local IDs; enrichments keyed by FS ID
// are the ones that survive that. Names are worse still — this archive
// has two Eileens and a Rick/Richard.
//
// The media is keyed by its content hash, not its path. Rick is moving
// 285 GB from MoviesExpansion to FamilyArchive as this is written; a
// path-keyed link would be broken by the move it was made before. The
// path is kept ALONGSIDE as a human-readable hint and a fallback for
// records that have no hash yet, but the hash is what is matched on.
//
// A link is an EDGE, deliberately, rather than a field on either side.
// The same mechanism then serves "Uncle Bill is in this video" and
// "Martha's birth certificate", which is why documents did not need
// their own attachment model.

import Foundation

/// Links between catalog records and people in the family tree.
///
/// Pure and injectable: `directory` is supplied, never discovered, so a
/// test writes to its own scratch dir and never the real archive.
struct MediaPersonLinks: Equatable, Sendable {

    /// Who said so. Kept because this archive's whole approach is
    /// evidence with provenance — a guess a detector made and a fact
    /// Rick typed must never be indistinguishable later.
    enum Source: String, Codable, Equatable, Sendable {
        /// A person said so. The strongest claim the archive has.
        case stated
        /// Face detection or another automatic pass proposed it.
        case detected
    }

    struct Link: Codable, Equatable, Sendable {
        /// FamilySearch ID, e.g. "GVQV-NW3".
        let personID: String
        /// The catalog record's partial MD5 — stable across moves.
        /// Empty only for records that have never been hashed.
        let mediaHash: String
        /// Where the file was when the link was made. A hint for humans
        /// and a fallback matcher, never the identity.
        var mediaPath: String
        var source: Source
        var notedAt: Date
        /// Optional free text: "second from the left", "page 2".
        var note: String?

        /// The edge's identity. Two links are the same edge when they
        /// join the same person to the same content, whoever said so.
        var edgeKey: String { "\(personID)\u{1}\(mediaHash.isEmpty ? mediaPath : mediaHash)" }
    }

    private(set) var links: [String: Link]

    init(links: [String: Link] = [:]) { self.links = links }

    var count: Int { links.count }
    var isEmpty: Bool { links.isEmpty }
    var all: [Link] { Array(links.values) }

    // MARK: - Reading

    /// Everything linked to one person, newest first.
    func media(forPerson personID: String) -> [Link] {
        links.values.filter { $0.personID == personID }
                    .sorted { $0.notedAt > $1.notedAt }
    }

    /// Everyone linked to one record. Matched on hash when the record has
    /// one, so a file that moved still resolves; on path otherwise.
    func people(forHash hash: String, path: String) -> [Link] {
        links.values.filter { link in
            if !hash.isEmpty, !link.mediaHash.isEmpty { return link.mediaHash == hash }
            return link.mediaPath == path
        }.sorted { $0.notedAt > $1.notedAt }
    }

    func isLinked(personID: String, hash: String, path: String) -> Bool {
        people(forHash: hash, path: path).contains { $0.personID == personID }
    }

    // MARK: - Writing

    /// Add or update an edge. A stated link never silently loses to a
    /// detected one: if a person already said Uncle Bill is on this tape,
    /// a later detector pass must not downgrade that to a guess.
    @discardableResult
    mutating func link(personID: String, hash: String, path: String,
                       source: Source = .stated, note: String? = nil,
                       now: Date = Date()) -> Link {
        let fresh = Link(personID: personID, mediaHash: hash, mediaPath: path,
                         source: source, notedAt: now, note: note)
        if var existing = links[fresh.edgeKey] {
            if existing.source == .stated && source == .detected {
                // Keep the human claim; still refresh the path, since the
                // detector just proved where the file is now.
                existing.mediaPath = path
                links[fresh.edgeKey] = existing
                return existing
            }
            existing.source = source
            existing.mediaPath = path
            existing.notedAt = now
            if let note { existing.note = note }
            links[fresh.edgeKey] = existing
            return existing
        }
        links[fresh.edgeKey] = fresh
        return fresh
    }

    @discardableResult
    mutating func unlink(personID: String, hash: String, path: String) -> Bool {
        let key = Link(personID: personID, mediaHash: hash, mediaPath: path,
                       source: .stated, notedAt: Date(), note: nil).edgeKey
        return links.removeValue(forKey: key) != nil
    }

    /// Repoint every link that named an old path. Called after a move so
    /// the human-readable hint does not rot; the hash match already
    /// worked without it.
    mutating func notePathChange(from oldPath: String, to newPath: String) {
        for (key, var link) in links where link.mediaPath == oldPath {
            link.mediaPath = newPath
            links[key] = link
        }
    }

    // MARK: - Persistence

    static let fileName = "media-person-links.json"

    static func fileURL(in directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Never throws. A missing or unreadable file means "no links" — a
    /// lost sidecar must not stop the tree or the catalog from opening.
    static func load(from directory: URL) -> MediaPersonLinks {
        guard let data = try? Data(contentsOf: fileURL(in: directory)) else {
            return MediaPersonLinks()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let list = try? decoder.decode([Link].self, from: data) else {
            return MediaPersonLinks()
        }
        return MediaPersonLinks(
            links: Dictionary(list.map { ($0.edgeKey, $0) },
                              uniquingKeysWith: { a, b in
                                  // Same edge twice in one file: the human
                                  // claim wins, then the newer one.
                                  if a.source != b.source {
                                      return a.source == .stated ? a : b
                                  }
                                  return a.notedAt >= b.notedAt ? a : b
                              }))
    }

    /// Written as a sorted ARRAY so two machines editing the same archive
    /// produce a diffable file rather than churning key order.
    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let ordered = links.values.sorted { $0.edgeKey < $1.edgeKey }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        try encoder.encode(ordered).write(to: Self.fileURL(in: directory), options: .atomic)
    }
}
