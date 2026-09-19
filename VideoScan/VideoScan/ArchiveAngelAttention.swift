// ArchiveAngelAttention.swift
// The Archive Angel's ATTENTION MEMORY — Phase 1 of
// docs/archive_angel_curation_direction.md (Rick 2026-09-19: "AA keeps
// suggesting the same N files … the challenge is to get the AA to suggest
// files that have not had any attention").
//
// The truth is the Media Ledger (append-only, audited, travels with the
// archive): `angelProposed` when a file enters a batch, `angelSkipped`
// when Rick passes on it, `angelCleared` when a prepared batch is thrown
// away undecided. This file is the DERIVED view of those lines — a small
// per-record summary the scorer reads — and it is rebuilt from the ledger
// at launch and kept current in memory as events are appended. Nothing
// here is authoritative; delete the cache and the ledger rebuilds it.
//
// How the scorer uses it (ArchiveAngelScorer, rules v8):
//   • novelty      — never proposed → +noveltyBonus (the explore arm);
//   • fatigue      — score × fatigueFactor^effectiveSkips, printed as a
//                    negative evidence line so the score is still the sum
//                    of its printed reasons;
//   • resting      — effectiveSkips ≥ restAfterSkips within restDays of
//                    the last skip → hard floor `.resting` (excluded, with
//                    the reason shown), back after restDays;
//   • family       — members of one event family (`ArchiveAngelFamily`)
//                    share half of each other's skips.
// A skip older than `oldSkipAfterDays` counts `oldSkipWeight`; a clear
// counts `clearWeight` of a skip. Explicit "Prepare with Archive Angel"
// picks ignore attention — the person chose them.
//
// (For Rick: `ArchiveAngelAttention` is a POD value; the store is a
// main-actor class with two dictionaries, like a tiny in-memory index over
// the ledger, keyed by record id AND by content key so a skipped tape's
// twin on another volume is not "new".)

import Combine
import Foundation
import VideoScanCore

// MARK: - The per-record summary (pure value)

struct ArchiveAngelAttention: Sendable, Equatable, Codable {
    /// Bounded: only the most recent `keep` timestamps per kind are held.
    /// Fatigue and resting only look at the recent ones anyway.
    static let keep = 12

    var proposed: [Date] = []
    var skipped: [Date] = []
    var cleared: [Date] = []

    static let none = ArchiveAngelAttention()

    var timesProposed: Int { proposed.count }
    var timesSkipped: Int { skipped.count }
    var timesCleared: Int { cleared.count }
    var lastProposedAt: Date? { proposed.max() }
    var lastSkippedAt: Date? { Self.later(skipped.max(), cleared.max()) }
    /// Never shown to the person by the Angel.
    var isNew: Bool { proposed.isEmpty && skipped.isEmpty && cleared.isEmpty }
    var isEmpty: Bool { isNew }

    mutating func note(_ kind: MediaLedgerEvent.Kind, at: Date) {
        switch kind {
        case .angelProposed: Self.push(&proposed, at)
        case .angelSkipped: Self.push(&skipped, at)
        case .angelCleared: Self.push(&cleared, at)
        default: break
        }
    }

    /// Union of two summaries (a record and its content twins). Dates are
    /// deduplicated at second resolution so the same ledger line counted
    /// through two keys is not two skips.
    func merged(with other: ArchiveAngelAttention) -> ArchiveAngelAttention {
        var out = self
        out.proposed = Self.union(proposed, other.proposed)
        out.skipped = Self.union(skipped, other.skipped)
        out.cleared = Self.union(cleared, other.cleared)
        return out
    }

    /// Skips weighted by age (recent = 1, old = `oldSkipWeight`) plus
    /// clears at `clearWeight`. Pure over `now`.
    func effectiveSkips(now: Date, weights w: ArchiveAngelWeights = .standard) -> Double {
        let oldAfter = w.oldSkipAfterDays * 86_400
        var total = 0.0
        for d in skipped {
            total += now.timeIntervalSince(d) > oldAfter ? w.oldSkipWeight : 1
        }
        for d in cleared {
            total += w.clearWeight * (now.timeIntervalSince(d) > oldAfter ? w.oldSkipWeight : 1)
        }
        return total
    }

    /// Resting = passed on `restAfterSkips` times (effective) and the last
    /// pass was within `restDays`. Returns the day the file comes back, or
    /// nil when it is not resting.
    func restingUntil(now: Date, weights w: ArchiveAngelWeights = .standard) -> Date? {
        guard effectiveSkips(now: now, weights: w) >= w.restAfterSkips, let last = lastSkippedAt else { return nil }
        let until = last.addingTimeInterval(w.restDays * 86_400)
        return until > now ? until : nil
    }

    private static func push(_ list: inout [Date], _ d: Date) {
        list.append(d)
        if list.count > keep {
            list.sort()
            list.removeFirst(list.count - keep)
        }
    }

    private static func union(_ a: [Date], _ b: [Date]) -> [Date] {
        guard !b.isEmpty else { return a }
        guard !a.isEmpty else { return b }
        var seen = Set<Int64>()
        var out: [Date] = []
        for d in (a + b).sorted() {
            let key = Int64(d.timeIntervalSince1970.rounded())
            if seen.insert(key).inserted { out.append(d) }
        }
        if out.count > keep { out.removeFirst(out.count - keep) }
        return out
    }

    private static func later(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case (nil, nil): return nil
        case (let x?, nil): return x
        case (nil, let y?): return y
        case (let x?, let y?): return x > y ? x : y
        }
    }
}

// MARK: - Event families (pure)

/// "Thanksgiving_2009.mov", "Thanksgiving_2009_fixedup.mov",
/// "Thanksgiving_2009_clip1.mov" in one folder are ONE event family: the
/// person who passed on one has seen the event. The key is the folder plus
/// the stem with derivative tokens (`ArchiveAngelNaming.derivativeBaseStem`)
/// and share-out tokens (`clip 1`, `part 2`, `v3`, `fixedup`, `edit`,
/// `denoise`, `_1`, `(2)`) stripped from the end, repeatedly. Pure,
/// table-tested; a key never matches across folders (a different tape
/// called "Tape 12" elsewhere is a different event).
enum ArchiveAngelFamily {

    nonisolated static func key(filename: String, fullPath: String) -> String {
        let folder = (fullPath as NSString).deletingLastPathComponent.lowercased()
        let stem = (filename as NSString).deletingPathExtension
        return folder + "|" + baseStem(stem)
    }

    /// The stem with every trailing derivative / share-out token removed.
    nonisolated static func baseStem(_ stem: String) -> String {
        var current = ArchiveAngelNaming.derivativeBaseStem(stem) ?? stem
        while let m = shareOutTokenRegex.firstMatch(in: current, range: NSRange(current.startIndex..., in: current)),
              let r = Range(m.range, in: current) {
            let next = String(current[..<r.lowerBound])
            if next.isEmpty { break }
            // A derivative token may sit UNDER a share-out token ("x_fixed_clip1").
            current = ArchiveAngelNaming.derivativeBaseStem(next) ?? next
        }
        let base = current.trimmingCharacters(in: CharacterSet(charactersIn: " _-.")).lowercased()
        return base.isEmpty ? stem.lowercased() : base
    }

    /// Compiled once. Trailing NAMED tokens only ("_clip1", " part 2",
    /// "-v3", "_fixedup", " (2)"), separated from the stem by a space,
    /// underscore, dash or dot. A bare trailing number is deliberately NOT
    /// a token: "Tape 12" and "Tape 13" are two tapes, "cape-1992" is a
    /// year — collapsing them would hide real files behind one slot.
    nonisolated static let shareOutTokenRegex = try! NSRegularExpression(
        pattern: #"([ _\-.]+(clip|part|pt|segment|seg|take|cut|edit|edited|fix|fixed|fixedup|fixup|final|short|long|denoise[a-z0-9]*)[ _\-]?\d{0,3}|[ _\-.]+v\d{1,2}|[ _\-]*\(\d{1,3}\))$"#,
        options: [.caseInsensitive])
}

// MARK: - The store (main actor, derived from the ledger)

@MainActor
final class ArchiveAngelAttentionStore: ObservableObject {

    /// Summaries by record id.
    private(set) var byRecord: [UUID: ArchiveAngelAttention] = [:]
    /// Record ids that share a content key — a skipped tape's twin on
    /// another volume has been seen too.
    private(set) var recordsByContent: [String: Set<UUID>] = [:]
    /// When the newest attention event happened. Evidence computed before
    /// this is stale for the Angel's pick (the job then walks).
    @Published private(set) var lastEventAt: Date?
    /// Bumped on every change so views and the job can observe it.
    @Published private(set) var revision: Int = 0
    private(set) var isLoaded = false

    init() {}

    static let attentionKinds: Set<MediaLedgerEvent.Kind> = [.angelProposed, .angelSkipped, .angelCleared]

    /// The summary for a record: its own lines plus those of every copy
    /// of the same content. O(copies).
    func summary(recordID: UUID, contentKey: String) -> ArchiveAngelAttention {
        var out = byRecord[recordID] ?? .none
        if !contentKey.isEmpty, let twins = recordsByContent[contentKey] {
            for twin in twins where twin != recordID {
                if let t = byRecord[twin] { out = out.merged(with: t) }
            }
        }
        return out
    }

    var recordCount: Int { byRecord.count }

    /// Fold new ledger lines in (called right after they are appended).
    func note(_ events: [MediaLedgerEvent]) {
        var changed = false
        for e in events where Self.attentionKinds.contains(e.event) {
            byRecord[e.recordID, default: .none].note(e.event, at: e.at)
            if !e.contentKey.isEmpty { recordsByContent[e.contentKey, default: []].insert(e.recordID) }
            if lastEventAt.map({ e.at > $0 }) ?? true { lastEventAt = e.at }
            changed = true
        }
        if changed { revision &+= 1 }
    }

    /// Replace everything from a full event list (launch rebuild).
    func replace(from events: [MediaLedgerEvent]) {
        let built = Self.build(from: events)
        byRecord = built.byRecord
        recordsByContent = built.recordsByContent
        lastEventAt = built.lastEventAt
        isLoaded = true
        revision &+= 1
    }

    /// Rebuild from the ledger file, read off the main actor.
    func load(from ledger: MediaLedger) async {
        let events = await Self.readOffMain(ledger)
        replace(from: events)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func readOffMain(_ ledger: MediaLedger) async -> [MediaLedgerEvent] {
        ledger.allEvents().filter { attentionKinds.contains($0.event) }
    }

    /// Pure fold — what `replace` and `note` both compute.
    nonisolated static func build(from events: [MediaLedgerEvent])
    -> (byRecord: [UUID: ArchiveAngelAttention], recordsByContent: [String: Set<UUID>], lastEventAt: Date?) {
        var byRecord: [UUID: ArchiveAngelAttention] = [:]
        var byContent: [String: Set<UUID>] = [:]
        var last: Date?
        for e in events where attentionKinds.contains(e.event) {
            byRecord[e.recordID, default: .none].note(e.event, at: e.at)
            if !e.contentKey.isEmpty { byContent[e.contentKey, default: []].insert(e.recordID) }
            if last.map({ e.at > $0 }) ?? true { last = e.at }
        }
        return (byRecord, byContent, last)
    }
}
