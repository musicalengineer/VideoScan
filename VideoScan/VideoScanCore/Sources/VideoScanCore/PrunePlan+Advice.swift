// PrunePlan+Advice.swift
// What the plan SAYS, as opposed to what it offers: the one-sentence advice
// before the person confirms ("N files will exist only in the Master Archive
// after this", naming any with no cloud or off-site "yes"), the protection
// line, and one log line per archive file. Advice only — nothing here gates
// a move (Rick 2026-10-21: attestations advise; they never hold a copy).
//
// (For Rick: an extension ≈ more member functions of the same class, kept in
// their own file because they are a separate concern.)

import Foundation

extension PrunePlan.Item {

    /// After the `selected` offered rows go, no copy with the archive's bytes
    /// remains outside the archive. A held identical copy (offline, protected,
    /// pair) still exists, so it counts as remaining; a missing one does not.
    public func leavesArchiveOnly(after selected: Set<UUID>) -> Bool {
        let going = rows.filter { $0.isOffered && selected.contains($0.id) }
        guard !going.isEmpty else { return false }
        return !rows.contains { row in
            row.isIdentical && row.reason != .missing && !(row.isOffered && selected.contains(row.id))
        }
    }

    /// A cloud or off-site "yes" on the archive file or any copy listed with it.
    public var hasCloudOrOffsiteYes: Bool {
        let latest = BackupAttestation.latestPerKind(archive.attestations + rows.flatMap(\.attestations))
        return latest[.cloud]?.answer == .yes || latest[.offsite]?.answer == .yes
    }

    /// The protection-line facts: the archive file and every identical copy
    /// that is still there (offline copies count, missing ones do not).
    var copyFacts: [ProtectionSummary.CopyFacts] {
        let archiveFacts = ProtectionSummary.CopyFacts(volumeName: archive.volumeName, isOnline: true,
                                                       isArchiveCopy: true, fixityVerified: digest != nil,
                                                       attestations: archive.attestations)
        return [archiveFacts] + rows.filter { $0.isIdentical && $0.reason != .missing }.map(\.workingFacts)
    }

    /// "what-next: Christmas2008.mov — archive ✓ · 2 offered · held: 1 drive not connected".
    public var logLine: String {
        var parts = [digest == nil ? "archive not verified" : "archive ✓", "\(offered.count) offered"]
        let held = Dictionary(grouping: rows.compactMap(\.reason), by: { $0 })
            .map { "\($0.value.count) \($0.key.text)" }.sorted()
        if !held.isEmpty { parts.append("held: " + held.joined(separator: ", ")) }
        return "what-next: \(archive.filename) — " + parts.joined(separator: " · ")
    }
}

extension PrunePlan.Row {
    var workingFacts: ProtectionSummary.CopyFacts {
        ProtectionSummary.CopyFacts(volumeName: volumeName, isOnline: reason != .driveOffline,
                                    isArchiveCopy: false, fixityVerified: false, attestations: attestations)
    }
}

extension PrunePlan {

    public func archiveOnlyItems(after selected: Set<UUID>) -> [Item] {
        items.filter { $0.leavesArchiveOnly(after: selected) }
    }

    /// The confirmation's advice sentence, or nil when every item keeps a
    /// copy outside the archive.
    public func adviceSentence(after selected: Set<UUID>) -> String? {
        let only = archiveOnlyItems(after: selected)
        guard !only.isEmpty else { return nil }
        let n = only.count
        var text = "\(n) file\(n == 1 ? "" : "s") will exist only in the Master Archive after this."
        let bare = only.filter { !$0.hasCloudOrOffsiteYes }.map(\.archive.filename)
        if !bare.isEmpty { text += " No cloud or off-site copy is recorded for " + Self.names(bare) + "." }
        return text
    }

    /// "A, B and 3 more".
    static func names(_ list: [String], limit: Int = 3) -> String {
        let head = list.prefix(limit).joined(separator: ", ")
        return list.count > limit ? "\(head) and \(list.count - limit) more" : head
    }

    /// The protection line for the plan: one family per archive file, plus
    /// one per batch record that is not archived yet.
    public var protection: ProtectionSummary {
        ProtectionSummary.summarize(families: items.map(\.copyFacts) + unarchived.map { [$0.workingFacts] })
    }

    /// One header line plus one line per item, for the log.
    public func logLines(batchID: String) -> [String] {
        let head = "Archived — what next? [\(batchID)]: \(items.count) archived file\(items.count == 1 ? "" : "s"), "
            + "\(offeredCount) offered (\(offeredBytes) bytes), \(unarchived.count) not in the archive yet"
            + (hiddenRowCount > 0 ? ", \(hiddenRowCount) not listed" : "")
        return [head] + items.map(\.logLine)
    }
}
