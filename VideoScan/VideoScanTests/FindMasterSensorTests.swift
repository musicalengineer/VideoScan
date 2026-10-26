// FindMasterSensorTests.swift — source sensors for Provenance ▸ Find Master
// (design provenance_retroactive_2026_10_26 §Phase A, sensor lane):
//   • the Find Master files write nothing — no commit, save, sidecar put,
//     file removal or trash — and add no `extension VideoScanModel` (rule 12);
//   • no app file constructs an AudioMatchVerdict (the verdict is Core's
//     pair matcher, rule 4);
//   • `.findMaster` is a registered kind with a detail view;
//   • the catalog row menu carries the Provenance menu.

import Foundation
import Testing
@testable import VideoScan

@Suite("FindMaster sensors")
@MainActor
struct FindMasterSensorTests {

    static let files = ["FindMasterPlan.swift", "FindMasterAnswer.swift", "FindMasterJob.swift",
                        "FindMasterDetailView.swift", "FindMasterMenuItem.swift"]

    @Test("the Find Master files write nothing and extend no model")
    func findMasterFilesWriteNothing() throws {
        let forbidden = ["commit(", "saveCatalog", ".put(", "removeItem", "trashItem", "extension VideoScanModel",
                         "createFile", ".write(to:"]
        for name in Self.files {
            let code = try SourceTree.appCode(named: "Provenance/" + name)
            #expect(!code.isEmpty, "\(name) read as empty")
            for token in forbidden {
                #expect(!code.contains(token), "\(name) contains \(token)")
            }
        }
    }

    @Test("no app source constructs an AudioMatchVerdict — the verdict is Core's")
    func noVerdictIsMadeOutsideCore() throws {
        let constructors = try Regex(#"AudioMatchVerdict\s*\.\s*(sameRecording|containedInMaster|masterContainedInQuery|overlap|different|inconclusive)\b|(=|return)\s*\.(sameRecording|different)\b"#)
        for name in Self.files {
            let code = try SourceTree.appCode(named: "Provenance/" + name)
            #expect(!code.contains(constructors), "\(name) builds a verdict")
        }
    }

    @Test("weak overlaps are a collapsed-by-default group with their count; strong hits are listed")
    func weakOverlapsStartCollapsed() throws {
        let code = try SourceTree.appCode(named: "Provenance/FindMasterDetailView.swift")
        #expect(code.contains("@State private var isExpanded = false"))
        #expect(code.contains("DisclosureGroup(isExpanded: $isExpanded)"))
        #expect(code.contains("FindMasterAnswer.weakHeader(count: weak.count)"))
        #expect(code.contains("FindMasterAnswer.split(found)"))
    }

    @Test(".findMaster is a registered kind with a detail view")
    func findMasterIsARegisteredKind() {
        #expect(MediaFileOperationKind.all.contains(.findMaster))
        #expect(MediaFileOperationKind.findMaster.hasDetailView)
        #expect(MediaFileOperationKind.findMaster.logVerb == "find master")
    }

    @Test("the catalog row menu carries Provenance ▸ Find Master")
    func tableContextMenuHasTheProvenanceMenu() throws {
        let code = try SourceTree.appCode(named: "Catalog/CatalogContent+FolderTable.swift")
        let start = try #require(code.range(of: "func tableContextMenu("))
        let body = code[start.lowerBound...].prefix(900)
        #expect(body.contains("FindMasterMenuItem("))
        let menu = try SourceTree.appCode(named: "Provenance/FindMasterMenuItem.swift")
        #expect(menu.contains("Menu(\"Provenance\")"))
        #expect(menu.contains("startFindMaster("))
    }
}
