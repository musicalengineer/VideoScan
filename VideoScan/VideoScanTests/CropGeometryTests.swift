import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import VideoScan

// Adjust Photo… (feature/family-tree-notes-and-nav, 2026-08-26).
// Dimensions per the feature-test checklist:
//   Logic     — centre, clamped pan, zoom bounds, output size, real crop
//   Media     — a synthetic JPEG through the store (card precedence)
//   Isolation — store rooted in a temp directory only

@Suite("Crop geometry — pure math")
struct CropGeometryTests {

    // A 4:3 landscape image in a square viewport: height fills, width overflows.
    private func landscape() -> CropGeometry {
        CropGeometry(viewport: CGSize(width: 300, height: 300),
                     imageSize: CGSize(width: 4000, height: 3000))
    }

    @Test func centredFillShowsTheMiddleSquare() {
        let g = landscape()
        #expect(g.zoom == 1)
        #expect(g.clampedOffset == .zero)
        // fillScale = max(300/4000, 300/3000) = 0.1 → displayed 400×300.
        #expect(abs(g.fillScale - 0.1) < 1e-9)
        #expect(g.displayedSize == CGSize(width: 400, height: 300))
        #expect(g.maxOffset == CGSize(width: 50, height: 0))
        // Middle 3000×3000 of the 4000×3000 image.
        #expect(g.sourceRect == CGRect(x: 500, y: 0, width: 3000, height: 3000))
        #expect(g.outputSize(maxPixels: 1024) == CGSize(width: 1024, height: 1024))
    }

    @Test func panIsClampedToTheImageEdge() {
        var g = landscape()
        g.pan(from: .zero, by: CGSize(width: 1_000, height: -1_000))
        #expect(g.clampedOffset == CGSize(width: 50, height: 0))
        // Image shifted right by 50 pt → viewport shows the LEFT edge.
        #expect(g.sourceRect == CGRect(x: 0, y: 0, width: 3000, height: 3000))
        g.pan(from: .zero, by: CGSize(width: -1_000, height: 0))
        #expect(g.sourceRect == CGRect(x: 1000, y: 0, width: 3000, height: 3000))
        // A partial pan lands where asked.
        g.pan(from: .zero, by: CGSize(width: 20, height: 0))
        #expect(g.clampedOffset == CGSize(width: 20, height: 0))
        #expect(g.sourceRect.minX == 300)
        // Non-finite input is ignored, never propagated.
        g.setOffset(CGSize(width: CGFloat.nan, height: CGFloat.infinity))
        #expect(g.clampedOffset == .zero)
    }

    @Test func zoomIsBoundedAndReclampsThePan() {
        var g = landscape()
        g.setZoom(0.2)
        #expect(g.zoom == CropGeometry.minZoom)
        g.setZoom(50)
        #expect(g.zoom == CropGeometry.maxZoom)
        g.setZoom(CGFloat.nan)
        #expect(g.zoom == 1)

        g.setZoom(2)
        // displayed 800×600 → max pan 250×150; source rect is 150 pt / 0.2 = 1500 px square.
        #expect(g.maxOffset == CGSize(width: 250, height: 150))
        g.pan(from: .zero, by: CGSize(width: -250, height: -150))
        #expect(g.sourceRect == CGRect(x: 2500, y: 1500, width: 1500, height: 1500))
        // Zooming back out shrinks the allowed pan; the offset follows.
        g.setZoom(1)
        #expect(g.clampedOffset == CGSize(width: -50, height: 0))
        g.center()
        #expect(g.zoom == 1 && g.clampedOffset == .zero)
    }

    @Test func outputNeverUpscalesAndDegenerateGeometryIsSafe() {
        var g = CropGeometry(viewport: CGSize(width: 300, height: 300),
                             imageSize: CGSize(width: 500, height: 500))
        #expect(g.sourceRect == CGRect(x: 0, y: 0, width: 500, height: 500))
        #expect(g.outputSize(maxPixels: 1024) == CGSize(width: 500, height: 500))
        g.setZoom(4)
        #expect(g.sourceRect.width == 125)
        #expect(g.outputSize(maxPixels: 1024) == CGSize(width: 125, height: 125))

        let empty = CropGeometry(viewport: .zero, imageSize: CGSize(width: 10, height: 10))
        #expect(!empty.isValid)
        #expect(empty.sourceRect == .zero)
        #expect(empty.outputSize(maxPixels: 1024) == .zero)
        let noImage = CropGeometry(viewport: CGSize(width: 10, height: 10), imageSize: .zero)
        #expect(noImage.sourceRect == .zero)
    }

    @Test func croppingARealBitmapProducesTheExpectedPixels() throws {
        // 40×30 image: left half red, right half blue.
        let width = 40, height = 30
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = x < 20 ? 255 : 0        // R
            pixels[i + 2] = x < 20 ? 0 : 255    // B
            pixels[i + 3] = 255
        } }
        let context = try #require(CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())

        var g = CropGeometry(viewport: CGSize(width: 30, height: 30),
                             imageSize: CGSize(width: 40, height: 30))
        // Pan fully right → viewport shows x 0..<30 (mostly red).
        g.pan(from: .zero, by: CGSize(width: 100, height: 0))
        let leftCrop = try #require(g.cropped(image, maxPixels: 1024))
        #expect(leftCrop.width == 30 && leftCrop.height == 30)
        #expect(dominantIsRed(leftCrop))
        g.pan(from: .zero, by: CGSize(width: -100, height: 0))
        let rightCrop = try #require(g.cropped(image, maxPixels: 1024))
        #expect(!dominantIsRed(rightCrop))
        // Downscale path: cap at 10 px.
        let small = try #require(g.cropped(image, maxPixels: 10))
        #expect(small.width == 10 && small.height == 10)
        // Wrong image for this geometry is refused.
        let other = CropGeometry(viewport: CGSize(width: 30, height: 30), imageSize: CGSize(width: 41, height: 30))
        #expect(other.cropped(image) == nil)
    }

    private func dominantIsRed(_ image: CGImage) -> Bool {
        let w = image.width, h = image.height
        var buffer = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buffer, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        var red = 0, blue = 0
        for i in stride(from: 0, to: buffer.count, by: 4) {
            if buffer[i] > buffer[i + 2] { red += 1 } else { blue += 1 }
        }
        return red > blue
    }
}

@Suite("Crop geometry — card photo precedence in the store")
struct CardPhotoStoreTests {

    @Test func savedCardWinsOverTheOriginalWhichIsKept() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("CardPhoto-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let person = FamilyAssetPerson(gedcomID: "@I7@", name: "Richard Breen", birthYear: 1959)

        // Original: a real 64×48 JPEG dropped into the person's folder.
        let folder = try store.folderForPhotoRequest(person: person)
        let original = folder.appendingPathComponent("portrait.jpg")
        try jpeg(width: 64, height: 48).write(to: original)
        #expect(store.cardPhotoURL(for: person) == nil)
        #expect(same(store.originalPhotoURL(for: person), original))

        // Crop through the geometry and save as the card.
        let image = try #require(CropRenderer.boundedImage(at: original))
        let g = CropGeometry(viewport: CGSize(width: 100, height: 100),
                             imageSize: CGSize(width: image.width, height: image.height))
        let cropped = try #require(g.cropped(image, maxPixels: 1024))
        #expect(cropped.width == 48 && cropped.height == 48)
        let data = try #require(CropRenderer.jpegData(cropped, quality: 0.9))
        let card = try store.saveCardPhoto(data, for: person, nextTo: original)
        #expect(card.lastPathComponent == "portrait-card.jpg")
        #expect(same(card.deletingLastPathComponent(), folder))

        // Precedence: card first; original untouched and still the source.
        #expect(same(store.cardPhotoURL(for: person), card))
        #expect(same(store.originalPhotoURL(for: person), original))
        #expect(FileManager.default.fileExists(atPath: original.path))
        #expect(store.photoURLs(for: person).count == 2)

        // A second adjust never overwrites; the newest card wins.
        let second = try store.saveCardPhoto(data, for: person, nextTo: original)
        #expect(second.lastPathComponent == "portrait-card-2.jpg")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: second.path)
        #expect(same(store.cardPhotoURL(for: person), second))

        // Garbage bytes are refused before anything lands on disk.
        #expect(throws: FamilyAssetStore.StoreError.self) {
            try store.saveCardPhoto(Data("not an image".utf8), for: person, nextTo: original)
        }
    }

    /// `/private/var` vs `/var`: `standardizedFileURL` strips the prefix on
    /// a freshly built URL while discovery returns the canonical form.
    private func same(_ lhs: URL?, _ rhs: URL?) -> Bool {
        lhs?.resolvingSymlinksInPath().path == rhs?.resolvingSymlinksInPath().path
    }

    private func jpeg(width: Int, height: Int) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return try #require(CropRenderer.jpegData(image))
    }
}
