// CatalogRowMenuLayoutSensorTests.swift
// SENSOR for the Catalog row menu's 2026-10-08 layout (Rick: "EXACTLY!"):
// seven groups in a fixed order with a separator between each, the
// Get Info… / Verify… / Repair… wording, both Remove items in the bottom
// group, and Delete File ▸ shown DISABLED with the reason — never hidden —
// when nothing selected may be deleted. Which records are deletable is
// the delete gate's business and is NOT exercised here beyond reading it.
//
// The builder is SwiftUI, so the order is pinned against its source (the
// repo's source-sensor convention, SourceTree); the decisions are pinned
// as plain values (CatalogRowMenuGroup, CatalogDeleteFileItem).

import Foundation
import Testing
@testable import VideoScan

@Suite("Catalog row menu — Get Info · Verify · Repair layout")
@MainActor
struct CatalogRowMenuLayoutSensorTests {

    /// The source between `start` and `end` in one app file.
    private func slice(_ file: String, from start: String, to end: String) throws -> Substring {
        let s = try SourceTree.appSource(named: file)
        let a = try #require(s.range(of: start), "\(file): no \(start)")
        let b = try #require(s.range(of: end, range: a.upperBound..<s.endIndex), "\(file): no \(end) after \(start)")
        return s[a.upperBound..<b.lowerBound]
    }

    private func activeMenuBody() throws -> Substring {
        try slice("CatalogRowContextMenu.swift",
                  from: "private func activeRowContextMenu(", to: "private func isTranscodeRunning(")
    }

    @Test func theGroupsAreTheSevenRickAskedFor() {
        #expect(CatalogRowMenuGroup.allCases == [.open, .inspect, .process, .archive, .describe, .find, .remove])
    }

    /// Every group's builder is called, in `CatalogRowMenuGroup` order,
    /// with exactly one Divider between consecutive groups.
    @Test func groupsAppearInOrderWithASeparatorBetweenEach() throws {
        let body = try activeMenuBody()
        var previous: String.Index?
        var previousName = ""
        for group in CatalogRowMenuGroup.allCases {
            let call = try #require(body.range(of: "\(group.builderName)("), "\(group.builderName) is not called")
            if let previous {
                #expect(previous < call.lowerBound, "\(group.builderName) must come after \(previousName)")
                let between = body[previous..<call.lowerBound]
                #expect(between.components(separatedBy: "Divider()").count - 1 == 1,
                        "exactly one separator between \(previousName) and \(group.builderName)")
            }
            previous = call.upperBound
            previousName = group.builderName
        }
        #expect(body.components(separatedBy: "Divider()").count - 1 == CatalogRowMenuGroup.allCases.count - 1)
    }

    @Test func renamedLabels() {
        #expect(CatalogRowMenuText.getInfo == "Get Info\u{2026}")
        #expect(CatalogRowMenuText.verify(count: 1) == "Verify\u{2026}")
        #expect(CatalogRowMenuText.verify(count: 2) == "Verify 2 Files\u{2026}")
        #expect(CatalogRowMenuText.repair == "Repair\u{2026}")
    }

    /// The inspect group reads Get Info… · Verify… · Repair…, in that order.
    @Test func inspectGroupReadsGetInfoVerifyRepair() throws {
        let group = try slice("CatalogRowContextMenu+Media.swift",
                              from: "func mediaCheckMenuItems(", to: "func presentMediaInfo(")
        let info = try #require(group.range(of: "CatalogRowMenuText.getInfo"))
        let verify = try #require(group.range(of: "checkMediaMenuItem("))
        let repair = try #require(group.range(of: "repairMenuItem("))
        #expect(info.lowerBound < verify.lowerBound && verify.lowerBound < repair.lowerBound)
    }

    /// Repair… is enabled for one connected file (Verify first when there
    /// is no current card), disabled with the reason otherwise.
    @Test func repairMenuStateTruthTable() {
        let none = MediaRepairSoundFacts()
        let layout = MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: 10, headline: "",
                                     checks: [MediaCheck(kind: .layout, verdict: .problem, sentence: "apart")])
        let clean = MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: 10, headline: "",
                                    checks: [MediaCheck(kind: .layout, verdict: .ok, sentence: "fine")])
        #expect(MediaRepairPlan.menuState(card: nil, fileSizeBytes: 10, sound: none, reachable: true, selectionCount: 1) == .verifyFirst)
        #expect(MediaRepairPlan.menuState(card: layout, fileSizeBytes: 99, sound: none, reachable: true, selectionCount: 1) == .verifyFirst)
        #expect(MediaRepairPlan.menuState(card: layout, fileSizeBytes: 10, sound: none, reachable: true, selectionCount: 1) == .ready(count: 1))
        #expect(!MediaRepairPlan.menuState(card: clean, fileSizeBytes: 10, sound: none, reachable: true, selectionCount: 1).isEnabled)
        #expect(!MediaRepairPlan.menuState(card: layout, fileSizeBytes: 10, sound: none, reachable: false, selectionCount: 1).isEnabled)
        #expect(!MediaRepairPlan.menuState(card: layout, fileSizeBytes: 10, sound: none, reachable: true, selectionCount: 2).isEnabled)
    }

    /// No user-visible string literal in the app still says the old verbs
    /// (comments may keep the history).
    @Test func theOldVerbsAreGoneFromEveryUserVisibleString() throws {
        var hits: [String] = []
        for entry in SourceTree.appSources {
            let text = (try? String(contentsOf: entry.url, encoding: .utf8)) ?? ""
            for line in text.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.hasPrefix("//") else { continue }
                let literals = trimmed.matches(of: /"[^"]*"/).map { String(trimmed[$0.range]) }
                for lit in literals where lit.contains("Check Media") || lit.contains("Get Media Info") {
                    hits.append("\((entry.relative as NSString).lastPathComponent): \(lit)")
                }
            }
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    /// Both Remove items live in the bottom group, above Delete File; the
    /// keep-files one left the archive group.
    @Test func bothRemoveItemsSitInTheBottomGroup() throws {
        let bottom = try slice("CatalogRowContextMenu.swift",
                               from: "private func removeAndDeleteItems(", to: "private func deleteFileItem(")
        let remove = try #require(bottom.range(of: "CatalogRowMenuText.removeFromCatalog(count:"))
        let keep = try #require(bottom.range(of: "removeFromCatalogMenuItem("))
        let delete = try #require(bottom.range(of: "switch deleteFileItem("))
        #expect(remove.lowerBound < keep.lowerBound && keep.lowerBound < delete.lowerBound)
        let archive = try slice("CatalogRowContextMenu+FileOps.swift",
                                from: "func archiveItems(", to: "/// Transcribe Audio")
        #expect(!archive.contains("removeFromCatalogMenuItem("), "moved down, not duplicated")
        // Labels unchanged (Rick hasn't decided on renames).
        #expect(CatalogRowMenuText.removeFromCatalog(count: 1) == "Remove from Catalog")
        let promote = try SourceTree.appSource(named: "CatalogContent+Promote.swift")
        #expect(promote.contains("\"Remove from Catalog (keep files)\""))
    }

    // MARK: Delete File ▸ — presentation of the gate's answer

    @Test func deleteFileStateTruthTable() {
        #expect(CatalogDeleteFileItem.resolve(activeCount: 0, deletableCount: 0, refusalNote: nil) == .hidden)
        #expect(CatalogDeleteFileItem.resolve(activeCount: 3, deletableCount: 2, refusalNote: nil) == .enabled(count: 2))
        let one = CatalogDeleteFileItem.resolve(
            activeCount: 1, deletableCount: 0,
            refusalNote: VideoScanModel.bulkDeleteRefusalNote(.archiveVolume, volume: "FamilyArchive"))
        #expect(one == .disabled(help: "Protected: this file lives on FamilyArchive, the Master Archive volume, which only archive actions may change."))
        guard case .disabled(let many) = CatalogDeleteFileItem.resolve(activeCount: 4, deletableCount: 0, refusalNote: "x") else {
            Issue.record("4 protected rows must read disabled"); return
        }
        #expect(many.hasPrefix("Protected: none of these files may be deleted"))
    }

    private func model(_ label: String) -> VideoScanModel {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_rowmenu_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        m.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        return m
    }

    private func target(_ path: String, readOnly: Bool) -> CatalogScanTarget {
        let t = CatalogScanTarget(searchPath: path)
        t.role = .workspace
        t.isReachable = true
        if readOnly { t.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(timeIntervalSince1970: 1_790_000_000), volumeUUID: nil) }
        return t
    }

    private func record(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        return r
    }

    /// The real gate decides; the menu only presents: a file on a volume
    /// marked Read only gets a DISABLED Delete File with the gate's reason,
    /// a normal file an enabled one.
    @Test func deleteFileIsDisabledForAProtectedRecordAndEnabledForANormalOne() {
        let m = model("delete")
        m.scanTargets = [target("/Volumes/test_SanDiskRO", readOnly: true), target("/Volumes/test_X9", readOnly: false)]
        let protected = record("/Volumes/test_SanDiskRO/test_a.mov")
        let normal = record("/Volumes/test_X9/test_b.mov")

        let protectedDeletable = m.recordsBulkVerbsMayRemove([protected])
        #expect(protectedDeletable.isEmpty, "the gate (unchanged) refuses the read-only file")
        #expect(m.deleteFileMenuItem(activeRecs: [protected], deletableRecs: protectedDeletable)
                == .disabled(help: "Protected: this file lives on test_SanDiskRO, which you marked Read only."))

        let normalDeletable = m.recordsBulkVerbsMayRemove([normal])
        #expect(m.deleteFileMenuItem(activeRecs: [normal], deletableRecs: normalDeletable) == .enabled(count: 1))

        // Mixed: only the deletable one is counted — the scope is the gate's.
        let mixed = m.recordsBulkVerbsMayRemove([protected, normal])
        #expect(m.deleteFileMenuItem(activeRecs: [protected, normal], deletableRecs: mixed) == .enabled(count: 1))
    }

    /// The disabled item is built from the SAME empty scope, so even if it
    /// could be invoked it would act on nothing.
    @Test func theDisabledItemNeverActs() throws {
        let bottom = try slice("CatalogRowContextMenu.swift",
                               from: "case .disabled(let help):", to: "case .enabled:")
        #expect(bottom.contains(".disabled(true)"))
        #expect(!bottom.contains("deleteConfirmedJunk"), "no action inside the protected item")
    }
}
