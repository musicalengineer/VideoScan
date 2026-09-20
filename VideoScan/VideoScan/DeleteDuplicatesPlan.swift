// DeleteDuplicatesPlan.swift
// Delete Duplicates — the saved plan (Rick 2026-09-20: quit + resume,
// pause, a time estimate, and something to look at).
//
// `plan.json` under App Support/VideoScan/delete-duplicates/<jobID>/ is the
// job's memory: the volume, every target (record id, path, size, keeper),
// each one's status and reason, the safety snapshot it was taken under.
// It is rewritten atomically after EVERY pair through one ordered writer,
// so a quit or a crash mid-run leaves a plan the next launch can OFFER to
// resume — never resume on its own. A finished plan moves to `done/` and
// stays there for the log; nothing here is ever deleted.
//
// Same shape as ArchiveAngelPlan (plan.json + store + ordered writer), not
// the same files: a deletion plan has no buffer, no companions, no review.
//
// (For Rick: plain Codable value types + a namespace of static functions
// for the file work. `actor` at the bottom ≈ a class with an implicit
// mutex around all members — it serialises the saves.)

import Foundation
import VideoScanCore

struct DeleteDuplicatesPlan: Codable, Sendable, Identifiable, Equatable {

    enum EntryStatus: String, Codable, Sendable {
        case pending
        /// Being read right now (one at a time).
        case verifying
        /// Bytes proved identical; the unlink is in flight. Transient —
        /// a plan reloaded with a row in this state re-verifies it.
        case verified
        case deleted
        /// The gate said no — `note` names the keeper and why.
        case refused
        /// The unlink itself failed (or the file was retained in quarantine).
        case failed
        /// Dropped at resume: the record left the catalog, its path or
        /// keeper changed, or the run was cancelled before it was reached.
        case skipped

        var isSettled: Bool {
            switch self {
            case .pending, .verifying, .verified: return false
            case .deleted, .refused, .failed, .skipped: return true
            }
        }
    }

    struct Entry: Codable, Sendable, Identifiable, Equatable {
        /// Catalog record id of the file to delete.
        var id: UUID
        var path: String
        var filename: String
        var sizeBytes: Int64
        var keeperID: UUID
        var keeperPath: String
        var keeperFilename: String
        /// The keeper's stat stamp when the plan was made. A resume refuses
        /// the row when the keeper on disk no longer reproduces it — a
        /// keeper rewritten between sessions is named, not re-trusted.
        var keeperStamp: FileIdentityStamp?
        /// Master on another drive (the "Also clean up working copies"
        /// mode) — drives the [WORKING-COPY] log line.
        var isWorkingCopy: Bool = false
        var status: EntryStatus = .pending
        var note: String = ""
        var settledAt: Date?
        /// True when the keeper was matched by its stored fixity (not
        /// re-read) for this row. nil until verified.
        var keeperMatchedByStoredFixity: Bool?
        /// WHERE the file is while it sits in quarantine (status
        /// `.verified`): the exact owner-only folder the job moved it into,
        /// written to disk BEFORE the unlink. A crash between the move and
        /// the unlink leaves a plan that names the folder to put the file
        /// back from — recovery never guesses from a basename (codex 1593
        /// blocker 2). Cleared once the row settles.
        var quarantineDirectory: String?
        /// The file's full stat stamp (ctime included) the instant it
        /// landed in quarantine. Recovery restores only a file that still
        /// reproduces it.
        var quarantinedStamp: FileIdentityStamp?

        var keeperVolumeName: String { VolumeReachability.volumeName(forPath: keeperPath) }
    }

    var id: UUID
    var createdAt: Date
    var volumePath: String
    var volumeName: String
    /// `catalogStore.fileLocation` of the catalog the plan was made from —
    /// a plan is only ever offered to the same catalog.
    var catalogLocation: String
    var crossVolumeMode: Bool
    /// Extras on the volume that were never targets, with the reasons
    /// (already logged when the plan was made).
    var skippedBeforePlan: Int
    var summaryLine: String
    /// The pre-delete safety snapshot the cross-volume part ran under.
    var snapshotPath: String?
    var snapshotTakenAt: Date?
    var entries: [Entry]
    var startedAt: Date?
    var finishedAt: Date?
    /// Why the run ended: "completed", "cancelled", "discarded", "stopped
    /// (plan not saved)". nil while the plan is still resumable — including
    /// after a Quit, which suspends the run and leaves the plan in place
    /// for the next launch's offer (codex 1593 #5).
    var outcome: String?
    var log: [String] = []
    /// How many times this plan has been resumed.
    var resumeCount: Int = 0

    init(id: UUID = UUID(), createdAt: Date = Date(), volumePath: String, catalogLocation: String,
         crossVolumeMode: Bool, skippedBeforePlan: Int, summaryLine: String,
         snapshotPath: String? = nil, entries: [Entry]) {
        self.id = id
        self.createdAt = createdAt
        self.volumePath = volumePath
        self.volumeName = URL(fileURLWithPath: volumePath).lastPathComponent
        self.catalogLocation = catalogLocation
        self.crossVolumeMode = crossVolumeMode
        self.skippedBeforePlan = skippedBeforePlan
        self.summaryLine = summaryLine
        self.snapshotPath = snapshotPath
        self.snapshotTakenAt = snapshotPath == nil ? nil : createdAt
        self.entries = entries
    }

    // MARK: Counts (O(entries), called from the job, never from a view body)

    struct Counts: Equatable, Sendable {
        var total = 0
        var pending = 0
        var deleted = 0
        var refused = 0
        var failed = 0
        var skipped = 0
        var totalBytes: Int64 = 0
        /// Bytes of duplicates whose verification is over (any settled
        /// status) — the progress numerator.
        var settledBytes: Int64 = 0
        var freedBytes: Int64 = 0
        var settled: Int { deleted + refused + failed + skipped }
        var fraction: Double { totalBytes > 0 ? Double(settledBytes) / Double(totalBytes) : (total > 0 ? Double(settled) / Double(total) : 0) }
    }

    var counts: Counts {
        var c = Counts()
        for e in entries {
            c.total += 1
            c.totalBytes += e.sizeBytes
            switch e.status {
            case .pending, .verifying, .verified: c.pending += 1
            case .deleted: c.deleted += 1; c.settledBytes += e.sizeBytes; c.freedBytes += e.sizeBytes
            case .refused: c.refused += 1; c.settledBytes += e.sizeBytes
            case .failed: c.failed += 1; c.settledBytes += e.sizeBytes
            case .skipped: c.skipped += 1; c.settledBytes += e.sizeBytes
            }
        }
        return c
    }

    var remainingCount: Int { entries.reduce(0) { $0 + ($1.status.isSettled ? 0 : 1) } }
    var isFinished: Bool { finishedAt != nil }
    /// A plan worth offering: not finished and with rows still to do.
    var isResumable: Bool { finishedAt == nil && remainingCount > 0 }

    /// "Resume deleting duplicates on SanDisk — 1,203 of 2,992 remaining?"
    var resumeOffer: String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        let remaining = f.string(from: NSNumber(value: remainingCount)) ?? "\(remainingCount)"
        let total = f.string(from: NSNumber(value: entries.count)) ?? "\(entries.count)"
        return "Resume deleting duplicates on \(volumeName) — \(remaining) of \(total) remaining?"
    }

    mutating func set(_ id: UUID, _ status: EntryStatus, note: String = "", at now: Date = Date(),
                      keeperMatchedByStoredFixity: Bool? = nil) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = status
        if !note.isEmpty { entries[i].note = note }
        if status.isSettled { entries[i].settledAt = now }
        if let k = keeperMatchedByStoredFixity { entries[i].keeperMatchedByStoredFixity = k }
    }

    /// The row is in quarantine: record exactly where, and the file's
    /// stamp there, so the plan on disk can name it (status `.verified`).
    mutating func setQuarantined(_ id: UUID, directory: String, stamp: FileIdentityStamp) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].status = .verified
        entries[i].quarantineDirectory = directory
        entries[i].quarantinedStamp = stamp
    }

    /// The row left quarantine (deleted, or put back): forget the folder.
    mutating func clearQuarantine(_ id: UUID) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[i].quarantineDirectory = nil
        entries[i].quarantinedStamp = nil
    }

    /// Rows still unsettled become `skipped` with `reason` (cancel / quit).
    mutating func skipRemaining(reason: String, at now: Date = Date()) -> Int {
        var n = 0
        for i in entries.indices where !entries[i].status.isSettled {
            entries[i].status = .skipped
            entries[i].note = reason
            entries[i].settledAt = now
            n += 1
        }
        return n
    }

    static let planFilename = "plan.json"
}

// MARK: - Rate / ETA (pure)

/// The subtitle's numbers: throughput over the last `window` pairs and
/// the time left at that rate. No clock of its own — the job feeds it
/// (bytes, seconds) per pair — so it is table-testable.
struct DeleteDuplicatesRate: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        let bytes: Int64
        let seconds: Double
    }

    static let window = 20
    /// No estimate before this many pairs — the first few include the
    /// keeper's one-time full read and would say "3 days".
    static let minimumPairsForETA = 5

    private(set) var samples: [Sample] = []
    private(set) var pairsSeen = 0

    mutating func add(bytes: Int64, seconds: Double) {
        pairsSeen += 1
        samples.append(Sample(bytes: bytes, seconds: max(0, seconds)))
        if samples.count > Self.window { samples.removeFirst(samples.count - Self.window) }
    }

    /// Bytes per second over the window; nil with no samples or no time.
    var bytesPerSecond: Double? {
        let seconds = samples.reduce(0.0) { $0 + $1.seconds }
        guard !samples.isEmpty, seconds > 0 else { return nil }
        return Double(samples.reduce(Int64(0)) { $0 + $1.bytes }) / seconds
    }

    /// Seconds left for `remainingBytes`; nil before `minimumPairsForETA`
    /// pairs or without a rate.
    func secondsRemaining(remainingBytes: Int64) -> Double? {
        guard pairsSeen >= Self.minimumPairsForETA, let rate = bytesPerSecond, rate > 0 else { return nil }
        return Double(max(0, remainingBytes)) / rate
    }

    /// "1.4 GB/s" — the family-facing rate.
    static func rateText(bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .file) + "/s"
    }

    /// "about 2 h 10 min left" / "about 4 min left" / "under a minute left".
    static func etaText(seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "under a minute left" }
        let h = s / 3600
        let m = (s % 3600) / 60
        if h == 0 { return "about \(m) min left" }
        if m == 0 { return "about \(h) h left" }
        return "about \(h) h \(m) min left"
    }

    /// The whole subtitle: "verified 2 of 2,992 · 3 deleted · 1 refused ·
    /// 1.4 GB/s · about 2 h 10 min left". Counts first, then only the
    /// numbers that exist yet.
    static func subtitle(counts c: DeleteDuplicatesPlan.Counts, rate: DeleteDuplicatesRate,
                         paused: Bool = false) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal
        func n(_ v: Int) -> String { f.string(from: NSNumber(value: v)) ?? "\(v)" }
        var parts = ["verified \(n(c.settled)) of \(n(c.total))"]
        if c.deleted > 0 { parts.append("\(n(c.deleted)) deleted") }
        if c.refused > 0 { parts.append("\(n(c.refused)) refused") }
        if c.failed > 0 { parts.append("\(n(c.failed)) failed") }
        if paused {
            parts.append("paused")
        } else if let bps = rate.bytesPerSecond {
            parts.append(rateText(bytesPerSecond: bps))
            if let eta = rate.secondsRemaining(remainingBytes: c.totalBytes - c.settledBytes) {
                parts.append(etaText(seconds: eta))
            }
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Store (atomic plan.json; list; done/)

enum DeleteDuplicatesPlanStore {

    /// App Support/VideoScan/delete-duplicates — the production home.
    /// Under a test host: a per-process scratch folder (the MediaLedger /
    /// evidence-store discipline) so no test can ever read or offer Rick's
    /// real plans.
    nonisolated static var defaultRoot: URL {
        if TestEnvironment.isTestHost { return testHostRoot }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("delete-duplicates", isDirectory: true)
    }

    nonisolated static let testHostRoot = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("VideoScan-tests/delete-duplicates-\(ProcessInfo.processInfo.processIdentifier)",
                                isDirectory: true)

    static let doneFolder = "done"

    nonisolated static func directory(for planID: UUID, root: URL) -> URL {
        root.appendingPathComponent(planID.uuidString, isDirectory: true)
    }

    nonisolated static func planURL(for planID: UUID, root: URL) -> URL {
        directory(for: planID, root: root).appendingPathComponent(DeleteDuplicatesPlan.planFilename)
    }

    nonisolated static func doneURL(for planID: UUID, root: URL) -> URL {
        root.appendingPathComponent(doneFolder, isDirectory: true)
            .appendingPathComponent(planID.uuidString, isDirectory: true)
    }

    /// Atomic, fully synced: a forced reboot is the operational reality of
    /// this app's worst bug, and the plan is what makes a resume honest.
    nonisolated static func save(_ plan: DeleteDuplicatesPlan, root: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try AtomicFilePublish.write(try enc.encode(plan), to: planURL(for: plan.id, root: root),
                                    durability: .fullFsync)
    }

    nonisolated static func load(url: URL) throws -> DeleteDuplicatesPlan {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(DeleteDuplicatesPlan.self, from: Data(contentsOf: url))
    }

    /// Every unfinished plan under `root` (not under done/), newest first.
    /// Unreadable folders are named to `log` once per call and left alone.
    nonisolated static func unfinishedPlans(root: URL,
                                            log: (String) -> Void = { appLog.write($0) }) -> [DeleteDuplicatesPlan] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root.path) else { return [] }
        var plans: [DeleteDuplicatesPlan] = []
        for name in names where name != doneFolder && UUID(uuidString: name) != nil {
            let url = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(DeleteDuplicatesPlan.planFilename)
            guard fm.fileExists(atPath: url.path) else { continue }
            do {
                let plan = try load(url: url)
                if plan.isResumable { plans.append(plan) }
            } catch {
                log("Delete Duplicates: plan \(name) can't be read — \(error.localizedDescription); left in place")
            }
        }
        return plans.sorted { $0.createdAt > $1.createdAt }
    }

    /// Move `<root>/<id>` to `<root>/done/<id>` — kept for the log, never
    /// deleted. A name collision (a plan resumed twice) gets a suffix.
    nonisolated static func moveToDone(_ plan: DeleteDuplicatesPlan, root: URL) throws {
        let fm = FileManager.default
        let source = directory(for: plan.id, root: root)
        guard fm.fileExists(atPath: source.path) else { return }
        let doneRoot = root.appendingPathComponent(doneFolder, isDirectory: true)
        try fm.createDirectory(at: doneRoot, withIntermediateDirectories: true)
        var target = doneURL(for: plan.id, root: root)
        var n = 2
        while fm.fileExists(atPath: target.path) {
            target = doneRoot.appendingPathComponent("\(plan.id.uuidString)-\(n)", isDirectory: true)
            n += 1
        }
        try fm.moveItem(at: source, to: target)
    }
}

/// The ONE writer of a plan's plan.json (the ArchiveAngelPlanWriter shape):
/// each save carries a generation taken on the main actor when requested;
/// writes land in arrival order and a save older than the last one written
/// for that plan is dropped — the newer save already holds its change.
actor DeleteDuplicatesPlanWriter {
    static let shared = DeleteDuplicatesPlanWriter()
    private var written: [UUID: UInt64] = [:]

    /// The last generation written for `planID` in this process (0 when
    /// none). A job that resumes a plan in the SAME process seeds its
    /// counter from this, so its saves are never dropped as stale (QA
    /// MINOR 4 on 462b034b).
    func lastGeneration(for planID: UUID) -> UInt64 { written[planID] ?? 0 }

    @discardableResult
    func write(_ plan: DeleteDuplicatesPlan, root: URL, generation: UInt64) throws -> Bool {
        if let last = written[plan.id], last >= generation { return false }
        try DeleteDuplicatesPlanStore.save(plan, root: root)
        written[plan.id] = generation
        return true
    }
}
