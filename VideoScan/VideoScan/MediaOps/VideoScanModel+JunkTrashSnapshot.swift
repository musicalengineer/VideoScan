// VideoScanModel+JunkTrashSnapshot.swift
// Delete Junk acts on EXACTLY the set its confirmation counted (design R1,
// codex design review F1, 2026-10-09).
//
// Workflow (Rick's words): "Mark junk, and move exactly the junk I
// confirmed to the Trash, file by file, telling me what moved and what was
// held back and why."
//
// When the confirmation opens, the set is FROZEN: each record, its path,
// its file identity (device + inode + size + mtime) and its size. The
// confirmation shows that snapshot; Move to Trash executes ONLY that
// snapshot, through the one Trash routine, with a per-file guard that
// re-checks at each file's turn.

import Foundation

extension VideoScanModel {

    /// The exact set a Delete Junk confirmation counted, frozen when it
    /// opened. Summary numbers are computed ONCE here (never in a view
    /// body — no O(records) work in a body).
    struct JunkTrashSnapshot {
        /// What the confirmation said would happen to one file.
        enum Plan: Equatable {
            /// Will be moved to the Trash (if it is still the same file).
            case toMove
            /// Its drive was not connected — skipped, untouched.
            case offline
            /// Protected (Master Archive, a drive marked Read only…): held
            /// back, with the gate's own sentence.
            case held(String)
        }
        struct Item {
            let record: VideoRecord
            /// `record.fullPath` when frozen.
            let path: String
            /// The file at `path` when frozen; nil when it could not be
            /// stat'ed (missing) or was not stamped (offline / protected).
            let identity: FileIdentityStamp?
            /// Bytes the confirmation counted: the measured size, else the
            /// catalog's.
            let bytes: Int64
            let plan: Plan
        }

        let items: [Item]
        let frozenAt: Date
        let moveCount: Int
        let moveBytes: Int64
        let offlineCount: Int
        /// Held-back reasons with how many files each, in first-seen order.
        let heldGroups: [(reason: String, count: Int)]
        var count: Int { items.count }
        var heldCount: Int { heldGroups.reduce(0) { $0 + $1.count } }

        init(items: [Item], frozenAt: Date = Date()) {
            self.items = items
            self.frozenAt = frozenAt
            var moveCount = 0, offline = 0
            var moveBytes: Int64 = 0
            var order: [String] = []
            var held: [String: Int] = [:]
            for item in items {
                switch item.plan {
                case .toMove:
                    moveCount += 1
                    moveBytes += item.bytes
                case .offline:
                    offline += 1
                case .held(let why):
                    if held[why] == nil { order.append(why) }
                    held[why, default: 0] += 1
                }
            }
            self.moveCount = moveCount
            self.moveBytes = moveBytes
            self.offlineCount = offline
            self.heldGroups = order.map { (reason: $0, count: held[$0] ?? 0) }
        }
    }

    /// Freeze `recs` for a Delete Junk confirmation. Catalog reads on main
    /// (O(n), no disk); one stat per file that may move, off-main. The
    /// offline predicate is injectable so tests never depend on which drives
    /// the host has mounted (CLAUDE.md isolation dimension).
    func freezeJunkSnapshot(_ recs: [VideoRecord],
                            isOffline: @MainActor (VideoRecord) -> Bool = VideoScanModel.isRecordOnOfflineVolume) async
        -> JunkTrashSnapshot {
        let mayGo = Set(recordsBulkVerbsMayRemove(recs).map(ObjectIdentifier.init))
        let archiveVolume = mayGo.count < recs.count ? archiveVolumeProtection() : nil
        let label = archiveVolume?.label ?? "the archive volume"
        var seen = Set<UUID>()
        var drafts: [(record: VideoRecord, path: String, plan: JunkTrashSnapshot.Plan)] = []
        drafts.reserveCapacity(recs.count)
        for rec in recs where seen.insert(rec.id).inserted {
            let plan: JunkTrashSnapshot.Plan
            if !mayGo.contains(ObjectIdentifier(rec)) {
                let note = bulkDeleteRefusal(rec, volume: archiveVolume)
                    .map { Self.bulkDeleteRefusalNote($0, volume: label) } ?? "is protected by the delete rules"
                plan = .held(note)
            } else if isOffline(rec) {
                plan = .offline
            } else {
                plan = .toMove
            }
            drafts.append((rec, rec.fullPath, plan))
        }
        let toStamp: [String?] = drafts.map { $0.plan == .toMove ? $0.path : nil }
        let stamps = await Task.detached(priority: .userInitiated) {
            toStamp.map { $0.flatMap(FileIdentityStamp.capture(path:)) }
        }.value
        let items = zip(drafts, stamps).map { draft, stamp in
            JunkTrashSnapshot.Item(record: draft.record, path: draft.path, identity: stamp,
                                   bytes: stamp?.size ?? draft.record.sizeBytes, plan: draft.plan)
        }
        return JunkTrashSnapshot(items: items)
    }

    /// Move to Trash for a frozen Delete Junk confirmation: ONLY the
    /// snapshot's records, through the one Trash routine, with a guard that
    /// re-checks each file at its turn (catalog on main, disk off-main).
    /// Trash only — there is no mode. `fileOperation` is the tests' seam
    /// (nil = FileManager's trashItem).
    func trashFrozenJunk(_ snapshot: JunkTrashSnapshot,
                         fileOperation: (@Sendable (URL) throws -> Void)? = nil) async -> JunkDeletionResult {
        log("Delete Confirmed Junk: START — \(snapshot.count) file(s) as confirmed at \(snapshot.frozenAt.formatted(date: .omitted, time: .standard)): \(snapshot.moveCount) to move to the Trash (\(Formatting.humanSize(snapshot.moveBytes))), \(snapshot.offlineCount) offline, \(snapshot.heldCount) held back")
        let frozen = FrozenJunkFiles(snapshot)
        let pathByID = Dictionary(snapshot.items.map { ($0.record.id, $0.path) }, uniquingKeysWith: { first, _ in first })
        let fileGuard = JunkDeletionGuard(
            authorize: { [weak self] rec in
                guard let self else { return "the catalog went away — nothing moved" }
                return self.frozenJunkCatalogProblem(rec, frozenPath: pathByID[rec.id])
            },
            beforeRemoval: { path in frozen.diskProblem(at: path) },
            remove: fileOperation)
        let result = await deleteConfirmedJunk(snapshot.items.map(\.record), mode: .toTrash, guard: fileGuard)
            .trashFailuresHeld()
        logJunkLaneOutcome(result, verb: "Delete Confirmed Junk")
        return result
    }

    /// OUTCOME line plus one line per file that stayed, with its reason —
    /// the console carries the same list the result sheet / alert shows.
    func logJunkLaneOutcome(_ result: JunkDeletionResult, verb: String) {
        let report = JunkDeletionReport(result)
        log("\(verb): OUTCOME — \(report.summary.joined(separator: "; "))")
        for line in report.lines { log("\(verb): stayed — \(line.filename) — \(line.reason)") }
    }

    /// The catalog half of a frozen file's re-check, at its turn: still the
    /// same catalog record, still active, still Confirmed Junk, still at
    /// the path that was counted. nil = go on.
    func frozenJunkCatalogProblem(_ rec: VideoRecord, frozenPath: String?) -> String? {
        guard record(forID: rec.id) === rec else { return "is no longer in the catalog — nothing moved" }
        guard rec.purgedAt == nil else { return "was already removed from the catalog — nothing moved" }
        guard rec.mediaDisposition == .confirmedJunk else { return "is no longer marked Confirmed Junk — nothing moved" }
        guard let frozenPath, rec.fullPath == frozenPath else {
            return "was moved in the catalog after you confirmed — nothing moved"
        }
        return nil
    }
}

extension VideoScanModel.JunkDeletionResult {
    /// The junk lanes' reading of a Trash failure (design R3; the same
    /// words as the Excess lane): the routine never falls back to another
    /// kind of removal, so the file is where it was — a HOLD naming the
    /// drive and the reason, not an error that invites "try harder".
    /// Every other outcome passes through unchanged.
    func trashFailuresHeld() -> Self {
        Self(items: items.map { item in
            guard case .failed(let error) = item.outcome else { return item }
            return .init(record: item.record, outcome: .held(Self.trashFailureNote(item.record, error)))
        })
    }

    static func trashFailureNote(_ rec: VideoRecord, _ error: any Error) -> String {
        let volume = rec.volumeName.isEmpty ? VolumeReachability.volumeName(forPath: rec.fullPath) : rec.volumeName
        return "couldn't move it to the Trash on \(volume): \(error.localizedDescription) — nothing was deleted"
    }
}

/// The disk half of a frozen file's re-check, as a Sendable value the
/// routine's worker can carry: path → what was frozen.
struct FrozenJunkFiles: Sendable {
    struct File: Sendable {
        let identity: FileIdentityStamp?
        /// Why the confirmation did NOT count this file as moving (offline
        /// or held back) — such a file never moves from this snapshot.
        let notCounted: String?
    }
    let byPath: [String: File]

    init(_ snapshot: VideoScanModel.JunkTrashSnapshot) {
        var map: [String: File] = [:]
        for item in snapshot.items where map[item.path] == nil {
            let notCounted: String?
            switch item.plan {
            case .toMove: notCounted = nil
            case .offline: notCounted = "its drive wasn't connected when you confirmed — confirm again to move it"
            case .held(let why): notCounted = "was held back when you confirmed (\(why)) — nothing moved"
            }
            map[item.path] = File(identity: item.identity, notCounted: notCounted)
        }
        byPath = map
    }

    /// Off-main, immediately before the file's own Trash: nil = it is the
    /// file that was counted (or it is gone — the routine calls that
    /// "already missing"). One stat.
    func diskProblem(at path: String) -> String? {
        guard let file = byPath[path] else { return "was not in the set you confirmed — nothing moved" }
        if let notCounted = file.notCounted { return notCounted }
        return Self.identityProblem(frozen: file.identity, now: FileIdentityStamp.capture(path: path))
    }

    /// Pure: the frozen identity against the file at the path now. Same
    /// volume + inode + size + mtime (change time ignored — a Finder tag
    /// does not make it another file).
    static func identityProblem(frozen: FileIdentityStamp?, now: FileIdentityStamp?) -> String? {
        switch (frozen, now) {
        case (_, nil):
            return nil
        case (nil, .some):
            return "a file appeared at this path after you confirmed — nothing moved"
        case let (was?, current?):
            return current.matchesIgnoringChangeTime(was)
                ? nil
                : "is not the file you confirmed — it changed or was replaced since — nothing moved"
        }
    }
}
