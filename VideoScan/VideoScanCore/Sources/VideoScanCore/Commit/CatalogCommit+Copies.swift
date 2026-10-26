// CatalogCommit+Copies.swift
// After a commit wrote a curated field for a content, every in-memory copy
// of that content shows it (cutover B2, catalog_cutover_f_prime §8 risk 3):
// the display tables are keyed by digest, so a reload would show the new
// star on every copy — the session must not show the old one until then.
//
// `digest(of:)` is the importer's identity rule (CatalogRecordDTO
// .resolveDigest) applied to a live record: the whole-file SHA-256 its
// fixity names for its current size; two fixities that disagree name none.
//
// (For Rick: the in-memory half of "copies share one value" — the copy
// loop Promote already does for an archived file, done for every content.)

import Foundation

extension CatalogCommit {

    /// The record's whole-file digest, as the importer would decide it.
    public static func digest(of record: VideoRecord) -> String? {
        digest(content: record.contentFixity, archive: record.archiveFixity, size: record.sizeBytes)
    }

    /// The same rule on a commit's snapshot (the door, codex #145 F2).
    public static func digest(of snapshot: VideoRecordDTO) -> String? {
        digest(content: snapshot.contentFixity, archive: snapshot.archiveFixity, size: snapshot.sizeBytes)
    }

    private static func digest(content contentFixity: ContentFixity?, archive archiveFixity: ArchiveFixity?, size: Int64) -> String? {
        let content = contentFixity.flatMap { f -> String? in
            let hex = f.digest.lowercased()
            return f.algorithm == "sha256" && CatalogRecordDTO.isWholeFileDigest(hex) ? hex : nil
        }
        let archive = archiveFixity.flatMap { f -> String? in
            let hex = f.digest.lowercased()
            return f.algorithm == "sha256" && CatalogRecordDTO.isWholeFileDigest(hex) ? hex : nil
        }
        if let content, let archive, content != archive { return nil }
        if let content, contentFixity?.byteCount == size { return content }
        if let archive, archiveFixity?.sizeBytes == size { return archive }
        return nil
    }

    /// Copy the curated `fields` `source` carries onto `copy` (a record of
    /// the same content). Fields that belong to one row (lineage, archive,
    /// footage decisions, set-aside) are never shared.
    public static func shareCurated(_ fields: [CatalogDDL.KnowledgeField], from source: VideoRecord, to copy: VideoRecord) {
        for field in fields {
            switch field {
            case .starRating: copy.starRating = source.starRating
            case .userNotes: copy.userNotes = source.userNotes
            case .mediaDisposition: copy.mediaDisposition = source.mediaDisposition
            case .tags: copy.tags = source.tags
            case .confirmedByUserPeople, .rejectedPeople:
                copy.confirmedByUserPeople = source.confirmedByUserPeople
                copy.rejectedPeople = source.rejectedPeople
            case .userDate, .userDateConfidence:
                copy.userDate = source.userDate
                copy.userDateConfidence = source.userDateConfidence
            case .userPlace, .userPlaceConfidence:
                copy.userPlace = source.userPlace
                copy.userPlaceConfidence = source.userPlaceConfidence
            case .backupAttestations: copy.backupAttestations = source.backupAttestations
            case .familyMusic: copy.familyMusic = source.familyMusic
            case .repairConfirmedDate, .footageDecisions, .setAsideReason, .archivedAt, .archiveFixity, .lineage,
                 .supersededByID, .mediaReportCard:
                continue
            }
        }
    }
}
