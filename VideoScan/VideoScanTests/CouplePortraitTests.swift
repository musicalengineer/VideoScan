import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import VideoScan

// MARK: - CouplePortraitTests
//
// The couple portrait (Rick & Donna beside the Family Tree title and on
// the People tab, 2026-09-08) is per-user: a bounded JPEG copy in App
// Support plus a file NAME and caption in UserDefaults. These pin the
// storage contract — what is written, what is forgotten, and what a
// poisoned preference can and cannot reach.
//
// Isolation: every case builds its own UserDefaults suite AND its own
// temp directory; nothing here can see or write real prefs or the real
// App Support folder.

struct CouplePortraitTests {

    // MARK: Fixtures

    private func suite() -> UserDefaults {
        // swiftlint:disable:next force_unwrapping
        UserDefaults(suiteName: "CouplePortraitTests.\(UUID().uuidString)")!
    }

    private func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CouplePortraitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A synthetic photo of the given pixel size, encoded as `type`
    /// (`.tiff` stands in for Rick's restored composite, `.png`/`.jpeg`
    /// for phone exports).
    private func makeImage(width: Int, height: Int, type: UTType, in dir: URL) throws -> URL {
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw TestFailure.contextFailed }
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw TestFailure.contextFailed }
        let url = dir.appendingPathComponent("source.\(type.preferredFilenameExtension ?? "img")")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
        else { throw TestFailure.contextFailed }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw TestFailure.contextFailed }
        return url
    }

    private func pixelSize(of url: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    private enum TestFailure: Error { case contextFailed }

    // MARK: Logic

    /// A fresh install has no portrait and no caption — the views show
    /// the placeholder, never a broken image.
    @Test func freshInstallHasNothing() throws {
        let dir = try tempDirectory()
        #expect(CouplePortraitPreference.load(from: suite(), directory: dir) == nil)
        #expect(CouplePortraitPreference.caption(from: suite()).isEmpty)
    }

    /// Import writes ONE bounded JPEG into the directory and points the
    /// preference at it by file name, not by absolute path.
    @Test func importStoresABoundedJPEGAndRecordsOnlyTheName() throws {
        let dir = try tempDirectory()
        let defaults = suite()
        let source = try makeImage(width: 3000, height: 3400, type: .tiff, in: dir)

        let stored = try CouplePortraitPreference.importPhoto(at: source, into: dir, defaults: defaults)

        #expect(stored.deletingLastPathComponent() == dir)
        #expect(stored.pathExtension == "jpg")
        let name = try #require(defaults.string(forKey: CouplePortraitPreference.fileNameKey))
        #expect(name == stored.lastPathComponent)
        #expect(!name.contains("/"))
        let (w, h) = try #require(pixelSize(of: stored))
        #expect(max(w, h) <= CouplePortraitPreference.storedMaxPixels)
        #expect(max(w, h) == CouplePortraitPreference.storedMaxPixels, "a large source is scaled DOWN to the bound, not left alone")
        // Aspect ratio survives (3000:3400 ≈ 0.882).
        #expect(abs(Double(w) / Double(h) - 3000.0 / 3400.0) < 0.01)
        #expect(CouplePortraitPreference.load(from: defaults, directory: dir)?.url == stored)
    }

    /// A small source is not upscaled.
    @Test func smallSourceKeepsItsSize() throws {
        let dir = try tempDirectory()
        let source = try makeImage(width: 300, height: 200, type: .png, in: dir)
        let stored = try CouplePortraitPreference.importPhoto(at: source, into: dir, defaults: suite())
        let (w, h) = try #require(pixelSize(of: stored))
        #expect(w == 300 && h == 200)
    }

    /// Choosing a second photo replaces the first: the old copy is
    /// deleted so App Support does not fill with abandoned portraits.
    @Test func secondImportDeletesTheFirstCopy() throws {
        let dir = try tempDirectory()
        let defaults = suite()
        let first = try CouplePortraitPreference.importPhoto(
            at: makeImage(width: 400, height: 500, type: .jpeg, in: dir), into: dir, defaults: defaults)
        let second = try CouplePortraitPreference.importPhoto(
            at: makeImage(width: 400, height: 500, type: .jpeg, in: dir), into: dir, defaults: defaults)

        #expect(first != second)
        #expect(!FileManager.default.fileExists(atPath: first.path))
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(CouplePortraitPreference.load(from: defaults, directory: dir)?.url == second)
    }

    /// Remove forgets the file and deletes it; the caption is kept.
    @Test func removeDeletesTheCopyAndKeepsTheCaption() throws {
        let dir = try tempDirectory()
        let defaults = suite()
        let stored = try CouplePortraitPreference.importPhoto(
            at: makeImage(width: 400, height: 500, type: .png, in: dir), into: dir, defaults: defaults)
        CouplePortraitPreference.saveCaption("Rick & Donna, Camp Iroquois", to: defaults)

        CouplePortraitPreference.remove(from: defaults, directory: dir)

        #expect(!FileManager.default.fileExists(atPath: stored.path))
        #expect(defaults.string(forKey: CouplePortraitPreference.fileNameKey) == nil)
        #expect(CouplePortraitPreference.load(from: defaults, directory: dir) == nil)
        #expect(CouplePortraitPreference.caption(from: defaults) == "Rick & Donna, Camp Iroquois")
    }

    @Test func captionRoundTripsTrimmedAndEmptyClears() {
        let defaults = suite()
        CouplePortraitPreference.saveCaption("  Rick & Donna  ", to: defaults)
        #expect(CouplePortraitPreference.caption(from: defaults) == "Rick & Donna")
        CouplePortraitPreference.saveCaption("   ", to: defaults)
        #expect(CouplePortraitPreference.caption(from: defaults).isEmpty)
        #expect(defaults.object(forKey: CouplePortraitPreference.captionKey) == nil)
    }

    /// A non-image throws a typed error and leaves the preference alone.
    @Test func nonImageIsRejectedWithoutTouchingThePreference() throws {
        let dir = try tempDirectory()
        let defaults = suite()
        let junk = dir.appendingPathComponent("notes.txt")
        try Data("not a photo".utf8).write(to: junk)

        #expect(throws: CouplePortraitPreference.ImportError.notAnImage) {
            try CouplePortraitPreference.importPhoto(at: junk, into: dir, defaults: defaults)
        }
        #expect(defaults.string(forKey: CouplePortraitPreference.fileNameKey) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["notes.txt"])
    }

    // MARK: Media matrix — the formats a family photo actually arrives in

    @Test(arguments: [UTType.tiff, .png, .jpeg, .bmp, .gif])
    func everyCommonStillFormatImports(type: UTType) throws {
        let dir = try tempDirectory()
        let source = try makeImage(width: 640, height: 800, type: type, in: dir)
        let stored = try CouplePortraitPreference.importPhoto(at: source, into: dir, defaults: suite())
        let (w, h) = try #require(pixelSize(of: stored))
        #expect(w == 640 && h == 800, "\(type.identifier) did not survive import")
    }

    // MARK: Isolation — a poisoned preference

    /// The stored name is resolved INSIDE the portrait folder only. A
    /// hand-edited plist with a path, a traversal, or a dotfile must yield
    /// "no portrait", never a file from elsewhere on disk.
    @Test(arguments: ["../../etc/hosts", "/etc/hosts", "..", ".", "", ".hidden.jpg", "sub/dir.jpg", "a\\b.jpg"])
    func unsafeStoredNamesResolveToNothing(name: String) throws {
        let dir = try tempDirectory()
        let defaults = suite()
        defaults.set(name, forKey: CouplePortraitPreference.fileNameKey)
        #expect(CouplePortraitPreference.load(from: defaults, directory: dir) == nil)
        #expect(!CouplePortraitPreference.isSafeFileName(name))
    }

    /// A name that is safe but whose file was deleted out from under us
    /// (Rick cleared App Support) is "no portrait", not a crash.
    @Test func missingFileBehindAValidNameIsNoPortrait() throws {
        let dir = try tempDirectory()
        let defaults = suite()
        defaults.set("portrait-gone.jpg", forKey: CouplePortraitPreference.fileNameKey)
        #expect(CouplePortraitPreference.isSafeFileName("portrait-gone.jpg"))
        #expect(CouplePortraitPreference.load(from: defaults, directory: dir) == nil)
    }

    /// Two users (two suites) never see each other's choice.
    @Test func separateDefaultsSuitesAreIndependent() throws {
        let dir = try tempDirectory()
        let rick = suite(), other = suite()
        try CouplePortraitPreference.importPhoto(
            at: makeImage(width: 400, height: 500, type: .png, in: dir), into: dir, defaults: rick)
        #expect(CouplePortraitPreference.load(from: rick, directory: dir) != nil)
        #expect(CouplePortraitPreference.load(from: other, directory: dir) == nil)
    }

    // MARK: Sensor — cost of the one-time import

    /// A 24-megapixel camera original must import in well under the time
    /// a person waits after an open panel. Guards against someone
    /// swapping the bounded decode for a full decode + resize.
    @Test func largeSourceImportsWithinBudget() throws {
        let dir = try tempDirectory()
        let source = try makeImage(width: 6000, height: 4000, type: .jpeg, in: dir)
        let start = Date()
        _ = try CouplePortraitPreference.importPhoto(at: source, into: dir, defaults: suite())
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0, "import took \(elapsed)s")
    }
}
