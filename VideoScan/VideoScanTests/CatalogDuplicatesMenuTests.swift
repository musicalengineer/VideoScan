// CatalogDuplicatesMenuTests.swift
// Regression tests for "Delete Duplicates on Volume… flashes and won't let
// me pick a volume" (Rick 2026-09-22, Release b334247b).
//
// Root cause (measured in the test host 2026-09-22): an open NESTED SwiftUI
// submenu on macOS closes whenever anything in the same window updates —
// even a sibling view the menu does not depend on. `.equatable()` isolation
// did not help. The Catalog window updates constantly while work runs, so
// the submenu was unusable. Fix: the menu item opens a volume-picker sheet.
//
// These tests are deliberately NON-INTERACTIVE: no windows ordered front,
// no app activation, no synthesized key or mouse events (the WIP's live
// NSMenu sensor did all three and grabbed Rick's machine; it is parked in
// .trash/). A real click-through is Rick's manual check.
//
// Suites (filter by SUITE name — -only-testing at method granularity runs
// zero Swift Testing tests):
//   CatalogDuplicatesMenuLogicTests      — titles, when Delete is offered
//   CatalogDuplicatesMenuStructureTests  — sensor: no nested Menu comes back;
//                                          the picker → onDismiss → alert
//                                          wiring stays in place
//   CatalogDuplicatesMenuIsolationTests  — neither the menu nor CatalogView
//                                          subscribes to the model / center
//
// Swift Testing for a C++ reader: `@Suite struct` ≈ a GTest fixture class,
// `@Test func` ≈ TEST_F, `#expect` ≈ EXPECT_TRUE (records and continues),
// `#require` ≈ ASSERT_TRUE (stops the test).

import Testing
import Foundation
import SwiftUI
@testable import VideoScan

// MARK: - Logic

@Suite("CatalogDuplicatesMenu — titles and offer rule")
@MainActor
struct CatalogDuplicatesMenuLogicTests {

    @Test func volumeTitlesNameTheDriveAndPluralise() {
        #expect(CatalogDuplicatesMenu.title(for: .init(path: "/Volumes/SanDisk", count: 12)) == "SanDisk — 12 files")
        #expect(CatalogDuplicatesMenu.title(for: .init(path: "/Volumes/SanDisk", count: 1)) == "SanDisk — 1 file")
        #expect(CatalogDuplicatesMenu.title(for: .init(path: "/Volumes/My Book 4TB", count: 0)) == "My Book 4TB — 0 files")
    }

    /// Positive and negative: offered only when writable AND there is at
    /// least one volume to choose.
    @Test func deleteIsOfferedOnlyWhenWritableWithVolumes() {
        let one: [CatalogDuplicatesMenu.Volume] = [.init(path: "/Volumes/SanDisk", count: 3)]
        #expect(CatalogDuplicatesMenu.offersDelete(isReadOnly: false, volumes: one))
        #expect(!CatalogDuplicatesMenu.offersDelete(isReadOnly: true, volumes: one))
        #expect(!CatalogDuplicatesMenu.offersDelete(isReadOnly: false, volumes: []))
        #expect(!CatalogDuplicatesMenu.offersDelete(isReadOnly: true, volumes: []))
    }

    /// Picker rows are keyed by path: two volumes with the same drive name
    /// under different mount points stay distinct rows.
    @Test func volumeIdentityIsThePath() {
        let a = CatalogDuplicatesMenu.Volume(path: "/Volumes/X9", count: 1)
        let b = CatalogDuplicatesMenu.Volume(path: "/Volumes/Other/X9", count: 1)
        #expect(a.id != b.id)
        #expect(a.id == "/Volumes/X9")
    }

    /// The picker hands back exactly the row the user clicked — path AND
    /// count — through `onPick`, and Cancel never picks.
    @Test func pickerHandsBackTheChosenVolume() {
        let vols: [CatalogDuplicatesMenu.Volume] = [.init(path: "/Volumes/SanDisk", count: 12),
                                                    .init(path: "/Volumes/X9", count: 3)]
        var picked: [CatalogDuplicatesMenu.Volume] = []
        var cancels = 0
        let picker = DeleteDuplicatesVolumePicker(volumes: vols,
                                                  onPick: { picked.append($0) },
                                                  onCancel: { cancels += 1 })
        picker.onPick(vols[1])
        picker.onCancel()
        #expect(picked == [vols[1]])
        #expect(cancels == 1)
    }
}

// MARK: - Structure sensor (source-level)

@Suite("CatalogDuplicatesMenu — no nested submenu (sensor)")
struct CatalogDuplicatesMenuStructureTests {

    private func appSource(_ file: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
        return try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
    }

    /// Code only — comment lines stripped, so the header's explanation of
    /// the old submenu doesn't trip the check.
    private func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// THE sensor. Exactly one `Menu` in the Duplicates menu (the top
    /// level); a nested submenu here is what closed on every update.
    @Test func duplicatesMenuHasNoNestedSubmenu() throws {
        let src = code(try appSource("CatalogDuplicatesMenu.swift"))
        let menus = src.components(separatedBy: "Menu {").count - 1
            + src.components(separatedBy: "Menu(").count - 1
        #expect(menus == 1, "CatalogDuplicatesMenu has \(menus) Menu constructors — a nested submenu is back")
        #expect(src.contains("Button(Self.deleteOnVolumeTitle, action: onChooseVolumeToDelete)"))
    }

    /// The toolbar no longer builds its own delete-per-volume items.
    @Test func toolbarDoesNotBuildVolumeItems() throws {
        let src = code(try appSource("CatalogToolbar.swift"))
        #expect(!src.contains("Menu(\"Delete Duplicates on Volume"))
        #expect(!src.contains("onDeleteDuplicates"))
        #expect(src.contains("onChooseVolumeToDelete: onChooseVolumeToDeleteDuplicates"))
    }

    /// The picker's choice becomes the confirmation only from onDismiss —
    /// never an alert raised while the sheet is still up.
    @Test func confirmationIsRaisedFromThePickerOnDismiss() throws {
        let src = code(try appSource("ContentView.swift"))
        #expect(src.contains(".sheet(item: $deleteDuplicatesVolumePicker, onDismiss: {"))
        #expect(src.contains("prepareDeleteDuplicatesConfirmation(path: vol.path, count: vol.count)"))
        // The only place that raises the alert is the helper.
        #expect(src.components(separatedBy: "showDeleteDuplicatesConfirm = true").count - 1 == 1)
    }
}

// MARK: - Isolation

@Suite("CatalogDuplicatesMenu — observation isolation")
@MainActor
struct CatalogDuplicatesMenuIsolationTests {

    /// Type names of every stored property, via reflection. `Mirror` ≈ a
    /// runtime field walk; property wrappers show up as their wrapper type
    /// (e.g. `EnvironmentObject<VideoScanModel>` for `_model`).
    private func storedPropertyTypes(of value: Any) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            out[child.label ?? "?"] = String(describing: type(of: child.value))
        }
        return out
    }

    /// The menu is value-only: no wrapper that subscribes to anything.
    @Test func menuObservesNothing() {
        let m = CatalogDuplicatesMenu(isReadOnly: false, isAnalyzing: false, isDeleting: false,
                                      isDisabled: false, hasSelection: false, volumes: [],
                                      alsoCleanUpWorkingCopies: false, reanalyzeHint: nil,
                                      onFindDuplicates: {}, onFindDuplicatesOfSelected: {},
                                      onChooseVolumeToDelete: {}, onSetAlsoCleanUpWorkingCopies: { _ in })
        let observing = storedPropertyTypes(of: m).filter { _, type in
            type.contains("EnvironmentObject") || type.contains("ObservedObject") || type.contains("StateObject")
        }
        #expect(observing.isEmpty, "CatalogDuplicatesMenu must not observe any object — found \(observing)")
    }

    /// CatalogView must not SUBSCRIBE to the Media File Operations center
    /// (it re-ran its whole body at 4 Hz while any job ran). It holds a
    /// non-observing reference.
    @Test func catalogViewDoesNotSubscribeToTheCenter() {
        let types = storedPropertyTypes(of: CatalogView())
        let subscribing = types.filter { _, type in
            type.contains("MediaFileOperationsCenter")
                && (type.contains("EnvironmentObject") || type.contains("ObservedObject") || type.contains("StateObject"))
        }
        #expect(subscribing.isEmpty, "CatalogView subscribes to MediaFileOperationsCenter again: \(subscribing)")
        // Positive counterweight: the non-observing reference is there, so
        // the Delete Duplicates buttons can still start jobs.
        #expect(types.values.contains { $0.contains("Environment<Optional<MediaFileOperationsCenter>>") },
                "CatalogView lost its non-observing center reference: \(types.filter { $0.value.contains("Environment<") })")
    }

    /// The main window injects the non-observing reference next to the
    /// observed one — without it every Delete Duplicates start is refused.
    @Test func appInjectsTheReference() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan")
        let app = try String(contentsOf: dir.appendingPathComponent("VideoScanApp.swift"), encoding: .utf8)
        #expect(app.contains(".environment(\\.mediaFileOperationsCenterReference, fileOpsCenter)"))
    }
}
