import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// Family Tree default focus + "remember where we left off"
// (feature/family-tree-default-focus, 2026-08-28). Rick: "family tree
// always opens to John Allen VII born 1495 … it should start at Rick and
// Donna, but when we go to another window and come back it remembers."
// Dimensions per the feature-test checklist:
//   Logic     — first root wins over the alphabetical first row; remembered
//               focus survives re-install (session + defaults); a missing
//               remembered person falls back to the root with a log line
//   Isolation — injected originals directory + injected UserDefaults suite;
//               the demo tree never writes the key

// MARK: - Fixture: two roots (Rick then Donna), alphabetical-first is Allen.

private let twoRootGedcom = """
0 HEAD
1 SOUR VideoScanTests
1 _VS_ROOT @I1@
1 _VS_ROOT @I9@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 FAMS @F0@
0 @I9@ INDI
1 NAME Donna Marie /Hudson/
1 SEX F
1 _FSFTID G2CL-86B
1 FAMS @F0@
0 @I2@ INDI
1 NAME John /Allen/ VII
1 SEX M
1 _FSFTID KWXX-AL7
1 BIRT
2 DATE 1495
0 @I3@ INDI
1 NAME Edith /Latta/
1 SEX F
0 @F0@ FAM
1 HUSB @I1@
1 WIFE @I9@
0 TRLR
"""

/// Same people, but John Allen is gone (a re-pull that dropped him).
private let withoutAllenGedcom = twoRootGedcom
    .replacingOccurrences(of: "0 @I2@ INDI\n1 NAME John /Allen/ VII\n1 SEX M\n1 _FSFTID KWXX-AL7\n1 BIRT\n2 DATE 1495\n",
                          with: "")

@Suite("Family Tree — default focus and remembered focus")
@MainActor
struct FamilyTreeDefaultFocusTests {

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "FamilyTreeDefaultFocusTests.\(UUID().uuidString)")!
    }

    private func model(_ defaults: UserDefaults) -> FamilyTreeLiveModel {
        FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            focusDefaults: defaults)
    }

    /// Fixture sanity: a FamilySearch ID is 4-3 alphanumerics; a malformed
    /// one is silently dropped by the parser and the pointer gets remembered
    /// instead (that is exactly how the first cut of this file failed).
    @Test func fixtureCarriesTheIDsTheTestsRelyOn() {
        let graph = GedcomFamilyGraph(gedcomText: twoRootGedcom)
        #expect(graph.rootPersonIDs == ["@I1@", "@I9@"])
        #expect(graph.person(familySearchID: "GVQV-NW3")?.id == "@I1@")
        #expect(graph.person(familySearchID: "G2CL-86B")?.id == "@I9@")
        #expect(graph.person(familySearchID: "KWXX-AL7")?.id == "@I2@")
        #expect(graph.people["@I3@"]?.familySearchID == nil)
        #expect(GedcomFamilyGraph(gedcomText: withoutAllenGedcom).people["@I2@"] == nil)
    }

    @Test func freshInstallOpensOnTheFirstRootNotTheAlphabeticalFirst() {
        let sink = InMemoryLogSink()
        let model = model(defaults())
        withAppLog(sink) { model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom)) }
        #expect(model.isLive)
        #expect(model.peopleCount == 4)
        #expect(model.filteredPeople.first?.name.contains("Allen") == true)   // the old silent default
        #expect(model.selectedID == "@I1@")
        // Privacy-safe logging (codex hardening, 8/29): the line carries the
        // REASON, never the person's name; the name is pinned by selectedID.
        #expect(sink.joined.contains("[family-tree] default focus applied reason=first root"))
        #expect(!sink.joined.contains("Richard Harding Breen Jr"))
    }

    @Test func reinstallRemembersTheLastFocusInSessionAndInDefaults() {
        let d = defaults()
        let model = model(d)
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        model.select("@I2@")
        #expect(d.string(forKey: FamilyTreeLiveModel.lastFocusDefaultsKey) == "KWXX-AL7")

        // Same instance, selection dropped (as a miss does), then re-install.
        model.install(graph: nil)                                  // leave the tab → demo
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        #expect(model.selectedID == "@I2@")

        // New instance over the same defaults ≈ app relaunch.
        let relaunched = self.model(d)
        relaunched.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        #expect(relaunched.selectedID == "@I2@")
    }

    @Test func rememberedPersonMissingFallsBackToTheRootWithALogLine() {
        let d = defaults()
        d.set("KWXX-AL7", forKey: FamilyTreeLiveModel.lastFocusDefaultsKey)
        let sink = InMemoryLogSink()
        let model = model(d)
        withAppLog(sink) { model.install(graph: GedcomFamilyGraph(gedcomText: withoutAllenGedcom)) }
        #expect(model.selectedID == "@I1@")
        #expect(sink.joined.contains("[family-tree] default focus applied reason=first root"))
        // The stale key is replaced by the person actually shown.
        #expect(d.string(forKey: FamilyTreeLiveModel.lastFocusDefaultsKey) == "GVQV-NW3")
    }

    @Test func pointerIsRememberedWhenThereIsNoFamilySearchID() {
        let d = defaults()
        let model = model(d)
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        model.select("@I3@")                                       // Edith has no _FSFTID
        #expect(d.string(forKey: FamilyTreeLiveModel.lastFocusDefaultsKey) == "@I3@")
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        #expect(model.selectedID == "@I3@")
    }

    @Test func existingSelectionStillWinsOverTheRememberedKey() {
        let d = defaults()
        d.set("G2CL-86B", forKey: FamilyTreeLiveModel.lastFocusDefaultsKey)
        let model = model(d)
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        #expect(model.selectedID == "@I9@")                        // Donna, remembered
        model.select("@I2@")
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        #expect(model.selectedID == "@I2@")                        // keep wins
    }

    @Test func homeReturnsToTheFirstRoot() {
        let model = model(defaults())
        model.install(graph: GedcomFamilyGraph(gedcomText: twoRootGedcom))
        model.select("@I2@")
        model.focusHome()
        #expect(model.selectedID == "@I1@")
    }

    @Test func demoTreeNeverWritesTheKey() {
        let d = defaults()
        let model = model(d)
        model.install(graph: nil)
        #expect(!model.isLive)
        #expect(model.selectedID == FamilyTreeDemoData.rootID)
        model.select(FamilyTreeDemoData.people.last!.id)
        #expect(d.string(forKey: FamilyTreeLiveModel.lastFocusDefaultsKey) == nil)
        #expect(model.rememberedFocusKey == nil)
    }
}
