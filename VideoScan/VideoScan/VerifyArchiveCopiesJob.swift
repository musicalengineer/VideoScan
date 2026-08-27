// VerifyArchiveCopiesJob.swift
// "Verify Archive Copies" — the manifest-driven fixity audit + recovery
// pass (GH #167, 2026-08-20). A catalog clobber stripped `archiveFixity`
// from archive-copy records while the on-disk 00_Index manifest still
// carried every SHA-256; this job re-reads each archive copy end to end,
// compares the digest against the manifest, and RESTORES the fixity
// record on a match. It doubles as the periodic fixity audit the
// MediaAngel roadmap wants.
//
// Per-file semantics (the contract this tool must never soften):
//
//   MATCH        → restore/refresh the record's `archiveFixity` (same
//                  shape as PromoteToArchiveJob writes at promotion).
//   MISMATCH     → NEVER touch fixity. Flagged loudly — this is the
//                  potential-corruption signal, the one outcome this
//                  tool exists to surface, never to paper over.
//   MISSING      → file absent from a reachable archive — flagged.
//   ORPHAN       → manifest row with no catalog record — REPORT ONLY
//                  (Promote's adopt path or a rescan restores it; this
//                  job never invents catalog records).
//   UNMANIFESTED → catalog archive copy with no manifest row — re-hash
//                  if the file exists, report; never append a manifest
//                  row (the manifest is Promote's to write, and a fresh
//                  hash of unknown bytes is not ground truth).
//
// Read-only on media throughout: the archive is only ever READ (through
// ArchivePromoteEngine's contained dirfd/O_NOFOLLOW chain — this file
// deliberately reuses `sha256(fd:)`, never a second hasher). Catalog
// writes happen only on the main actor via `restoreArchiveFixity`.
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
/// key — the manifest is append-only, so a re-promote's newer row
/// supersedes.
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
        let recordID: UUID?
        /// Archive-relative path (hash through the contained chain);
        /// nil ⇒ the record's path is outside the current root.
        let relPath: String?
        /// Absolute path — display, and the hashing fallback for a
        /// record that lives outside the root.
        let fullPath: String
        let filename: String
        /// Manifest reference digest; nil ⇒ unmanifested.
        let manifestSHA: String?
        let manifestBytes: Int64?
        /// The record's existing fixity digest (unmanifested compare)
        /// — nil when GH #167-style stripping (or rescan) left none.
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
            /// corruption. Fixity untouched.
            case mismatch
            /// Reachable archive, file absent.
            case missing
            /// Manifest row with no catalog record. Report only.
            case orphan
            /// Catalog archive copy with no manifest row — hashed if
            /// present, reported; no manifest row invented.
            case unmanifested
            /// The check itself errored (unreadable, symlink refusal…).
            case failed
        }
        let id = UUID()
        /// relpath when known, else filename.
        let name: String
        let kind: Kind
        let detail: String
    }
    @Published private(set) var outcomes: [FileOutcome] = []

    struct Tally: Equatable {
        var verified = 0, restored = 0, mismatch = 0, missing = 0
        var orphan = 0, unmanifested = 0, failed = 0
        var bytesDone: Int64 = 0
    }
    private(set) var tally = Tally()

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
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
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
            // Prefer hashing the path the MANIFEST names when the record
            // sits elsewhere — the manifest is the recovery ground truth.
            let hashRel = rel ?? row?.relPath
            let bytes = row?.sizeBytes ?? rec.sizeBytes
            items.append(.init(recordID: rec.id,
                               relPath: hashRel,
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
    /// when not under it.
    nonisolated static func relPath(of path: String, underRoot root: String) -> String? {
        let rootComps = URL(fileURLWithPath: root).standardizedFileURL.pathComponents
        let pathComps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard rootComps.count > 1, pathComps.count > rootComps.count,
              Array(pathComps.prefix(rootComps.count)) == rootComps else { return nil }
        return pathComps[rootComps.count...].joined(separator: "/")
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
                   "in the manifest (sha256 \(row.sha256.prefix(12))…) but not in the catalog — a rescan or Promote's adopt path can restore the record")
        }

        let total = plan.items.count
        for (index, item) in plan.items.enumerated() {
            if Task.isCancelled || state == .cancelling { break }
            subtitleText = "\(index + 1)/\(total) · \(item.filename)"
            await verifyOne(item, model: model, root: root, totalBytes: plan.totalBytes)
            tally.bytesDone += item.expectedBytes
            fractionValue = plan.totalBytes > 0
                ? min(1, Double(tally.bytesDone) / Double(plan.totalBytes))
                : 1
        }

        // Batch end: one durable save carrying every restored fixity —
        // runs on cancel too (verified files STAY verified).
        if tally.restored + tally.verified + tally.unmanifested > 0 {
            if !model.saveCatalogNow() {
                model.log("Verify Archive: the catalog could not be saved right now — restored fixity records are in memory and will persist with the next successful save.")
            }
        }
        finishRun(model: model)
    }

    /// One item: hash (contained chain when the path is under the root,
    /// plain O_NOFOLLOW read otherwise), then classify + apply.
    private func verifyOne(_ item: VerifyArchivePlan.Item,
                           model: VideoScanModel,
                           root: String,
                           totalBytes: Int64) async {
        let name = item.relPath ?? item.filename
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
            tally.failed += 1
            record(.failed, name, PromoteToArchiveJob.describe(error))
            verifyArchiveLog.error("verify archive: \(name, privacy: .public) — \(PromoteToArchiveJob.describe(error), privacy: .public)")
            return
        }
        // `sha256` returns nil on cancel as well as on absence.
        if Task.isCancelled || state == .cancelling { return }

        guard let actual = actualOrNil?.lowercased() else {
            tally.missing += 1
            record(.missing, name, "listed in the \(item.manifestSHA != nil ? "manifest" : "catalog") but the file is not in the archive — check the archive by hand")
            model.log("Verify Archive: MISSING \(name) — the archive volume is reachable but the file is not there.")
            return
        }

        if let expected = item.manifestSHA {
            if actual == expected {
                applyMatch(item: item, digest: actual, model: model, name: name)
            } else {
                flagMismatch(name: name, expected: expected, actual: actual,
                             reference: "manifest", model: model)
            }
            return
        }

        // Unmanifested: the only reference is the record's own fixity.
        if let recorded = item.recordDigest {
            if actual == recorded {
                tally.unmanifested += 1
                if let id = item.recordID {
                    model.restoreArchiveFixity(recordID: id, digest: actual,
                                               sizeBytes: item.expectedBytes)
                }
                record(.unmanifested, name, "no manifest row, but the bytes match the catalog's fixity record — consider re-promoting so the manifest covers it")
            } else {
                flagMismatch(name: name, expected: recorded, actual: actual,
                             reference: "catalog fixity record", model: model)
            }
        } else {
            tally.unmanifested += 1
            record(.unmanifested, name, "no manifest row and no fixity record — current bytes hash to \(actual.prefix(12))…; no reference to verify against (nothing was written)")
        }
    }

    private func applyMatch(item: VerifyArchivePlan.Item, digest: String,
                            model: VideoScanModel, name: String) {
        let hadFixity = item.recordDigest != nil
        if let id = item.recordID {
            model.restoreArchiveFixity(recordID: id, digest: digest,
                                       sizeBytes: item.manifestBytes ?? item.expectedBytes)
        }
        if hadFixity {
            tally.verified += 1
            record(.verified, name, "matches the manifest (sha256 \(digest.prefix(12))…)")
        } else {
            tally.restored += 1
            record(.restored, name, "matches the manifest — fixity record restored (sha256 \(digest.prefix(12))…)")
            model.log("Verify Archive: restored fixity on \(name) from the manifest.")
        }
    }

    /// The loud path. Fixity is NEVER written here — a mismatch must
    /// stay visible until a human resolves it.
    private func flagMismatch(name: String, expected: String, actual: String,
                              reference: String, model: VideoScanModel) {
        tally.mismatch += 1
        let detail = "POSSIBLE CORRUPTION — bytes on disk hash to \(actual.prefix(16))… but the \(reference) says \(expected.prefix(16))…. Fixity NOT restored; check this file by hand before trusting it."
        record(.mismatch, name, detail)
        model.log("Verify Archive: MISMATCH \(name) — \(detail)")
        appLog.write("verify archive MISMATCH: \(name) — expected \(expected) (\(reference)), got \(actual)")
        verifyArchiveLog.error("verify archive MISMATCH: \(name, privacy: .public) expected \(expected, privacy: .public) actual \(actual, privacy: .public)")
    }

    private func record(_ kind: FileOutcome.Kind, _ name: String, _ detail: String) {
        outcomes.append(FileOutcome(name: name, kind: kind, detail: detail))
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
        model.log("Verify Archive: \(summary).")
        if tally.mismatch > 0 {
            // A mismatch is a completed run with an alarming verdict —
            // the row goes red so it cannot be skimmed past.
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

// MARK: - Model surface (the ONLY catalog write this feature makes)

extension VideoScanModel {
    /// Restore (or refresh) an archive copy's full-file fixity record —
    /// same shape `registerPromotedCopy` writes at promotion time.
    /// Called by VerifyArchiveCopiesJob AFTER an end-to-end read-back
    /// matched the manifest digest (or, for an unmanifested copy, its
    /// own previous fixity). Refused on a read-only viewer.
    @discardableResult
    func restoreArchiveFixity(recordID: UUID,
                              digest: String,
                              sizeBytes: Int64,
                              verifiedAt: Date = Date()) -> Bool {
        guard !isReadOnly, let rec = record(forID: recordID) else { return false }
        rec.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: verifiedAt,
                                          sizeBytes: sizeBytes)
        noteCatalogRecordsMutated()
        saveCatalogDebounced()
        return true
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
