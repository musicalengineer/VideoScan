import Testing
import Foundation
@testable import VideoScan

// MARK: - People-tag mutation tests (Rick 2026-08-01: "People →" menu)
//
// Mirrors WorkflowTagsAndUserNotesTests' model-level pattern: the
// setPerson path must apply toggle semantics across mixed selections,
// keep the search index in lock-step (a click is people:-searchable
// NOW), and honor the confirm-clears-rejection rule shared with the
// Inspector. Also pins the Inspector's notification path — the index
// staleness gap found during the archivist perf pass.

@MainActor
@Suite("People tag mutations")
struct PeopleTagsTests {

    private func makeRecord(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    @Test func setPersonAppliesToMixedSelectionAndUpdatesIndex() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        let b = makeRecord("/Volumes/T/b.mov")
        b.confirmedByUserPeople = [ConfirmedTag(name: "Dan", confirmedAt: Date())]  // mixed
        model.records = [a, b]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Dan", on: [a, b], present: true)
        #expect(a.confirmedByUserPeople.map(\.name) == ["Dan"])
        #expect(b.confirmedByUserPeople.count == 1)          // no duplicate
        #expect(model.searchIndex.filter(records: model.records, query: "people:dan").count == 2)

        model.setPerson("Dan", on: [a, b], present: false)
        #expect(a.confirmedByUserPeople.isEmpty && b.confirmedByUserPeople.isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "people:dan").isEmpty)
    }

    /// Menu "Dan" must toggle a free-text "dan" (case-insensitive
    /// identity), never double-tag beside it.
    @Test func setPersonMatchesCaseInsensitively() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        a.confirmedByUserPeople = [ConfirmedTag(name: "dan", confirmedAt: Date())]
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Dan", on: [a], present: true)       // already there
        #expect(a.confirmedByUserPeople.count == 1)

        model.setPerson("DAN", on: [a], present: false)
        #expect(a.confirmedByUserPeople.isEmpty)
    }

    /// Confirming clears a matching rejection — the user changed their
    /// mind; same rule as the Inspector's confirmTag.
    @Test func confirmingClearsRejection() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        a.rejectedPeople = ["Donna"]
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Donna", on: [a], present: true)
        #expect(a.rejectedPeople.isEmpty)
        #expect(a.confirmedByUserPeople.map(\.name) == ["Donna"])
    }

    /// The Beth case (Rick 2026-08-01): unset must mean "NOT in this
    /// video" — an old engine detection must not keep the name visible
    /// (and searchable) after the user un-tags it. Auto-sourced names
    /// land in rejectedPeople so a rescan can't resurrect them.
    @Test func unsetScrubsAutoDetectionsAndRecordsRejection() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        a.detectedPeople = ["Beth"]                 // old auto-tagger mistake
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Beth", on: [a], present: true)     // Rick's first try
        model.setPerson("Beth", on: [a], present: false)    // then unset
        #expect(a.taggedPeople.isEmpty, "Beth still visible after unset")
        #expect(a.detectedPeople.isEmpty)
        #expect(a.rejectedPeople == ["Beth"])
        #expect(model.searchIndex.filter(records: model.records, query: "people:beth").isEmpty)

        // Re-confirming clears the rejection (change of mind, again).
        model.setPerson("Beth", on: [a], present: true)
        #expect(a.rejectedPeople.isEmpty)
        #expect(a.taggedPeople == ["Beth"])
    }

    /// Unset of a purely-manual tag (never auto-detected) must NOT
    /// record a rejection — undoing a misclick is not ground truth.
    @Test func unsetOfManualOnlyTagDoesNotReject() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Dan", on: [a], present: true)
        model.setPerson("Dan", on: [a], present: false)
        #expect(a.confirmedByUserPeople.isEmpty)
        #expect(a.rejectedPeople.isEmpty)
    }

    /// "Clear People Tags" — the mistake-cleanup verb: wipes all four
    /// lists and the index reflects it immediately.
    @Test func removeAllPeopleClearsEveryListAndIndex() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        a.detectedPeople = ["Beth"]
        a.suspectedPeople = ["Donna"]
        a.confirmedByUserPeople = [ConfirmedTag(name: "Dan", confirmedAt: Date())]
        a.rejectedPeople = ["Mark"]
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.removeAllPeople(from: [a])
        #expect(a.detectedPeople.isEmpty && a.suspectedPeople.isEmpty)
        #expect(a.confirmedByUserPeople.isEmpty && a.rejectedPeople.isEmpty)
        for q in ["people:beth", "people:donna", "people:dan"] {
            #expect(model.searchIndex.filter(records: model.records, query: q).isEmpty,
                    "'\(q)' still matches after Clear People Tags")
        }
    }

    /// Family toggle: tagging "Family" via the menu makes the record a
    /// hit for ANY person search; untoggling withdraws it.
    @Test func familyTagSurfacesForEveryPersonSearch() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/christmas.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("Family", on: [a], present: true)
        #expect(model.searchIndex.filter(records: model.records, query: "people:donna").count == 1)
        #expect(model.searchIndex.filter(records: model.records, query: "people:anyone").count == 1)

        model.setPerson("Family", on: [a], present: false)
        #expect(model.searchIndex.filter(records: model.records, query: "people:donna").isEmpty)
    }

    /// Negative: whitespace-only names and no-op toggles never dirty
    /// the catalog (no changed records → no save scheduled).
    @Test func noOpTogglesAndBlankNamesChangeNothing() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setPerson("   ", on: [a], present: true)
        model.setPerson("Ghost", on: [a], present: false)    // absent → no-op
        #expect(a.confirmedByUserPeople.isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "people:ghost").isEmpty)
    }

    /// The Inspector's notification path: posting videoScanCatalogMutated
    /// WITH the record refreshes that record's index entry — an
    /// Inspector confirm is people:-searchable without waiting for a
    /// rebuild (the staleness gap this pass closed).
    @Test func mutationNotificationWithRecordRefreshesIndex() async throws {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)
        #expect(model.searchIndex.filter(records: model.records, query: "people:timmy").isEmpty)

        a.confirmedByUserPeople = [ConfirmedTag(name: "Timmy", confirmedAt: Date())]
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: a)
        // The listener hops through the main queue; yield until it runs.
        for _ in 0..<50 where model.searchIndex.filter(
            records: model.records, query: "people:timmy").isEmpty {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(model.searchIndex.filter(records: model.records, query: "people:timmy").count == 1)
    }
}
