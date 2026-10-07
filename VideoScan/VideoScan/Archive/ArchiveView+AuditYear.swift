// ArchiveView+AuditYear.swift
// Archive tab — wiring for "Audit <year>…" (Rick 2026-10-07): the main-
// actor projection of archived cards into `ArchiveAuditInput`s, and the
// model glue for the two things the audit remembers (ArchiveAuditStore).
// The rules themselves are pure: ArchiveAuditYear.swift.
//
// Visibility rule (Rick): the audit lives behind the year header's
// right-click ONLY — no badges on the ribbon or the cards.

import Foundation
import VideoScanCore

/// Drives the sheet: `.sheet(item:)` needs an Identifiable value.
struct ArchiveAuditRequest: Identifiable, Equatable {
    let year: Int
    var id: Int { year }
}

// MARK: - Projection (main actor, O(archived cards))

extension ArchiveView {

    /// Every archived card as an audit input — the timeline items (tags
    /// applied) plus the catalog facts the repeat rules read. Transcripts
    /// are copied only for `year`'s cards (Swift strings are copy-on-write,
    /// so this shares the catalog's storage rather than duplicating it).
    /// Called once per sheet open / refresh, never from a view body.
    @MainActor
    static func auditInputs(items: [ArchiveTimelineItem], year: Int, model: VideoScanModel,
                            tags: [UUID: ArchiveOccasionTag]) -> [ArchiveAuditInput] {
        items.map { auditInput($0, year: year, model: model, isTagged: tags[$0.id] != nil) }
    }

    @MainActor
    static func auditInput(_ item: ArchiveTimelineItem, year: Int, model: VideoScanModel,
                           isTagged: Bool) -> ArchiveAuditInput {
        var input = ArchiveAuditInput(id: item.id, title: item.title, year: item.year,
                                      durationSeconds: item.durationSeconds, occasion: item.occasion,
                                      occasionIsUserTag: isTagged)
        var memberIDs = [item.id]
        for v in item.versions where v.id != item.id { memberIDs.append(v.id) }
        input.memberIDs = memberIDs
        var lineage = Set<UUID>()
        var hashes = Set<String>()
        var groups = Set<UUID>()
        for rec in memberIDs.compactMap({ model.record(forID: $0) }) {
            let copy = model.isArchiveCopy(rec) ? nil : model.masterArchiveCopy(of: rec)
            for r in [rec] + (copy.map { [$0] } ?? []) {
                lineage.insert(r.id)
                if let d = r.derivedFrom { lineage.insert(d) }
                if !r.contentHash.isEmpty { hashes.insert(r.contentHash) }
                if let g = r.footageGroupID { groups.insert(g) }
                input.thumbnailPaths.append(r.fullPath)
            }
            if item.year == year, input.transcript == nil, let t = rec.audioTranscript, !t.isEmpty {
                input.transcript = t
            }
        }
        input.lineageKeys = lineage.sorted { $0.uuidString < $1.uuidString }
        input.contentHashes = hashes.sorted()
        input.footageGroupIDs = groups.sorted { $0.uuidString < $1.uuidString }
        return input
    }

    /// The timeline items with Rick's occasion tags applied — what the
    /// decade page and the audit both read. O(archived) per data change.
    @MainActor
    func taggedTimelineItems() -> [ArchiveTimelineItem] {
        ArchiveOccasionTags.apply(model.archiveAuditStore.tags, to: cachedTimelineItems())
    }

    /// The sheet's input snapshot for `year` (main actor; the build runs
    /// off-main in the sheet).
    @MainActor
    func auditSnapshot(year: Int) -> (inputs: [ArchiveAuditInput], decisions: [ArchiveAuditDecision]) {
        let store = model.archiveAuditStore
        return (Self.auditInputs(items: taggedTimelineItems(), year: year, model: model, tags: store.tags),
                store.decisions)
    }
}

// MARK: - Off-main build

extension ArchiveAuditBuilder {
    /// The build on the cooperative pool, never the main actor. (For Rick:
    /// `@concurrent` ≈ "always run this on a worker thread", even when the
    /// caller is the UI thread — without it a nonisolated async func runs
    /// on the CALLER's actor in this project; see the approachable-
    /// concurrency note in memory.)
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func buildOffMain(year: Int, inputs: [ArchiveAuditInput],
                                         decisions: [ArchiveAuditDecision]) async -> ArchiveAuditReport {
        build(year: year, inputs: inputs, decisions: decisions)
    }
}

// MARK: - Model glue (decisions + tags)

extension VideoScanModel {

    /// Load the sidecar once — the Archive tab's first appearance. Bumps the
    /// revision so tags loaded from disk reach the cues.
    func loadArchiveAuditIfNeeded() async {
        guard !archiveAuditStore.isLoaded else { return }
        await archiveAuditStore.loadIfNeeded()
        archiveAuditRevision &+= 1
    }

    /// "These are different, keep both" for one group.
    func archiveAuditKeepBoth(_ group: ArchiveAuditRepeatGroup, titles: [String]) {
        guard archiveAuditStore.keepBoth(kind: group.kind, ids: group.decisionIDs, titles: titles) else { return }
        persistArchiveAudit("Audit: kept as different (\(group.kind.heading)) — \(titles.joined(separator: " · "))")
    }

    /// Undo of the above.
    func archiveAuditUndoKeepBoth(_ group: ArchiveAuditRepeatGroup) {
        guard archiveAuditStore.forgetDecision(kind: group.kind, ids: group.decisionIDs) else { return }
        persistArchiveAudit("Audit: \(group.kind.heading) group shown again")
    }

    /// Tag occasion ▸ … on one card.
    func archiveAuditTag(itemID: UUID, occasion: ArchiveOccasion, word: String? = nil, title: String) {
        archiveAuditStore.setTag(itemID: itemID, occasion: occasion, word: word, title: title)
        persistArchiveAudit("Audit: tagged “\(title)” as \(word ?? occasion.word)")
    }

    func archiveAuditClearTag(itemID: UUID, title: String) {
        guard archiveAuditStore.clearTag(itemID: itemID) else { return }
        persistArchiveAudit("Audit: tag removed from “\(title)” — back to the Angel's reading")
    }

    /// One revision bump (the timeline memo re-keys), one off-main atomic
    /// save, one log line.
    private func persistArchiveAudit(_ line: String) {
        archiveAuditRevision &+= 1
        appLog.write(line)
        let store = archiveAuditStore
        Task { @MainActor in await store.save() }
    }
}
