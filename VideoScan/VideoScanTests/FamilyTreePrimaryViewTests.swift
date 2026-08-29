import Foundation
import Testing
import PDFKit
import AppKit
@testable import VideoScan

// Tree-as-primary-view (feature/family-tree-primary-view, 2026-08-29).
// Dimensions per the feature-test checklist:
//   Logic     — sidebar preference default/round-trip; zoom step/clamp;
//               fit math; export title / file name; pagination
//   Isolation — the preference is read and written on an injected
//               UserDefaults suite; a poisoned real-looking key in another
//               suite must not leak
//   Scale     — a 10-generation synthetic chain renders to a non-empty PDF
//               (page count = the pure pagination's answer, title in the
//               document metadata) and a 2× PNG; a 200-generation chain
//               stays under the PNG bitmap budget
//   Sensor    — fitScale never leaves the slider range

// MARK: - Fixture

private func syntheticChain(generations: Int) -> FamilyTreeLineChain {
    let names = ["Martha Lamson", "Josiah Lamson", "Hannah Lamson", "Samuel Breen",
                 "Mary Breen", "George Breen", "Muriel Lamb", "Richard Harding Breen Sr"]
    var cards: [FamilyTreeLineChain.Card] = []
    for index in 0...generations {
        let isLast = index == generations
        let name = isLast ? "Richard Harding Breen Jr" : names[index % names.count]
        let born = 1640 + index * 32
        cards.append(FamilyTreeLineChain.Card(
            person: FamilyTreePersonSummary(
                id: "@I\(index)@", name: name, surname: name.split(separator: " ").last.map(String.init),
                years: "\(born)–\(born + 71)", sex: index % 2 == 0 ? .female : .male,
                reference: "I\(index)"),
            spouseNames: index == 0 ? [] : ["Spouse \(index)"],
            generation: index,
            lifeLines: ["Born \(born) (Ipswich, Massachusetts)", "Died \(born + 71), age 71 (Sudbury, Massachusetts)"]))
    }
    return FamilyTreeLineChain(
        anchor: FamilyTreeAnchor(id: "@I\(generations)@", label: "Richard", isRoot: true),
        title: "Martha Lamson → Richard: your 8th-great-grandmother (\(generations) generations)",
        cards: cards)
}

private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("FamilyTreePrimaryViewTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: - Sidebar preference

@Suite("Family Tree — sidebar preference (isolated)")
struct FamilyTreeSidebarPreferenceTests {

    private func suite() -> UserDefaults {
        // swiftlint:disable:next force_unwrapping
        UserDefaults(suiteName: "FamilyTreeSidebarPreferenceTests.\(UUID().uuidString)")!
    }

    @Test func defaultIsShownUntilSaved() {
        let defaults = suite()
        #expect(FamilyTreeSidebarPreference.load(from: defaults) == true)
        FamilyTreeSidebarPreference.save(false, to: defaults)
        #expect(FamilyTreeSidebarPreference.load(from: defaults) == false)
        FamilyTreeSidebarPreference.save(true, to: defaults)
        #expect(FamilyTreeSidebarPreference.load(from: defaults) == true)
    }

    @Test func savedFalseIsNotConfusedWithNeverSaved() {
        // bool(forKey:) alone returns false for both cases — the load must
        // tell them apart, or a fresh install would open with no sidebar.
        let defaults = suite()
        FamilyTreeSidebarPreference.save(false, to: defaults)
        #expect(defaults.object(forKey: FamilyTreeSidebarPreference.key) != nil)
        #expect(FamilyTreeSidebarPreference.load(from: defaults) == false)
    }

    @Test func poisonedOtherSuiteDoesNotLeak() {
        let poisoned = suite()
        FamilyTreeSidebarPreference.save(false, to: poisoned)
        let clean = suite()
        #expect(FamilyTreeSidebarPreference.load(from: clean) == true)
        #expect(FamilyTreeSidebarPreference.load(from: poisoned) == false)
    }
}

// MARK: - Zoom math

@Suite("Family Tree — zoom math (pure)")
struct FamilyTreeZoomMathTests {

    @Test func stepsAreMultiplicativeAndClamped() {
        let z = FamilyTreeZoomMath.default
        #expect(FamilyTreeZoomMath.zoomIn(z) > z)
        #expect(FamilyTreeZoomMath.zoomOut(z) < z)
        #expect(abs(FamilyTreeZoomMath.zoomOut(FamilyTreeZoomMath.zoomIn(z)) - z) < 1e-9)
        var top = z
        for _ in 0..<50 { top = FamilyTreeZoomMath.zoomIn(top) }
        #expect(top == FamilyTreeZoomMath.range.upperBound)
        var bottom = z
        for _ in 0..<50 { bottom = FamilyTreeZoomMath.zoomOut(bottom) }
        #expect(bottom == FamilyTreeZoomMath.range.lowerBound)
        #expect(FamilyTreeZoomMath.range.contains(FamilyTreeZoomMath.default))
    }

    @Test func fitScaleUsesTheTighterAxisWithPadding() {
        // 1000×500 scene into 1080×580 viewport with 40 pt padding → 1.0.
        let exact = FamilyTreeZoomMath.fitScale(content: CGSize(width: 1000, height: 500),
                                                viewport: CGSize(width: 1080, height: 580))
        #expect(abs(exact - 1.0) < 1e-9)
        // Height is the limit: 1000×1000 into 1080×580 → 500/1000 = 0.5.
        let tall = FamilyTreeZoomMath.fitScale(content: CGSize(width: 1000, height: 1000),
                                               viewport: CGSize(width: 1080, height: 580))
        #expect(abs(tall - 0.5) < 1e-9)
        // Tiny scene never zooms past the range top; huge never under the floor.
        #expect(FamilyTreeZoomMath.fitScale(content: CGSize(width: 10, height: 10),
                                            viewport: CGSize(width: 2000, height: 2000))
                == FamilyTreeZoomMath.range.upperBound)
        #expect(FamilyTreeZoomMath.fitScale(content: CGSize(width: 100_000, height: 100_000),
                                            viewport: CGSize(width: 800, height: 600))
                == FamilyTreeZoomMath.range.lowerBound)
    }

    @Test func degenerateSizesFallBackToTheDefault() {
        #expect(FamilyTreeZoomMath.fitScale(content: .zero, viewport: CGSize(width: 800, height: 600))
                == FamilyTreeZoomMath.default)
        #expect(FamilyTreeZoomMath.fitScale(content: CGSize(width: 800, height: 600), viewport: .zero)
                == FamilyTreeZoomMath.default)
        // Viewport smaller than the padding alone.
        #expect(FamilyTreeZoomMath.fitScale(content: CGSize(width: 800, height: 600),
                                            viewport: CGSize(width: 50, height: 50))
                == FamilyTreeZoomMath.default)
    }

    @Test func fitLineFitsByWidthOnly() {
        let ten = FamilyTreeLineChainMetrics.contentSize(cardCount: 11)
        #expect(ten.width == FamilyTreeLineChainMetrics.cardWidth + FamilyTreeLineChainMetrics.verticalPadding * 2)
        #expect(ten.height == 11 * FamilyTreeLineChainMetrics.cardHeight
                + 10 * FamilyTreeLineChainMetrics.connectorHeight
                + FamilyTreeLineChainMetrics.verticalPadding * 2)
        #expect(FamilyTreeLineChainMetrics.contentSize(cardCount: 0) == .zero)
        // A 700 pt wide canvas: (700 − 80) / 340 ≈ 1.82 — the chain fills
        // the width and scrolls; fitting by height would give confetti.
        let byWidth = FamilyTreeZoomMath.fitWidthScale(content: ten, viewport: CGSize(width: 700, height: 500))
        #expect(abs(byWidth - Double((700.0 - 80.0) / ten.width)) < 1e-9)
        #expect(FamilyTreeZoomMath.fitScale(content: ten, viewport: CGSize(width: 700, height: 500))
                == FamilyTreeZoomMath.range.lowerBound)
    }
}

// MARK: - Export

@Suite("Family Tree — export line (title, pagination, PDF, PNG)")
@MainActor
struct FamilyTreeLineExportTests {

    @Test func titleAndFileNameFollowTheChain() {
        let spec = FamilyTreeLineExportSpec(chain: syntheticChain(generations: 10))
        #expect(spec.title == "Martha Lamson → Richard Harding Breen Jr, 10 generations")
        #expect(spec.defaultFileBase == "Martha-Lamson-to-Richard-Harding-Breen-Jr-line")
        let one = FamilyTreeLineExportSpec(chain: syntheticChain(generations: 1))
        #expect(one.title.hasSuffix(", 1 generation"))
        #expect(FamilyTreeLineExportSpec.fileToken("Mary O'Connor / \"Polly\"") == "Mary-OConnor-Polly")
        #expect(FamilyTreeLineExportSpec.fileToken("   ") == "person")
    }

    @Test func paginationScalesToPageWidthAndSplitsHeight() {
        let page = FamilyTreeLinePage.letter
        let margin = FamilyTreeLinePage.margin
        let available = page.height - margin * 2
        // Narrow strip: scale 1, one page.
        let short = FamilyTreeLinePage.paginate(stripSize: CGSize(width: 420, height: 400))
        #expect(short == .init(scale: 1, pageCount: 1, stripHeightPerPage: available))
        // Exactly one page tall is still one page; one point more is two.
        #expect(FamilyTreeLinePage.paginate(stripSize: CGSize(width: 420, height: available)).pageCount == 1)
        #expect(FamilyTreeLinePage.paginate(stripSize: CGSize(width: 420, height: available + 1)).pageCount == 2)
        // Wide strip scales down (never up) and gets more strip per page.
        let wide = FamilyTreeLinePage.paginate(stripSize: CGSize(width: 1080, height: 3000))
        #expect(abs(wide.scale - (page.width - margin * 2) / 1080) < 1e-9)
        #expect(wide.stripHeightPerPage > available)
        #expect(wide.pageCount == Int((3000 / wide.stripHeightPerPage).rounded(.up)))
        #expect(FamilyTreeLinePage.paginate(stripSize: .zero).pageCount == 1)
    }

    @Test func tenGenerationChainRendersToPDFWithTitleAndPageCount() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = FamilyTreeLineExportSpec(chain: syntheticChain(generations: 10), includePhotos: false)
        let url = dir.appendingPathComponent(spec.defaultFileBase + ".pdf")

        let pagination = try FamilyTreeLineExporter.writePDF(spec, to: url)

        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 2_000, "PDF is \(size) bytes")
        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount == pagination.pageCount)
        // Eleven cards with two life lines each do not fit one Letter page.
        #expect(pagination.pageCount >= 2, "pagination: \(pagination)")
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String
                == "Martha Lamson → Richard Harding Breen Jr, 10 generations")
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == FamilyTreeLinePage.letter)
        // The strip is real text, not a bitmap: the title is extractable.
        #expect(first.string?.contains("Martha Lamson") == true)
        let last = try #require(document.page(at: document.pageCount - 1))
        #expect(last.string?.contains("Richard Harding Breen Jr") == true)
    }

    @Test func tenGenerationChainRendersToPNGAtTwoX() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let photo = NSImage(size: NSSize(width: 40, height: 40), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill(); return true
        }
        let spec = FamilyTreeLineExportSpec(chain: syntheticChain(generations: 10),
                                            includePhotos: true, photo: { _ in photo })
        let url = dir.appendingPathComponent(spec.defaultFileBase + ".png")

        let pixels = try FamilyTreeLineExporter.writePNG(spec, to: url)

        let size = try #require(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        #expect(size > 10_000, "PNG is \(size) bytes")
        #expect(pixels.width == FamilyTreeLineStripView.width * 2)
        #expect(pixels.height > pixels.width * 3, "a 10-generation strip is tall: \(pixels)")
        let image = try #require(NSImage(contentsOf: url))
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        #expect(rep.pixelsWide == Int(pixels.width) && rep.pixelsHigh == Int(pixels.height))
    }

    @Test func hugeChainStaysUnderThePNGBitmapBudget() throws {
        let dir = try tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let spec = FamilyTreeLineExportSpec(chain: syntheticChain(generations: 200), includePhotos: false)
        let url = dir.appendingPathComponent("huge.png")
        let pixels = try FamilyTreeLineExporter.writePNG(spec, to: url)
        #expect(Int(pixels.width * pixels.height) * 4 <= FamilyTreeLineExporter.pngBitmapBudget + 4 * Int(pixels.width),
                "bitmap \(pixels) over budget")
        #expect(pixels.width < FamilyTreeLineStripView.width * 2)
    }
}
