// AppSupportSideStoreInventoryTests.swift
// SENSOR (2026-10-19, "every decision Rick makes lives in catalog.sqlite"):
// every file name the app or VideoScanCore spells out (a "*.json", "*.jsonl",
// "*.plist", "*.sqlite", "*.log", "*.txt", "*.csv", "*.bin", "*.db" string
// literal) has been REVIEWED and given a class here. A new literal — a new
// side store — fails this test until someone decides what it is:
//
//   decisionNotInCatalog  Rick's decisions that do NOT live in catalog.sqlite
//                         yet — must move (the open list, said in the report)
//   journalIngested       a journal the app ingests into catalog.sqlite
//   frozenAfterImport     imported into catalog.sqlite; never written again
//   derived               rebuildable from the catalog or the media
//   logOrReport           logs, receipts, reports, job memory
//   separateByDesign      its own store on purpose (People/POI, the family
//                         tree, Hallie, settings, the store's own witnesses)
//   notAppSupport         not under Application Support/VideoScan (archive
//                         volume, Logs/, a save panel, a bundle, temp, an SF
//                         Symbol name)
//
// Moving a store between classes is a decision for Rick; changing this table
// is how it is recorded. Synthetic names only — no media is opened.

import Foundation
import Testing
@testable import VideoScan

@Suite("App Support side stores — every one classified")
struct AppSupportSideStoreInventoryTests {

    enum StoreClass: String, Sendable {
        case decisionNotInCatalog, journalIngested, frozenAfterImport, derived, logOrReport, separateByDesign, notAppSupport
    }

    /// The reviewed inventory (2026-10-19). Key = the literal as spelled.
    static let inventory: [String: StoreClass] = [
        // Rick's decisions NOT in catalog.sqlite — must move
        "archive-audit.json": .decisionNotInCatalog,          // Archive ▸ Audit <year>: "keep both" + occasion tags
        "media-person-links.json": .decisionNotInCatalog,     // "this record is about this person" (FamilySearch id ↔ record)
        "media-ledger.jsonl": .decisionNotInCatalog,          // ledger/: history of Rick's acts; JSONL only since the cutover
        // Journals ingested into catalog.sqlite
        ".ingest-state.json": .journalIngested,               // findtag-journal/ cursor: advances only after a durable save
        // Imported into catalog.sqlite, frozen
        "catalog.json": .frozenAfterImport,
        "events-decisions.json": .frozenAfterImport,          // EventsJSONImport (folders port)
        "ignored-content.json": .frozenAfterImport,           // IgnoredContentJSONImport (this change)
        // Derived / rebuildable
        "catalog.search-index.v1.plist": .derived,
        "evidence.json": .derived,                            // archive-angel/: the Angel's scores
        "events_latest.json": .derived,                       // metrics for tools/publish_metrics.py
        "metadata_cache.sqlite": .derived,                    // ffprobe cache
        "personfinder_cache.sqlite": .derived,
        "fullhash-backfill.json": .derived,                   // resume state of Fill In Full Hashes
        "sync-sources.json": .derived,                        // CatalogSync: written beside the manifest
        "sets.json": .derived,                                // Footage Spectrum helper input
        "current.json": .derived,                             // compiled family graph / sync pointer
        "last_sync.txt": .derived,
        "pronunciation-drill-manifest.json": .derived,
        // Logs, receipts, reports, job memory
        "integrity-latest.json": .logOrReport,
        "integrity-2026-10-16.json": .logOrReport,
        "catalog-audit.json": .logOrReport,                   // Audit Catalog's marker; results also land in audit_results
        "catalog-write-errors.jsonl": .logOrReport,
        "catalog.highwater.log": .logOrReport,                // the high-water's second witness
        "plan.json": .logOrReport,                            // delete-duplicates/<job>/ and Angel Prepare job memory
        "findtagd.log": .logOrReport,
        "background.log": .logOrReport,                       // ~/Library/Logs/VideoScan: VideoScan Background's own log (step 0, 2026-10-30)
        "previewsweepd.log": .logOrReport,
        "ollama.log": .logOrReport,
        "keys.log": .logOrReport,
        "people-audit.jsonl": .logOrReport,
        "person-refresh-journal.jsonl": .logOrReport,
        "m1.jsonl": .logOrReport, "m4.jsonl": .logOrReport, "m5.jsonl": .logOrReport,   // fleet stats
        // Separate stores by design
        "audio-fingerprints.sqlite": .separateByDesign,       // landmarks (the stamp is in catalog.sqlite)
        "model-lab.sqlite": .separateByDesign,                // model-lab runs/outputs/segments/vectors (video_llm_lab design §3.4; 2026-10-30)
        "catalog.sqlite": .separateByDesign,                  // THE catalog
        "policy.json": .separateByDesign,                     // archive-angel/: Rick's optional override, never written by the app
        "profile.json": .separateByDesign,                    // POI/
        ".uuid-migration.json": .separateByDesign,            // POI/
        "validation_labels.json": .separateByDesign,
        "cluster_names.json": .separateByDesign, "cluster_promotions.json": .separateByDesign,
        "holdout-review-clears.json": .separateByDesign,
        "family-identity-decisions.json": .separateByDesign, "family-tree-bookmarks.json": .separateByDesign,
        "chosen-photo.json": .separateByDesign, "decorations.json": .separateByDesign, "documents.json": .separateByDesign,
        "dossier.json": .separateByDesign, "overlay.json": .separateByDesign, ".notof.json": .separateByDesign,
        "person-of-the-day.json": .separateByDesign, "pronunciations.json": .separateByDesign,
        "pronunciation-drill.json": .separateByDesign, "kind-words.json": .separateByDesign, "cyberbrain.json": .separateByDesign,
        // Not under Application Support/VideoScan
        ".attestation_journal.jsonl": .notAppSupport, ".promote_journal.jsonl": .notAppSupport,
        ".promote_decisions.jsonl": .notAppSupport, ".videoscan-backup.json": .notAppSupport,
        "Archive_Inventory_Manifest.csv": .notAppSupport, "README_Naming_and_Layout.txt": .notAppSupport,
        ".framemd5-MISMATCH.log": .notAppSupport,             // beside a transcode output
        "2026-10-09_214502_junk.csv": .notAppSupport,         // Logs/VideoScan/deletions (doc example)
        "TidyCatalog_dry_run.csv": .notAppSupport, "VideoScan_Volumes.csv": .notAppSupport,
        "rick-review-neutral.csv": .notAppSupport, "rick-review-neutral.person.txt": .notAppSupport,
        "cluster_summary.csv": .notAppSupport,                // a People run's output folder
        "manifest.json": .notAppSupport, "settings.json": .notAppSupport, "volumes.json": .notAppSupport,   // bundle members
        "concat.txt": .notAppSupport, "transcript.txt": .notAppSupport,                                      // temp
        "thumbs.db": .notAppSupport,                           // a scan skip name
        "xmark.bin": .notAppSupport,                           // an SF Symbol
    ]

    /// Every file-name literal in the app and VideoScanCore sources.
    static func literals() throws -> Set<String> {
        let projectDir = SourceTree.appSourceRoot.deletingLastPathComponent()
        let roots = [SourceTree.appSourceRoot, projectDir.appendingPathComponent("VideoScanCore/Sources", isDirectory: true)]
        let pattern = try NSRegularExpression(pattern: #""([A-Za-z0-9_.\-]+\.(?:json|jsonl|plist|sqlite|txt|log|csv|bin|db))""#)
        var found = Set<String>()
        for root in roots {
            let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            while let url = walk?.nextObject() as? URL {
                guard url.pathExtension == "swift", let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for m in pattern.matches(in: text, range: range) {
                    if let r = Range(m.range(at: 1), in: text) { found.insert(String(text[r])) }
                }
            }
        }
        return found
    }

    @Test("every file name the code spells is classified — a new side store cannot appear unreviewed")
    func everyLiteralIsClassified() throws {
        let found = try Self.literals()
        #expect(found.count > 50, "the scan read the sources (found \(found.count))")
        let unreviewed = found.subtracting(Self.inventory.keys).sorted()
        #expect(unreviewed.isEmpty, "classify these in AppSupportSideStoreInventoryTests.inventory: \(unreviewed)")
    }

    @Test("the table names no store the code no longer spells (it stays the truth, not a museum)")
    func noStaleEntries() throws {
        let found = try Self.literals()
        let stale = Set(Self.inventory.keys).subtracting(found).sorted()
        #expect(stale.isEmpty, "remove from the inventory: \(stale)")
    }

    @Test("the open list: Rick's decisions still outside catalog.sqlite are exactly these three")
    func openList() {
        let open = Self.inventory.filter { $0.value == .decisionNotInCatalog }.keys.sorted()
        #expect(open == ["archive-audit.json", "media-ledger.jsonl", "media-person-links.json"])
    }
}
