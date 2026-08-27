import Foundation
import Testing
@testable import VideoScan

// Archive tab entry/hand-off state machine (ArchiveHomeState.swift).
// Regression for Rick 2026-08-26: "the default in the archive view should
// be the archive, not the list of files". Dimensions: Logic (rules 1–4),
// Isolation (a poisoned archive.viewMode in an injected defaults suite
// must not change what entry shows). Pure model — no media, no scale.

@Suite("Archive tab — home state machine")
struct ArchiveHomeStateTests {

    // A tiny catalog: two archived ids, two not-yet-archived (one undated).
    let archivedA = UUID(), archivedB = UUID()
    let pendingP = UUID(), undatedU = UUID()

    private func isArchived(_ id: UUID) -> Bool { id == archivedA || id == archivedB }
    private func category(_ id: UUID) -> ArchiveCategory {
        if isArchived(id) { return .archived }
        return id == undatedU ? .needsDate : .notYetArchived
    }
    private func focusSet(_ id: UUID) -> Set<UUID> { [id] }

    private func resolve(_ entry: ArchiveTabEntry) -> ArchiveTabState {
        ArchiveHomeState.resolveEntry(entry, isArchived: isArchived,
                                      category: category, focusSet: focusSet)
    }

    // Rule 1
    @Test func entryWithNothingPendingIsArchivedTimeline() {
        let s = resolve(ArchiveTabEntry())
        #expect(s == .home)
        #expect(s.isHome)
        #expect(s.category == .archived)
        #expect(s.viewMode == .timeline)
        #expect(s.detour == nil)
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func entryIsHomeEvenWhenTheArchiveIsEmpty() {
        // The old picker chose Not Yet Archived for an empty archive;
        // the timeline has its own "story starts with the first promote"
        // empty state, so home stays home.
        let s = ArchiveHomeState.resolveEntry(ArchiveTabEntry(),
                                              isArchived: { _ in false },
                                              category: { _ in .notYetArchived },
                                              focusSet: { [$0] })
        #expect(s.isHome)
    }

    // Rule 2
    @Test func pendingArchivedIdStaysOnTimelineWithSelection() {
        let s = resolve(ArchiveTabEntry(pendingSelection: archivedA, pendingSearch: "cape"))
        #expect(s.category == .archived)
        #expect(s.viewMode == .timeline)
        #expect(s.selectedIDs == [archivedA])
        #expect(s.scrollTarget == archivedA)
        #expect(s.searchText == "cape")
        #expect(s.detour == nil)
    }

    @Test func pendingArchivedIdIgnoresPersistedFilesMode() {
        let s = resolve(ArchiveTabEntry(pendingSelection: archivedB,
                                        persistedViewMode: "files"))
        #expect(s.viewMode == .timeline)
    }

    // Rule 3
    @Test func pendingNotArchivedIdDetoursToItsListWithBanner() {
        let s = resolve(ArchiveTabEntry(pendingSelection: pendingP))
        #expect(s.category == .notYetArchived)
        #expect(s.viewMode == .files)
        #expect(s.detour == .notYetArchived)
        #expect(s.selectedIDs == [pendingP])
        #expect(s.scrollTarget == nil)
        #expect(!s.isHome)
    }

    @Test func pendingUndatedIdDetoursToNeedsDate() {
        let s = resolve(ArchiveTabEntry(pendingSelection: undatedU))
        #expect(s.category == .needsDate)
        #expect(s.detour == .needsDate)
    }

    @Test func pendingSelectionBeatsLingeringFocus() {
        let s = resolve(ArchiveTabEntry(pendingSelection: archivedA,
                                        focusedIDs: [pendingP]))
        #expect(s.isHome)
        #expect(s.selectedIDs == [archivedA])
    }

    // Focus restore (the writer that used to strand the tab in a list)
    @Test func focusedArchivedIdsRestoreOnTheTimeline() {
        let s = resolve(ArchiveTabEntry(focusedIDs: [archivedA, archivedB]))
        #expect(s.category == .archived)
        #expect(s.viewMode == .timeline)
        #expect(s.selectedIDs == [archivedA, archivedB])
        #expect(s.scrollTarget != nil && isArchived(s.scrollTarget!))
        #expect(s.searchText == "")
    }

    @Test func focusedNotArchivedIdsDetourWithBanner() {
        let s = resolve(ArchiveTabEntry(focusedIDs: [pendingP]))
        #expect(s.category == .notYetArchived)
        #expect(s.detour == .notYetArchived)
        #expect(s.selectedIDs == [pendingP])
    }

    @Test func mixedFocusPrefersTheArchivedMember() {
        // An A/V pair where one half is archived: show the archive.
        let s = resolve(ArchiveTabEntry(focusedIDs: [pendingP, archivedA]))
        #expect(s.category == .archived)
        #expect(s.scrollTarget == archivedA)
    }

    // Rule 4
    @Test func backToArchiveAfterADetourIsHome() {
        let detour = resolve(ArchiveTabEntry(pendingSelection: pendingP))
        #expect(detour.detour != nil)
        let back = ArchiveHomeState.backToArchive()
        #expect(back == .home)
        #expect(back.detour == nil)
        #expect(back.selectedIDs.isEmpty)
    }

    // Sidebar clicks
    @Test func sidebarPickClearsDetourAndSelection() {
        let s = ArchiveHomeState.sidebarPick(.notYetArchived, viewMode: .timeline)
        #expect(s.category == .notYetArchived)
        #expect(s.detour == nil)          // the user chose it — no banner
        #expect(s.viewMode == .files)     // lists are table-only
        #expect(s.selectedIDs.isEmpty)
    }

    @Test func sidebarPickArchivedHonorsInSessionFilesChoice() {
        let s = ArchiveHomeState.sidebarPick(.archived, viewMode: .files)
        #expect(s.category == .archived)
        #expect(s.viewMode == .files)
        #expect(s.detour == nil)
    }

    // Persisted-key contract
    @Test func viewModeRawValuesMatchThePersistedStrings() {
        #expect(ArchiveViewMode.timeline.rawValue == "timeline")
        #expect(ArchiveViewMode.files.rawValue == "files")
        #expect(ArchiveViewMode(rawValue: "garbage") == nil)
    }
}

// Isolation: the resolver must be immune to whatever `archive.viewMode`
// says on disk. The view reads the key via @AppStorage; here we feed the
// same value from an injected suite and prove entry still lands on the
// timeline. (The view copies the resolver's viewMode back into the key,
// so a poisoned "files" is overwritten on entry — by design.)
@Suite("Archive tab — home state isolation")
struct ArchiveHomeStateIsolationTests {

    @Test func poisonedViewModeSuiteDoesNotChangeEntry() throws {
        let suiteName = "ArchiveHomeStateIsolationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("files", forKey: "archive.viewMode")

        let id = UUID()
        let entry = ArchiveTabEntry(pendingSelection: id,
                                    persistedViewMode: defaults.string(forKey: "archive.viewMode"))
        let s = ArchiveHomeState.resolveEntry(entry,
                                              isArchived: { _ in true },
                                              category: { _ in .archived },
                                              focusSet: { [$0] })
        #expect(s.viewMode == .timeline)

        let home = ArchiveHomeState.resolveEntry(
            ArchiveTabEntry(persistedViewMode: defaults.string(forKey: "archive.viewMode")),
            isArchived: { _ in true }, category: { _ in .archived }, focusSet: { [$0] })
        #expect(home == .home)
        // And the suite is untouched by the resolver (pure function).
        #expect(defaults.string(forKey: "archive.viewMode") == "files")
    }
}

// MARK: - Entry controller (integration seam, QA + codex #700 2026-08-26)

// Drives the SAME sequence the view does — appear with a pending id and
// search → consume → the model's id→nil transition fires onChange →
// entry again — through ArchiveEntryController, without SwiftUI. Before
// the controller, the second run resolved from the cleared model and
// overwrote the search with "".
@Suite("Archive tab — entry controller seam")
struct ArchiveEntryControllerTests {

    let archivedA = UUID(), archivedB = UUID(), pendingP = UUID()

    private func isArchived(_ id: UUID) -> Bool { id == archivedA || id == archivedB }
    private func category(_ id: UUID) -> ArchiveCategory { isArchived(id) ? .archived : .notYetArchived }
    private func focusSet(_ id: UUID) -> Set<UUID> { [id] }

    private func handle(_ trigger: ArchiveEntryController.Trigger,
                        _ request: inout ArchiveEntryRequest) -> ArchiveEntryController.Outcome? {
        ArchiveEntryController.handle(trigger, request: &request, persistedViewMode: "files",
                                      isArchived: isArchived, category: category, focusSet: focusSet)
    }

    @Test func searchAndScrollTargetSurviveTheConsumptionTransition() throws {
        var request = ArchiveEntryRequest(pendingSelection: archivedA, pendingSearch: "cape",
                                          focusedIDs: [pendingP])
        // 1. Tab appears with a pending hand-off.
        let first = try #require(handle(.appear, &request))
        #expect(first.consumed)
        #expect(first.state.searchText == "cape")
        #expect(first.state.scrollTarget == archivedA)
        #expect(first.state.selectedIDs == [archivedA])
        #expect(first.state.category == .archived && first.state.viewMode == .timeline)
        // The request was consumed: the caller writes these back to the model.
        #expect(request.pendingSelection == nil)
        #expect(request.pendingSearch == nil)
        #expect(request.focusedIDs == [archivedA])

        // 2. Writing nil back fires onChange(nil) — must be a no-op, NOT a
        //    second resolution with search "".
        #expect(handle(.pendingSelectionChanged(nil), &request) == nil)
        #expect(request.pendingSelection == nil && request.focusedIDs == [archivedA])

        // 3. A later re-entry (Catalog and back) is a focus restore: same
        //    item, no search — by design, and not what step 2 does.
        let again = try #require(handle(.appear, &request))
        #expect(!again.consumed)
        #expect(again.state.scrollTarget == archivedA)
        #expect(again.state.searchText.isEmpty)
    }

    @Test func aNewPendingIdWhileTheTabIsUpIsResolvedFromTheSnapshot() throws {
        var request = ArchiveEntryRequest(pendingSelection: archivedB, pendingSearch: "1988",
                                          focusedIDs: [archivedA])
        let outcome = try #require(handle(.pendingSelectionChanged(archivedB), &request))
        #expect(outcome.consumed)
        #expect(outcome.state.scrollTarget == archivedB)
        #expect(outcome.state.searchText == "1988")
        #expect(request.focusedIDs == [archivedB])
    }

    @Test func focusedIDsNeverOverrideTheRequestedId() throws {
        // A stale focus on B must not steal the hand-off to A.
        var request = ArchiveEntryRequest(pendingSelection: archivedA, pendingSearch: nil,
                                          focusedIDs: [archivedB])
        let outcome = try #require(handle(.appear, &request))
        #expect(outcome.state.scrollTarget == archivedA)
        #expect(outcome.state.selectedIDs == [archivedA])
        #expect(request.focusedIDs == [archivedA])
    }

    @Test func nothingPendingIsHomeAndTouchesNothing() throws {
        var request = ArchiveEntryRequest()
        let outcome = try #require(handle(.appear, &request))
        #expect(!outcome.consumed)
        #expect(outcome.state == .home)
        #expect(request == ArchiveEntryRequest())
    }
}
