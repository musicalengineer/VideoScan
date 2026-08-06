// FindTagIngestEngine.swift (VideoScanCore)
// The PURE ingest pass for find-tag journals (2026-08-06, codex QA
// #279/#281): every side effect — file reads, record resolution, tag
// application, catalog persistence, cursor persistence, logging — is
// an injected closure, so the durability ordering is a testable pure
// policy. The app's VideoScanModel wraps this with real dependencies;
// codex tests it with fakes.
//
// THE durability invariant (round-3 blocker): the per-file cursor and
// parse offsets may advance past a verdict batch only when EITHER
//   (a) the batch contained no APPLICABLE verdict (no resolvable
//       record with a score — errors/orphans only), OR
//   (b) saveCatalog() returned true THIS pass,
// AND (round 4) the advanced cursor itself durably persisted
// (persistCursor). "Applicable" — not "applied": a verdict whose
// apply() returns false may be a memory mutation from a PRIOR pass
// whose save failed; the retry pass must still save.
//
// CROSS-PROCESS READER RULES (round-4 blockers — the daemon writes
// while the app reads):
//   - Header classification needs one COMPLETE line: a file with no
//     newline yet (writer created it but hasn't fsync'd runStart) is
//     simply "not ready" — looked at again next poll, NEVER sticky-
//     rejected. Sticky rejection requires a complete first line that
//     positively fails to be a valid, same-catalog, known-recipe,
//     known-version runStart.
//   - Offsets advance only to the last NEWLINE boundary of what was
//     read: a torn trailing fragment (reader raced the writer's
//     append) stays un-consumed and is re-read whole next poll —
//     skipping it via a size-based offset would silently drop the
//     verdict when its remainder lands.

import Foundation

// MARK: - Per-file parse state (in-memory; rebuilt on relaunch)

public struct FindTagIngestFileState: Equatable, Sendable {
    /// Byte offset of journal content already parsed AND cursor-
    /// committed — always a line boundary. Advances only when the
    /// pass is fully durable (catalog + cursor).
    public var parsedThrough: Int64
    /// Nothing pending at last look (skip stat-unchanged files).
    public var exhausted: Bool
    /// Header POSITIVELY failed validation — never look again.
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
        /// Catalog + cursor both durably persisted (or nothing needed
        /// persisting). False ⇒ nothing committed; next pass retries.
        public var durable = true
        public init() {}
    }

    /// One ingest pass. See the file header for the invariants.
    ///
    /// - Parameters mirror the app's dependencies; `persistCursor`
    ///   durably saves the advanced cursor sidecar and reports success
    ///   (round 4: a silent sidecar failure must not strand offsets).
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
        persistCursor: (FindTagIngestState) -> Bool,
        log: (String) -> Void
    ) -> PassResult {
        var result = PassResult()
        /// filename → staged advance, committed only if the pass ends
        /// fully durable.
        var staged: [String: (seq: Int, parsedThrough: Int64, exhausted: Bool)] = [:]
        /// Header fields discovered THIS pass for first-encounter files
        /// (committed to fileStates immediately — header knowledge is
        /// not a durability concern; offsets are).
        var newHeaders: [String: FindTagIngestFileState] = [:]

        for (url, size) in journalFiles.sorted(by: { $0.url.lastPathComponent < $1.url.lastPathComponent }) {
            let name = url.lastPathComponent
            let known = fileStates[name]
            if let known, known.rejected { continue }
            if let known, known.exhausted, known.parsedThrough == size { continue }

            let offsetBase = known?.parsedThrough ?? 0
            guard let raw = readData(url, offsetBase) else { continue }
            // Only COMPLETE lines participate; a torn tail fragment is
            // left for the next poll (its bytes stay above the staged
            // offset).
            let completeLength: Int
            if let lastNewline = raw.lastIndex(of: 0x0A) {
                completeLength = raw.distance(from: raw.startIndex, to: lastNewline) + 1
            } else {
                completeLength = 0
            }
            let complete = raw.prefix(completeLength)

            var fileState: FindTagIngestFileState
            if let known {
                fileState = known
            } else {
                // First encounter: classify the header — but ONLY from
                // a complete first line. No newline yet ⇒ the writer
                // hasn't finished runStart ⇒ not ready, try next poll.
                guard completeLength > 0 else { continue }
                guard let classified = classifyHeader(
                    complete: complete, name: name,
                    activeCatalogPath: activeCatalogPath,
                    isKnownRecipeID: isKnownRecipeID,
                    currentGalleryDigest: currentGalleryDigest,
                    currentParamsDigest: currentParamsDigest,
                    log: log) else {
                    // Positive rejection — sticky.
                    fileStates[name] = FindTagIngestFileState(rejected: true)
                    continue
                }
                fileState = classified
                newHeaders[name] = classified
            }

            let entries = FindTagJournalReader.entries(in: complete)
            let pending = cursor.pendingVerdicts(in: entries, filename: name)
            let stagedOffset = offsetBase + Int64(completeLength)
            guard !pending.isEmpty else {
                staged[name] = (cursor.appliedSeq[name] ?? 0, stagedOffset, true)
                continue
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
            staged[name] = (lastSeq, stagedOffset, true)
        }

        // Header knowledge commits regardless of durability (it never
        // changes); offsets in it start at 0 until a durable commit.
        for (name, header) in newHeaders where fileStates[name] == nil {
            fileStates[name] = header
        }

        // Durability gate 1: any applicable verdict ⇒ catalog must save.
        let catalogDurable = result.applicable == 0 ? true : saveCatalog()
        guard catalogDurable else {
            result.durable = false
            log("Find and Tag ingest: catalog save refused/failed — nothing committed; will retry next pass")
            return result
        }
        // Durability gate 2 (round 4): the advanced cursor must itself
        // persist before offsets move — a silently-lost sidecar with
        // advanced in-memory offsets would suppress retry until
        // relaunch.
        var advanced = cursor
        for (name, stagedState) in staged {
            advanced.markApplied(filename: name, through: stagedState.seq)
        }
        guard staged.isEmpty || persistCursor(advanced) else {
            result.durable = false
            log("Find and Tag ingest: cursor save failed — offsets held; will retry next pass")
            return result
        }
        cursor = advanced
        for (name, stagedState) in staged {
            if var fileState = fileStates[name] {
                fileState.parsedThrough = stagedState.parsedThrough
                fileState.exhausted = stagedState.exhausted
                fileStates[name] = fileState
            }
        }
        return result
    }

    /// First-complete-line header classification. nil = POSITIVE
    /// rejection (caller marks sticky). A valid runStart for this
    /// catalog/recipe/version returns the file's header state.
    private static func classifyHeader(
        complete: Data.SubSequence,
        name: String,
        activeCatalogPath: String,
        isKnownRecipeID: (String) -> Bool,
        currentGalleryDigest: String?,
        currentParamsDigest: String?,
        log: (String) -> Void
    ) -> FindTagIngestFileState? {
        guard let newlineIndex = complete.firstIndex(of: 0x0A) else { return nil }
        let firstLine = Data(complete[complete.startIndex..<newlineIndex])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let entry = try? decoder.decode(FindTagJournalEntry.self, from: firstLine),
              case .runStart(let start) = entry else {
            log("Find and Tag ingest: skipping \(name) — first line is not a run header")
            return nil
        }
        guard start.v == FindTagJournalSchema.version else {
            log("Find and Tag ingest: skipping \(name) — unknown schema v\(start.v)")
            return nil
        }
        guard URL(fileURLWithPath: start.catalogPath).standardizedFileURL.path
                == activeCatalogPath else {
            log("Find and Tag ingest: skipping \(name) — journal is for a different catalog (\(start.catalogPath))")
            return nil
        }
        guard isKnownRecipeID(start.recipeID) else {
            log("Find and Tag ingest: skipping \(name) — unknown recipeID \(start.recipeID)")
            return nil
        }
        if let current = currentGalleryDigest, let run = start.galleryDigest,
           current != run {
            log("Find and Tag ingest: note — \(name) was scored against a different reference gallery (still ingesting; a rescan will re-score)")
        }
        if let current = currentParamsDigest, let run = start.paramsDigest,
           current != run {
            log("Find and Tag ingest: note — \(name) was scored under a different scorer configuration (still ingesting; a rescan will re-score)")
        }
        return FindTagIngestFileState(parsedThrough: 0, exhausted: false,
                                      rejected: false, person: start.person,
                                      recipeID: start.recipeID)
    }
}
