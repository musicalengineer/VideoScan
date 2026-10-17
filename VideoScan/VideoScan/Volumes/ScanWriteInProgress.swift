// ScanWriteInProgress.swift
// A file still being written never becomes a catalog row (Verify Catalog
// bug 3, 2026-10-17: a combined archive output was catalogued at 450 MB at
// the same second as its mtime; on disk it is 944 MB — the scan built the
// row from ONE stat and an ffprobe of a file ffmpeg was still writing).
//
// THE SCAN RULE (`reason`), applied in `probeFileOutcome` when it is called
// from the scan (`skipIfStillBeingWritten` — the default):
//   1. before the cache lookup: an mtime inside the settle window (60 s in
//      production) → skipped, "still being written — rescan later";
//   2. after ffprobe: a second stat; a size or mtime that differs from the
//      first (or a file that is gone) → skipped, same words.
// A skipped file is an outcome with `stillBeingWritten = true`: the drain
// gate keeps it out of the catalog, the probe cache never sees it, the
// discovery audit counts and names it, and the console says so. The next
// scan looks again. O(1) per file: one extra stat(2).
//
// The settle window is `0 ≤ now − mtime < settleSeconds`. A FUTURE mtime
// (clock skew, a camera's clock) is not "being written" — the file is
// catalogued; the two-stat check still guards it (codex P2, 2026-10-17).
//
// THE REPROBE RULE (`waitUntilSettled`), for a single file the caller JUST
// wrote — Transcode, Reformat, Trim, Clean Up, Balance/Rebuild Audio,
// Repair, Link Repaired Copy, Import, Promote (`reprobeFileOutcome`): a
// reprobe never skips. Inside the window it polls two stats until they
// agree (bounded: `reprobeMaxWaitSeconds`), then probes with the scan rule
// OFF; a file still changing at the deadline is the typed
// `ReprobeOutcome.stillBeingWritten` the caller can show — never a record
// built from a half-written file, never a skip the caller cannot see
// (codex P1, 2026-10-17: the wrapper applied the skipped outcome and
// Transcode catalogued its own output as ffprobeFailed).
//
// The settle window is 0 under the test host — every scan test writes its
// fixtures seconds before scanning — and ScanStillBeingWrittenTests pins
// both defaults and sets the production value where it matters.
//
// (For Rick: `ScanFileStat` is a two-field POD; `reason` and
// `waitUntilSettled` are pure functions of stats and a clock — the tests
// feed them values and fake sleeps directly; the model extension is the
// only place that touches the filesystem or the seams.)

import Foundation
import VideoScanCore

/// What one stat says about a file's bytes and when they last changed.
struct ScanFileStat: Equatable, Sendable {
    let sizeBytes: Int64
    let modifiedAt: Date

    /// The file's current stat; nil when it cannot be read (gone).
    static func of(path: String) -> ScanFileStat? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        return ScanFileStat(sizeBytes: (attrs[.size] as? Int64) ?? 0,
                            modifiedAt: (attrs[.modificationDate] as? Date) ?? .distantPast)
    }
}

/// What a single-file reprobe produced: the probe, or the typed fact that
/// the file kept changing for the whole wait.
enum ReprobeOutcome: Sendable {
    case probed(ProbeOutcome)
    /// `why` is the last change seen; `skipped` is the scan's skipped
    /// outcome for callers that must materialize a record anyway.
    case stillBeingWritten(why: String, skipped: ProbeOutcome)

    /// The carrier either way (the skipped one reads "Still being written").
    var outcome: ProbeOutcome {
        switch self {
        case .probed(let o), .stillBeingWritten(_, let o): return o
        }
    }

    var isStillBeingWritten: Bool {
        if case .stillBeingWritten = self { return true }
        return false
    }
}

enum ScanWriteInProgress {

    /// Production settle window: a file modified more recently than this
    /// is treated as still being written (a slow copy can hold its size
    /// between two stats a second apart; its mtime gives it away).
    static let settleSeconds: TimeInterval = 60

    /// A reprobe inside the window waits at most this long for two stats
    /// to agree, polling every `reprobePollSeconds`.
    static let reprobeMaxWaitSeconds: TimeInterval = 10
    static let reprobePollSeconds: TimeInterval = 0.5

    /// The words on the skipped line, in the audit and in the console.
    static let skipWords = "still being written — rescan later"

    /// The app settles for 60 s; a test host writes its fixtures and scans
    /// them at once, so it settles for 0 (pinned by ScanStillBeingWrittenTests).
    static func defaultSettleSeconds(isTestHost: Bool) -> TimeInterval {
        isTestHost ? 0 : settleSeconds
    }

    /// nil when the file looked stable; otherwise why it is skipped this
    /// scan. `after` is the second stat (nil = the file is gone).
    static func reason(before: ScanFileStat, after: ScanFileStat?, now: Date,
                       settleSeconds: TimeInterval) -> String? {
        guard let after else { return "gone after the probe" }
        return changeReason(before: before, after: after) ?? settleReason(after, now: now, settleSeconds: settleSeconds)
    }

    /// The two stats disagree: the size, else the mtime. nil when they agree.
    static func changeReason(before: ScanFileStat, after: ScanFileStat) -> String? {
        if after.sizeBytes != before.sizeBytes {
            return "size changed under the probe (\(before.sizeBytes.formatted()) → \(after.sizeBytes.formatted()) bytes)"
        }
        if after.modifiedAt != before.modifiedAt { return "modified under the probe" }
        return nil
    }

    /// The mtime is inside `0 ≤ now − mtime < settleSeconds`. A future
    /// mtime is never inside it; a 0 s window is empty.
    static func settleReason(_ stat: ScanFileStat, now: Date, settleSeconds: TimeInterval) -> String? {
        let age = now.timeIntervalSince(stat.modifiedAt)
        guard (0..<settleSeconds).contains(age) else { return nil }
        return "modified \(Int(age.rounded())) s ago (inside the \(Int(settleSeconds)) s settle window)"
    }

    /// The outcome for a skipped file: the file's identity, the reason, and
    /// `stillBeingWritten` so the drain gate keeps it out of the catalog.
    static func skippedOutcome(url: URL, stat: ScanFileStat, why: String) -> ProbeOutcome {
        var o = ProbeOutcome()
        o.filename = url.lastPathComponent
        o.ext = url.pathExtension.uppercased()
        o.fullPath = url.path
        o.directory = url.deletingLastPathComponent().path
        o.sizeBytes = stat.sizeBytes
        o.size = Formatting.humanSize(stat.sizeBytes)
        o.probe.isPlayable = "Still being written"
        o.probe.streamTypeRaw = StreamType.ffprobeFailed.rawValue
        o.notes = MachineNote.line(author: .scan, text: "\(skipWords) — \(why)")
        o.stillBeingWritten = true
        return o
    }

    // MARK: The reprobe wait

    /// How the wait ended.
    enum ReprobeWait: Equatable, Sendable {
        case settled(ScanFileStat)
        case gone
        case stillChanging(why: String)
    }

    /// Wait for a just-written file to settle: a stat outside the settle
    /// window is settled at once (no sleep); inside it, poll until two
    /// stats `poll` apart agree, or `maxWait` passes. `stat` nil = gone.
    /// `sleep` returns false when the task was cancelled (the wait ends).
    static func waitUntilSettled(path: String, settleSeconds: TimeInterval, maxWait: TimeInterval = reprobeMaxWaitSeconds,
                                 poll: TimeInterval = reprobePollSeconds,
                                 now: () -> Date, stat: (String) -> ScanFileStat?,
                                 sleep: (TimeInterval) async -> Bool) async -> ReprobeWait {
        guard var before = stat(path) else { return .gone }
        guard settleReason(before, now: now(), settleSeconds: settleSeconds) != nil else { return .settled(before) }
        let deadline = now().addingTimeInterval(maxWait)
        var why = ""
        while true {
            let slept = await sleep(poll)
            guard let after = stat(path) else { return .gone }
            if let change = changeReason(before: before, after: after) {
                why = change
                before = after
            } else {
                return .settled(after)
            }
            if !slept || now() >= deadline {
                return .stillChanging(why: slept ? why : "the wait was cancelled after: \(why)")
            }
        }
    }
}

extension VideoScanModel {

    /// The scan rule with this model's settle window, clock and (after the
    /// probe) a fresh second stat — through the test seams when set.
    nonisolated func writeInProgressReason(path: String, before: ScanFileStat, afterProbe: Bool) -> String? {
        let after: ScanFileStat?
        if !afterProbe {
            after = before
        } else if let seam = scanSecondStatForTesting {
            after = seam(path)   // the seam's nil means "gone", never "ask the disk"
        } else {
            after = ScanFileStat.of(path: path)
        }
        return ScanWriteInProgress.reason(before: before, after: after,
                                          now: scanClockForTesting?() ?? Date(), settleSeconds: scanSettleSeconds)
    }

    /// Probe ONE file the caller just wrote: wait for it to settle
    /// (bounded), then `probeFileOutcome` with the scan's skip rule OFF.
    /// A file still changing at the deadline, or gone, is the typed
    /// `.stillBeingWritten` — never a record built from a half-written
    /// file. Every single-file reprobe goes through here (`probeFile`,
    /// Promote); the scan does not.
    /// LOAD-BEARING SEAM — `@concurrent` so the stats and the wait run off
    /// the caller's actor (the @MainActor jobs call this directly).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated func reprobeFileOutcome(url: URL, prefetchToRAM: Bool = false, ramPath: String? = nil, skipHashing: Bool = false,
                                        scanRootPath: String? = nil,
                                        maxWait: TimeInterval = ScanWriteInProgress.reprobeMaxWaitSeconds) async -> ReprobeOutcome {
        let waited = await ScanWriteInProgress.waitUntilSettled(
            path: url.path, settleSeconds: scanSettleSeconds, maxWait: maxWait,
            now: { scanClockForTesting?() ?? Date() },
            stat: { ScanFileStat.of(path: $0) },
            sleep: { seconds in
                do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); return true } catch { return false }
            })
        switch waited {
        case .settled:
            return .probed(await probeFileOutcome(url: url, prefetchToRAM: prefetchToRAM, ramPath: ramPath, skipHashing: skipHashing,
                                                  scanRootPath: scanRootPath, skipIfStillBeingWritten: false))
        case .gone:
            // The not-found sentinel the core already produces (same words as a scan).
            return .probed(await probeFileOutcome(url: url, skipHashing: true, skipIfStillBeingWritten: false))
        case .stillChanging(let why):
            let last = ScanFileStat.of(path: url.path) ?? ScanFileStat(sizeBytes: 0, modifiedAt: .distantPast)
            return .stillBeingWritten(why: why, skipped: ScanWriteInProgress.skippedOutcome(url: url, stat: last, why: why))
        }
    }

    /// The fields a row takes from the filesystem before ffprobe runs:
    /// identity, size, the (validated) dates and the two scan hashes.
    /// Moved out of `probeFileOutcome` for its length; same code.
    nonisolated func scanTimeFields(url: URL, attrs: [FileAttributeKey: Any]?, fileSize: Int64,
                                    skipHashing: Bool) -> ProbeOutcome {
        // autoreleasepool drains Obj-C bridged objects (DateFormatter, NSString,
        // FileManager internals) created during record population
        autoreleasepool {
            var o = ProbeOutcome()
            o.filename  = url.lastPathComponent
            o.ext       = url.pathExtension.uppercased()
            o.fullPath  = url.path
            o.directory = url.deletingLastPathComponent().path

            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            o.sizeBytes       = fileSize
            o.size            = Formatting.humanSize(fileSize)
            // Reject impossible dates (future, before 1900, or the
            // known 2040-02-06 06:28:16 UTC sentinel from Rick's old
            // MacPro PRAM-dead scan) so they never enter the catalog.
            // See DateValidation.swift for the predicates + tests.
            o.dateModifiedRaw = pfDateOrNilIfImpossible(attrs?[.modificationDate] as? Date)
            o.dateCreatedRaw  = pfDateOrNilIfImpossible(attrs?[.creationDate] as? Date)
            o.dateModified    = o.dateModifiedRaw.map { df.string(from: $0) } ?? ""
            o.dateCreated     = o.dateCreatedRaw.map { df.string(from: $0) } ?? ""

            // partialMD5 is the strong identity key for duplicate detection.
            // Skip reads ~64 KB per file, which is free on local SSD but costs
            // real seconds over SMB on thousands of files. skipHashing trades
            // dup detection for a faster pass — user can run "Analyze
            // Duplicates" later if they change their mind.
            o.partialMD5 = skipHashing ? "" : FileHasher.partialMD5(path: url.path)
            // Segmented content hash — the identity strong enough to
            // authorize deletion (see FileHasher). Rides the SAME
            // skipHashing gate: it is three 1 MiB reads, negligible on
            // local SSD and deliberately skippable over SMB.
            o.contentHash = skipHashing ? "" : FileHasher.segmentedHash(path: url.path)
            o.contentHashAt = o.contentHash.isEmpty ? nil : Date()
            return o
        }
    }
}
