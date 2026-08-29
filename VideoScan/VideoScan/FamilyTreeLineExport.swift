// FamilyTreeLineExport.swift
// "Export line…" / "Print line…" (Rick 2026-08-29): a "Line to Rick /
// Donna" chain rendered as a vertical strip — title, one card per
// generation with name, years, places when the GEDCOM has them, spouses
// and an optional photo — to PDF (paginated on US Letter), PNG at 2×, or
// straight to the printer. Rick screen-caps and prints these.
//
// Nothing here touches the model; it takes the chain the model already
// built (`FamilyTreeLineChain`) and a photo lookup closure.
//
// Memory: the strip is O(generations). A PNG at 2× of a 10-generation
// line is ~840 × 3,200 px ≈ 11 MB of bitmap; `writePNG` lowers the scale
// so the bitmap never exceeds `pngBitmapBudget` (a 200-generation line
// would otherwise want ~200 MB). PDF and print are vector and cost
// nothing beyond the view hierarchy.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - What to export

struct FamilyTreeLineExportSpec {
    let chain: FamilyTreeLineChain
    var includePhotos: Bool = true
    /// Photo by person id (the view passes `model.photo(for:)`). Called
    /// once per card at render time, never cached here.
    var photo: (String) -> NSImage? = { _ in nil }

    var generations: Int { max(chain.cards.count - 1, 0) }
    var fromName: String { chain.cards.first?.person.name ?? "" }
    var toName: String { chain.cards.last?.person.name ?? "" }

    /// "Martha Lamson → Richard Harding Breen Jr, 10 generations"
    var title: String {
        "\(fromName) → \(toName), \(generations) generation\(generations == 1 ? "" : "s")"
    }

    /// "Martha-Lamson-to-Richard-Harding-Breen-Jr-line" — the save panel
    /// adds the extension.
    var defaultFileBase: String {
        "\(Self.fileToken(fromName))-to-\(Self.fileToken(toName))-line"
    }

    /// Spaces → "-", everything that is not a letter, digit, "-" or "_"
    /// dropped (slashes, quotes, "→"), runs of "-" collapsed.
    static func fileToken(_ name: String) -> String {
        var out = ""
        var lastDash = true   // suppress a leading dash
        for scalar in name.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if scalar == " " || scalar == "-" {
                if !lastDash { out.append("-"); lastDash = true }
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "person" : out
    }
}

// MARK: - Pagination (pure)

/// US-Letter pagination of a strip: scale the strip to the page's content
/// width (never up), then split its height into pages.
enum FamilyTreeLinePage {
    static let letter = CGSize(width: 612, height: 792)
    static let margin: CGFloat = 36

    struct Pagination: Equatable {
        /// Strip points → page points.
        let scale: CGFloat
        let pageCount: Int
        /// Height of strip (unscaled points) that lands on one page.
        let stripHeightPerPage: CGFloat
    }

    static func paginate(stripSize: CGSize, page: CGSize = letter,
                         margin: CGFloat = margin) -> Pagination {
        let availableWidth = page.width - margin * 2
        let availableHeight = page.height - margin * 2
        guard stripSize.width > 0, stripSize.height > 0,
              availableWidth > 0, availableHeight > 0 else {
            return Pagination(scale: 1, pageCount: 1, stripHeightPerPage: availableHeight)
        }
        let scale = min(1, availableWidth / stripSize.width)
        let perPage = availableHeight / scale
        let count = max(1, Int((stripSize.height / perPage).rounded(.up)))
        return Pagination(scale: scale, pageCount: count, stripHeightPerPage: perPage)
    }
}

// MARK: - The strip

/// Light-on-white so it prints; the on-screen chain stays dark.
struct FamilyTreeLineStripView: View {
    let spec: FamilyTreeLineExportSpec
    static let width: CGFloat = 420
    private let photoSide: CGFloat = 56

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(spec.title)
                .font(.system(size: 17, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
            Text(spec.chain.title)
                .font(.system(size: 11))
                .foregroundStyle(Color(white: 0.35))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 3)
            Rectangle().fill(Color(white: 0.75)).frame(height: 1).padding(.vertical, 12)
            ForEach(spec.chain.cards) { card in
                if card.generation > 0 {
                    Rectangle()
                        .fill(Color(white: 0.55))
                        .frame(width: 2, height: 22)
                        .padding(.leading, 34)
                }
                stripCard(card)
            }
            Text("VideoScan Family Tree · \(Self.dateStamp())")
                .font(.system(size: 9))
                .foregroundStyle(Color(white: 0.5))
                .padding(.top, 14)
        }
        .padding(24)
        .frame(width: Self.width, alignment: .leading)
        .background(Color.white)
        .environment(\.colorScheme, .light)
    }

    private func stripCard(_ card: FamilyTreeLineChain.Card) -> some View {
        let person = card.person
        let photo = spec.includePhotos ? spec.photo(person.id) : nil
        return HStack(alignment: .top, spacing: 10) {
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .scaledToFill()
                    .frame(width: photoSide, height: photoSide)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if !person.sex.glyph.isEmpty {
                        Text(person.sex.glyph)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(person.sex.accent)
                    }
                    Text(person.name)
                        .font(.system(size: 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !card.lifeLines.isEmpty {
                    ForEach(card.lifeLines, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color(white: 0.3))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let years = person.years {
                    Text(years)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 0.3))
                }
                if !card.spouseNames.isEmpty {
                    Text("⚭ " + card.spouseNames.joined(separator: ", "))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(white: 0.3))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(card.generation == 0
                     ? "top of this line · \(person.reference)"
                     : "\(card.generation) generation\(card.generation == 1 ? "" : "s") down · \(person.reference)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color(white: 0.5))
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .stroke(person.sex.accent.opacity(0.8), lineWidth: 1.2))
        .foregroundStyle(.black)
    }

    private static func dateStamp() -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .none
        return f.string(from: Date())
    }
}

// MARK: - Rendering

/// `@MainActor` ≈ must run on the UI thread — `ImageRenderer` and
/// `NSHostingView` are main-thread objects.
@MainActor
enum FamilyTreeLineExporter {
    enum ExportError: LocalizedError {
        case pdfContext, bitmap, encode
        var errorDescription: String? {
            switch self {
            case .pdfContext: return "Couldn't create the PDF file."
            case .bitmap: return "Couldn't rasterize the line."
            case .encode: return "Couldn't encode the PNG."
            }
        }
    }

    /// Worst case for `writePNG`: 64 MB of RGBA (≈ 16 M pixels — a 120-
    /// generation strip at 2×). Above this the scale is lowered.
    static let pngBitmapBudget: Int = 64 * 1024 * 1024

    private static func renderer(for spec: FamilyTreeLineExportSpec) -> ImageRenderer<FamilyTreeLineStripView> {
        let renderer = ImageRenderer(content: FamilyTreeLineStripView(spec: spec))
        renderer.proposedSize = ProposedViewSize(width: FamilyTreeLineStripView.width, height: nil)
        return renderer
    }

    /// Paginated US-Letter PDF with the title in the document metadata.
    @discardableResult
    static func writePDF(_ spec: FamilyTreeLineExportSpec, to url: URL) throws -> FamilyTreeLinePage.Pagination {
        var result = FamilyTreeLinePage.paginate(stripSize: .zero)
        var failure: Error?
        renderer(for: spec).render { size, draw in
            let page = FamilyTreeLinePage.letter
            let margin = FamilyTreeLinePage.margin
            let pagination = FamilyTreeLinePage.paginate(stripSize: size)
            result = pagination
            var mediaBox = CGRect(origin: .zero, size: page)
            let info: [CFString: Any] = [
                kCGPDFContextTitle: spec.title,
                kCGPDFContextCreator: "VideoScan",
            ]
            guard let ctx = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
                failure = ExportError.pdfContext
                return
            }
            let contentBox = CGRect(x: margin, y: margin,
                                    width: page.width - margin * 2, height: page.height - margin * 2)
            for index in 0..<pagination.pageCount {
                ctx.beginPDFPage(nil)
                ctx.saveGState()
                ctx.clip(to: contentBox)
                // CG's origin is bottom-left; the renderer draws the view
                // with its top at y = size.height. Put the top of this
                // page's slice at the top of the content box.
                let sliceTop = size.height - CGFloat(index) * pagination.stripHeightPerPage
                ctx.translateBy(x: margin, y: page.height - margin)
                ctx.scaleBy(x: pagination.scale, y: pagination.scale)
                ctx.translateBy(x: 0, y: -sliceTop)
                draw(ctx)
                ctx.restoreGState()
                ctx.endPDFPage()
            }
            ctx.closePDF()
        }
        if let failure { throw failure }
        return result
    }

    /// PNG at `scale`× (2× by default). Returns the pixel size written.
    @discardableResult
    static func writePNG(_ spec: FamilyTreeLineExportSpec, to url: URL,
                         scale: CGFloat = 2) throws -> CGSize {
        let renderer = renderer(for: spec)
        renderer.isOpaque = true
        // Budget check needs the natural size; a throwaway 1× render
        // callback reports it without allocating a bitmap.
        var natural = CGSize.zero
        renderer.render { size, _ in natural = size }
        var effectiveScale = scale
        let bytes = natural.width * natural.height * 4
        if bytes > 0, bytes * scale * scale > CGFloat(pngBitmapBudget) {
            effectiveScale = max(1, (CGFloat(pngBitmapBudget) / bytes).squareRoot())
            appLog.write("Family Tree: export PNG scale lowered to \(String(format: "%.2f", effectiveScale))× to stay under the bitmap budget")
        }
        renderer.scale = effectiveScale
        guard let cgImage = renderer.cgImage else { throw ExportError.bitmap }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw ExportError.encode }
        try data.write(to: url, options: .atomic)
        return CGSize(width: cgImage.width, height: cgImage.height)
    }

    /// Standard print panel. The strip is scaled to the page width and
    /// paginated vertically by AppKit (`verticalPagination = .automatic`).
    static func printLine(_ spec: FamilyTreeLineExportSpec) {
        let hosting = NSHostingView(rootView: FamilyTreeLineStripView(spec: spec))
        hosting.frame = CGRect(origin: .zero, size: hosting.fittingSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = false
        info.topMargin = FamilyTreeLinePage.margin
        info.bottomMargin = FamilyTreeLinePage.margin
        info.leftMargin = FamilyTreeLinePage.margin
        info.rightMargin = FamilyTreeLinePage.margin
        let operation = NSPrintOperation(view: hosting, printInfo: info)
        operation.jobTitle = spec.title
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        appLog.write("Family Tree: print line — \(spec.title)")
        operation.run()
    }

    /// Save panel (Desktop, "<from>-to-<to>-line.pdf"); the extension the
    /// user leaves on the name picks PDF or PNG. `completion` gets the
    /// written URL or the error; nil when cancelled.
    static func exportViaPanel(_ spec: FamilyTreeLineExportSpec,
                               format: UTType = .pdf,
                               completion: @escaping (Result<URL, Error>?) -> Void) {
        let panel = NSSavePanel()
        panel.title = "Export Line"
        panel.allowedContentTypes = [.pdf, .png]
        panel.canSelectHiddenExtension = true
        panel.isExtensionHidden = false
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        panel.nameFieldStringValue = spec.defaultFileBase + "." + (format == .png ? "png" : "pdf")
        panel.begin { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            do {
                if url.pathExtension.lowercased() == "png" {
                    let pixels = try writePNG(spec, to: url)
                    appLog.write("Family Tree: exported line PNG \(Int(pixels.width))×\(Int(pixels.height)) → \(url.path)")
                } else {
                    let pages = try writePDF(spec, to: url)
                    appLog.write("Family Tree: exported line PDF (\(pages.pageCount) page\(pages.pageCount == 1 ? "" : "s")) → \(url.path)")
                }
                completion(.success(url))
            } catch {
                appLog.write("Family Tree: export line failed — \(error.localizedDescription)")
                completion(.failure(error))
            }
        }
    }
}
