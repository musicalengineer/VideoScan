// ObservationsTests.swift — the Observations window (Observations/,
// docs/design/file_dossier_view.md Part II). Streamlined (Rick 11/06: an
// experiment) — the thin safety net:
//   LOGIC    ObservationsStoreTests: a load publishes the report for the
//            scope it was read for; a short query clears; a failure is words.
//   SENSOR   ObservationsSensorTests: no `extension VideoScanModel`, no
//            records walk, read-only (no INSERT/UPDATE/DELETE/write in the
//            module, Core's SQL included), the search SQL matches observation
//            columns only — never filename / path / notes / tags / stars /
//            places (Rick 11/06: machine observations only); the three entry
//            points use the ONE door; the dossier is the one loader; reads
//            run off the main actor; never yellow.
//   MOCKUP   ObservationsMockupTests renders the real view from a synthetic
//            report (light, dark, and the hits) through ImageRenderer; with
//            VIDEOSCAN_MOCKUP_DIR set the PNGs are written there (.scratch only).
// Synthetic names only.

import AppKit
import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

private enum Fixture {
    typealias R = ObservationsReport
    typealias Row = ObservationsReport.Row

    static func files(_ label: String, _ n: Int, source: String, evidence: String? = nil, standing: R.Standing = .observation) -> Row {
        Row(label: label, value: R.files(n), count: n, source: source, evidence: evidence, standing: standing)
    }

    /// A believable synthetic report (names are made up).
    static func report(scope: ObservationsScope = .everything) -> ObservationsReport {
        let probe = "ffprobe"
        let technical = R.Tier(layer: .technical, summary: "4 format readings · most common: DV camcorder/deck capture, NTSC 720×480 (61 files)", groups: [
            R.Group(title: "Format readings", rows: [
                files("DV camcorder/deck capture, NTSC 720×480", 61, source: "TechnicalReading over the probe facts", evidence: "one reading per probe tuple"),
                files("ProRes transfer master 720×480 interlaced: carrier unknown", 22, source: "TechnicalReading over the probe facts"),
                files("camera-native hevc 3840×2160 from Apple iPhone 13", 9, source: "TechnicalReading over the probe facts"),
                files("h264 1920×1080 29.97 fps in mp4", 7, source: "TechnicalReading over the probe facts"),
            ]),
            R.Group(title: "Containers", rows: [files("DV (Digital Video)", 61, source: probe, evidence: "raw DV stream", standing: .fact),
                                               files("QuickTime / MOV", 31, source: probe, standing: .fact), files("MP4", 7, source: probe, standing: .fact)]),
            R.Group(title: "Video codecs", rows: [files("dvvideo", 61, source: "ffprobe (first video stream)", standing: .fact),
                                                 files("prores", 22, source: "ffprobe (first video stream)", standing: .fact),
                                                 files("hevc", 9, source: "ffprobe (first video stream)", standing: .fact)]),
            R.Group(title: "Embedded creation dates", rows: [
                Row(label: "2000s", value: R.files(58), count: 58, source: "embedded tag", evidence: "58 files when the DV was copied to a computer, not shot", standing: .observation),
                Row(label: "2020s", value: R.files(9), count: 9, source: "embedded tag", evidence: "9 files almost certainly the recording date (device tags present)", standing: .observation),
            ]),
            R.Group(title: "Probe", rows: [files("Probed", 99, source: probe, standing: .fact), files("Not probed yet", 1, source: probe, standing: .missing),
                                          files("Probe failed", 0, source: probe, standing: .missing)]),
        ])
        let era = "8B era, unconfirmed"
        let patterns = R.Tier(layer: .patterns, summary: "71 files with a machine era · 88 files with scenes described · 64 files with speech", groups: [
            R.Group(title: "Machine era", rows: [
                files("1980s", 14, source: era, evidence: "middle year in this decade"), files("1990s", 48, source: era), files("2000s", 9, source: era),
                files("Reading: early 1990s (1991–1995)", 31, source: era), files("Reading: late 1980s (1987–1989)", 12, source: era),
                files("No usable era", 11, source: era, standing: .nothingFound), files("Given up", 3, source: era, standing: .missing),
                files("Rejected by you", 2, source: "Rick", standing: .fact), files("Not analyzed yet", 12, source: era, standing: .missing),
            ]),
            R.Group(title: "Burned-in dates", rows: [files("1991-07-04", 3, source: "8B date reader, unconfirmed"), files("1988-12-25", 2, source: "8B date reader, unconfirmed")]),
            R.Group(title: "Scenes described", rows: [files("Files with scenes described", 88, source: "qwen3-vl-8b"),
                                                     Row(label: "Frames described", value: "1,412 frames", count: 1412, source: "qwen3-vl-8b", standing: .observation),
                                                     files("No scenes described", 2, source: "qwen3-vl-8b", standing: .nothingFound),
                                                     files("Not described yet", 9, source: "scene captions", standing: .missing)]),
            R.Group(title: "Most described", rows: [("tree", 212), ("cake", 97), ("beach", 88), ("snow", 61), ("dog", 44), ("lake", 39)].map {
                Row(label: $0.0, value: "\($0.1) mentions", count: $0.1, source: "qwen3-vl-8b captions, counted words", standing: .observation) }),
            R.Group(title: "Speech", rows: [files("Files with speech", 64, source: "whisper-medium"), files("No speech found", 21, source: "whisper-medium", standing: .nothingFound),
                                           files("Not transcribed yet", 14, source: "transcript", standing: .missing),
                                           Row(label: "Words in all", value: "183,402 words", count: 183_402, source: "whisper-medium", standing: .observation)]),
            R.Group(title: "Most said", rows: [("birthday", 140), ("grandma", 96), ("camera", 71), ("presents", 55)].map {
                Row(label: $0.0, value: "\($0.1) mentions", count: $0.1, source: "whisper-medium transcripts, counted words", standing: .observation) }),
            R.Group(title: "People the machine found", rows: [files("Donna (detected)", 23, source: "face recognition, unconfirmed"),
                                                             files("Rick (suspected)", 11, source: "face recognition, unconfirmed"),
                                                             files("Confirmed by you (the comparison)", 40, source: "Rick", standing: .fact)]),
            R.Group(title: "Events", rows: [Row(label: "Christmas 1990", value: "6 files · confirmed by you", count: 6, source: "related-score ladder", standing: .fact)]),
        ])
        let collection = R.Tier(layer: .collection, summary: "100 files · 41 h 12 m · 89 % analyzed by a machine", groups: [
            R.Group(title: "This scope", rows: [
                Row(label: "Files", value: "100 files · 99 distinct contents", count: 100, source: "catalog.sqlite", standing: .fact),
                Row(label: "Duration in all", value: "41 h 12 m", count: 148_320, source: probe, standing: .fact),
                Row(label: "Analyzed by any machine", value: "89 files (89 %)", count: 89, source: "every analyzer", standing: .observation),
                Row(label: "Nothing yet", value: "11 files (11 %)", count: 11, source: "every analyzer", standing: .missing),
                files("Observed in the last 24 h", 37, source: "every analyzer"),
            ]),
            R.Group(title: "Machine eras across the collection", rows: [
                Row(label: "Agrees with your date within 5 years", value: "17 of 21 (81 %)", count: 17, source: "comparison with your dates", standing: .fact),
                Row(label: "Span of machine eras", value: "1984–2009", count: 26, source: "era analyzers", standing: .observation),
            ]),
            R.Group(title: "Models and runs", rows: [files("Scene captions · qwen3-vl-8b", 90, source: "qwen3-vl-8b", evidence: "first run 2026-10-28, last run 2026-11-06", standing: .fact),
                                                    files("Transcripts · whisper-medium", 85, source: "whisper-medium", standing: .fact),
                                                    files("Era · 8B", 85, source: "machine:qwen3-vl-8b-4bit/era-v1/window-60s@r3", standing: .fact)]),
            R.Group(title: "Speech en masse", rows: [Row(label: "Words in all transcripts", value: "183,402 words", count: 183_402, source: "whisper-medium", standing: .observation),
                                                    Row(label: "Average per transcript", value: "2,865 words", count: 2865, source: "whisper-medium", standing: .observation)]),
        ])
        return ObservationsReport(scope: scope, files: 100, contents: 99, analyzed: 89, technical: technical, patterns: patterns, collection: collection,
                                  builtAt: 1_762_470_000)
    }

    static func hits(_ q: String) -> ObservationsSearch {
        typealias H = ObservationsSearch.Hit
        let hits = [
            H(id: "1", kind: .scene, text: "a living room with a christmas tree and wrapped presents", at: 12, source: "qwen3-vl-8b", digest: "a", recordID: UUID(), filename: "Christmas_1990.dv", path: "/V/tapes/Christmas_1990.dv", removed: false),
            H(id: "2", kind: .scene, text: "children opening presents under the tree", at: 84, source: "qwen3-vl-8b", digest: "a", recordID: UUID(), filename: "Christmas_1990.dv", path: "/V/tapes/Christmas_1990.dv", removed: false),
            H(id: "3", kind: .speech, text: "…and we opened the presents before breakfast, the dog went straight for the wrapping…", at: nil, source: "whisper-medium", digest: "b", recordID: UUID(), filename: "Xmas_morning_1992.dv", path: "/V/tapes/Xmas_morning_1992.dv", removed: false),
            H(id: "4", kind: .event, text: "Christmas 1990", at: nil, source: "related-score ladder · confirmed by you", digest: "a", recordID: UUID(), filename: "Christmas_1990.dv", path: "/V/tapes/Christmas_1990.dv", removed: false),
        ]
        return ObservationsSearch(query: q, hits: hits, truncated: false, counts: [.scene: 2, .speech: 1, .event: 1])
    }

    @MainActor
    static func loader(report: @escaping @Sendable (ObservationsScope) throws -> ObservationsReport = { Fixture.report(scope: $0) },
                       search: @escaping @Sendable (String) throws -> ObservationsSearch = { Fixture.hits($0) },
                       notes: Notes = Notes()) -> ObservationsLoader {
        ObservationsLoader(loadReport: { scope in try report(scope) }, search: { _, q in try search(q) },
                           reveal: { _ in true }, dossiers: nil, note: { notes.lines.append($0) })
    }

    @MainActor final class Notes { var lines: [String] = [] }
}

// MARK: - LOGIC

@Suite("Observations — the store")
@MainActor
struct ObservationsStoreTests {

    @Test func aLoadPublishesTheReportForItsScopeAndAShortQueryClears() async throws {
        let notes = Fixture.Notes()
        let store = ObservationsStore(scope: .folder("/V/tapes"), loader: Fixture.loader(notes: notes))
        await store.load()
        #expect(store.report?.scope == .folder("/V/tapes") && store.report?.files == 100 && store.failure == nil && store.reads == 1)
        #expect(notes.lines.first?.hasPrefix("read the folder /V/tapes: 100 files, 89 analyzed") == true)
        await store.search("presents")
        #expect(store.search?.hits.count == 4 && store.search?.counts[.scene] == 2)
        await store.search("x")
        #expect(store.search == nil, "two characters minimum: the hits clear")
        await store.set(scope: .everything)
        #expect(store.report?.scope == .everything && store.search == nil, "a new scope re-reads and drops the old hits")
    }

    @Test func aFailureIsWordsAndIsLoggedOnce() async throws {
        let notes = Fixture.Notes()
        let store = ObservationsStore(scope: .everything, loader: Fixture.loader(report: { _ in throw Refusal("catalog.sqlite is not open") }, notes: notes))
        await store.load()
        await store.load()
        #expect(store.report == nil && store.failure?.contains("not open") == true)
        #expect(notes.lines.filter { $0.contains("could not be read") }.count == 1)
    }
}

// MARK: - SENSOR

@Suite("Observations — sensors (one door, read-only, observations only)")
struct ObservationsSensorTests {

    private let module = ["ObservationsStore.swift", "ObservationsWindow.swift", "CatalogRowContextMenu+Observations.swift"]
    private func code(_ file: String) throws -> String { try SourceTree.appCode(named: file) }

    /// Core's files, by path from the app root (SourceTree has no Core lookup).
    private func core(_ relative: String) throws -> String {
        let url = SourceTree.appSourceRoot.deletingLastPathComponent().appendingPathComponent("VideoScanCore/Sources/VideoScanCore/" + relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records", "for rec in records", "records.reduce", "records.first", "records.count"]

    @Test func noModelExtensionAndNoRecordsWorkAndTheViewReadsOneStore() throws {
        for file in module {
            let src = try code(file)
            #expect(!src.contains("extension VideoScanModel"), "rule 12: \(file)")
            for walk in recordsWalks { #expect(!src.contains(walk), "\(file) walks records: `\(walk)`") }
        }
        let view = try code("ObservationsWindow.swift")
        #expect(!view.contains("@EnvironmentObject") && !view.contains("model."), "the view observes one store; the controller holds the model")
        #expect(!view.contains(".yellow"), "DECISIONS 2026-11-03: never yellow")
    }

    @Test func everythingIsReadOnly() throws {
        let sources = try module.map(code) + [try core("Observations/ObservationsReport.swift"), try core("Observations/ObservationsSearch.swift"),
                                               try core("Observations/ObservationsScope.swift"), try core("Store/CatalogObservationsRows.swift"),
                                               try core("Store/GRDBCatalogRepository+Observations.swift")]
        for src in sources {
            for forbidden in ["INSERT", "UPDATE ", "DELETE", "writeBlocking", "write(as", "commit(as", "appendProvenanceAssertion", "FileHandle(forWritingTo", "write(to:"] {
                #expect(!src.contains(forbidden), "read-only: `\(forbidden)`")
            }
        }
        #expect(try core("Store/GRDBCatalogRepository+Observations.swift").contains("extension GRDBReader: CatalogObservationsReading"), "the READ handle only")
        #expect(!(try core("Store/GRDBCatalogRepository+Observations.swift")).contains("GRDBTransaction"), "never the transaction handle")
    }

    @Test func theSearchMatchesObservationColumnsOnlyNeverACatalogField() throws {
        let sql = try core("Store/GRDBCatalogRepository+Observations.swift")
        for never in ["user_notes", "workflow_tags", "user_places", "stars", "family_music", "dispositions", "machine_notes"] {
            #expect(!sql.contains(never), "Rick 11/06: machine observations only — `\(never)` is a catalog field")
        }
        #expect(sql.components(separatedBy: "user_dates").count == 3, "Rick's date is read once (the agreement comparison): \(sql.components(separatedBy: "user_dates").count - 1) mentions")
        // Every LIKE in the search is on an observation's text column.
        let start = try #require(sql.range(of: "func observationTextHits"))
        let end = try #require(sql.range(of: "private static func hit("))
        let search = String(sql[start.lowerBound..<end.lowerBound])
        let likes = search.components(separatedBy: "\\(like)").dropLast()
        #expect(likes.count == 7, "seven observation kinds")
        for before in likes {
            let column = before.split(whereSeparator: { $0 == " " || $0 == "\n" }).last.map(String.init) ?? ""
            #expect(["c.text", "t.text", "a.value", "p.name", "e.name"].contains(column), "LIKE on `\(column)` is not an observation column")
        }
        for never in ["filename LIKE", "full_path LIKE", "directory LIKE", "filename \\(like)", "full_path \\(like)", "directory \\(like)"] {
            #expect(!search.contains(never), "a file name or path is never matched")
        }
        #expect(!search.contains("instr(lower(f."), "the snippet window is cut from the transcript, never a catalog field")
        #expect(try core("Observations/ObservationsSearch.swift").contains("minimumQuery = 2"))
    }

    @Test func theThreeEntryPointsUseTheOneDoorAndTheDossierIsTheOneLoader() throws {
        let door = "ObservationsWindowController.shared.show(model: model, scope:"
        #expect(try code("AnalyzePanelView.swift").contains(door + " .everything, source: \"panel\")"), "Content Analysis ▸ Observations…")
        #expect(try code("CatalogRowContextMenu+Observations.swift").contains("source: \"catalog-row\")"), "the catalog row menu")
        #expect(try code("CatalogRowContextMenu.swift").contains("observationsItem(selectedRecs: selection.selected)"), "in the row menu's find group")
        #expect(try code("RealtimeAnalysisStore.swift").contains("source: \"realtime-pass\")"), "the Realtime window's See what we learned")
        #expect(try code("RealtimeContentAnalysisWindow.swift").contains("store.seeWhatWeLearned()"), "the view asks the store, not the controller")
        let window = try code("ObservationsWindow.swift")
        #expect(window.components(separatedBy: "ObservationsStore(scope:").count == 2, "one store per window, built once by the controller")
        #expect(window.components(separatedBy: "ObservationsLoader.production(model: model)").count == 2, "the one loader")
        let store = try code("ObservationsStore.swift")
        #expect(store.contains("dossiers: FileDossierLoader.production(model: model)") && !store.contains("FileDossierLoader("), "the one dossier door")
        #expect(store.contains("model.showInCatalog(recordID: id)") && store.contains("model.canNavigateToRecord(id: id)"), "the one reveal door")
        #expect(store.contains("Task.detached(priority: .userInitiated)"), "reads run off the main actor")
        #expect(store.contains("repository.read {"), "inside the repository's read snapshot")
    }
}

// MARK: - MOCKUPS (rendered from the real view)

@Suite("Observations — the view renders (mockups)")
@MainActor
struct ObservationsMockupTests {

    private func render(_ label: String, dark: Bool, hits: Bool) async throws -> CGImage {
        let store = ObservationsStore(scope: .everything, loader: Fixture.loader())
        await store.load()
        if hits { await store.search("presents") }
        let content = ObservationsContent(store: store, expanded: [.technical, .patterns, .collection], mockup: true)
        let view = hits ? AnyView(content.hitsForMockup.frame(width: 980, alignment: .top)) : AnyView(content.tiersForMockup.frame(width: 980, alignment: .top))
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, dark ? .dark : .light))
        renderer.scale = 2
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var rendered: CGImage?
        appearance?.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
        let image = try #require(rendered, "\(label) rendered")
        #expect(image.width == 1960 && image.height > 600, "\(label): \(image.width)×\(image.height)")
        // Thin dark text on white reads ≈ 9 ‰; the dark theme ≈ 15 ‰ (a blank render is 0).
        let ink = Self.inkFraction(image)
        #expect(ink > 0.005, "\(label): \(Int(ink * 1000)) ‰ of the pixels are not background")
        if let dir = ProcessInfo.processInfo.environment["VIDEOSCAN_MOCKUP_DIR"], !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(label).png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let rep = NSBitmapImageRep(cgImage: image)
            try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        }
        return image
    }

    private static func inkFraction(_ image: CGImage) -> Double {
        guard let data = image.dataProvider?.data as Data?, image.bitsPerPixel == 32 else { return 0 }
        let row = image.bytesPerRow
        var ink = 0, seen = 0
        let bg = (data[0], data[1], data[2])
        for y in stride(from: 0, to: image.height, by: 4) {
            for x in stride(from: 0, to: image.width, by: 4) {
                let i = y * row + x * 4
                seen += 1
                if abs(Int(data[i]) - Int(bg.0)) > 24 || abs(Int(data[i + 1]) - Int(bg.1)) > 24 || abs(Int(data[i + 2]) - Int(bg.2)) > 24 { ink += 1 }
            }
        }
        return seen > 0 ? Double(ink) / Double(seen) : 0
    }

    @Test func tiersLight() async throws { _ = try await render("MOCKUP-observations-tiers-light", dark: false, hits: false) }
    @Test func tiersDark() async throws { _ = try await render("MOCKUP-observations-tiers-dark", dark: true, hits: false) }
    @Test func hitsDark() async throws { _ = try await render("MOCKUP-observations-hits-dark", dark: true, hits: true) }
}
