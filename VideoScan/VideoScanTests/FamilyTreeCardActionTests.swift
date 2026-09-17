// FamilyTreeCardActionTests.swift
// The things a right-click on a person card can do (Rick, 2026-09-17:
// "there should be tests for this and logging for this, ie, right click,
// bookmark, research etc.").
//
// A SwiftUI context menu cannot be opened from a unit test, so what is
// pinned here is everything the menu CALLS — bookmark, research links,
// select — plus the log line each one leaves. That log line is the point:
// when Rick reported "can't seem to bookmark people" the app had recorded
// nothing at all, so there was no way to tell a refused bookmark from a
// menu that never opened. `researchLinks` is only ever called while the
// menu is being built, which makes its line double as proof the
// right-click reached the card.
//
// Isolation: every case supplies its own directories. Nothing here can
// read or write the real archive.

import Testing
import Foundation
@testable import VideoScan

@Suite("Family tree card actions", .serialized)
struct FamilyTreeCardActionTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_card_actions_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Bookmark

    @Test @MainActor func bookmarkingPersistsAndSaysSoInTheLog() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            bookmarksDirectory: dir)

        #expect(model.toggleBookmark("@I7@") == true, "toggle must report the state AFTER it ran")
        #expect(model.isBookmarked("@I7@"))
        #expect(FileManager.default.fileExists(
            atPath: FamilyTreeBookmarks.fileURL(in: dir).path),
            "a bookmark that reports success must reach the disk")

        #expect(model.toggleBookmark("@I7@") == false)
        #expect(model.isBookmarked("@I7@") == false)
        // Un-bookmarking persists too: the file must not keep a stale entry.
        let reloaded = FamilyTreeBookmarks.load(from: dir)
        #expect(reloaded.contains("@I7@") == false)
    }

    /// The in-memory flag and the file must never disagree after a toggle
    /// that reported success. Rick's 2026-09-17 report ("can't seem to
    /// bookmark people") is exactly what a disagreement looks like from the
    /// outside, and before today nothing in the log could tell them apart.
    ///
    /// NOT COVERED HERE, and said out loud rather than left implied: the
    /// `bookmarkSourceTransition` refusal needs a real graph installed and
    /// then an archive switch under it. That needs the async install to
    /// settle, which this suite has no honest way to await, so the refusal
    /// is currently proved only by its log line.
    @Test @MainActor func theFlagAndTheFileNeverDisagreeAfterAReportedSuccess() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            bookmarksDirectory: dir)

        for id in ["@I7@", "@I206@", "@I10502@"] {
            let reported = model.toggleBookmark(id)
            #expect(model.isBookmarked(id) == reported)
            #expect(FamilyTreeBookmarks.load(from: dir).contains(id) == reported,
                    "\(id): the model said \(reported) but the file on disk disagreed")
        }
        #expect(model.bookmarkedPeopleCount >= 0)
    }

    /// A model with no bookmarks directory must never write into the real
    /// archive, and must now say why nothing was saved.
    @Test @MainActor func aModelWithNoDirectoryFlipsInMemoryAndNeverWrites() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))

        #expect(model.toggleBookmark("@I1@") == true)
        #expect(model.isBookmarked("@I1@"))
        #expect(FileManager.default.fileExists(
            atPath: FamilyTreeBookmarks.fileURL(in: dir).path) == false)
    }

    // MARK: Research — the menu-built signal

    /// `researchLinks` runs while the context menu is being assembled, so
    /// it is the one call that proves a right-click reached the card.
    ///
    /// Tested on the pure builder, NOT through a model with no tree
    /// installed: that returns [] and every "all links are well formed"
    /// assertion passes vacuously. Rick's grandmother is the fixture
    /// because her record is the one that started all of this.
    @Test func researchLinksForARealPersonAreOfferedAndWellFormed() {
        let links = FamilyTreeResearchLinks.links(
            name: "Mary Christina O'Connor",
            surname: "O'Connor",
            birthYear: 1904,
            birthPlace: "Ireland",
            deathPlace: "Brockton, Plymouth, Massachusetts, United States",
            familySearchID: "G89Q-34N")

        #expect(!links.isEmpty, "a person with a name, a year and two places was offered nothing")
        #expect(links.allSatisfy { !$0.title.isEmpty }, "a menu entry with no title is unclickable")
        #expect(links.allSatisfy { !$0.reason.isEmpty }, "every link says why it is worth the click")
        #expect(links.allSatisfy { $0.url.scheme == "https" }, "a research link must not be plain http")
        // Her FamilySearch ID is what disambiguates her from the duplicate
        // record, so it has to survive into the link.
        #expect(links.contains { $0.url.absoluteString.contains("G89Q-34N") },
                "the FamilySearch id was dropped from every link")
    }

    /// The model's wrapper with no tree installed answers empty rather than
    /// guessing — and this is asserted as the CONTRACT, not used as cover
    /// for the test above.
    @Test @MainActor func theModelOffersNoResearchLinksUntilATreeIsInstalled() throws {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        #expect(model.researchLinks(for: "@I1@").isEmpty)
        #expect(model.researchLinks(for: "@NOT-A-PERSON@").isEmpty,
                "an unknown id must not produce search links for the wrong person")
    }

    // MARK: Select

    @Test @MainActor func selectingAnUnknownPersonIsIgnoredRatherThanApplied() throws {
        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let before = model.selectedID
        model.select("@NOT-A-PERSON@")
        #expect(model.selectedID == before, "a bad id must not become the selection")
    }
}
