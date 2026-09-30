// CatalogAuditFixer.swift
// Applies a CatalogAuditFix through the model on the main actor — the
// "Fix it for me" half of Audit Catalog (Rick 2026-08-19). Every mutation
// goes through the same in-memory records + debounced save + mutation
// notification as a hand edit, so it is logged, persisted under the
// single-writer discipline, and reflected everywhere at once.

import Foundation

enum CatalogAuditFixer {
    struct Outcome: Equatable {
        var changed: Int
        var summary: String
    }

    @MainActor
    static func apply(_ fix: CatalogAuditFix, model: VideoScanModel) -> Outcome {
        let outcome: Outcome
        switch fix {
        case .setPurgedStages(let ids):
            let want = Set(ids)
            var n = 0
            for r in model.records where want.contains(r.id) && r.isPurged {
                if r.lifecycleStage != .trashed && r.lifecycleStage != .deletedPermanently {
                    r.lifecycleStage = .trashed
                    n += 1
                }
            }
            outcome = Outcome(changed: n, summary: "Set Trashed on \(n) purged record\(n == 1 ? "" : "s")")

        case .unpair(let ids):
            let want = Set(ids)
            var n = 0
            for r in model.records where want.contains(r.id) {
                if let partner = r.pairedWith, partner.pairedWith === r {
                    partner.pairedWith = nil
                    partner.pairGroupID = nil
                    partner.pairConfidence = nil
                }
                if r.pairedWith != nil || r.pendingPairedWithID != nil || r.pairGroupID != nil {
                    r.pairedWith = nil
                    r.pendingPairedWithID = nil
                    r.pairGroupID = nil
                    r.pairConfidence = nil
                    n += 1
                }
            }
            outcome = Outcome(changed: n, summary: "Unpaired \(n) record\(n == 1 ? "" : "s")")

        case .recountDuplicateGroups(let groupIDs):
            let want = Set(groupIDs)
            var members: [UUID: [VideoRecord]] = [:]
            for r in pfActiveRecords(model.records) {
                if let g = r.duplicateGroupID, want.contains(g) { members[g, default: []].append(r) }
            }
            var n = 0
            for (_, recs) in members {
                if recs.count <= 1 {
                    for r in recs {
                        r.duplicateGroupID = nil
                        r.duplicateGroupCount = 0
                        r.duplicateConfidence = nil
                        r.duplicateDisposition = .none
                        r.duplicateReasons = ""
                        r.duplicateBestMatchFilename = ""
                        n += 1
                    }
                } else {
                    for r in recs where r.duplicateGroupCount != recs.count {
                        r.duplicateGroupCount = recs.count
                        n += 1
                    }
                }
            }
            // Stale groups whose members are ALL gone (purged) — nothing to
            // touch; they simply no longer exist among active records.
            outcome = Outcome(changed: n, summary: "Recounted \(members.count) group\(members.count == 1 ? "" : "s"), \(n) record\(n == 1 ? "" : "s") updated")

        case .deleteEmptyTargets(let paths):
            var n = 0
            for p in paths {
                if let t = model.scanTargets.first(where: { $0.searchPath == p }), !t.isRetired {
                    if model.deleteScanTarget(t) { n += 1 }
                }
            }
            outcome = Outcome(changed: n, summary: "Deleted \(n) empty scan target\(n == 1 ? "" : "s") from the list")
        }

        if outcome.changed > 0 {
            model.saveCatalogDebounced()
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: nil)
        }
        model.log("Catalog audit fix: \(outcome.summary)")
        return outcome
    }
}
