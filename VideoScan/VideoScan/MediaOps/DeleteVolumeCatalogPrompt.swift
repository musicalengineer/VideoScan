// DeleteVolumeCatalogPrompt.swift
// The value the Delete Volume Catalog alert presents (codex #1417,
// 2026-09-12). It carries the EXACT removal plan made at the gesture so
// the count the user reads and the ids the model removes are one thing.
//
// Before this, the alert read the coalesced `scanTargetFacts` projection
// (up to one recompute window stale) while `deleteCatalogForTarget` re-
// scoped against the live catalog: a cached "1 file" could confirm and
// remove 2 after an append; a Browse… re-point could swap the whole
// root under a stale count. Now the alert shows `plan.count`, the Delete
// button hands `plan` back, and the model refuses a plan the catalog has
// drifted from — re-presenting this prompt with the fresh plan.
//
// Wording (Rick's ruling 2026-10-03: "it should always be clear what
// we're deleting before we even click it"): these gestures remove CATALOG
// RECORDS ONLY, never media on disk, and they sit near Storage's "Delete
// duplicates here…" which really removes files. So the menus say
// "Remove from Catalog" / "Forget …", and every confirmation carries the
// sentence in `RemoveFromCatalogWording.filesNeverTouched`.
//
// Same ruling, same day: the volume table's MULTI-select "Delete Catalog"
// used to remove with no confirmation at all. `DeleteVolumesCatalogPrompt`
// below is its confirmation — one plan per selected volume, made at the
// gesture, applied exactly or refused, like the single-volume prompt.

import Foundation

/// The shared words for the "remove catalog records" menus and
/// confirmations (one volume / several volumes / the entire catalog). One
/// place, so the menus, the alerts and the sensor test cannot drift apart.
/// (A caseless `enum` ≈ a C++ namespace of constants and free functions:
/// it cannot be instantiated.)
enum RemoveFromCatalogWording {
    /// Catalog Options menu section title.
    static let sectionTitle = "Remove from Catalog"
    /// Title of every confirmation alert.
    static let alertTitle = "Remove from Catalog?"
    /// The sentence every alert message must contain.
    static let filesNeverTouched = "Files on disk are never touched."
    /// Catalog Options menu tooltip.
    static let menuHelp = "Update the catalog, or forget records (files on disk are never touched)"
    /// Volume-table context-menu tooltip.
    static let contextMenuHelp = "Forget the catalog records for the selected volume(s). Files on disk are never touched."
    /// Last line of the per-volume confirmations.
    static let probeCacheNote = "The probe cache is unaffected — a re-scan will replay quickly from cache."
    /// How many volumes a multi-volume confirmation names before "and N more".
    static let maxVolumesListed = 5

    /// "1 record" / "N records".
    static func records(_ count: Int) -> String {
        count == 1 ? "1 record" : "\(count) records"
    }

    /// Confirm button of every alert: "Forget N Records".
    static func forgetButtonTitle(count: Int) -> String {
        count == 1 ? "Forget 1 Record" : "Forget \(count) Records"
    }

    /// Catalog Options row for one volume: "Forget N records from <Volume>…".
    /// (No possessive — volume names ending in "s" read badly with 's.)
    static func forgetVolumeMenuTitle(volume: String, count: Int) -> String {
        "Forget \(records(count)) from \(volume)…"
    }

    /// Catalog Options row for everything: "Forget the entire catalog (N records)…".
    static func forgetAllMenuTitle(count: Int) -> String {
        "Forget the entire catalog (\(records(count)))…"
    }

    /// Volume-table context-menu item, by how many volumes are selected.
    static func contextMenuTitle(volumeCount: Int) -> String {
        volumeCount == 1
            ? "Forget This Volume's Records…"
            : "Forget Records for \(volumeCount) Volumes…"
    }

    /// Body of the entire-catalog confirmation. Pure over `count`.
    static func forgetAllMessage(count: Int) -> String {
        "This will forget all \(count) catalog records across every volume. \(filesNeverTouched) The probe cache is unaffected.\n\nAre you sure?"
    }
}

// MARK: - One volume

struct DeleteVolumeCatalogPrompt {
    let target: CatalogScanTarget
    /// The plan made when the user chose Forget; what the alert counts
    /// and what the confirm button applies.
    let plan: TargetRemovalPlan
    /// Non-nil when this prompt replaces one the model refused as stale —
    /// the message says so and quotes the old count, so the user knows
    /// why the dialog came back.
    let replacedStalePlan: TargetRemovalPlan?

    /// Confirm button label — the PLAN's count, same number as the message.
    var confirmButtonTitle: String {
        RemoveFromCatalogWording.forgetButtonTitle(count: plan.count)
    }

    /// Alert body. Pure over the prompt's fields (no model read) so
    /// ContentView's alert stage stays O(1) and the text is unit-testable.
    var message: String {
        let label = VolumeReachability.displayLabel(forPath: plan.root)
        var lines: [String] = []
        if let stale = replacedStalePlan {
            lines.append("The catalog changed while this was open (was \(stale.count) record(s), now \(plan.count)). Nothing was removed — please confirm again.")
            lines.append("")
        }
        lines.append("Forget \(plan.count) catalog record(s) for \(label)?")
        lines.append(RemoveFromCatalogWording.filesNeverTouched)
        if plan.keptCoveredByOtherTargets > 0 {
            lines.append("")
            lines.append("\(plan.keptCoveredByOtherTargets) record(s) under this path also belong to another scan target and will be kept.")
        }
        lines.append("")
        lines.append(RemoveFromCatalogWording.probeCacheNote)
        return lines.joined(separator: "\n")
    }
}

// MARK: - Several volumes (volume-table multi-select)

/// The confirmation for "Forget Records for N Volumes…". One
/// `TargetRemovalPlan` per selected volume, all made at the gesture; the
/// alert shows their summed count and the confirm button applies exactly
/// those plans through the same guarded `deleteCatalogForTarget(_:plan:)`
/// the single-volume prompt uses. Never more than shown.
///
/// Memory: one `Set<UUID>` of record ids per selected volume — at most one
/// id (16 bytes + set overhead) per catalog record in total, and only
/// while the alert is up.
struct DeleteVolumesCatalogPrompt {
    struct Item {
        let target: CatalogScanTarget
        let plan: TargetRemovalPlan
    }

    /// What happened on the previous confirm, when this prompt is a
    /// re-presentation after the model refused some plans as stale.
    struct Replaced: Equatable {
        /// Summed count the user had been shown for the volumes listed now.
        let staleCount: Int
        /// Records already forgotten, exactly as shown, on that confirm.
        let alreadyRemoved: Int
        /// How many volumes those came from.
        let alreadyRemovedVolumes: Int
    }

    let items: [Item]
    let replaced: Replaced?

    /// The total the alert shows and the button names — the plans' sum.
    var totalCount: Int { items.reduce(0) { $0 + $1.plan.count } }

    var keptCoveredByOtherTargets: Int {
        items.reduce(0) { $0 + $1.plan.keptCoveredByOtherTargets }
    }

    var confirmButtonTitle: String {
        RemoveFromCatalogWording.forgetButtonTitle(count: totalCount)
    }

    /// Alert body. Pure over the carried plans (no model read) — O(items),
    /// never O(records).
    var message: String {
        var lines: [String] = []
        if let replaced {
            if replaced.alreadyRemoved > 0 {
                lines.append("Forgot \(RemoveFromCatalogWording.records(replaced.alreadyRemoved)) from \(replaced.alreadyRemovedVolumes) volume(s), as shown.")
            }
            lines.append("The catalog changed while this was open (was \(replaced.staleCount) record(s), now \(totalCount)). Nothing was removed for the volume(s) below — please confirm again.")
            lines.append("")
        }
        lines.append("Forget \(totalCount) catalog record(s) for \(items.count) volume(s)?")
        let limit = RemoveFromCatalogWording.maxVolumesListed
        for item in items.prefix(limit) {
            let label = VolumeReachability.displayLabel(forPath: item.plan.root)
            lines.append("• \(label) — \(RemoveFromCatalogWording.records(item.plan.count))")
        }
        if items.count > limit {
            lines.append("and \(items.count - limit) more")
        }
        lines.append("")
        lines.append(RemoveFromCatalogWording.filesNeverTouched)
        if keptCoveredByOtherTargets > 0 {
            lines.append("\(keptCoveredByOtherTargets) record(s) under these paths also belong to another scan target and will be kept.")
        }
        lines.append("")
        lines.append(RemoveFromCatalogWording.probeCacheNote)
        return lines.joined(separator: "\n")
    }

    /// Plan every target NOW — one O(records) pass per selected volume, on
    /// an explicit gesture, never from a view body. Sorted by volume label
    /// so the alert reads the same every time (the selection is a Set).
    /// (`@MainActor` ≈ "must run on the UI thread": the model is UI-thread
    /// state.)
    @MainActor
    static func plan(for targets: [CatalogScanTarget], model: VideoScanModel) -> DeleteVolumesCatalogPrompt {
        let items = targets
            .map { Item(target: $0, plan: model.planTargetRemoval(for: $0)) }
            .sorted {
                VolumeReachability.displayLabel(forPath: $0.plan.root)
                    .localizedStandardCompare(VolumeReachability.displayLabel(forPath: $1.plan.root)) == .orderedAscending
            }
        return DeleteVolumesCatalogPrompt(items: items, replaced: nil)
    }

    /// The confirm button. Applies each volume's carried plan through the
    /// guarded, plan-taking model entry. A plan the model refuses as stale
    /// removes nothing for that volume; those volumes come back as a
    /// replacement prompt carrying the model's fresh plans (the caller
    /// re-presents it). Returns nil when there is nothing to re-confirm.
    ///
    /// Volumes whose plan is still exact ARE forgotten on this confirm —
    /// that is what the user was shown for them; the replacement prompt
    /// says so. Target-gone and no-snapshot refusals end quietly here: the
    /// model has already logged the reason and removed nothing.
    @MainActor
    func apply(to model: VideoScanModel) -> DeleteVolumesCatalogPrompt? {
        var stale: [Item] = []
        var staleCount = 0
        var removed = 0
        var removedVolumes = 0
        for item in items {
            switch model.deleteCatalogForTarget(item.target, plan: item.plan) {
            case .applied(let count, _):
                removed += count
                removedVolumes += 1
            case .refusedStale(let current):
                stale.append(Item(target: item.target, plan: current))
                staleCount += item.plan.count
            case .refusedNoSnapshot, .cancelledTargetGone:
                break
            }
        }
        guard !stale.isEmpty else { return nil }
        return DeleteVolumesCatalogPrompt(
            items: stale,
            replaced: Replaced(staleCount: staleCount,
                               alreadyRemoved: removed,
                               alreadyRemovedVolumes: removedVolumes))
    }
}
