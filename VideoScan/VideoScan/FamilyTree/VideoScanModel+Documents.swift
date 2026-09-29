// VideoScanModel+Documents.swift
// Adding documents to the catalog (2026-08-31).
//
// Rick, on whether the app should know about promoted PDFs: "I think yes
// so we can search them."

import Foundation
import AppKit

extension VideoScanModel {

    /// Add chosen documents to the catalog. Duplicates by path are
    /// skipped rather than doubling a record — picking the same folder
    /// twice is an ordinary thing to do, not an error worth a dialog.
    ///
    /// Returns what happened so the caller can tell the user the truth
    /// about partial success.
    @MainActor
    @discardableResult
    func addDocuments(urls: [URL]) -> DocumentIngest.Outcome {
        var outcome = DocumentIngest.makeRecords(urls: urls)

        let known = Set(records.map(\.fullPath))
        let (fresh, duplicates) = outcome.records
            .reduce(into: ([VideoRecord](), [VideoRecord]())) { acc, rec in
                if known.contains(rec.fullPath) { acc.1.append(rec) } else { acc.0.append(rec) }
            }
        outcome.records = fresh

        for rec in fresh {
            records.append(rec)
            // Without this the document is in the catalog but invisible
            // to search until the next full rebuild.
            searchIndex.update(rec)
        }

        if !fresh.isEmpty {
            log("📄 Added \(fresh.count) document\(fresh.count == 1 ? "" : "s") to the catalog")
            for rec in fresh { log("    → \(rec.filename) (\(rec.size))") }
            saveCatalogDebounced()
            indexDocumentText(for: fresh)
        }
        if !duplicates.isEmpty {
            log("📄 Skipped \(duplicates.count) already in the catalog")
        }
        for (url, why) in outcome.rejected {
            log("⚠️ Skipped \(url.lastPathComponent) — it \(why.message)")
        }
        return outcome
    }

    /// Read each document's text and fold it into the search index.
    ///
    /// Runs after the records are already in the catalog, so the
    /// documents are visible immediately and the text arrives when it
    /// arrives — a scanned certificate needs optical recognition, which
    /// takes seconds per page, and blocking the add on that would make
    /// picking ten files feel broken.
    @MainActor
    func indexDocumentText(for newRecords: [VideoRecord]) {
        Task { [weak self] in
            for rec in newRecords {
                let url = URL(fileURLWithPath: rec.fullPath)
                let extraction = await DocumentTextExtractor.extract(url: url)
                guard let self else { return }

                guard !extraction.isEmpty else {
                    // Say so rather than leaving a silent gap: a .docx or
                    // a blank scan produces nothing, and a person
                    // searching for it later deserves to know why it
                    // never turns up.
                    self.log("    · No searchable text in \(rec.filename)")
                    continue
                }
                rec.ocrText = extraction.captions
                // Per-record refresh, not a full rebuild: the index is
                // O(n) to rebuild and a document add is a handful of
                // rows in a catalog of tens of thousands.
                self.searchIndex.update(rec)
                let how = extraction.usedOCR ? "read the scan" : "read the text layer"
                let pages = extraction.pages.filter { !$0.text.isEmpty }.count
                let cut = extraction.truncated ? ", truncated" : ""
                self.log("    · \(rec.filename): \(how), \(pages) page\(pages == 1 ? "" : "s") indexed\(cut)")
            }
            self?.saveCatalogDebounced()
        }
    }

    /// Open the picker, then add whatever was chosen. Folders are allowed
    /// and are walked one level deep for documents: dropping in a folder
    /// of scanned certificates should not mean picking them one by one,
    /// but a recursive walk would quietly hoover up an entire drive.
    @MainActor
    func promptForDocuments() {
        let panel = NSOpenPanel()
        panel.title = "Add Documents to the Catalog"
        panel.message = "Choose birth certificates, letters, records, or a folder of them."
        panel.prompt = "Add"
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.resolvesAliases = true

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        addDocuments(urls: Self.expandDocumentPicks(panel.urls))
    }

    /// Files stay as picked; a picked folder contributes its immediate
    /// children. One level only, and deliberately so — see above.
    static func expandDocumentPicks(_ urls: [URL],
                                    fileManager: FileManager = .default) -> [URL] {
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let children = (try? fileManager.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])) ?? []
                // Only the documents — a folder of certificates often has
                // a stray thumbnail or note beside them, and refusing the
                // whole folder over that would be obnoxious.
                out.append(contentsOf: children.filter {
                    ArchiveMedium.forFilename($0.lastPathComponent) == .document
                })
            } else {
                out.append(url)
            }
        }
        return out
    }
}
