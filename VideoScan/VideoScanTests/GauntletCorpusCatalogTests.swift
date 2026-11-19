// GauntletCorpusCatalogTests.swift
// The corpus UI lane's in-app seal (GauntletCorpusCatalog.swift): may the app
// under XCUITest show the M4 corpus's sealed catalog? Pinned by behaviour on
// real folders (symlinks included), never by reading the source.
//
//   LOGIC      the whole seal holds → nil; each condition alone refuses with
//              its own word; records under the media root pass, anything else
//              refuses; one scan target per corpus volume.
//   ISOLATION  poisoned state: a HOME that is the real home, the work folder
//              itself, or a run folder that is a symlink back to the real
//              home; Application Support outside HOME (the real ~/Library); a
//              catalog that is the live App Support catalog, or a symlink in
//              ~/corpus/state pointing at it; `..` in any path; the Ultra by
//              name; not a test host.
//   SCALE      the record check and the volume roots over 100k paths stay
//              inside a 1 s budget.
//   SENSOR     the install is reached only from restoreScanTargets' test-host
//              branch, and the seam getter reads nothing outside a test host.
//   MEDIA      N/A — the seal opens no media.

import Foundation
import Testing
@testable import VideoScan

/// A fake account on disk: <root>/home is the "real home" with a corpus in it.
private struct CorpusFixture {
    let root: URL
    var home: String { root.appendingPathComponent("home").path }
    var corpus: String { home + "/corpus" }
    var catalog: String { corpus + "/state/catalog.sqlite" }
    var runHome: String { corpus + "/work/20261118_220000_1-ui/home" }
    var runAppSupport: String { runHome + "/Library/Application Support" }
    var liveCatalog: String { home + "/Library/Application Support/VideoScan/catalog.sqlite" }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("corpus-seal-\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        for dir in [corpus + "/state", corpus + "/media/Volumes/VolA", corpus + "/work",
                    runHome + "/Library/Application Support", home + "/Library/Application Support/VideoScan"] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        for file in [corpus + "/THIS_IS_TEST_DATA.txt", catalog, corpus + "/state/catalog.cutover", liveCatalog] {
            fm.createFile(atPath: file, contents: Data("x".utf8))
        }
    }

    func input(_ edit: (inout GauntletCorpusSealInput) -> Void = { _ in }) -> GauntletCorpusSealInput {
        var i = GauntletCorpusSealInput(isTestHost: true, hostname: "RicksM4.local", realHome: home,
                                        catalogPath: catalog, home: runHome, applicationSupport: runAppSupport)
        edit(&i)
        return i
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}

@Suite("Corpus UI lane — the in-app seal")
struct GauntletCorpusSealTests {

    @Test("LOGIC: the whole seal holds → nothing refuses")
    func holds() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        #expect(GauntletCorpusCatalog.refusal(f.input()) == nil)
    }

    @Test("ISOLATION: not a test host, or not the M4 (the Ultra by name), refuses")
    func hostAndTestHost() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.isTestHost = false }) == "not_a_test_host")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.hostname = "RicksUltra.local" }) == "not_the_m4")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.hostname = "" }) == "not_the_m4")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.hostname = "ricksm4" }) == nil)
    }

    @Test("ISOLATION: no THIS_IS_TEST_DATA marker refuses")
    func marker() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        try FileManager.default.removeItem(atPath: f.corpus + "/THIS_IS_TEST_DATA.txt")
        #expect(GauntletCorpusCatalog.refusal(f.input()) == "no_test_data_marker")
    }

    @Test("ISOLATION: the live App Support catalog, a symlink to it, a `..` path, a missing latch — all refused")
    func catalogIsTheSealedOne() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.catalogPath = f.liveCatalog })
                == "catalog_is_not_the_sealed_corpus_catalog")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.catalogPath = f.corpus + "/state/../state/catalog.sqlite" })
                == "catalog_is_not_the_sealed_corpus_catalog")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.catalogPath = "catalog.sqlite" })
                == "catalog_is_not_the_sealed_corpus_catalog")
        // ~/corpus/state/catalog.sqlite itself made a symlink to the live catalog.
        try FileManager.default.removeItem(atPath: f.catalog)
        try FileManager.default.createSymbolicLink(atPath: f.catalog, withDestinationPath: f.liveCatalog)
        #expect(GauntletCorpusCatalog.refusal(f.input()) == "catalog_is_not_the_sealed_corpus_catalog")
    }

    @Test("ISOLATION: no catalog.cutover beside the sealed catalog refuses")
    func latch() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        try FileManager.default.removeItem(atPath: f.corpus + "/state/catalog.cutover")
        #expect(GauntletCorpusCatalog.refusal(f.input()) == "no_latch_beside_the_catalog")
    }

    @Test("ISOLATION: HOME must be inside a run folder under ~/corpus/work, App Support inside HOME")
    func homeSealed() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.home = f.home }) == "home_not_sealed")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.home = f.corpus + "/work" }) == "home_not_sealed")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.home = f.corpus + "/state/home" }) == "home_not_sealed")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.applicationSupport = f.home + "/Library/Application Support" })
                == "home_not_sealed")
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.home = f.corpus + "/work/../work/x" }) == "home_not_sealed")
        // A run folder that is a symlink back to the real home.
        let trap = f.corpus + "/work/trap"
        try FileManager.default.createSymbolicLink(atPath: trap, withDestinationPath: f.home)
        #expect(GauntletCorpusCatalog.refusal(f.input { $0.home = trap; $0.applicationSupport = trap + "/Library/Application Support" })
                == "home_not_sealed")
    }

    @Test("ISOLATION: the status line is written only inside a proven run HOME — never the real home or ~/corpus/work itself")
    func statusFileOnlyInsideTheRun() throws {
        let f = try CorpusFixture()
        defer { f.remove() }
        let runHome = try #require(GauntletCorpusCatalog.resolved(f.runHome))
        #expect(GauntletCorpusCatalog.statusFile(f.input()) == runHome + "/corpus-ui-seam.txt")
        // Written even when another condition refuses (that is when it is needed most).
        #expect(GauntletCorpusCatalog.statusFile(f.input { $0.hostname = "RicksUltra" }) != nil)
        #expect(GauntletCorpusCatalog.statusFile(f.input { $0.home = f.home }) == nil)
        #expect(GauntletCorpusCatalog.statusFile(f.input { $0.home = f.corpus + "/work" }) == nil)
        GauntletCorpusCatalog.writeStatus("refused not_the_m4", f.input { $0.hostname = "RicksUltra" })
        GauntletCorpusCatalog.writeStatus("refused home_not_sealed", f.input { $0.home = f.home })
        #expect(try String(contentsOfFile: runHome + "/corpus-ui-seam.txt", encoding: .utf8) == "refused not_the_m4\n")
        #expect(!FileManager.default.fileExists(atPath: f.home + "/corpus-ui-seam.txt"))
    }

    @Test("LOGIC + ISOLATION: records must lie under ~/corpus/media; `..` and a look-alike root refuse")
    func records() {
        let media = "/Users/x/corpus/media"
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: [media + "/Volumes/A/a.mov", media + "/b.mp4"], mediaRoot: media) == nil)
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: [], mediaRoot: media) == nil)
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: ["/Volumes/A/a.mov"], mediaRoot: media)
                == "a_record_is_outside_the_corpus")
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: [media + "2/a.mov"], mediaRoot: media)
                == "a_record_is_outside_the_corpus")
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: [media + "/Volumes/../../live/a.mov"], mediaRoot: media)
                == "a_record_is_outside_the_corpus")
    }

    @Test("LOGIC: one scan target per corpus volume; a loose file maps to the media root")
    func volumeRoots() {
        let media = "/Users/x/corpus/media"
        let roots = GauntletCorpusCatalog.volumeRoots(paths: [
            media + "/Volumes/B/x/1.mov", media + "/Volumes/A/2.mov", media + "/Volumes/A/d/3.mov", media + "/loose.mov",
        ], mediaRoot: media)
        #expect(roots == [media, media + "/Volumes/A", media + "/Volumes/B"])
    }

    @Test("SCALE: the record check and the volume roots over 100k paths inside 1 s")
    func scale() {
        let media = "/Users/x/corpus/media"
        let paths = (0..<100_000).map { media + "/Volumes/V\($0 % 40)/dir\($0 % 300)/clip_\($0).mov" }
        let started = Date()
        #expect(GauntletCorpusCatalog.recordsRefusal(paths: paths, mediaRoot: media) == nil)
        #expect(GauntletCorpusCatalog.volumeRoots(paths: paths, mediaRoot: media).count == 40)
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("SENSOR: the install is reached only from restoreScanTargets' test-host branch")
    func installOnlyInTheTestHostBranch() throws {
        let here = URL(fileURLWithPath: #filePath)
        let source = here.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/Volumes/VideoScanModel+ScanTargetPersistence.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let branch = try #require(text.range(of: "if Self.isRunningTests {"))
        let returnInBranch = try #require(text.range(of: "return", range: branch.upperBound..<text.endIndex))
        let call = try #require(text.range(of: "GauntletCorpusCatalog.installIfRequested(into: self)"))
        #expect(call.lowerBound > branch.upperBound && call.upperBound < returnInBranch.lowerBound)
        // Exactly one caller in the app.
        let appRoot = here.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("VideoScan")
        var callers = 0
        for case let url as URL in FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil) ?? .init()
            where url.pathExtension == "swift" {
            let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            callers += body.components(separatedBy: "GauntletCorpusCatalog.installIfRequested(").count - 1
        }
        #expect(callers == 1)
    }
}
