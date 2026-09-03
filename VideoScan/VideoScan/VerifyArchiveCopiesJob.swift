// VerifyArchiveCopiesJob.swift
// "Verify Archive Copies" — the manifest-driven fixity audit + recovery
// pass (GH #167, 2026-08-20). A catalog clobber stripped `archiveFixity`
// from archive-copy records while the on-disk 00_Index manifest still
// carried every SHA-256; this job re-reads each archive copy end to end,
// compares the digest against the manifest, and RESTORES the fixity
// record on a match. It doubles as the periodic fixity audit the
// MediaAngel roadmap wants.
//
// THE CONTRACT every reader of `archiveFixity` relies on (sidebar,
// Archived banner, Volume dashboard, Hallie stats — all treat non-nil as
// "verified"):
//
//     archiveFixity present  ⇒  these bytes verified
//                               AND the file was present at the last Verify.
//
// Per-file semantics (the contract this tool must never soften):
//
//   MATCH        → restore/refresh the record's `archiveFixity` (same
//                  shape as PromoteToArchiveJob writes at promotion).
//   MISMATCH     → NEVER write fixity. Flagged loudly — this is the
//                  potential-corruption signal, the one outcome this
//                  tool exists to surface, never to paper over. A STALE
//                  fixity already on the record is CLEARED (codex #975,
//                  2026-09-02): the field's presence means "verified for
//                  these bytes", and these bytes just failed. The
//                  manifest row keeps the expected digest, so no evidence
//                  is lost — the record simply stops claiming verified.
//   MISSING      → file absent from a REACHABLE archive — flagged, and a
//                  fixity the record carried is CLEARED exactly like a
//                  mismatch (codex #983, 2026-09-02): "verified" cannot
//                  describe a file that is not there. The run goes red.
//                  An UNREACHABLE root (volume gone) is not a verdict:
//                  preflight refuses before any I/O, and a root that
//                  vanishes mid-run aborts the run — nothing is cleared
//                  on the strength of an absent disk.
//   ORPHAN       → manifest row with no catalog record — REPORT ONLY
//                  (Promote's adopt path or a rescan restores it; this
//                  job never invents catalog records).
//   UNMANIFESTED → catalog archive copy with no manifest row — re-hash
//                  if the file exists, report; never append a manifest
//                  row (the manifest is Promote's to write, and a fresh
//                  hash of unknown bytes is not ground truth). On a
//                  mismatch against the record's own previous fixity the
//                  expected digest survives in this job's structured
//                  outcome row (`expectedDigest`) — the record itself
//                  never keeps a digest it failed.
//
// Verify vs. rescan (codex #983 blocker 2): a same-path rescan REPLACES
// the record instance (fresh UUID) while Verify is hashing off-main. So
// every catalog write here resolves its target BY PATH at write time and
// is CONDITIONAL: it lands only when the live record at that path still
// carries the fixity Verify observed when the plan was built (digest
// equality, or both nil). Anything else — record gone from the path, or
// a fixity that moved under us — is skipped, counted
// (`tally.changedUnderVerify`), and reported in ONE line per run:
// "re-run to settle them". The rescan side holds up its half in
// VideoScanModel+RescanPreservation (live fixity re-read at apply time).
//
// Read-only on media throughout: the archive is only ever READ (through
// ArchivePromoteEngine's contained dirfd/O_NOFOLLOW chain — this file
// deliberately reuses `sha256(fd:)`, never a second hasher). Catalog
// writes happen only on the main actor via `restoreArchiveFixity` /
// `invalidateArchiveFixity` (path-conditional, below).
//
// Cancellation is per-chunk (`sha256(fd:shouldCancel:)` polls every
// 1 MB); files already verified keep their restored fixity — the
// batch-end durable save runs on cancel too.
//
// Memory: constant per file (the engine's 1 MB chunk buffer); the plan/
// outcome arrays are O(archive copies + manifest rows) of small value
// structs — a 10k-row archive is ~a few MB. Worst case < 10 MB in-process.

import Combine
import Foundation
import os

private let verifyArchiveLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "verifyArchive")

// MARK: - Manifest index (pure parse + contained load)

/// Every manifest row keyed three ways: by archive relpath (primary —
/// it is what the catalog record's path joins on), by the copy's
/// `record_id`, and by `source_record_id` (fallbacks for a copy record
/// whose path is no longer under the current root). Latest row wins per
/// key — the manifest is append-only, so a later row for the same file
/// (a retried promotion, or a future Refile) supersedes.
struct VerifyArchiveManifestIndex: Sendable {
    struct Row: Sendable, Equatable {
        let relPath: String
        let sha256: String
        let sizeBytes: Int64
        let recordID: UUID?
        let sourceRecordID: UUID?
    }

    let byRelPath: [String: Row]
    let byRecordID: [UUID: Row]
    let bySourceID: [UUID: Row]

    var rowCount: Int { byRelPath.count }

    /// Pure text → index. `nonisolated` + static so the 10k-row scale
    /// test can time it directly with no filesystem.
    /// (For Rick: ≈ a free function over a string — no state, no I/O.)
    nonisolated static func parse(text: String) -> VerifyArchiveManifestIndex {
        var byRelPath: [String: Row] = [:]
        var byRecordID: [UUID: Row] = [:]
        var bySourceID: [UUID: Row] = [:]
        for line in text.split(separator: "\n").dropFirst() {   // header
            let f = ArchiveManifestCSV.fields(ofLine: String(line))
            guard f.count >= 12, !f[ArchiveManifestCSV.relPathColumn].isEmpty else { continue }
            let row = Row(relPath: f[ArchiveManifestCSV.relPathColumn],
                          sha256: f[ArchiveManifestCSV.sha256Column].lowercased(),
                          sizeBytes: Int64(f[3]) ?? 0,
                          recordID: UUID(uuidString: f[6]),
                          sourceRecordID: UUID(uuidString: f[ArchiveManifestCSV.sourceRecordIDColumn]))
            byRelPath[row.relPath] = row
            if let id = row.recordID { byRecordID[id] = row }
            if let id = row.sourceRecordID { bySourceID[id] = row }
        }
        return VerifyArchiveManifestIndex(byRelPath: byRelPath,
                                          byRecordID: byRecordID,
                                          bySourceID: bySourceID)
    }

    /// Load THROUGH the validated descriptor chain (openIndexFile:
    /// dirfd, O_NOFOLLOW, regular file, header checked) — same read
    /// path `fieldRowsBySource` uses; the manifest is never re-opened
    /// by bare path. Throws the same refusals Promote's preflight does.
    nonisolated static func load(rootPath: String) throws -> VerifyArchiveManifestIndex {
        let fd = try ArchivePromoteEngine.openIndexFile(
            root: rootPath, name: MasterArchiveLayout.manifestFilename,
            mustExist: true, expectedHeaders: MasterArchiveLayout.acceptedManifestHeaders)
        defer { close(fd) }
        let data = try ArchivePromoteEngine.readAll(fd: fd)
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ArchivePromoteEngine.Failure.manifestInvalid(
                "\(MasterArchiveLayout.manifestFilename) is not valid UTF-8")
        }
        return parse(text: text)
    }
}

// MARK: - Plan (built on the main actor, Sendable afterwards)

/// What one run will check. Orphans are carried for reporting; only
/// items with a `recordID` are hashed against a reference.
struct VerifyArchivePlan: Sendable {
    struct Item: Sendable {
        /// Catalog archive-copy record; nil ⇒ manifest-only orphan.
        /// Display/lineage only — every WRITE resolves by `fullPath`
        /// (the id may be dead by write time; see file header).
        let recordID: UUID?
        /// Archive-relative path (hash through the contained chain);
        /// nil ⇒ the record's path is outside the current root.
        let relPath: String?
        /// Absolute path — display, the hashing fallback for a record
        /// that lives outside the root, AND the write-time identity of
        /// the record (`VideoScanModel.record(forPath:)`).
        let fullPath: String
        let filename: String
        /// Manifest reference digest; nil ⇒ unmanifested.
        let manifestSHA: String?
        let manifestBytes: Int64?
        /// The record's fixity digest AS OBSERVED when the plan was built
        /// (lowercased) — nil when GH #167-style stripping (or rescan)
        /// left none. Doubles as the unmanifested reference and as the
        /// conditional-write guard: a write lands only if the live
        /// record still carries exactly this.
        let recordDigest: String?
        /// Bytes this item contributes to the progress denominator.
        let expectedBytes: Int64
    }
    let rootPath: String
    /// Items to hash (paired + unmanifested), sorted by path.
    let items: [Item]
    /// Manifest rows with no catalog record — reported, never hashed.
    let orphans: [VerifyArchiveManifestIndex.Row]
    let totalBytes: Int64
}

// MARK: - Job

/// (For Rick: `@MainActor` before the protocol name (SE-0470) — the
/// conformance is UI-thread-only, statically checked, like the other
/// new-style MFO jobs.)
@MainActor
final class VerifyArchiveCopiesJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .verifyArchive
    let startedAt = Date()

    weak var model: VideoScanModel?

    /// Per-disk pacing — one long sequential read of the archive volume.
    private let gates: [MediaVolumeGate]

    // MARK: Outcomes

    struct FileOutcome: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Digest matches the manifest; the record already carried a
            /// matching fixity (verifiedAt refreshed).
            case verified
            /// Digest matches the manifest; the record had NO fixity —
            /// the GH #167 recovery case. Fixity written.
            case restored
            /// Digest does NOT match the reference — potential
            /// corruption. No fixity written; a stale one is cleared.
            case mismatch
            /// Reachable archive, file absent. A fixity the record
            /// carried is cleared.
            case missing
            /// Manifest row with no catalog record. Report only.
            case orphan
            /// Catalog archive copy with no manifest row — hashed if
            /// present, reported; no manifest row invented.
            case unmanifested
            /// The check itself errored (unreadable, symlink refusal…).
            case failed
            /// Bytes matched, but the catalog record at this path changed
            /// under Verify (replaced by a rescan, or its fixity moved) —
            /// nothing written; re-run to settle. (Mismatch / missing
            /// verdicts keep their own kind when the write is skipped —
            /// the alarm stands regardless.)
            case changedUnderVerify
        }
        let id = UUID()
        /// relpath when known, else filename.
        let name: String
        let kind: Kind
        let detail: String
        /// The reference digest this file was checked against (manifest
        /// row, or the record's own previous fixity for an unmanifested
        /// copy). Structured so an unmanifested MISMATCH — whose only
        /// reference was the fixity just cleared — keeps its expected
        /// digest in the report row, not in the record (codex #983 minor).
        var expectedDigest: String? = nil
        /// What the bytes on disk actually hashed to (nil when absent).
        var actualDigest: String? = nil
        /// True when the catalog write this verdict called for was
        /// skipped because the record changed under Verify.
        var writeSkipped: Bool = false
    }
    @Published private(set) var outcomes: [FileOutcome] = []

    struct Tally: Equatable {
        var verified = 0, restored = 0, mismatch = 0, missing = 0
        var orphan = 0, unmanifested = 0, failed = 0
        /// Catalog writes skipped because the record at the path changed
        /// between plan and write (codex #983). Overlaps the verdict
        /// counters: a skipped mismatch is in `mismatch` AND here.
        var changedUnderVerify = 0
        var bytesDone: Int64 = 0
    }
    private(set) var tally = Tally()
    /// Verdicts (mismatch OR missing) that also CLEARED a fixity the
    /// record carried (codex #975/#983). Counted apart from the verdict
    /// tallies so the batch-end save knows a catalog write happened even
    /// when nothing was restored.
    private(set) var staleFixityCleared = 0
    /// Set when the archive root stopped being reachable mid-run: the
    /// remaining items were NOT judged (an absent disk is not a verdict).
    private(set) var abortedRootUnreachable = false

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet { if !state.isActive, finishedAt == nil { finishedAt = Date() } }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText = "Preparing to verify archive copies…"
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue = true
    private(set) var wasRefused = false

    /// Internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    /// TEST SEAM (codex #983 race tests): invoked on the main actor for
    /// each item AFTER its bytes were hashed and BEFORE the verdict is
    /// applied — the exact window a same-path rescan merge or another
    /// fixity writer can land in. Production never sets it.
    var testHookAfterHash: (@MainActor (VerifyArchivePlan.Item) -> Void)?

    var title: String { "Verify Archive Copies" }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label, root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    @Published private(set) var waitingForVolumeLabel: String?
    private var waitingForVolumeRoot: String?
    private var heldGates: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []

    init(model: VideoScanModel, gates: [MediaVolumeGate] = []) {
        self.model = model
        self.gates = gates
    }

    /// Idempotent — a second call is a no-op.
    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            await self.runHoldingGates()
        }
    }

    /// Park the row as refused before any work (Center-level guard).
    func refuseToStart(reason: String) {
        guard task == nil, state.isActive else { return }
        wasRefused = true
        finish(failed: reason)
        task = Task {}
    }

    func cancel() {
        guard state.isActive else { return }
        state = .cancelling
        subtitleText = "Cancelling — files already verified keep their fixity…"
        task?.cancel()
    }

    // MARK: Gates (same holding pattern as Promote)

    private func runHoldingGates() async {
        for gate in gates {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                heldGates.append((gate, permit))
                VolumeGateBoard.shared.claim(root: gate.root, jobID: id,
                                             name: "Verify Archive Copies")
            } catch {
                waitingForVolumeLabel = nil
                waitingForVolumeRoot = nil
                await releaseGates()
                finishCancelled()
                return
            }
        }
        waitingForVolumeLabel = nil
        waitingForVolumeRoot = nil
        await run()
        await releaseGates()
    }

    private func releaseGates() async {
        for entry in heldGates.reversed() {
            await entry.permit.close()
            VolumeGateBoard.shared.clear(root: entry.gate.root, jobID: id)
        }
        heldGates = []
    }

    // MARK: Preflight

    /// Refuse before ANY I/O when: read-only viewer (fixity restoration
    /// is a catalog write); no designation; the mounted volume is not
    /// the archive volume (UUID mismatch); root offline; manifest
    /// missing / symlinked / header-less.
    func preflight(model: VideoScanModel) -> String? {
        if model.isReadOnly {
            finish(failed: "This Mac is a read-only viewer of the catalog — verification results could not be recorded here. Run Verify Archive Copies on the master Mac.")
            return nil
        }
        guard let root = model.masterArchiveRootPath else {
            finish(failed: "No Master Archive is designated — nothing to verify. Initialize a Master Archive first.")
            return nil
        }
        if let refusal = model.masterArchiveIdentityRefusal() {
            model.masterArchiveIdentityMismatch = refusal
            finish(failed: refusal)
            return nil
        }
        guard Self.archiveRootIsReachable(root) else {
            finish(failed: "The Master Archive folder is not reachable (\(root)). Connect the archive volume and try again.")
            return nil
        }
        do {
            try ArchiveManifestCSV.validate(rootPath: root)
        } catch {
            finish(failed: PromoteToArchiveJob.describe(error))
            return nil
        }
        return root
    }

    /// "Reachable" for the MISSING verdict: the root directory is there
    /// AND the manifest is still inside it. A yanked volume fails both;
    /// a stale mount point (empty directory left behind) fails the
    /// second — either way no file under it can be judged absent.
    nonisolated static func archiveRootIsReachable(_ root: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return FileManager.default.fileExists(
            atPath: MasterArchiveLayout.manifestURL(rootPath: root).path)
    }

    // MARK: Plan collection (main actor — reads the live catalog)

    /// Pair the catalog's archive copies with the manifest. Catalog side:
    /// every active record that IS a promoted copy (`derivationKind ==
    /// archivePromotion`) or that lives under the archive root (cataloged
    /// by rescan), excluding 00_Index. Manifest side joins by relpath
    /// first, then by the copy's record id, then by source id.
    static func collectPlan(model: VideoScanModel,
                            root: String,
                            manifest: VerifyArchiveManifestIndex) -> VerifyArchivePlan {
        let indexPrefix = MasterArchiveLayout.indexFolder + "/"
        var items: [VerifyArchivePlan.Item] = []
        var claimedRelPaths = Set<String>()
        var total: Int64 = 0

        let copies = pfActiveRecords(model.records).filter { rec in
            model.isArchiveCopy(rec) || ArchivePathResolver.isInside(path: rec.fullPath, root: root)
        }
        for rec in copies {
            let rel = relPath(of: rec.fullPath, underRoot: root)
            if let rel, rel.hasPrefix(indexPrefix) { continue }   // manifest/README are not media
            var row: VerifyArchiveManifestIndex.Row?
            if let rel { row = manifest.byRelPath[rel] }
            if row == nil { row = manifest.byRecordID[rec.id] }
            if row == nil, let src = rec.derivedFrom { row = manifest.bySourceID[src] }
            if let claimed = row?.relPath { claimedRelPaths.insert(claimed) }
            // The manifest digest is the expected REFERENCE, never a path
            // redirect. A promoted catalog record may have been moved
            // outside the designated archive root; Verify must read that
            // record's own fullPath. Otherwise bytes still sitting at the
            // old manifest path could falsely bless different bytes at the
            // catalog path (codex #985 cycle 4).
            let bytes = row?.sizeBytes ?? rec.sizeBytes
            items.append(.init(recordID: rec.id,
                               relPath: rel,
                               fullPath: rec.fullPath,
                               filename: rec.filename,
                               manifestSHA: row?.sha256,
                               manifestBytes: row?.sizeBytes,
                               recordDigest: rec.archiveFixity?.digest.lowercased(),
                               expectedBytes: max(0, bytes)))
            total += max(0, bytes)
        }
        let orphans = manifest.byRelPath.values
            .filter { !claimedRelPaths.contains($0.relPath) }
            .sorted { $0.relPath < $1.relPath }
        let sorted = items.sorted { ($0.relPath ?? $0.fullPath) < ($1.relPath ?? $1.fullPath) }
        return VerifyArchivePlan(rootPath: root, items: sorted,
                                 orphans: orphans, totalBytes: total)
    }

    /// `path` relative to `root` (component-wise, standardized), or nil
    /// when not under it. Raw `.` / `..` components are rejected BEFORE
    /// standardization: normalizing `root/link/../clip.mov` can erase a
    /// symlink-sensitive traversal and make the contained hasher read a
    /// different file from the catalog path.
    nonisolated static func relPath(of path: String, underRoot root: String) -> String? {
        guard !containsLexicalDotComponent(path),
              !containsLexicalDotComponent(root) else { return nil }
        let rootComps = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard rootComps.count > 1, pathComps.count > rootComps.count,
              Array(pathComps.prefix(rootComps.count)) == rootComps else { return nil }
        return pathComps[rootComps.count...].joined(separator: "/")
    }

    /// Pure lexical check — deliberately does not resolve symlinks or touch
    /// the filesystem. A literal `%2E%2E` filename remains legal; only path
    /// components the POSIX resolver treats as `.` / `..` are refused.
    nonisolated static func containsLexicalDotComponent(_ path: String) -> Bool {
        path.split(separator: "/", omittingEmptySubsequences: true).contains {
            $0 == "." || $0 == ".."
        }
    }

    // MARK: Run

    private func run() async {
        guard state != .cancelling else { finishCancelled(); return }
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }
        guard let root = preflight(model: model) else { return }

        subtitleText = "Reading the archive manifest…"
        let manifest: VerifyArchiveManifestIndex
        do {
            manifest = try await Self.loadManifestOffMain(rootPath: root)
        } catch {
            finish(failed: PromoteToArchiveJob.describe(error))
            return
        }

        let plan = Self.collectPlan(model: model, root: root, manifest: manifest)
        verifyArchiveLog.info("verify archive START: \(plan.items.count) copy record(s), \(manifest.rowCount) manifest row(s), \(plan.orphans.count) orphan(s) at \(root, privacy: .public)")
        isIndeterminateValue = false

        // Orphans first — pure reporting, no I/O.
        for row in plan.orphans {
            tally.orphan += 1
            record(.orphan, row.relPath,
                   "in the manifest (sha256 \(row.sha256.prefix(12))…) but not in the catalog — a rescan or Promote's adopt path can restore the record",
                   expected: row.sha256)
        }

        let total = plan.items.count
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled || state == .cancelling { break }
            subtitleText = "\(index + 1)/\(total) · \(item.filename)"
            let keepGoing = await verifyOne(item, model: model, root: root, totalBytes: plan.totalBytes)
            tally.bytesDone += item.expectedBytes
            fractionValue = plan.totalBytes > 0
                ? min(1, Double(tally.bytesDone) / Double(plan.totalBytes))
                : 1
            if !keepGoing { break }
        }

        // Batch end: one durable save carrying every restored fixity —
        // runs on cancel too (verified files STAY verified). A cleared
        // fixity (mismatch OR missing) is a catalog write as well and must
        // land for the same reason: an unverified record must not come
        // back green on the next launch.
        if tally.restored + tally.verified + tally.unmanifested + staleFixityCleared > 0 {
            if !model.saveCatalogNow() {
                model.log("Verify Archive: the catalog could not be saved right now — restored fixity records are in memory and will persist with the next successful save.")
            }
        }
        finishRun(model: model)
    }

    /// One item: hash (contained chain when the path is under the root,
    /// plain O_NOFOLLOW read otherwise), then classify + apply. Returns
    /// false when the run must stop (archive root vanished).
    private func verifyOne(_ item: VerifyArchivePlan.Item,
                           model: VideoScanModel,
                           root: String,
                           totalBytes: Int64) async -> Bool {
        let name = item.relPath ?? item.filename
        // Do not let the off-root fallback hash a raw path that relPath
        // deliberately refused. With a symlink followed by `..`, the raw
        // catalog path and its standardized spelling can name different
        // files. That is no safe basis for either blessing or clearing
        // fixity, so fail closed without reading bytes or writing catalog.
        if Self.containsLexicalDotComponent(item.fullPath)
            || Self.containsLexicalDotComponent(root) {
            tally.failed += 1
            let detail = "catalog path contains a '.' or '..' component — refused without reading bytes; existing fixity was preserved"
            record(.failed, name, detail)
            verifyArchiveLog.error("verify archive: \(item.fullPath, privacy: .public) — \(detail, privacy: .public)")
            return true
        }
        let actualOrNil: String?
        do {
            let reporter = PromoteProgressReporter()
            let fileBytes = max(1, item.expectedBytes)
            let baseDone = tally.bytesDone
            let filename = item.filename
            let denominator = max(1, totalBytes)
            // Throttled to ~4 UI updates/s — a 40 GB tape posts ~40k
            // 1 MB chunk callbacks otherwise (Promote's reporter, reused).
            let progress: @Sendable (Int64) -> Void = { [weak self] done in
                guard let tick = reporter.tick(phase: .verifying, done: done, fileBytes: fileBytes) else { return }
                let overall = Double(baseDone + min(done, fileBytes)) / Double(denominator)
                let sub = "Verifying \(filename) · \(tick.doneText) of \(tick.totalText) · \(tick.rateText)\(tick.etaText)"
                Task { @MainActor [weak self] in
                    guard let self, self.state.isActive else { return }
                    self.fractionValue = min(1, max(self.fractionValue, overall))
                    self.subtitleText = sub
                }
            }
            if let rel = item.relPath {
                actualOrNil = try await Self.hashContainedOffMain(root: root, relPath: rel, progress: progress)
            } else if FileManager.default.fileExists(atPath: item.fullPath) {
                actualOrNil = try await Self.hashPathOffMain(path: item.fullPath, progress: progress)
            } else {
                actualOrNil = nil
            }
        } catch {
            // A read error from a volume that is no longer there is not a
            // verdict on this file. In-root items use the archive root;
            // off-root promoted records use THEIR OWN path's volume.
            guard Self.itemVolumeIsReachable(item, archiveRoot: root) else {
                return abortRootUnreachable(name: name, item: item)
            }
            tally.failed += 1
            record(.failed, name, PromoteToArchiveJob.describe(error))
            verifyArchiveLog.error("verify archive: \(name, privacy: .public) — \(PromoteToArchiveJob.describe(error), privacy: .public)")
            return true
        }
        // `sha256` returns nil on cancel as well as on absence.
        if Task.isCancelled || state == .cancelling { return false }

        // The write-race window (see file header): the catalog may have
        // changed while the bytes were being read.
        testHookAfterHash?(item)

        guard let actual = actualOrNil?.lowercased() else {
            // Absent — but absent from WHAT? If the archive root itself is
            // gone (volume yanked mid-run), no file under it can be judged
            // and nothing may be cleared: stop here, no verdict.
            guard Self.itemVolumeIsReachable(item, archiveRoot: root) else {
                return abortRootUnreachable(name: name, item: item)
            }
            flagMissing(item: item, name: name, model: model)
            return true
        }

        if let expected = item.manifestSHA {
            if actual == expected {
                applyMatch(item: item, digest: actual, model: model, name: name)
            } else {
                flagMismatch(item: item, name: name, expected: expected, actual: actual,
                             reference: "manifest", model: model)
            }
            return true
        }

        // Unmanifested: the only reference is the record's own fixity.
        if let recorded = item.recordDigest {
            if actual == recorded {
                let write = model.restoreArchiveFixity(path: item.fullPath,
                                                       observedDigest: item.recordDigest,
                                                       digest: actual,
                                                       sizeBytes: item.expectedBytes)
                if write == .changedUnderVerify {
                    noteChangedUnderVerify(name: name, verdict: "bytes match the catalog's fixity record (no manifest row)",
                                           expected: recorded, actual: actual)
                } else {
                    tally.unmanifested += 1
                    record(.unmanifested, name, "no manifest row, but the bytes match the catalog's fixity record — consider re-promoting so the manifest covers it",
                           expected: recorded, actual: actual)
                }
            } else {
                flagMismatch(item: item, name: name, expected: recorded, actual: actual,
                             reference: "catalog fixity record", model: model)
            }
        } else {
            tally.unmanifested += 1
            record(.unmanifested, name, "no manifest row and no fixity record — current bytes hash to \(actual.prefix(12))…; no reference to verify against (nothing was written)",
                   actual: actual)
        }
        return true
    }

    /// The archive root vanished mid-run (volume yanked): this item gets
    /// no verdict, nothing is written, and the loop stops. Returns false
    /// for the loop.
    private func abortRootUnreachable(name: String, item: VerifyArchivePlan.Item? = nil) -> Bool {
        abortedRootUnreachable = true
        tally.failed += 1
        let subject = item?.relPath == nil ? "the volume containing this catalog path" : "the Master Archive"
        record(.failed, name, "\(subject) became unreachable while verifying — no verdict for this file (nothing written); reconnect the volume and re-run")
        verifyArchiveLog.error("verify archive ABORT: item volume unreachable mid-run at \(name, privacy: .public)")
        return false
    }

    /// Direct, no-cache volume reachability for a verdict. The designated
    /// archive gets its stronger root+manifest check. A promoted record that
    /// lives elsewhere is judged against the volume containing `fullPath`,
    /// never against the still-mounted archive volume.
    nonisolated static func itemVolumeIsReachable(
        _ item: VerifyArchivePlan.Item,
        archiveRoot: String
    ) -> Bool {
        if item.relPath != nil { return archiveRootIsReachable(archiveRoot) }
        let comps = (item.fullPath as NSString).pathComponents
        if comps.count >= 3, comps[1] == "Volumes" {
            return VolumeReachability.currentMountedRoots().contains("/Volumes/\(comps[2])")
        }
        // Internal paths all reside on the root filesystem. File/directory
        // absence is a MISSING verdict; only loss of the owning volume is
        // "unreachable".
        return VolumeReachability.currentMountedRoots().contains("/")
    }

    private func applyMatch(item: VerifyArchivePlan.Item, digest: String,
                            model: VideoScanModel, name: String) {
        let hadFixity = item.recordDigest != nil
        let write = model.restoreArchiveFixity(path: item.fullPath,
                                               observedDigest: item.recordDigest,
                                               digest: digest,
                                               sizeBytes: item.manifestBytes ?? item.expectedBytes)
        if write == .changedUnderVerify {
            noteChangedUnderVerify(name: name, verdict: "bytes match the manifest",
                                   expected: digest, actual: digest)
            return
        }
        if hadFixity {
            tally.verified += 1
            record(.verified, name, "matches the manifest (sha256 \(digest.prefix(12))…)",
                   expected: digest, actual: digest)
        } else {
            tally.restored += 1
            record(.restored, name, "matches the manifest — fixity record restored (sha256 \(digest.prefix(12))…)",
                   expected: digest, actual: digest)
            model.log("Verify Archive: restored fixity on \(name) from the manifest.")
        }
    }

    /// The loud path. Fixity is NEVER written here — a mismatch must
    /// stay visible until a human resolves it.
    ///
    /// A fixity the record ALREADY carries is cleared (codex #975): its
    /// presence tells every UI reader "verified", and the bytes on disk
    /// just proved otherwise. The expected digest survives in the
    /// manifest row (and in this outcome's structured row + the logs),
    /// so clearing loses no evidence — it only stops a false green.
    private func flagMismatch(item: VerifyArchivePlan.Item, name: String,
                              expected: String, actual: String,
                              reference: String, model: VideoScanModel) {
        tally.mismatch += 1
        let write = model.invalidateArchiveFixity(path: item.fullPath, observedDigest: item.recordDigest)
        let cleared = write == .written
        if cleared { staleFixityCleared += 1 }
        let skipped = write == .changedUnderVerify
        if skipped { tally.changedUnderVerify += 1 }
        let fixityClause: String
        if cleared {
            fixityClause = "Stale fixity record CLEARED (it claimed these bytes were verified); nothing restored"
        } else if skipped {
            fixityClause = "The catalog record changed under Verify, so its fixity was left alone — re-run Verify to settle it; nothing restored"
        } else {
            fixityClause = "Fixity NOT restored"
        }
        let detail = "POSSIBLE CORRUPTION — bytes on disk hash to \(actual.prefix(16))… but the \(reference) says \(expected.prefix(16))…. \(fixityClause); check this file by hand before trusting it."
        outcomes.append(FileOutcome(name: name, kind: .mismatch, detail: detail,
                                    expectedDigest: expected, actualDigest: actual,
                                    writeSkipped: skipped))
        model.log("Verify Archive: MISMATCH \(name) — \(detail)")
        appLog.write("verify archive MISMATCH: \(name) — expected \(expected) (\(reference)), got \(actual)\(cleared ? "; stale fixity record cleared" : "")\(skipped ? "; record changed under Verify, fixity untouched" : "")")
        verifyArchiveLog.error("verify archive MISMATCH: \(name, privacy: .public) expected \(expected, privacy: .public) actual \(actual, privacy: .public) staleFixityCleared=\(cleared) changedUnderVerify=\(skipped)")
    }

    /// File absent from a REACHABLE archive (caller checked). Same
    /// catalog consequence as a mismatch (codex #983): a fixity the
    /// record carries is cleared — "verified" cannot describe a file that
    /// is not there. The manifest row (recovery ground truth) is untouched.
    private func flagMissing(item: VerifyArchivePlan.Item, name: String, model: VideoScanModel) {
        tally.missing += 1
        let write = model.invalidateArchiveFixity(path: item.fullPath, observedDigest: item.recordDigest)
        let cleared = write == .written
        if cleared { staleFixityCleared += 1 }
        let skipped = write == .changedUnderVerify
        if skipped { tally.changedUnderVerify += 1 }
        let listedIn = item.manifestSHA != nil ? "manifest" : "catalog"
        let fixityClause: String
        if cleared {
            fixityClause = " Its fixity record was CLEARED (it claimed a verified file that is not there)."
        } else if skipped {
            fixityClause = " The catalog record changed under Verify, so its fixity was left alone — re-run Verify to settle it."
        } else {
            fixityClause = ""
        }
        let detail = "listed in the \(listedIn) but the file is not in the archive — check the archive by hand.\(fixityClause)"
        outcomes.append(FileOutcome(name: name, kind: .missing, detail: detail,
                                    expectedDigest: item.manifestSHA ?? item.recordDigest,
                                    actualDigest: nil, writeSkipped: skipped))
        model.log("Verify Archive: MISSING \(name) — the archive volume is reachable but the file is not there.\(fixityClause)")
        appLog.write("verify archive MISSING: \(name)\(cleared ? " — fixity record cleared" : "")\(skipped ? " — record changed under Verify, fixity untouched" : "")")
        verifyArchiveLog.error("verify archive MISSING: \(name, privacy: .public) fixityCleared=\(cleared) changedUnderVerify=\(skipped)")
    }

    /// A MATCH whose write was skipped: the verdict is good news but the
    /// record it was for is not the record that is there now.
    private func noteChangedUnderVerify(name: String, verdict: String,
                                        expected: String, actual: String) {
        tally.changedUnderVerify += 1
        outcomes.append(FileOutcome(name: name, kind: .changedUnderVerify,
                                    detail: "\(verdict), but the catalog record changed under Verify (replaced by a rescan, or its fixity moved) — nothing written; re-run Verify to settle it",
                                    expectedDigest: expected, actualDigest: actual,
                                    writeSkipped: true))
        verifyArchiveLog.notice("verify archive: \(name, privacy: .public) changed under Verify — write skipped")
    }

    private func record(_ kind: FileOutcome.Kind, _ name: String, _ detail: String,
                        expected: String? = nil, actual: String? = nil) {
        outcomes.append(FileOutcome(name: name, kind: kind, detail: detail,
                                    expectedDigest: expected, actualDigest: actual))
    }

    // MARK: Finish

    private func finishRun(model: VideoScanModel) {
        let summary = Self.summaryLine(tally)
        if Task.isCancelled || state == .cancelling {
            let kept = tally.verified + tally.restored
            model.log("Verify Archive: stopped\(kept > 0 ? " (\(kept) file(s) already verified keep their fixity)" : "").")
            finishCancelled()
            return
        }
        // ONE line per run for the race skips (never per-record spam).
        if tally.changedUnderVerify > 0 {
            model.log("Verify Archive: \(tally.changedUnderVerify) record(s) changed under Verify; re-run to settle them.")
        }
        if abortedRootUnreachable {
            let message = "The Master Archive became unreachable during verification — stopped; files not yet checked were NOT judged (nothing cleared). \(summary)"
            model.log("Verify Archive: \(message)")
            finish(failed: message)
            return
        }
        model.log("Verify Archive: \(summary).")
        if tally.mismatch > 0 || tally.missing > 0 || tally.failed > 0 {
            // A mismatch, missing file, or read refusal is a completed run
            // with an alarming verdict — the row goes red so it cannot be
            // skimmed past.
            finish(failed: summary)
        } else {
            finish(success: summary)
        }
    }

    /// Pure so tests can pin the wording per tally shape.
    nonisolated static func summaryLine(_ t: Tally) -> String {
        var parts: [String] = []
        if t.mismatch > 0 { parts.append("\(t.mismatch) MISMATCH — possible corruption") }
        parts.append("\(t.verified + t.restored) verified")
        if t.restored > 0 { parts.append("fixity restored on \(t.restored)") }
        if t.missing > 0 { parts.append("\(t.missing) missing") }
        if t.orphan > 0 { parts.append("\(t.orphan) in manifest only") }
        if t.unmanifested > 0 { parts.append("\(t.unmanifested) unmanifested") }
        if t.failed > 0 { parts.append("\(t.failed) failed") }
        if t.changedUnderVerify > 0 { parts.append("\(t.changedUnderVerify) changed under Verify — re-run to settle") }
        return parts.joined(separator: " · ")
    }

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        // Rick 2026-08-26: a job whose cancel was requested NEVER ends
        // .failed — the SIGTERM'd child's non-zero exit, or any typed error
        // thrown while the Task unwinds, is the user's Stop, not a failure.
        // (Stalls are unaffected: the watchdog cancels the Task but never
        // sets .cancelling — see MediaFileOperationState.cancelWasRequested.)
        if state.cancelWasRequested { finishCancelled(); return }
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        verifyArchiveLog.warning("verify archive failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled — \(Self.summaryLine(tally))"
        isIndeterminateValue = false
    }

    // MARK: Off-main hops
    //
    // `@concurrent` (Approachable Concurrency): without it a
    // `nonisolated async` runs on the CALLER's actor — the multi-GB
    // hash would run ON MAIN (the trap that has bitten this repo 3×).

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func loadManifestOffMain(rootPath: String) async throws -> VerifyArchiveManifestIndex {
        try VerifyArchiveManifestIndex.load(rootPath: rootPath)
    }

    /// Digest of an archive-relative file through the contained dirfd
    /// O_NOFOLLOW chain; nil ⇒ absent OR cancelled (caller checks
    /// Task.isCancelled); throws for non-contained / symlink / unreadable.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func hashContainedOffMain(root: String, relPath: String,
                                                 progress: @escaping @Sendable (Int64) -> Void) async throws -> String? {
        guard let fd = try ArchivePromoteEngine.openContainedFile(root: root, relativePath: relPath) else { return nil }
        defer { Darwin.close(fd) }
        return try ArchivePromoteEngine.sha256(fd: fd,
                                               shouldCancel: { Task.isCancelled },
                                               progress: progress)
    }

    /// Digest of an absolute path (O_NOFOLLOW, regular file only) — the
    /// fallback for a copy record whose path is outside the current root.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func hashPathOffMain(path: String,
                                            progress: @escaping @Sendable (Int64) -> Void) async throws -> String? {
        let h = try ArchivePromoteEngine.openSource(path: path)
        defer { h.close() }
        return try ArchivePromoteEngine.sha256(fd: h.fd,
                                               shouldCancel: { Task.isCancelled },
                                               progress: progress)
    }
}

// MARK: - Model surface (the ONLY catalog writes this feature makes)

extension VideoScanModel {

    /// What a path-conditional fixity write did. (For Rick: a result
    /// code, not an error — every case is a legitimate outcome the job
    /// counts differently.)
    enum ArchiveFixityWrite: Equatable, Sendable {
        /// The live record's fixity was set (restore) or removed (clear).
        case written
        /// A clear was asked for, but the live record carries no fixity
        /// and none was observed — nothing to do, not a write.
        case nothingToClear
        /// No record lives at the path any more, or the one that does
        /// carries a different fixity than Verify observed when it
        /// started. Skipped: this verdict was for a record that is no
        /// longer there. Re-run Verify to settle.
        case changedUnderVerify
        /// Read-only viewer.
        case refused
    }

    /// The conditional-write guard shared by restore and clear (codex
    /// #983 blocker 2). Resolves the LIVE record by path — a same-path
    /// rescan replaces the instance (fresh UUID) but keeps the path, and
    /// the path index is refreshed by `records.didSet` and the aggregates
    /// revision (renames bump it, main 4f74d809). The write is allowed
    /// only when that record still carries exactly the fixity the plan
    /// observed: same digest, or both absent.
    private func liveRecordForFixityWrite(path: String,
                                          observedDigest: String?) -> VideoRecord? {
        guard let rec = record(forPath: path) else { return nil }
        let live = rec.archiveFixity?.digest.lowercased()
        return live == observedDigest?.lowercased() ? rec : nil
    }

    /// Restore (or refresh) an archive copy's full-file fixity record —
    /// same shape `registerPromotedCopy` writes at promotion time.
    /// Called by VerifyArchiveCopiesJob AFTER an end-to-end read-back
    /// matched the manifest digest (or, for an unmanifested copy, its
    /// own previous fixity). Path-conditional (see
    /// `liveRecordForFixityWrite`). Refused on a read-only viewer.
    @discardableResult
    func restoreArchiveFixity(path: String,
                              observedDigest: String?,
                              digest: String,
                              sizeBytes: Int64,
                              verifiedAt: Date = Date()) -> ArchiveFixityWrite {
        guard !isReadOnly else { return .refused }
        guard let rec = liveRecordForFixityWrite(path: path, observedDigest: observedDigest) else {
            return .changedUnderVerify
        }
        rec.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: verifiedAt,
                                          sizeBytes: sizeBytes)
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        return .written
    }

    /// Clear a record's fixity after an end-to-end read-back proved the
    /// bytes no longer match the reference (codex #975), or the file is
    /// absent from a reachable archive (codex #983). `archiveFixity`
    /// present ⇒ verified for THESE bytes AND present — so a record that
    /// just failed either must stop carrying one. Nothing is written in
    /// its place: only a byte-for-byte match ever writes fixity.
    /// Path-conditional (see `liveRecordForFixityWrite`).
    @discardableResult
    func invalidateArchiveFixity(path: String,
                                 observedDigest: String?) -> ArchiveFixityWrite {
        guard !isReadOnly else { return .refused }
        guard let rec = liveRecordForFixityWrite(path: path, observedDigest: observedDigest) else {
            return .changedUnderVerify
        }
        guard rec.archiveFixity != nil else { return .nothingToClear }
        rec.archiveFixity = nil
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        return .written
    }
}

// MARK: - Center hook

extension MediaFileOperationsCenter {
    /// Kick off ONE archive-wide fixity verification. Gates on the
    /// archive volume (one long sequential read). Refuses (parked,
    /// `.failed` + wasRefused) when another verification is already
    /// active — two full-archive reads at once would just thrash the
    /// same disk, and the second's fixity writes would race the first's.
    @discardableResult
    func startVerifyArchiveCopies(model: VideoScanModel) -> VerifyArchiveCopiesJob {
        let root = model.masterArchiveRootPath
        let gates = root.map { gatePlan(forPaths: [$0]) } ?? []
        let job = VerifyArchiveCopiesJob(model: model, gates: gates)
        add(job)
        let duplicate = jobs.contains { other in
            other.id != job.id && other.state.isActive && other is VerifyArchiveCopiesJob
        }
        if duplicate {
            job.refuseToStart(reason: "An archive verification is already running — wait for it to finish (or stop it) before starting another. Nothing was started.")
            return job
        }
        job.start()
        appLog.write(Self.startSummaryLine(
            verb: job.kind.logVerb,
            title: job.title,
            plan: "re-read every archive copy and compare against the 00_Index manifest"))
        return job
    }
}
