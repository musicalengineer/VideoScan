// CuratedEditGuardTests.swift
// Codex #388 P1 (GH #343): a read-only session refuses the curated edit
// itself, not only its save — CuratedEditGuard in front of every curated
// mutator (CuratedRecordEdits.swift).
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      every mutator class applies in a writable session (the guard
//              does not over-refuse) and changes nothing in a viewer session.
//   ISOLATION  poisoned state = the read-only facts: a viewer role; and (in
//              CatalogRestoreCodex384Tests) a restore parked mid-way.
//   LOGGING    one "Edit refused" line per read-only episode, with the reason
//              in words — not one per click.
//   SENSOR     source: the views that used to write curated fields straight
//              into a record no longer do (a new direct writer fails here).
//   SCALE      N/A — O(selection) per click, unchanged. MEDIA N/A.
//   TRUTH      the record after a refused edit reads exactly as before.
//
// Suites (filter by SUITE): CuratedEditGuardTests · CuratedEditGuardSensorTests

import Foundation
import Testing
@testable import VideoScan
@testable import VideoScanCore

/// One class of curated edit, as a person reaches it (menu, Inspector, Triage).
enum CuratedEditClass: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case notes, tags, peopleMenu, rating, disposition, date, place, peopleChips, workbench
    var testDescription: String { rawValue }
}

/// The fields a curated edit may touch, compared whole.
struct CuratedSnapshot: Equatable {
    let tags: [String]
    let userNotes: String
    let stars: Int
    let disposition: MediaDisposition
    let stage: LifecycleStage
    let userDate: String?
    let userDateConfidence: String?
    let userPlace: String?
    let userPlaceConfidence: String?
    let confirmed: [String]
    let rejected: [String]
    let detected: [String]
    let suspected: [String]

    init(_ r: VideoRecord) {
        tags = r.tags; userNotes = r.userNotes; stars = r.starRating
        disposition = r.mediaDisposition; stage = r.lifecycleStage
        userDate = r.userDate; userDateConfidence = r.userDateConfidence
        userPlace = r.userPlace; userPlaceConfidence = r.userPlaceConfidence
        confirmed = r.confirmedByUserPeople.map(\.name); rejected = r.rejectedPeople
        detected = r.detectedPeople; suspected = r.suspectedPeople
    }
}

@MainActor
enum CuratedEditBattery {

    /// The console after its batched flush (DashboardState flushes 0.15 s
    /// after the first pending line, on the main actor).
    static func settledConsole(_ model: VideoScanModel) async -> [String] {
        try? await Task.sleep(for: .milliseconds(400))
        return model.dashboard.consoleLines
    }

    /// State every class can act on (a tag to clear, a person to unconfirm…).
    static func preseed(_ r: VideoRecord) {
        r.tags = ["Investigate"]
        r.userDate = "1980"; r.userDateConfidence = UserDateConfidence.estimated.rawValue
        r.userPlace = "Franklin, MA"; r.userPlaceConfidence = UserPlaceConfidence.estimated.rawValue
        r.confirmedByUserPeople = [ConfirmedTag(name: "Carol", confirmedAt: Date(timeIntervalSince1970: 0))]
        r.rejectedPeople = ["Zed"]
        r.detectedPeople = ["Bonnie"]
        r.suspectedPeople = ["Hal"]
        r.lifecycleStage = .workbench
    }

    /// Every production mutator of `kind`, run on `r`.
    static func run(_ kind: CuratedEditClass, model: VideoScanModel, on r: VideoRecord) {
        let edits = CuratedRecordEdits(model: model)
        switch kind {
        case .notes:
            model.setUserNotes("typed mid-restore", for: r)
        case .tags:
            model.setTag("Gold", on: [r], present: true)
            model.addTag("Fix Color", to: [r])
            model.removeTag("Investigate", from: r)
            model.removeAllTags(from: [r])
        case .peopleMenu:
            model.setPerson("Dan", on: [r], present: true)
            model.setPerson("Carol", on: [r], present: false)
            model.clearMachinePeopleTags(from: [r])
            model.clearRejections(from: [r])
            model.removeAllPeople(from: [r])
        case .rating:
            edits.setStarRating(3, on: r)
        case .disposition:
            edits.setDisposition(.important, on: [r])
            edits.triageDisposition(.confirmedJunk, on: [r])
        case .date:
            edits.setUserDate("1992", known: true, on: r)
            edits.setUserDate(nil, known: false, on: r)
        case .place:
            edits.setUserPlace("Cape Cod", known: true, on: r)
            edits.setUserPlace(nil, known: false, on: r)
        case .peopleChips:
            let carol = r.confirmedByUserPeople.first?.id ?? ""
            edits.confirmPerson("Ann", on: r)
            edits.rejectDetected("Bonnie", on: r)
            edits.unconfirm(tagID: carol, on: r)
            edits.unreject("Zed", on: r)
        case .workbench:
            model.dropWorkbenchToCatalog([r])
        }
    }
}

@MainActor
@Suite("Curated edits — refused in a read-only session, taken in a writable one", .serialized)
struct CuratedEditGuardTests {

    private func scene() -> (VideoScanModel, VideoRecord) {
        let model = VideoScanModel()
        let r = VideoRecord()
        r.fullPath = "/Volumes/T/reel.mov"
        r.filename = "reel.mov"
        r.directory = "/Volumes/T"
        CuratedEditBattery.preseed(r)
        model.records = [r]
        model.searchIndex.rebuild(records: model.records)
        return (model, r)
    }

    @Test("LOGIC: in a writable session every curated mutator changes the record", arguments: CuratedEditClass.allCases)
    func writableSessionTakesTheEdit(_ kind: CuratedEditClass) {
        let (model, r) = scene()
        let before = CuratedSnapshot(r)
        CuratedEditBattery.run(kind, model: model, on: r)
        #expect(CuratedSnapshot(r) != before, "\(kind) must apply when the session is writable")
    }

    @Test("ISOLATION: in a viewer session every curated mutator is refused — the record reads exactly as before", arguments: CuratedEditClass.allCases)
    func viewerSessionRefusesTheEdit(_ kind: CuratedEditClass) {
        let (model, r) = scene()
        model.updateReadOnlyFacts { $0.viewerRole = true }
        let before = CuratedSnapshot(r)
        CuratedEditBattery.run(kind, model: model, on: r)
        #expect(CuratedSnapshot(r) == before, "\(kind) changed a record in a viewer session")
    }

    @Test("LOGGING: one 'Edit refused' line per read-only episode, with the reason — not one per click; a new episode logs again")
    func refusalLoggedOncePerEpisode() async throws {
        let (model, r) = scene()
        model.updateReadOnlyFacts { $0.viewerRole = true }
        for kind in CuratedEditClass.allCases { CuratedEditBattery.run(kind, model: model, on: r) }
        let refused = await CuratedEditBattery.settledConsole(model).filter { $0.contains("Edit refused") }
        #expect(refused.count == 1, Comment(rawValue: refused.joined(separator: " | ")))
        #expect(refused.first?.contains("this Mac is a viewer") == true, Comment(rawValue: refused.first ?? "none"))
        // Writable again, an edit taken, then read-only again: a new line.
        model.updateReadOnlyFacts { $0.viewerRole = false }
        model.setUserNotes("between episodes", for: r)
        model.updateReadOnlyFacts { $0.restoringFromBackup = true }
        model.setUserNotes("typed mid-restore", for: r)
        let again = await CuratedEditBattery.settledConsole(model).filter { $0.contains("Edit refused") }
        #expect(again.count == 2 && again.last?.contains("restoring the catalog") == true,
                Comment(rawValue: again.joined(separator: " | ")))
        #expect(r.userNotes == "between episodes")
    }
}

@Suite("Curated edits — source sensors")
struct CuratedEditGuardSensorTests {

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("VideoScan").appendingPathComponent(relative), encoding: .utf8)
    }

    /// Code lines only (a `//` line is a comment).
    private static func code(_ text: String) -> String {
        text.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test("the views that used to write curated fields straight into a record go through CuratedRecordEdits (the guard)")
    func viewsWriteNoCuratedFieldDirectly() throws {
        let views = ["Catalog/InspectorDateView.swift", "Catalog/InspectorPlaceView.swift",
                     "Catalog/InspectorFamilyTagsView.swift", "Catalog/CatalogRowContextMenu+Organize.swift",
                     "Catalog/TriageView.swift", "Catalog/InspectorPanel+Sections.swift"]
        let pattern = try Regex(#"\.(userDate|userDateConfidence|userPlace|userPlaceConfidence|mediaDisposition|starRating|userNotes|tags|confirmedByUserPeople|rejectedPeople|detectedPeople|suspectedPeople)\s*(=[^=]|\.append|\.remove)"#)
        for view in views {
            let text = Self.code(try Self.source(view))
            let hits = text.split(separator: "\n").filter { $0.contains(pattern) }
            #expect(hits.isEmpty, Comment(rawValue: "\(view) writes a curated field directly: \(hits.joined(separator: " | "))"))
        }
    }

    @Test("every model-side curated mutator asks CuratedEditGuard first")
    func modelMutatorsAskTheGuard() throws {
        let expected: [(file: String, functions: [String])] = [
            ("Catalog/VideoScanModel+WorkflowTags.swift", ["func setTag(", "func removeAllTags(", "func setUserNotes("]),
            ("People/VideoScanModel+PeopleTags.swift", ["func setPerson(", "func clearMachinePeopleTags(", "func clearRejections(", "func removeAllPeople("]),
            ("Catalog/VideoScanModel+Workbench.swift", ["func dropWorkbenchToCatalog("]),
            ("People/ConfirmPersonSheet+Candidates.swift", ["func catalogWriteback("]),
        ]
        for (file, functions) in expected {
            let text = try Self.source(file)
            for function in functions {
                guard let start = text.range(of: function) else { Issue.record("\(file): \(function) not found"); continue }
                let body = text[start.upperBound...].prefix(700)
                #expect(body.contains("CuratedEditGuard.refuses("), Comment(rawValue: "\(file): \(function) does not ask CuratedEditGuard first"))
            }
        }
    }
}
