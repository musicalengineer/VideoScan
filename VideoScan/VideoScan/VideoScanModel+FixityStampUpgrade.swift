// VideoScanModel+FixityStampUpgrade.swift
// Bind pre-2026-09-23 ContentFixity stamps to their volume's UUID, so a
// remount (new st_dev) no longer makes a proven digest look stale.
//
// Why: stamps used to name their volume by st_dev, which macOS reassigns
// on every mount. On Rick's catalog 1,429 of 1,493 stamps failed ONLY on
// the device number — Find Similar Footage could never say "Identical",
// Archive Angel lent nothing, Delete Duplicates re-read keepers and
// siblings it had already proven. New stamps carry `volumeUUID`
// (FileIdentityStamp.capture); this pass upgrades the OLD ones — ONLY
// when `ContentFixity.upgradedToVolumeIdentity` proves it (inode, size,
// mtime, ctime reproduce AND the volume is the one the stamp was taken
// on: same device number, or today's volume UUID == the record's
// scan-time `ScanContext.volumeUUID`). Everything else is left exactly as
// it was — stale — and the next consumer that needs it re-reads the file.
// Never a guess: the rule lives in VideoScanCore and is unit-tested there.
//
// When: at launch (after master/viewer is decided — a viewer never
// writes) and on every volume mount (a drive that was away has its turn
// when it comes back). Debounced 2 s, one pass at a time, stat-only and
// off the main actor; the write-back is compare-and-set (a fixity
// rewritten meanwhile by a job is left alone). Idempotent: an upgraded
// stamp has a UUID and is never a candidate again.
//
// Logged once per volume per pass result (repeats suppressed for the
// session): "Fixity stamps on LaCieWorkspace: 1,115 bound to the volume
// identity …".
//
// (For Rick: `@concurrent` on a `nonisolated async` function is what
// actually moves it OFF the main actor — without it Swift 6.2's
// "approachable concurrency" runs a nonisolated async function on the
// CALLER's actor. Think "std::async(std::launch::async, …)" vs deferred.)

import Foundation
import OSLog
import VideoScanCore

private let fixityUpgradeLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "FixityStampUpgrade")

/// One legacy stamp to examine — a value, so it can cross to the off-main hop.
struct FixityStampUpgradeItem: Sendable, Equatable {
    let id: UUID
    let path: String
    let fixity: ContentFixity
    /// `ScanContext.volumeUUID` of the record ("" when unknown).
    let recordVolumeUUID: String
    /// For the log line ("LaCieWorkspace").
    let volumeLabel: String
}

/// What one pass did, per volume label.
struct FixityStampUpgradeReport: Sendable, Equatable {
    /// Legacy usable stamps examined.
    var candidates = 0
    /// Upgrades actually written to the catalog.
    var written = 0
    /// Proven but not written (the record changed under the pass, or the
    /// catalog is read-only).
    var skippedAtWrite = 0
    var upgradedByVolume: [String: Int] = [:]
    var notUpgradedByVolume: [String: [ContentFixity.VolumeIdentityUpgrade.Reason: Int]] = [:]
}

extension VideoScanModel {

    /// Ask for a pass. Coalesces bursts (a mount storm, launch + mount)
    /// into one pass 2 s later. No-op on a test host — tests call
    /// `upgradeLegacyFixityStampsNow` directly.
    func noteFixityStampUpgradeDue(trigger: String) {
        guard !TestEnvironment.isTestHost else { return }
        guard !fixityStampUpgradeScheduled else { return }
        fixityStampUpgradeScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.fixityStampUpgradeScheduled = false
            _ = await self.upgradeLegacyFixityStampsNow(trigger: trigger)
        }
    }

    /// The records whose stored fixity is usable but carries no volume
    /// UUID — the only ones a pass can change. O(records), main actor,
    /// never in a view body.
    func legacyFixityStampItems() -> [FixityStampUpgradeItem] {
        var out: [FixityStampUpgradeItem] = []
        for r in records {
            guard let f = r.contentFixity, f.stamp.volumeUUID == nil, f.isUsableForVerification else { continue }
            let label = r.scanContext.volumeName.isEmpty
                ? Self.fixityVolumeLabel(forPath: r.fullPath) : r.scanContext.volumeName
            out.append(FixityStampUpgradeItem(id: r.id, path: r.fullPath, fixity: f,
                                              recordVolumeUUID: r.scanContext.volumeUUID, volumeLabel: label))
        }
        return out
    }

    /// "/Volumes/X/…" → "X"; anything else → "this Mac".
    nonisolated static func fixityVolumeLabel(forPath path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Volumes" { return String(parts[1]) }
        return "this Mac"
    }

    /// Stat each item off the main actor and apply the core rule. Pure
    /// apart from the stat (and the task-local volume-UUID seam).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func computeFixityStampUpgrades(_ items: [FixityStampUpgradeItem])
        async -> [(item: FixityStampUpgradeItem, outcome: ContentFixity.VolumeIdentityUpgrade)] {
        var out: [(item: FixityStampUpgradeItem, outcome: ContentFixity.VolumeIdentityUpgrade)] = []
        out.reserveCapacity(items.count)
        for (i, item) in items.enumerated() {
            if i % 1024 == 0, Task.isCancelled { break }
            let now = FileIdentityStamp.capture(path: item.path)
            out.append((item, item.fixity.upgradedToVolumeIdentity(current: now,
                                                                   recordVolumeUUID: item.recordVolumeUUID)))
        }
        return out
    }

    /// One pass: snapshot → stat off-main → compare-and-set write-back →
    /// one log line per volume → debounced save. Returns what it did.
    @discardableResult
    func upgradeLegacyFixityStampsNow(trigger: String) async -> FixityStampUpgradeReport {
        var report = FixityStampUpgradeReport()
        guard !isReadOnly, !fixityStampUpgradeInFlight else { return report }
        fixityStampUpgradeInFlight = true
        defer { fixityStampUpgradeInFlight = false }

        let items = legacyFixityStampItems()
        report.candidates = items.count
        guard !items.isEmpty else { return report }
        let results = await Self.computeFixityStampUpgrades(items)
        applyFixityStampUpgrades(results, into: &report)
        logFixityStampUpgrade(report, trigger: trigger)
        if report.written > 0 { saveCatalogDebounced() }
        return report
    }

    /// The write-back, main actor. Compare-and-set per record; tallies
    /// into `report`. Separate so the CAS can be tested directly.
    func applyFixityStampUpgrades(_ results: [(item: FixityStampUpgradeItem,
                                               outcome: ContentFixity.VolumeIdentityUpgrade)],
                                  into report: inout FixityStampUpgradeReport) {
        for (item, outcome) in results {
            switch outcome {
            case .alreadyBound:
                continue
            case .notUpgraded(let why):
                report.notUpgradedByVolume[item.volumeLabel, default: [:]][why, default: 0] += 1
            case .upgraded(let fixity):
                // Compare-and-set: the same record, at the same path, still
                // holding exactly the fixity that was examined.
                guard !isReadOnly, let rec = record(forID: item.id), rec.fullPath == item.path,
                      rec.contentFixity == item.fixity else {
                    report.skippedAtWrite += 1
                    continue
                }
                rec.contentFixity = fixity
                report.written += 1
                report.upgradedByVolume[item.volumeLabel, default: 0] += 1
            }
        }
    }

    /// One line per volume that had something to say. A volume whose
    /// every legacy stamp is merely offline (drive away) says nothing —
    /// it gets its turn when it mounts. A line identical to one already
    /// logged this session is not repeated.
    private func logFixityStampUpgrade(_ report: FixityStampUpgradeReport, trigger: String) {
        let volumes = Set(report.upgradedByVolume.keys).union(report.notUpgradedByVolume.keys).sorted()
        for v in volumes {
            let up = report.upgradedByVolume[v] ?? 0
            let not = (report.notUpgradedByVolume[v] ?? [:]).filter { $0.key != .offline && $0.value > 0 }
            guard up > 0 || !not.isEmpty else { continue }
            var line = "Fixity stamps on \(v): \(up.formatted()) bound to the volume identity (they now survive remounts)"
            if !not.isEmpty {
                let parts = not.sorted { $0.key.rawValue < $1.key.rawValue }
                    .map { "\($0.value.formatted()) \($0.key.rawValue)" }
                line += "; not upgraded: " + parts.joined(separator: ", ") + " — those are re-read once when next needed"
            }
            guard fixityStampUpgradeLoggedLines.insert(line).inserted else { continue }
            log(line)
            fixityUpgradeLog.notice("\(line, privacy: .public) [trigger=\(trigger, privacy: .public)]")
        }
        if report.skippedAtWrite > 0 {
            fixityUpgradeLog.notice("fixity stamp upgrade: \(report.skippedAtWrite) proven upgrade(s) not written (record changed meanwhile or read-only)")
        }
    }
}
