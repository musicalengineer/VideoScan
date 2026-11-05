// FileDossier.swift (VideoScanCore/Dossier) — everything the catalog knows
// about ONE file, in the three layers of docs/design/file_dossier_view.md
// (Rick approved 2026-11-05; phase 1 = §7 step 1):
//   1. Technical — the stored probe facts, read by TechnicalReading;
//   2. Patterns & events — what the analyzers stored: the machine era
//      (MachineEraResolver; `era.none` is never an era), the burned-in
//      dates, the inferred date, scene captions, on-screen text, the
//      transcript, people, the dossier run;
//   3. Across the collection — a placeholder until the corpus rules (§5).
//
// One sentence: a PURE value, built from stored data only — opening it runs
// no model, no ffprobe, no file read. Each line carries its value, who said
// it (in words), its evidence for the ⓘ pop-over, and whether it is a fact,
// a machine observation (never shown as a fact) or a missing reading with
// the reason in words.
//
// Read path: `read(reader:fileID:now:)` runs inside the catalog
// repository's `read` (a snapshot on its reader — no write, no schema
// change): the loader's own one-row read (`storedRow(id:)`, the same mapping
// the app's records come from, so this view cannot disagree with the
// inspector) plus the content's `provenance_assertions` (indexed by
// subject). Measured cost and the budget: FileDossierTests' scale test.
//
// Memory: one file's rows — captions and OCR (tens to a few hundred short
// strings), one transcript (≤ a few hundred KB for a 2-hour tape), the
// content's assertions (tens). Nothing is cached here.
//
// (For Rick: a POD built by a pure function — like a C++ report struct a
// free `build()` fills from DAO rows; no state, no I/O of its own.)

import Foundation

public struct FileDossier: Sendable, Equatable {

    public enum Layer: String, Sendable, CaseIterable {
        case technical, patterns, collection

        public var title: String {
            switch self {
            case .technical: return "Technical"
            case .patterns: return "Patterns & events"
            case .collection: return "Across the collection"
            }
        }
    }

    /// What a line is: a stored fact, a machine observation (unconfirmed),
    /// or a reading that is not there yet (its value says why).
    public enum Standing: String, Sendable, Equatable {
        case fact, observation, missing
    }

    /// One item of a line's body (a caption at a frame time, the transcript).
    public struct TimedText: Sendable, Equatable {
        /// Seconds into the file; nil for an untimed body (a transcript).
        public var at: Double?
        public var text: String

        public init(at: Double?, text: String) {
            self.at = at
            self.text = text
        }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public var label: String
        public var value: String
        /// What it suggests ("→ a straight tape capture"); nil when nothing to add.
        public var reading: String?
        /// Who said it, in words ("ffprobe", "8B era, unconfirmed", "Rick").
        public var source: String
        /// The ⓘ pop-over's text: windows, frames, cue, the chain; nil = no ⓘ.
        public var evidence: String?
        public var standing: Standing
        /// The line's body when opened (captions, OCR reads, the transcript).
        public var body: [TimedText]

        public var id: String { label }

        public init(label: String, value: String, reading: String? = nil, source: String, evidence: String? = nil,
                    standing: Standing, body: [TimedText] = []) {
            self.label = label
            self.value = value
            self.reading = reading
            self.source = source
            self.evidence = evidence
            self.standing = standing
            self.body = body
        }
    }

    public struct Section: Sendable, Equatable, Identifiable {
        public var layer: Layer
        /// The collapsed group's one-line label.
        public var summary: String
        public var lines: [Line]

        public var id: Layer { layer }

        public init(layer: Layer, summary: String, lines: [Line]) {
            self.layer = layer
            self.summary = summary
            self.lines = lines
        }

        public func line(_ label: String) -> Line? { lines.first { $0.label == label } }
    }

    /// `files.id` (= VideoRecord.id).
    public var fileID: String
    public var filename: String
    public var path: String
    /// `content.digest`; nil for a file with no whole-file hash.
    public var digest: String?
    /// Every copy's removal marker is set on THIS row (it is not live).
    public var removed: Bool
    public var technical: Section
    public var patterns: Section
    public var collection: Section

    public var sections: [Section] { [technical, patterns, collection] }

    public init(fileID: String, filename: String, path: String, digest: String?, removed: Bool,
                technical: Section, patterns: Section, collection: Section) {
        self.fileID = fileID
        self.filename = filename
        self.path = path
        self.digest = digest
        self.removed = removed
        self.technical = technical
        self.patterns = patterns
        self.collection = collection
    }

    /// Layer 3's summary until the corpus rules land (design §5, Rick 11/05).
    public static let collectionComingNext = "coming next: the corpus rules (design §5)"
}

// MARK: - Reading it from the catalog

extension FileDossier {

    /// The dossier of `files.id = fileID` from one read snapshot; nil when
    /// the catalog has no such row (a file still waiting for its hash).
    /// Throws only what the reader throws. A stored value that no longer
    /// decodes does not hide the rest: the dossier is built without the
    /// derived values and says why on its own line.
    public static func read(reader: any CatalogLiveReading & CatalogProvenanceAssertionReading, fileID: String,
                            now: Date) throws -> FileDossier? {
        guard let row = try reader.storedRow(id: fileID) else { return nil }
        let record: VideoRecord
        var problem: String?
        do {
            record = try VideoRecord(loaded: row)
        } catch {
            problem = "\(error)"
            var bare = row
            bare.derived = []
            bare.rowKnowledge = [:]
            record = try VideoRecord(loaded: bare)
        }
        let assertions = try row.file.contentDigest.map {
            try reader.provenanceAssertions(subjectKind: ProvenanceAssertionSubject.content, subjectID: $0)
        } ?? []
        return build(record: record, digest: row.file.contentDigest, assertions: assertions, unreadable: problem, now: now)
    }
}
