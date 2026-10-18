// CatalogSharedCurated.swift
// The curated values every copy of one content SHOWS (the display tables are
// keyed by digest — cutover B2.1, codex B2 P1-1 / P1-2): stars, notes,
// disposition, tags, people, the user date and place, backup attestations,
// family music. A value type taken from a record (or its snapshot), so the
// committer can keep, per record, what that record last agreed with the
// store — its own per-FIELD baseline.
//
// Why. Two copies A and B of one content: A's notes are edited; B is dirty
// for a resolution change but still carries the OLD notes. Compared against
// the store, B's old notes "differ" and would be written over A's edit. The
// rule that fixes it: a row writes a shared curated field only when THAT
// record's own value changed since its own baseline (`edited(since:)`).
// And after a commit, a sibling takes the committed value only where it
// still holds its baseline (`take(_:from:where:)`) — an edit it got while
// the commit ran is never overwritten.
//
// Fields come in groups that are written together (the date and its
// confidence; the place and its confidence; confirmed and rejected people),
// so a group is edited when any of its members is.
//
// (For Rick: a small POD of the shared columns with a field-wise diff — the
// "dirty bit per column" a whole-row checksum cannot give.)

import Foundation

public struct CatalogSharedCurated: Sendable, Equatable {
    public var starRating: Int
    public var userNotes: String
    public var mediaDisposition: MediaDisposition
    public var tags: [String]
    public var confirmedByUserPeople: [ConfirmedTag]
    public var rejectedPeople: [String]
    public var userDate: String?
    public var userDateConfidence: String?
    public var userPlace: String?
    public var userPlaceConfidence: String?
    public var backupAttestations: [BackupAttestation]
    public var familyMusic: FamilyMusicInfo?

    public init(_ s: VideoRecordDTO) {
        starRating = s.starRating
        userNotes = s.userNotes
        mediaDisposition = s.mediaDisposition
        tags = s.tags
        confirmedByUserPeople = s.confirmedByUserPeople
        rejectedPeople = s.rejectedPeople
        userDate = s.userDate
        userDateConfidence = s.userDateConfidence
        userPlace = s.userPlace
        userPlaceConfidence = s.userPlaceConfidence
        backupAttestations = s.backupAttestations
        familyMusic = s.familyMusic
    }

    public init(_ r: VideoRecord) {
        self.init(VideoRecordDTO(r))
    }

    /// One group of fields written together, with the knowledge fields it covers.
    public enum Group: CaseIterable, Sendable {
        case stars, notes, disposition, tags, people, date, place, attestations, music

        public var fields: [CatalogDDL.KnowledgeField] {
            switch self {
            case .stars: return [.starRating]
            case .notes: return [.userNotes]
            case .disposition: return [.mediaDisposition]
            case .tags: return [.tags]
            case .people: return [.confirmedByUserPeople, .rejectedPeople]
            case .date: return [.userDate, .userDateConfidence]
            case .place: return [.userPlace, .userPlaceConfidence]
            case .attestations: return [.backupAttestations]
            case .music: return [.familyMusic]
            }
        }
    }

    /// True when `self` and `other` hold the same value(s) for `group`.
    public func same(_ group: Group, as other: Self) -> Bool {
        switch group {
        case .stars: return starRating == other.starRating
        case .notes: return userNotes == other.userNotes
        case .disposition: return mediaDisposition == other.mediaDisposition
        case .tags: return tags == other.tags
        case .people: return confirmedByUserPeople == other.confirmedByUserPeople && rejectedPeople == other.rejectedPeople
        case .date: return userDate == other.userDate && userDateConfidence == other.userDateConfidence
        case .place: return userPlace == other.userPlace && userPlaceConfidence == other.userPlaceConfidence
        case .attestations: return backupAttestations == other.backupAttestations
        case .music: return familyMusic == other.familyMusic
        }
    }

    /// The knowledge fields whose group differs from `baseline`.
    public func edited(since baseline: Self) -> Set<CatalogDDL.KnowledgeField> {
        Set(Group.allCases.filter { !same($0, as: baseline) }.flatMap(\.fields))
    }

    /// The groups any of `fields` belongs to.
    public static func groups(of fields: [CatalogDDL.KnowledgeField]) -> [Group] {
        let wanted = Set(fields)
        return Group.allCases.filter { !wanted.isDisjoint(with: $0.fields) }
    }

    /// Copy `group` from `source`.
    public mutating func take(_ group: Group, from source: Self) {
        switch group {
        case .stars: starRating = source.starRating
        case .notes: userNotes = source.userNotes
        case .disposition: mediaDisposition = source.mediaDisposition
        case .tags: tags = source.tags
        case .people:
            confirmedByUserPeople = source.confirmedByUserPeople
            rejectedPeople = source.rejectedPeople
        case .date:
            userDate = source.userDate
            userDateConfidence = source.userDateConfidence
        case .place:
            userPlace = source.userPlace
            userPlaceConfidence = source.userPlaceConfidence
        case .attestations: backupAttestations = source.backupAttestations
        case .music: familyMusic = source.familyMusic
        }
    }

    /// Write `group`'s value(s) onto `record`.
    public func apply(_ group: Group, to record: VideoRecord) {
        switch group {
        case .stars: record.starRating = starRating
        case .notes: record.userNotes = userNotes
        case .disposition: record.mediaDisposition = mediaDisposition
        case .tags: record.tags = tags
        case .people:
            record.confirmedByUserPeople = confirmedByUserPeople
            record.rejectedPeople = rejectedPeople
        case .date:
            record.userDate = userDate
            record.userDateConfidence = userDateConfidence
        case .place:
            record.userPlace = userPlace
            record.userPlaceConfidence = userPlaceConfidence
        case .attestations: record.backupAttestations = backupAttestations
        case .music: record.familyMusic = familyMusic
        }
    }

    /// The people as display rows' identities (name, kind).
    public var peopleKeys: Set<PeopleKey> {
        Set(confirmedByUserPeople.map { PeopleKey(name: $0.name, kind: .confirmed) }
            + rejectedPeople.map { PeopleKey(name: $0, kind: .rejected) })
    }

    /// Each confirmed name's date in whole Unix seconds (as catalog.json's
    /// ISO 8601 text — and so the people_tags row — carries it).
    public var confirmedSeconds: [String: Int64] {
        Dictionary(confirmedByUserPeople.map { ($0.name, Int64($0.confirmedAt.timeIntervalSince1970.rounded(.down))) },
                   uniquingKeysWith: { first, _ in first })
    }

    public struct PeopleKey: Hashable, Sendable {
        public var name: String
        public var kind: CatalogDDL.PeopleTagKind
    }
}
