import Testing
import Foundation
import PDFKit
@testable import VideoScan

// MARK: - FamilyTreeLinePrintTests
//
// "Print line…" produced BLANK PAGES (Rick, 2026-08-30) while "Export as
// PDF…" of the same line was fine. The cause was two rendering paths:
// export went through ImageRenderer + CGContext, printing handed an
// NSHostingView to NSPrintOperation(view:). A hosting view that is never
// added to a window and never laid out has nothing to draw when AppKit
// asks it to paint a page — and `fittingSize` still reports a plausible
// size, which is why the symptom looked like bad pagination rather than an
// empty view.
//
// Printing now prints the same PDF the export writes. These tests assert
// the thing that was actually wrong: that the bytes handed to the printer
// contain the line. A page-count check alone would have passed on the
// broken version, because it produced pages — they were just empty.

@MainActor
struct FamilyTreeLinePrintTests {

    private func chain(names: [String]) -> FamilyTreeLineChain {
        let cards = names.enumerated().map { index, name in
            FamilyTreeLineChain.Card(
                person: FamilyTreePersonSummary(
                    id: "@I\(index)@",
                    name: name,
                    surname: name.split(separator: " ").last.map(String.init),
                    years: "\(1700 + index * 30)–\(1700 + index * 30 + 70)",
                    sex: index.isMultiple(of: 2) ? .female : .male,
                    reference: "I\(index)"),
                spouseNames: [],
                generation: index,
                lifeLines: [])
        }
        return FamilyTreeLineChain(
            anchor: FamilyTreeAnchor(id: "@I\(names.count - 1)@",
                                     label: names.last ?? "", isRoot: true),
            title: "\(names.first ?? "") → \(names.last ?? "")",
            cards: cards)
    }

    private func text(of url: URL) throws -> String {
        let document = try #require(PDFDocument(url: url))
        return (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    /// The regression sensor. The bug was invisible ink, not missing
    /// pages, so this reads the text back out.
    @Test func thePrintedPdfActuallyContainsTheLine() throws {
        let spec = FamilyTreeLineExportSpec(
            chain: chain(names: ["Martha Lamson", "Ada Lamson", "Donna Breen"]),
            includePhotos: false)
        let url = try FamilyTreeLineExporter.makePrintablePDF(spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let body = try text(of: url)
        #expect(body.contains("Martha Lamson"),
                "the first generation must appear on the printed page")
        #expect(body.contains("Donna Breen"),
                "the last generation must appear on the printed page")
        #expect(body.contains("Ada Lamson"),
                "intermediate generations must not be dropped")
    }

    /// A page count on its own is not evidence: the broken version emitted
    /// pages too. Pinned so nobody "simplifies" the test above into one.
    @Test func aPageExistsAndIsNotEmpty() throws {
        let spec = FamilyTreeLineExportSpec(chain: chain(names: ["Martha Lamson", "Donna Breen"]),
                                            includePhotos: false)
        let url = try FamilyTreeLineExporter.makePrintablePDF(spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount >= 1)
        let first = try #require(document.page(at: 0)?.string)
        #expect(first.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                "page 1 must carry text — blank pages were the bug")
    }

    /// THE REGRESSION SENSOR. Runs the real print operation to a file
    /// instead of a printer and reads back what would have come out.
    ///
    /// This is the one that would have failed before the fix. The two
    /// tests above check `makePrintablePDF`, which is new code — they
    /// could not have caught the original bug, because the PDF export was
    /// never the broken half. Only driving `printOperation` proves paper
    /// gets ink.
    @Test func theActualPrintOperationEmitsPagesWithTextOnThem() throws {
        let spec = FamilyTreeLineExportSpec(
            chain: chain(names: ["Martha Lamson", "Ada Lamson", "Donna Breen"]),
            includePhotos: false)

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-print-sensor-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: out) }

        let operation = try FamilyTreeLineExporter.printOperation(spec)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
        #expect(operation.run(), "the print operation itself must succeed")

        let document = try #require(PDFDocument(url: out),
                                    "the print job produced no readable PDF")
        #expect(document.pageCount >= 1)
        let printed = (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined()
        #expect(printed.contains("Martha Lamson"),
                "BLANK PAGES: the print job emitted \(document.pageCount) page(s) with no line on them")
        #expect(printed.contains("Donna Breen"))
    }

    /// A long line must paginate rather than run off page one.
    @Test func aLongLinePaginates() throws {
        let names = (0..<40).map { "Generation \($0) Person" }
        let spec = FamilyTreeLineExportSpec(chain: chain(names: names), includePhotos: false)
        let url = try FamilyTreeLineExporter.makePrintablePDF(spec)
        defer { try? FileManager.default.removeItem(at: url) }

        let document = try #require(PDFDocument(url: url))
        #expect(document.pageCount > 1, "40 generations must span more than one page")
        let body = try text(of: url)
        #expect(body.contains("Generation 39 Person"),
                "the last generation must survive pagination onto a later page")
    }
}
