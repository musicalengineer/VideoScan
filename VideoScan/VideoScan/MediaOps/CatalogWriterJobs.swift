// CatalogWriterJobs.swift
// Which Media File Operations WRITE the catalog while they run (GH #350,
// QA r1). Two readers wait for them: the viewer-snapshot publisher (no
// 240 MB seal + integrity check every 2 min for the length of a run) and
// the Catalog folder Table's paint clock (job churn repaints at most once
// per 10 s). A job that only reads, or writes one derivative at the very
// end, is not a writer; a PAUSED job writes nothing, so it does not count.
//
// TWO explicit lists, one per answer, so a new kind cannot slip in
// unclassified: CatalogWriterJobsTests pins that together they are exactly
// `MediaFileOperationKind.all`, with no kind in both. When in doubt a kind
// is a writer — the cost of a wrong "writer" is a slower repaint and a
// later viewer copy; the cost of a wrong "not a writer" is the #350 churn.
//
// (For Rick: two `static let` sets ≈ two constexpr lookup tables; the
// check is one hash lookup, no switch.)

import Foundation

extension MediaFileOperationKind {

    /// Kinds whose jobs commit catalog rows as they go (checkpoint saves,
    /// per-file stamps, verdicts, removals, imports).
    static let catalogWriters: Set<MediaFileOperationKind> = [
        .analyze, .verifyAudio, .verifyVideo, .checkMedia, .repair, .findPerson, .promote,
        .verifyArchive, .archiveAngel, .deleteDuplicates, .pruneCopies, .findSimilarFootage,
        .bindFixity, .lockArchive, .fingerprintBackfill, .showAgain, .checkCopies, .fillFullHashes,
        .cleanupTrash, .fingerprintSound, .auditCatalog, .verifyCatalog, .importToSQLite, .validateCatalog,
    ]

    /// Kinds that read media, or add one derivative when they finish.
    static let notCatalogWriters: Set<MediaFileOperationKind> = [
        .combine, .compare, .extract, .ripFrames, .reformat, .transcode, .cleanup, .trim,
        .balanceAudio, .rebuildAudio, .compareFootage,
    ]

    var writesCatalog: Bool { Self.catalogWriters.contains(self) }
}

extension MediaFileOperationsCenter {

    /// The first live, unpaused catalog-writing job's title; nil when none
    /// runs. O(jobs). Read by CatalogWriteActivity's two callers.
    var runningCatalogWriterTitle: String? {
        Self.catalogWriterTitle(in: jobs)
    }

    /// The rule, over any job list (tests hand in fakes).
    static func catalogWriterTitle(in jobs: [any MediaFileOperationJob]) -> String? {
        jobs.first { $0.state.isActive && !$0.isQuiescentForQuit && !$0.isPaused && $0.kind.writesCatalog }?.title
    }
}
