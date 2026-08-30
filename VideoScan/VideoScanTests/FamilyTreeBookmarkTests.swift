import Testing
import Foundation
@testable import VideoScan

// MARK: - FamilyTreeBookmarkTests
//
// "Some way to tag someone in the family tree as interesting or follow up"
// (Rick, 2026-08-30). One flag, stored beside the GEDCOM on the archive so
// a bookmark Donna makes on the iPad is one Rick sees on the Mac —
// UserDefaults would have been per-machine and defeated the point.
//
// Isolation: every case supplies its own directory. Nothing here can read
// or write the real archive.

struct FamilyTreeBookmarkTests {

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_bookmarks_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func togglingAddsThenRemovesAndReportsTheNewState() {
        var marks = FamilyTreeBookmarks()
        #expect(marks.contains("@I1@") == false)
        #expect(marks.toggle("@I1@") == true, "toggle must report the state AFTER it ran")
        #expect(marks.contains("@I1@"))
        #expect(marks.count == 1)
        #expect(marks.toggle("@I1@") == false)
        #expect(marks.contains("@I1@") == false)
        #expect(marks.count == 0)
    }

    @Test func bookmarksSurviveASaveAndReload() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        var marks = FamilyTreeBookmarks()
        marks.toggle("@I1@")
        marks.toggle("@I50@")
        try marks.save(to: dir)

        let reloaded = FamilyTreeBookmarks.load(from: dir)
        #expect(reloaded.ids == ["@I1@", "@I50@"])
    }

    /// The file is written for two machines editing one archive, so it must
    /// be diffable rather than churning on dictionary order.
    @Test func theFileIsAStableSortedArray() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        var a = FamilyTreeBookmarks()
        for id in ["@I9@", "@I2@", "@I40@", "@I1@"] { a.toggle(id) }
        try a.save(to: dir)
        let first = try String(contentsOf: FamilyTreeBookmarks.fileURL(in: dir), encoding: .utf8)

        var b = FamilyTreeBookmarks()
        for id in ["@I1@", "@I40@", "@I2@", "@I9@"] { b.toggle(id) }   // inserted in a different order
        try b.save(to: dir)
        let second = try String(contentsOf: FamilyTreeBookmarks.fileURL(in: dir), encoding: .utf8)

        // Dates differ, so compare the id ordering rather than the bytes.
        func ids(_ json: String) -> [String] {
            json.split(separator: "\n")
                .filter { $0.contains("personID") }
                .map(String.init)
        }
        #expect(ids(first) == ids(second),
                "insertion order must not change the file's person order")
        #expect(ids(first) == ids(first).sorted(), "ids must be sorted")
    }

    /// Losing the file must not stop the tree opening. A bookmark is a
    /// convenience, not catalog data.
    @Test func aMissingOrCorruptFileMeansNoBookmarksRatherThanAFailure() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(FamilyTreeBookmarks.load(from: dir).count == 0, "missing file")

        try "not json at all {{{".write(to: FamilyTreeBookmarks.fileURL(in: dir),
                                        atomically: true, encoding: .utf8)
        #expect(FamilyTreeBookmarks.load(from: dir).count == 0, "corrupt file")
    }

    @Test func mostRecentFirstOrdersForATakeMeBackList() {
        var marks = FamilyTreeBookmarks()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        marks.toggle("@old@", now: base)
        marks.toggle("@new@", now: base.addingTimeInterval(600))
        marks.toggle("@mid@", now: base.addingTimeInterval(300))
        #expect(marks.mostRecentFirst.map(\.personID) == ["@new@", "@mid@", "@old@"])
    }

    // MARK: Isolation

    /// The rule copied from the CyberBrain root: a model given an originals
    /// directory but no bookmarks directory must get NO bookmarks, never
    /// the real archive's. Without this a test run could read — or worse,
    /// write — Rick's actual bookmark file.
    @Test @MainActor func aModelWithoutABookmarksDirectoryNeverTouchesTheArchive() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        #expect(model.bookmarks.count == 0)
        // Toggling must not throw and must not create a file anywhere.
        #expect(model.toggleBookmark("@I1@") == true)
        #expect(model.isBookmarked("@I1@"))
        #expect(FileManager.default.fileExists(
            atPath: FamilyTreeBookmarks.fileURL(in: dir).path) == false)
    }

    @Test @MainActor func aModelGivenADirectoryPersistsThroughIt() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }

        let model = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            bookmarksDirectory: dir)
        #expect(model.toggleBookmark("@I7@") == true)

        // A second model reading the same directory sees it — this is the
        // Donna-on-the-iPad case in miniature.
        let other = FamilyTreeLiveModel(
            originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"),
            bookmarksDirectory: dir)
        #expect(other.isBookmarked("@I7@"),
                "a bookmark made in one place must be visible in another")
    }
}
