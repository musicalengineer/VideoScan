// DocumentIngest.swift
// Cataloguing things ffprobe cannot describe (2026-08-31).
//
// Rick: "yes create documents per the spec and I can add important pdf
// files such as birth certs, letters, records etc., there" — and, on
// whether the app should know about them: "I think yes so we can search
// them."
//
// WHY THIS IS NOT PART OF THE VOLUME SCAN
//
// The scanner is deliberately video-only (`videoOnlyCatalogScope`, added
// 2026-07-15 after camera raws leaked in through "Scan Unrecognized File
// Types"). Sweeping documents in from a volume walk would undo that
// decision and bury a handful of birth certificates under every stray
// readme, invoice and manual on the drive.
//
// Documents are added deliberately instead, which is also how a person
// actually adds them: a chosen few, not a sweep. That keeps the scan's
// meaning intact and means this feature cannot regress it — there is a
// test asserting the walker still refuses a .pdf.
//
// WHY THERE IS NO SCHEMA CHANGE
//
// A record's medium is derived from its extension (`ArchiveMedium`), not
// stored. Nothing to migrate, nothing to backfill, and a catalog written
// today still opens in a build from last week.

import Foundation

/// Builds catalog records for files ffprobe has nothing to say about —
/// documents today, loose photo scans on the same path later.
enum DocumentIngest {

    enum Rejection: Error, Equatable {
        case notAFile
        case unreadable
        case notADocument(ArchiveMedium)
        case empty

        var message: String {
            switch self {
            case .notAFile:     return "not a file"
            case .unreadable:   return "could not be read"
            case .empty:        return "is empty (0 bytes)"
            case .notADocument(let m):
                return "is \(m == .photo ? "a photo" : "media") — add it with a scan, not as a document"
            }
        }
    }

    /// Everything the caller needs to report a partial success honestly:
    /// which files became records, and which did not and why.
    struct Outcome {
        var records: [VideoRecord] = []
        var rejected: [(url: URL, reason: Rejection)] = []
    }

    /// Catalog a chosen document. Returns nil (with a reason) rather than
    /// a half-filled record, so a bad pick never lands in the catalog as
    /// a phantom the user then has to hunt down.
    @MainActor
    static func makeRecord(url: URL,
                           fileManager: FileManager = .default) -> Result<VideoRecord, Rejection> {
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir),
              !isDir.boolValue else { return .failure(.notAFile) }

        let medium = ArchiveMedium.forFilename(url.lastPathComponent)
        guard medium == .document else { return .failure(.notADocument(medium)) }

        guard let attrs = try? fileManager.attributesOfItem(atPath: url.path) else {
            return .failure(.unreadable)
        }
        let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        guard bytes > 0 else { return .failure(.empty) }

        let rec = VideoRecord()
        rec.filename  = url.lastPathComponent
        rec.ext       = url.pathExtension.lowercased()
        rec.fullPath  = url.path
        rec.directory = url.deletingLastPathComponent().path
        rec.sizeBytes = bytes
        rec.size      = Formatting.humanSize(bytes)

        // A document has no streams. That is the truth, and it is also
        // what routes it to 50_Documents — `.noStreams` plus a document
        // extension. It is NOT `ffprobeFailed`: nothing failed, and
        // calling it a failure would put it in the probe-failure triage
        // queue forever.
        rec.streamTypeRaw = StreamType.noStreams.rawValue
        rec.container     = rec.ext.uppercased()
        rec.isPlayable    = "Not media"
        rec.duration      = ""
        rec.durationSeconds = 0

        let dateFmt = ISO8601DateFormatter()
        dateFmt.formatOptions = [.withFullDate, .withTime,
                                 .withDashSeparatorInDate, .withColonSeparatorInTime]
        if let created = pfDateOrNilIfImpossible(attrs[.creationDate] as? Date) {
            rec.dateCreatedRaw = created
            rec.dateCreated = dateFmt.string(from: created)
        }
        if let modified = pfDateOrNilIfImpossible(attrs[.modificationDate] as? Date) {
            rec.dateModifiedRaw = modified
            rec.dateModified = dateFmt.string(from: modified)
        }

        // Same hash the rest of the catalog uses, so a document takes
        // part in duplicate detection like anything else — people do end
        // up with the same certificate scanned twice.
        rec.partialMD5 = FileHasher.partialMD5(path: url.path)

        rec.mediaDisposition = .unreviewed
        rec.archiveStage = .none
        rec.notes = "Added as a document"
        return .success(rec)
    }

    /// Catalog several picked files, keeping the failures rather than
    /// discarding them — a silent skip is how a birth certificate goes
    /// missing without anyone noticing.
    @MainActor
    static func makeRecords(urls: [URL],
                            fileManager: FileManager = .default) -> Outcome {
        var outcome = Outcome()
        for url in urls {
            switch makeRecord(url: url, fileManager: fileManager) {
            case .success(let rec): outcome.records.append(rec)
            case .failure(let why): outcome.rejected.append((url, why))
            }
        }
        return outcome
    }
}
