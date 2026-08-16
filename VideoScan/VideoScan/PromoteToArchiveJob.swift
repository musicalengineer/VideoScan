import Combine
import CryptoKit
import Foundation
import os

// MARK: - PromoteToArchiveJob
//
// "Promote to Archive" (docs/archive_promotion_workflow.md §5, Rick
// 2026-08-15). ONE job per confirmation — N files, disk-paced through the
// MediaVolumeGate like every other MFO verb. Per file:
//
//   1. Resolve the destination relpath (ArchivePathResolver, §2). Refuse
//      if the source is already inside the archive root, or a copy for
//      this source already exists (idempotent — a second Promote of the
//      same selection is a no-op with "skipped" lines, never a duplicate).
//   2. Stream-copy source → `<dest>.partial` in 1 MB chunks, hashing the
//      SOURCE bytes as they go by (one read of the source), checking for
//      cancel between chunks.
//   3. Stream-hash the PARTIAL (a second, independent read of what
//      actually landed). Mismatch ⇒ delete the partial, fail the file.
//   4. rename(partial → dest); F_FULLFSYNC the file + fsync its directory
//      (CatalogStore.fullFsync).
//   5. Append the manifest row with ONE O_APPEND write. If that fails the
//      verified copy is removed again — "every file in the archive has a
//      manifest row" is the invariant the no-app cousin relies on.
//   6. Main actor: probe the copy, create the linked record, stamp the
//      source, `noteCatalogRecordsMutated()` + debounced save.
//
// Free space for the WHOLE batch is checked once, up front (§5.2).
// Cancel-safe: the in-flight partial is removed; completed files stay
// (they are verified, indexed and recorded). Source files are NEVER
// modified — the pipeline only reads them.
//
// Memory: constant per file — one 1 MB chunk buffer for the copy pass
// and one for the verify pass; the plan/result arrays are O(selection)
// (a few hundred bytes per file). Worst case for a 500-file batch is
// well under 2 MB in-process regardless of file sizes.

private let promoteLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                category: "promote")

// MARK: - Job

/// (For Rick: `@MainActor` before the protocol name (SE-0470) says the
/// conformance itself may only be used from the UI thread — statically
/// checked, like the other new-style jobs.)
@MainActor
final class PromoteToArchiveJob: @MainActor MediaFileOperationJob {

    let id = UUID()
    let kind: MediaFileOperationKind = .promote
    let startedAt = Date()

    /// The confirmed plan (root, entries, byte totals). Immutable.
    let plan: ArchivePromotePlan

    private weak var model: VideoScanModel?

    /// Per-disk pacing: the source volumes AND the archive volume. Held
    /// for the whole run (a batch is one long sequential read+write).
    private let gates: [MediaVolumeGate]

    /// One-file result rows for the end-of-run summary.
    struct FileOutcome: Identifiable, Equatable {
        enum Kind: Equatable { case promoted, skipped, failed }
        let id = UUID()
        let filename: String
        let kind: Kind
        /// relpath for promoted; reason for skipped / failed.
        let detail: String
    }
    @Published private(set) var outcomes: [FileOutcome] = []

    @Published private(set) var state: MediaFileOperationState = .running {
        didSet {
            if !state.isActive, finishedAt == nil { finishedAt = Date() }
        }
    }
    @Published private(set) var finishedAt: Date?
    @Published private(set) var subtitleText: String
    @Published private(set) var fractionValue: Double = 0
    @Published private(set) var isIndeterminateValue: Bool = true
    private(set) var wasRefused = false

    /// The run Task — internal so tests can `await job.task?.value`.
    private(set) var task: Task<Void, Never>?

    var title: String {
        plan.entries.count == 1
            ? (plan.entries.first?.filename ?? "1 file")
            : "\(plan.entries.count) files → Master Archive"
    }
    var subtitle: String {
        if let label = waitingForVolumeLabel {
            return VolumeGateBoard.describeWait(label: label,
                                                root: waitingForVolumeRoot ?? "")
        }
        return subtitleText
    }
    var fraction: Double { fractionValue }
    var isIndeterminate: Bool { isIndeterminateValue }

    @Published private(set) var waitingForVolumeLabel: String?
    private var waitingForVolumeRoot: String?
    private var heldGates: [(gate: MediaVolumeGate, permit: PausableGatePermit)] = []

    // MARK: Init / start

    init(plan: ArchivePromotePlan,
         model: VideoScanModel,
         gates: [MediaVolumeGate] = []) {
        self.plan = plan
        self.model = model
        self.gates = gates
        self.subtitleText = plan.entries.isEmpty
            ? "Nothing to promote"
            : "Preparing to promote \(plan.entries.count) file(s)…"
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
        subtitleText = "Cancelling…"
        task?.cancel()
    }

    // MARK: Gates

    private func runHoldingGates() async {
        for gate in gates {
            waitingForVolumeLabel = gate.label
            waitingForVolumeRoot = gate.root
            let permit = PausableGatePermit(semaphore: gate.semaphore)
            do {
                try await permit.acquire()
                heldGates.append((gate, permit))
                VolumeGateBoard.shared.claim(root: gate.root, jobID: id,
                                             name: "Promote \(title)")
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

    // MARK: Run

    private func run() async {
        guard state != .cancelling else { finishCancelled(); return }
        guard let model else { finish(failed: "The catalog went away before the job could start"); return }

        let root = plan.rootPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
            finish(failed: "The Master Archive folder is not reachable (\(root)). Connect the archive volume and try again.")
            return
        }
        let manifestURL = MasterArchiveLayout.manifestURL(rootPath: root)
        guard fm.fileExists(atPath: manifestURL.path) else {
            finish(failed: ArchiveManifestCSV.ManifestError.missingHeader(path: manifestURL.path).description)
            return
        }
        // Batch free-space check (§5.2) — re-read now, the sheet's number
        // may be minutes old.
        if let free = VideoScanModel.freeBytes(atPath: root), free < plan.requiredBytes {
            finish(failed: "Not enough free space on the archive volume — need about \(Self.humanBytes(plan.requiredBytes)), only \(Self.humanBytes(free)) available. Nothing was copied.")
            return
        }

        let total = plan.entries.count
        var promoted = 0, skipped = 0, failed = 0
        /// Names claimed by THIS batch (not yet on disk when the next
        /// file resolves) — folded into the resolver's exists check.
        var claimed = Set<String>()
        var bytesDone: Int64 = 0

        promoteLog.info("promote START: \(total) file(s) → \(root, privacy: .public)")
        isIndeterminateValue = false

        for (index, entry) in plan.entries.enumerated() {
            if Task.isCancelled || state == .cancelling { break }
            subtitleText = "\(index + 1)/\(total) · \(entry.filename)"

            guard let source = model.record(forID: entry.recordID) else {
                record(.skipped, entry.filename, "record no longer in the catalog"); skipped += 1
                continue
            }
            // Idempotency re-check ON the main actor (the plan may be
            // stale — another job could have promoted this since).
            if model.masterArchiveCopy(of: source) != nil {
                record(.skipped, entry.filename, "already has a master copy"); skipped += 1
                model.log("Promote: skipped \(entry.filename) — already in the Master Archive.")
                continue
            }
            if model.isInsideMasterArchive(path: source.fullPath) || model.isArchiveCopy(source) {
                record(.skipped, entry.filename, "already inside the Master Archive"); skipped += 1
                continue
            }
            guard fm.fileExists(atPath: source.fullPath) else {
                record(.failed, entry.filename, "source file missing on disk"); failed += 1
                model.log("Promote: FAILED \(entry.filename) — source file missing on disk.")
                continue
            }

            let facts = ArchivePathResolver.facts(for: source)
            let relPath = ArchivePathResolver.resolveRelativePath(
                facts: facts, rootPath: root,
                fileExists: { path in
                    claimed.contains(path)
                        || fm.fileExists(atPath: path)
                        || fm.fileExists(atPath: path + ".partial")
                })
            let destURL = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(relPath)
            claimed.insert(destURL.path)

            let sourcePath = source.fullPath
            let sourceBytes = source.sizeBytes
            let baseDone = bytesDone
            let totalBytes = max(1, plan.totalBytes)
            let progress: @Sendable (Int64) -> Void = { [weak self] copied in
                Task { @MainActor [weak self] in
                    self?.applyProgress(Double(baseDone + copied) / Double(totalBytes))
                }
            }

            do {
                let sha = try await Self.copyVerifyPublish(sourcePath: sourcePath,
                                                           destinationURL: destURL,
                                                           progress: progress)
                if Task.isCancelled { break }

                // Manifest row FIRST (needs the copy's id → probe first).
                let copyProbe = await model.probeFile(url: destURL)
                let row = ArchiveManifestCSV.Row(
                    promotedAt: Date(),
                    archiveRelPath: relPath,
                    sha256: sha,
                    sizeBytes: copyProbe.sizeBytes > 0 ? copyProbe.sizeBytes : sourceBytes,
                    originalPath: sourcePath,
                    originalVolume: source.volumeName,
                    recordID: copyProbe.id,
                    sourceRecordID: source.id,
                    recordDate: facts.dateHint.manifestDate,
                    dateConfidence: Self.dateConfidenceLabel(source: source, facts: facts),
                    people: Self.peopleForManifest(source),
                    starRating: max(source.starRating, 3))
                do {
                    try ArchiveManifestCSV.append(row, to: manifestURL)
                } catch {
                    // Invariant: no archive file without a manifest row.
                    try? fm.removeItem(at: destURL)
                    throw PromoteError(message: "manifest append failed — \(error); the copy was removed again")
                }

                model.registerPromotedCopy(source: source,
                                           destinationURL: destURL,
                                           relativePath: relPath,
                                           sha256: sha,
                                           probed: copyProbe,
                                           promotedAt: row.promotedAt)
                promoted += 1
                bytesDone += sourceBytes
                record(.promoted, entry.filename, relPath)
                model.log("Promote: \(entry.filename) → \(relPath) (sha256 \(sha.prefix(12))…) ✓")
                promoteLog.info("promoted \(entry.filename, privacy: .public) → \(relPath, privacy: .public)")
            } catch is CancellationError {
                break
            } catch {
                failed += 1
                bytesDone += sourceBytes
                let msg = (error as? PromoteError)?.message ?? String(describing: error)
                record(.failed, entry.filename, msg)
                model.log("Promote: FAILED \(entry.filename) — \(msg)")
                promoteLog.error("promote FAILED \(entry.filename, privacy: .public): \(msg, privacy: .public)")
            }
        }

        if Task.isCancelled || state == .cancelling {
            let done = promoted > 0 ? " (\(promoted) already promoted stay in the archive)" : ""
            model.log("Promote: cancelled\(done).")
            finishCancelled()
            return
        }
        let summary = "Promoted \(promoted) · skipped \(skipped) · failed \(failed)"
        model.log("Promote: \(summary).")
        if promoted == 0 && failed > 0 {
            finish(failed: summary)
        } else {
            finish(success: summary)
        }
    }

    private func record(_ kind: FileOutcome.Kind, _ filename: String, _ detail: String) {
        outcomes.append(FileOutcome(filename: filename, kind: kind, detail: detail))
    }

    private func applyProgress(_ fraction: Double) {
        guard state.isActive else { return }
        fractionValue = min(1, max(fractionValue, fraction))
    }

    // MARK: Off-main copy + verify + publish
    //
    // `@concurrent` (Approachable Concurrency): a `nonisolated async` on
    // this repo runs on the CALLER's actor — without the attribute the
    // whole multi-GB copy would run ON MAIN.

    /// Steps 2–4: chunked copy to `.partial` hashing the source as it
    /// streams, independent verify hash of the partial, rename into
    /// place, full fsync. Returns the sha256 hex. Throws PromoteError
    /// on any failure (partial removed) and CancellationError on cancel
    /// (partial removed).
    #if compiler(>=6.2)
    @concurrent
    #endif
    static func copyVerifyPublish(sourcePath: String,
                                  destinationURL: URL,
                                  progress: @escaping @Sendable (Int64) -> Void) async throws -> String {
        let fm = FileManager.default
        let partialURL = URL(fileURLWithPath: destinationURL.path + ".partial")
        let dir = destinationURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: partialURL.path) {
            try? fm.removeItem(at: partialURL)   // stale partial from a crashed run
        }
        guard fm.createFile(atPath: partialURL.path, contents: nil) else {
            throw PromoteError(message: "could not create \(partialURL.lastPathComponent) in \(dir.path)")
        }
        // Copy pass — 1 MB chunks, source hash on the fly.
        do {
            let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: sourcePath))
            defer { try? reader.close() }
            let writer = try FileHandle(forWritingTo: partialURL)
            defer { try? writer.close() }
            var hasher = SHA256()
            var copied: Int64 = 0
            let chunk = 1 << 20
            while true {
                if Task.isCancelled {
                    try? fm.removeItem(at: partialURL)
                    throw CancellationError()
                }
                guard let data = try reader.read(upToCount: chunk), !data.isEmpty else { break }
                hasher.update(data: data)
                try writer.write(contentsOf: data)
                copied += Int64(data.count)
                progress(copied)
            }
            try writer.synchronize()
            let sourceSHA = hasher.finalize().map { String(format: "%02x", $0) }.joined()

            // Verify pass — independent read of what actually landed.
            let destSHA = try CatalogStore.sha256HexStreaming(fileURL: partialURL)
            guard destSHA == sourceSHA else {
                try? fm.removeItem(at: partialURL)
                throw PromoteError(message: "verification failed — the copy's sha256 (\(destSHA.prefix(12))…) does not match the source (\(sourceSHA.prefix(12))…); the partial was removed")
            }
            // Keep the original's modification date on the archive copy.
            if let attrs = try? fm.attributesOfItem(atPath: sourcePath),
               let mtime = attrs[.modificationDate] as? Date {
                try? fm.setAttributes([.modificationDate: mtime], ofItemAtPath: partialURL.path)
            }
            // Publish: rename into place (non-clobbering — a name that
            // appeared since resolution is a failure, not an overwrite).
            guard !fm.fileExists(atPath: destinationURL.path) else {
                try? fm.removeItem(at: partialURL)
                throw PromoteError(message: "\(destinationURL.lastPathComponent) appeared in the archive while copying — nothing overwritten")
            }
            try fm.moveItem(at: partialURL, to: destinationURL)
            CatalogStore.fullFsync(fileURL: destinationURL)
            return sourceSHA
        } catch let error as PromoteError {
            throw error
        } catch is CancellationError {
            try? fm.removeItem(at: partialURL)
            throw CancellationError()
        } catch {
            try? fm.removeItem(at: partialURL)
            throw PromoteError(message: "copy failed — \(error.localizedDescription)")
        }
    }

    // MARK: Manifest helpers (pure)

    /// The manifest's `date_confidence` column: "user-known" /
    /// "user-estimated" / "inferred 0.87" / "low 0.41" / "".
    static func dateConfidenceLabel(source: VideoRecord,
                                    facts: ArchivePathResolver.RecordFacts) -> String {
        if source.userDate != nil {
            return source.userDateStatus == .known ? "user-known" : "user-estimated"
        }
        if let conf = source.inferredDateConfidence, source.inferredRecordDate != nil {
            let tag = facts.dateIsLowConfidence ? "low" : "inferred"
            return String(format: "%@ %.2f", tag, conf)
        }
        return ""
    }

    /// Confirmed people first, then detected — the manifest's `people`
    /// column (deduped, order-preserving).
    static func peopleForManifest(_ source: VideoRecord) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in source.confirmedByUserPeople.map(\.name) + source.detectedPeople {
            if seen.insert(name).inserted { out.append(name) }
        }
        return out
    }

    // MARK: Finish helpers

    private func finish(success: String) {
        state = .finished(summary: success)
        subtitleText = success
        fractionValue = 1.0
        isIndeterminateValue = false
    }

    private func finish(failed: String) {
        state = .failed(message: failed)
        subtitleText = failed
        isIndeterminateValue = false
        promoteLog.warning("promote failed: \(failed, privacy: .public)")
    }

    private func finishCancelled() {
        state = .cancelled
        subtitleText = "Cancelled"
        isIndeterminateValue = false
    }

    static func humanBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }
}

/// Typed per-file failure so the summary row carries the exact reason.
struct PromoteError: Error, Sendable {
    let message: String
}
