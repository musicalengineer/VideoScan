// ArchiveAngelBufferHygiene.swift
// Archive Angel curation Phase 2 — BUFFER HYGIENE, the pure half
// (docs/archive_angel_curation_direction.md, Phase 2).
//
// Rick 2026-09-19: the buffer held 82 GB on a disk with 11 GB free —
// one ready batch of 70.7 GB untouched for four days, a ready batch with
// nothing prepared, two PROMOTED batches still holding their failed rows'
// folders — and every new batch parked most of its rows "waiting for
// buffer space". The plan text: "On opening the Angel, if prepared batches
// are waiting: '3 prepared batches (74 GB) are waiting. What next?' Per
// batch: Review and Promote / Clear / Later; plus Clear all. Clearing
// removes only the Angel's derived copies (regenerable; originals
// untouched), frees the buffer, returns the rows to the pool, and counts
// as half a skip. Nothing is auto-deleted without an ask; a batch untouched
// for 14 days is flagged." Rick's rulings: NEVER auto-clear; old batches
// become this prompt.
//
// This file computes the REPORT the card and the start sheet show. It is
// pure and injectable — folder sizes, plan.json mtimes, liveness, the
// clock and the free-disk figure all come in as values or closures — so
// the classification, the 14-day flag, the totals and every line of text
// are table-tested without a buffer on disk. The Archive tab computes it
// OFF the main actor next to the batch scan; the model's
// `clearArchiveAngelBatch` (VideoScanModel+ArchiveAngelBufferHygiene.swift)
// is the ONE entry point that acts on a row.
//
// (For Rick: `enum … { static func … }` with no cases is Swift's way of
// writing a namespace of free functions — like a C++ `namespace` you
// cannot instantiate.)

import Combine
import Foundation

enum ArchiveAngelBufferHygiene {

    /// A batch nobody has touched for this many days gets the ⚠︎ badge.
    static let staleAfterDays = 14

    /// A finished (promoted / discarded) batch whose folder holds less
    /// than this is only its plan.json — the batch's own report, kept on
    /// purpose. Anything above it is companion files left behind.
    static let leftoverFloorBytes: Int64 = 1_000_000

    // MARK: - What a batch row IS

    enum Kind: Equatable, Sendable {
        /// A ready batch waiting for a decision. `pending` = rows not
        /// prepared yet (unsettled, or parked for buffer space); `failed`
        /// = rows that genuinely broke.
        case waiting(ready: Int, pending: Int, skipped: Int, failed: Int)
        /// Promoted or discarded, but its folder still holds files —
        /// typically the failed rows' companions. `rowsLeft` = rows that
        /// did not reach the archive.
        case leftover(status: ArchiveAngelPlan.Status, rowsLeft: Int)
        /// Still `preparing` in the plan, but no job in this app is
        /// working on it — interrupted. (The hour rule settles it later.)
        case parked(ready: Int, unfinished: Int)
        /// A job in this app is working on it right now — shown for the
        /// bytes, never clearable. `what` = "preparing" / "promoting".
        case inProgress(what: String)
    }

    struct BatchRow: Identifiable, Equatable, Sendable {
        let plan: ArchiveAngelPlan
        let bytes: Int64
        let kind: Kind
        /// Whole days since the plan last moved (plan.json mtime, else
        /// finishedAt, else createdAt).
        let untouchedDays: Int
        let isLive: Bool

        var id: String { plan.batchID }
        var isStale: Bool { untouchedDays >= ArchiveAngelBufferHygiene.staleAfterDays }

        /// Clear is offered for anything no job is touching. A promoting
        /// batch is refused even when it is not live in this process:
        /// `settleStrandedPromotions` decides its fate on the next refresh.
        var canClear: Bool {
            if case .inProgress = kind { return false }
            return !isLive && plan.status != .promoting
        }

        /// Review & Promote opens the existing review sheet — for a
        /// waiting batch, or a parked one that has rows ready to look at.
        var canReview: Bool {
            switch kind {
            case .waiting: return true
            case .parked(let ready, _): return ready > 0
            case .leftover, .inProgress: return false
            }
        }

        var isWaiting: Bool {
            switch kind {
            case .waiting, .parked: return true
            case .leftover, .inProgress: return false
            }
        }

        var isLeftover: Bool {
            if case .leftover = kind { return true }
            return false
        }

        /// The Clear button's title: a leftover says what it frees.
        var clearLabel: String {
            isLeftover ? "Free \(MediaBytes.display(bytes))" : "Clear"
        }

        /// "Sep 15 · 70.7 GB · 6 ready, 4 skipped · untouched 4 days"
        func line(now: Date) -> String {
            [ArchiveAngelBufferHygiene.dayText(plan.createdAt, now: now),
             MediaBytes.display(bytes),
             ArchiveAngelBufferHygiene.detailText(kind),
             ArchiveAngelBufferHygiene.untouchedText(untouchedDays)]
                .joined(separator: " · ")
        }
    }

    // MARK: - The report

    struct Report: Equatable, Sendable {
        /// Oldest first — the one that has waited longest is the one to
        /// decide about.
        var batches: [BatchRow] = []
        /// Every listed row's bytes, in-progress included.
        var totalBytes: Int64 = 0
        /// Waiting + parked rows.
        var waitingCount = 0
        var waitingBytes: Int64 = 0
        var leftoverCount = 0
        var leftoverBytes: Int64 = 0
        var diskFreeBytes: Int64?

        static let empty = Report()

        /// Nothing to ask about — the card stays hidden.
        var isEmpty: Bool { waitingCount == 0 && leftoverCount == 0 }

        /// Rows a Clear may act on.
        var clearable: [BatchRow] { batches.filter(\.canClear) }
        var clearableBytes: Int64 { clearable.reduce(0) { $0 + $1.bytes } }

        /// "3 prepared batches (74 GB) are waiting in the buffer — the disk
        /// has 11 GB free. What next?"
        var headline: String {
            ArchiveAngelBufferHygiene.headline(waitingCount: waitingCount, waitingBytes: waitingBytes,
                                               leftoverCount: leftoverCount, leftoverBytes: leftoverBytes,
                                               diskFree: diskFreeBytes)
        }

        /// The start sheet's one-liner: "3 batches (74 GB) are waiting in
        /// the buffer — clear or promote them first?"
        var bannerText: String {
            let n = waitingCount + leftoverCount
            guard n > 0 else { return "" }
            let bytes = waitingBytes + leftoverBytes
            return "\(n) batch\(n == 1 ? "" : "es") (\(MediaBytes.display(bytes))) "
                + (n == 1 ? "is" : "are") + " waiting in the buffer — clear or promote "
                + (n == 1 ? "it" : "them") + " first?"
        }
    }

    /// Classify every plan. `bytesOf` walks the folder (the caller runs
    /// this off the main actor); `modifiedAt` reads plan.json's mtime
    /// (nil = unknown → finishedAt / createdAt); `isLive` asks the
    /// process-local registry. Pure over its inputs.
    static func report(plans: [ArchiveAngelPlan],
                       bytesOf: (ArchiveAngelPlan) -> Int64,
                       modifiedAt: (ArchiveAngelPlan) -> Date? = { _ in nil },
                       isLive: (ArchiveAngelPlan) -> Bool = { ArchiveAngelLiveBatches.isLive($0.batchDir) },
                       now: Date = Date(),
                       diskFree: Int64? = nil) -> Report {
        var out = Report()
        out.diskFreeBytes = diskFree
        var rows: [BatchRow] = []
        for plan in plans {
            let live = isLive(plan)
            let bytes = bytesOf(plan)
            guard let kind = classify(plan, bytes: bytes, isLive: live) else { continue }
            let touched = modifiedAt(plan) ?? plan.finishedAt ?? plan.createdAt
            let days = max(0, Int(now.timeIntervalSince(touched) / 86_400))
            let row = BatchRow(plan: plan, bytes: bytes, kind: kind, untouchedDays: days, isLive: live)
            rows.append(row)
            out.totalBytes += bytes
            if row.isWaiting { out.waitingCount += 1; out.waitingBytes += bytes }
            if row.isLeftover { out.leftoverCount += 1; out.leftoverBytes += bytes }
        }
        out.batches = rows.sorted { $0.plan.createdAt < $1.plan.createdAt }
        return out
    }

    /// nil = not worth a row (a finished batch holding only its plan.json).
    static func classify(_ plan: ArchiveAngelPlan, bytes: Int64, isLive: Bool) -> Kind? {
        switch plan.status {
        case .ready:
            if isLive { return .inProgress(what: "promoting") }
            let unsettled = plan.entries.filter { $0.status.isUnsettled }.count
            let parked = plan.bufferShortCount
            let failed = plan.entries.filter { $0.status == .failed }.count - parked
            return .waiting(ready: plan.readyCount, pending: unsettled + parked,
                            skipped: plan.skippedCount, failed: failed)
        case .promoting:
            return .inProgress(what: "promoting")
        case .preparing:
            if isLive { return .inProgress(what: "preparing") }
            return .parked(ready: plan.readyCount,
                           unfinished: plan.entries.filter { $0.status.isUnsettled }.count)
        case .promoted, .discarded:
            guard bytes >= leftoverFloorBytes else { return nil }
            return .leftover(status: plan.status,
                             rowsLeft: plan.entries.filter { $0.status != .promoted }.count)
        }
    }

    // MARK: - Text

    static func headline(waitingCount: Int, waitingBytes: Int64,
                         leftoverCount: Int, leftoverBytes: Int64, diskFree: Int64?) -> String {
        let disk = diskFree.map { " — the disk has \(MediaBytes.display($0)) free" } ?? ""
        if waitingCount > 0 {
            var s = "\(waitingCount) prepared batch\(waitingCount == 1 ? " (" : "es (")\(MediaBytes.display(waitingBytes))) "
                + (waitingCount == 1 ? "is" : "are") + " waiting in the buffer"
            if leftoverCount > 0 {
                s += ", and \(leftoverCount) finished batch\(leftoverCount == 1 ? "" : "es") still hold"
                    + (leftoverCount == 1 ? "s" : "") + " \(MediaBytes.display(leftoverBytes))"
            }
            return s + disk + ". What next?"
        }
        if leftoverCount > 0 {
            return "\(leftoverCount) finished batch\(leftoverCount == 1 ? "" : "es") still hold"
                + (leftoverCount == 1 ? "s" : "") + " \(MediaBytes.display(leftoverBytes)) in the buffer"
                + disk + ". Free it?"
        }
        return ""
    }

    /// "6 ready, 4 skipped" / "promoted — files of 2 rows left behind" /
    /// "interrupted while preparing — 3 ready, 7 unfinished" / "preparing now"
    static func detailText(_ kind: Kind) -> String {
        switch kind {
        case .waiting(let ready, let pending, let skipped, let failed):
            var parts: [String] = []
            if ready > 0 { parts.append("\(ready) ready") }
            if pending > 0 { parts.append("\(pending) waiting for buffer space") }
            if skipped > 0 { parts.append("\(skipped) skipped") }
            if failed > 0 { parts.append("\(failed) failed") }
            return parts.isEmpty ? "nothing prepared" : parts.joined(separator: ", ")
        case .leftover(let status, let rowsLeft):
            let what = status == .promoted ? "promoted" : "discarded"
            return rowsLeft > 0
                ? "\(what) — files of \(rowsLeft) row\(rowsLeft == 1 ? "" : "s") left behind"
                : "\(what) — folder still here"
        case .parked(let ready, let unfinished):
            return "interrupted while preparing — \(ready) ready, \(unfinished) unfinished"
        case .inProgress(let what):
            return "\(what) now"
        }
    }

    static func untouchedText(_ days: Int) -> String {
        switch days {
        case 0: return "untouched today"
        case 1: return "untouched 1 day"
        default: return "untouched \(days) days"
        }
    }

    /// "Sep 15", or "Sep 15, 2025" when it is not this year.
    static func dayText(_ date: Date, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        f.dateFormat = cal.component(.year, from: date) == cal.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    // MARK: - Disk probes (the impure inputs, kept in one place)

    /// plan.json's modification date, or nil when it cannot be read.
    nonisolated static func planModifiedAt(_ plan: ArchiveAngelPlan) -> Date? {
        let attrs = try? FileManager.default.attributesOfItem(atPath: plan.planURL.path)
        return attrs?[.modificationDate] as? Date
    }

    /// Free bytes on the buffer's volume — the home volume when the buffer
    /// folder does not exist yet.
    nonisolated static func diskFree(bufferRoot: URL) -> Int64 {
        let probe = FileManager.default.fileExists(atPath: bufferRoot.path)
            ? bufferRoot
            : FileManager.default.homeDirectoryForCurrentUser
        return ArchiveAngelPlanStore.freeBytes(at: probe)
    }
}

/// "Later" — the rows Rick has put off for THIS RUN of the app. Deliberately
/// not persisted: a batch put off today is back in the prompt at the next
/// launch, which is how "nothing is auto-deleted, old batches become this
/// prompt" stays true. Process-lifetime (a static), not view @State —
/// ArchiveView is rebuilt on every tab entry and would forget.
///
/// (For Rick: `ObservableObject` + `@Published` ≈ a struct with a change
/// signal the UI subscribes to; `static let shared` is a plain singleton.)
@MainActor
final class ArchiveAngelHygieneSession: ObservableObject {
    static let shared = ArchiveAngelHygieneSession()
    @Published var laterBatchIDs: Set<String> = []
    init() {}
}
