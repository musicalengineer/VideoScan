// FindTagIngestEngine.swift (VideoScanCore)
// The PURE ingest pass for find-tag journals (2026-08-06, codex QA
// #279): every side effect — file reads, record resolution, tag
// application, catalog persistence, logging — is an injected closure,
// so the durability ordering that round 2/3 kept getting wrong is now
// a testable pure policy. The app's VideoScanModel wraps this with its
// real dependencies; codex tests it with fakes.
//
// THE durability invariant (round-3 blocker): the per-file cursor may
// advance past a verdict batch only when EITHER
//   (a) the batch contained no APPLICABLE verdict (no resolvable
//       record with a score — errors/orphans only), OR
//   (b) saveCatalog() returned true THIS pass.
// "Applicable" — not "applied": a verdict whose apply() returns false
// may still be a memory mutation from a PRIOR pass whose save failed
// (apply is idempotent, so the retry pass sees no change). Counting
// applied instead of applicable is exactly the round-3 hole: the
// retry pass would skip the save and commit the cursor over a tag
// that never reached disk.
//
// Incremental parsing: per-file `parsedThrough` byte offset — a poll
// re-reads only appended bytes of the active journal (the writer
// fsyncs whole lines, so a committed offset is always a line
// boundary; a torn tail line is skipped by the tolerant reader and
// re-read next pass because offsets only advance on cursor commit).
// Rejected files (foreign catalog, unknown recipeID, unknown schema,
// no runStart) are rejected STICKY — their header can't change.

import Foundation

// MARK: - Per-file parse state (in-memory; rebuilt on relaunch)

public struct FindTagIngestFileState: Equatable, Sendable {
    /// Byte offset of journal content already parsed AND cursor-
    /// committed. Advances only when the pass is durable.
    public var parsedThrough: Int64
    /// Nothing pending at last look (skip stat-unchanged files).
    public var exhausted: Bool
    /// Header failed validation — never look again.
    public var rejected: Bool
    public var person: String
    public var recipeID: String

    public init(parsedThrough: Int64 = 0, exhausted: Bool = false,
                rejected: Bool = false, person: String = "",
                recipeID: String = "") {
        self.parsedThrough = parsedThrough
        self.exhausted = exhausted
        self.rejected = rejected
        self.person = person
        self.recipeID = recipeID
    }
}

// MARK: - Engine

public enum FindTagIngestEngine {

    public struct PassResult: Equatable, Sendable {
        public var applied = 0
        public var applicable = 0
        public var orphaned = 0
        public var durable = true
        public init() {}
    }

    /// One ingest pass over the journal directory's files.
    ///
    /// - Parameters:
    ///   - journalFiles: (url, current byte size) per .jsonl file.
    ///   - fileStates: per-file parse state (caller keeps it in memory).
    ///   - cursor: the persistent per-file seq cursor. MUTATED only on
    ///     a durable pass; the caller persists it iff `result.durable`.
    ///   - activeCatalogPath: standardized path of the catalog THIS app
    ///     owns — journals for any other catalog are rejected.
    ///   - isKnownRecipeID: fail-closed gate for threshold mapping.
    ///   - currentGalleryDigest/currentParamsDigest: the app's present
    ///     scoring provenance; a mismatch with a journal's header is
    ///     LOGGED (epoch mixing is visible) but does not block ingest —
    ///     the verdicts were legitimate under the provenance that
    ///     produced them, same as historical in-app tags.
    ///   - readData: read `url` from byte offset to EOF (nil on error).
    ///   - resolveRecord: recordID + content fingerprint → opaque
    ///     record handle; nil when no trustworthy match exists.
    ///   - apply: apply one verdict; true when catalog memory changed.
    ///   - saveCatalog: durably persist catalog memory; true on disk.
    ///   - log: human-facing ingest log line.
    public static func pass<Record>(
        journalFiles: [(url: URL, size: Int64)],
        fileStates: inout [String: FindTagIngestFileState],
        cursor: inout FindTagIngestState,
        activeCatalogPath: String,
        isKnownRecipeID: (String) -> Bool,
        currentGalleryDigest: String?,
        currentParamsDigest: String?,
        readData: (URL, Int64) -> Data?,
        resolveRecord: (String, String?) -> Record?,
        apply: (String, Record, Double, String) -> Bool,
        saveCatalog: () -> Bool,
        log: (String) -> Void
    ) -> PassResult {
        var result = PassResult()
        /// filename → (seq to commit, bytes parsed, nothing left) —
        /// staged, committed only if the pass ends durable.
        var staged: [String: (seq: Int, parsedThrough: Int64, exhausted: Bool)] = [:]

        for (url, size) in journalFiles.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            let name = url.lastPathComponent
            var fileState = fileStates[name] ?? FindTagIngestFileState()
            if fileState.rejected { continue }
            if fileState.exhausted, fileState.parsedThrough == size { continue }

            // First encounter: full read + header validation.
            if fileStates[name] == nil {
                guard let data = readData(url, 0) else { continue }
                let entries = FindTagJournalReader.entries(in: data)
                guard case .runStart(let start)? = entries.first else {
                    fileState.rejected = true
                    fileStates[name] = fileState
                    continue
                }
                guard URL(fileURLWithPath: start.catalogPath).standardizedFileURL.path
                        == activeCatalogPath else {
                    log("Find and Tag ingest: skipping \(name) — journal is for a different catalog (\(start.catalogPath))")
                    fileState.rejected = true
                    fileStates[name] = fileState
                    continue
                }
                guard isKnownRecipeID(start.recipeID) else {
                    log("Find and Tag ingest: skipping \(name) — unknown recipeID \(start.recipeID)")
                    fileState.rejected = true
                    fileStates[name] = fileState
                    continue
                }
                if let current = currentGalleryDigest, let run = start.galleryDigest,
                   current != run {
                    log("Find and Tag ingest: note — \(name) was scored against a different reference gallery (still ingesting; a rescan will re-score)")
                }
                if let current = currentParamsDigest, let run = start.paramsDigest,
                   current != run {
                    log("Find and Tag ingest: note — \(name) was scored under a different scorer configuration (still ingesting; a rescan will re-score)")
                }
                fileState.person = start.person
                fileState.recipeID = start.recipeID
                fileStates[name] = fileState
                consume(entries: entries, name: name, fileState: fileState,
                        size: size, cursor: cursor, staged: &staged,
                        result: &result, resolveRecord: resolveRecord, apply: apply)
                continue
            }

            // Known file: read only the appended tail. Offsets advance
            // only on durable commit, so a failed pass re-reads and
            // re-derives the same pending set next time.
            guard let tail = readData(url, fileState.parsedThrough) else { continue }
            let entries = FindTagJournalReader.entries(in: tail)
            consume(entries: entries, name: name, fileState: fileState,
                    size: size, cursor: cursor, staged: &staged,
                    result: &result, resolveRecord: resolveRecord, apply: apply)
        }

        // THE invariant: any applicable verdict this pass ⇒ the catalog
        // must durably save before any cursor/offset movement. This
        // covers both fresh applies AND retry passes whose apply()
        // no-ops over dirty memory from an earlier failed save.
        result.durable = result.applicable == 0 ? true : saveCatalog()
        if result.durable {
            for (name, stagedState) in staged {
                cursor.markApplied(filename: name, through: stagedState.seq)
                if var fileState = fileStates[name] {
                    fileState.parsedThrough = stagedState.parsedThrough
                    fileState.exhausted = stagedState.exhausted
                    fileStates[name] = fileState
                }
            }
        } else {
            log("Find and Tag ingest: catalog save refused/failed — nothing committed; will retry next pass")
        }
        return result
    }

    /// Shared verdict-consumption half: filter by cursor, resolve,
    /// apply, stage the file's advance.
    private static func consume<Record>(
        entries: [FindTagJournalEntry],
        name: String,
        fileState: FindTagIngestFileState,
        size: Int64,
        cursor: FindTagIngestState,
        staged: inout [String: (seq: Int, parsedThrough: Int64, exhausted: Bool)],
        result: inout PassResult,
        resolveRecord: (String, String?) -> Record?,
        apply: (String, Record, Double, String) -> Bool
    ) {
        let pending = cursor.pendingVerdicts(in: entries, filename: name)
        guard !pending.isEmpty else {
            staged[name] = (cursor.appliedSeq[name] ?? 0, size, true)
            return
        }
        var lastSeq = 0
        for verdict in pending {
            lastSeq = verdict.seq
            guard let score = verdict.score else { continue }
            guard let record = resolveRecord(verdict.recordID, verdict.fingerprint) else {
                result.orphaned += 1
                continue
            }
            result.applicable += 1
            if apply(fileState.person, record, score, fileState.recipeID) {
                result.applied += 1
            }
        }
        staged[name] = (lastSeq, size, true)
    }
}
