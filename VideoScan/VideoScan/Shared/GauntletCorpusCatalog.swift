// GauntletCorpusCatalog.swift
// `-gauntletCorpusCatalog <path>` — the corpus UI lane (scripts/corpus_ui_lane.py,
// docs/guides/operations.md §1a): the REAL app, under XCUITest on the M4, shows
// the real-data corpus's SEALED catalog so its UI can be driven against real
// rows. Read-only through the viewer's own read door (`CatalogViewerSnapshot.load`:
// `openSealedSnapshot`, SQLITE_OPEN_READONLY on a rollback-journal file, nothing
// created beside it) — the same records a viewer Mac adopts, adopted the same way
// (records, then the search index).
//
// THE SEAL (fail closed; `refusal` is one pure function over injected facts,
// pinned by GauntletCorpusCatalogTests). Every condition must hold, or nothing is
// read and one log line says which word refused:
//   - this process is a test host (VS_UI_TEST=1 under XCUITest);
//   - this Mac is the M4 (by its own name); never the M5 Ultra;
//   - the real home (the account database, not $HOME) holds
//     corpus/THIS_IS_TEST_DATA.txt;
//   - the catalog IS ~/corpus/state/catalog.sqlite (symlinks followed), with its
//     catalog.cutover beside it;
//   - $HOME resolves INSIDE a run folder under ~/corpus/work (the lane makes it,
//     and removes it after the run), and Application Support resolves inside
//     $HOME — so every cache the app writes about family media stays in the
//     corpus box and goes with the run. Never the real ~/Library;
//   - after the read: every record is under ~/corpus/media (`recordsRefusal`).
// A shipped app ignores the seam: `GauntletSeams` reads nothing unless
// `TestEnvironment.isTestHost`, and the seal re-checks it.
//
// Nothing here writes: the store under a test host is inert (CatalogStore), the
// snapshot is opened sealed, and no Master Archive is named (the sealed catalog
// carries none; the app's designation lives in the redirected prefs).
//
// Privacy: the log lines carry counts and refusal words only — never a path.
//
// Memory: the corpus's records (234 today) and their search index; the read
// peaks at about twice the loaded rows (SQLiteCatalogLoader's note).
//
// (For Rick: a caseless `enum` with statics ≈ a C++ namespace of free
// functions; `@MainActor` ≈ "runs on the UI thread".)

import Foundation
import VideoScanCore

/// Everything the seal decides from: the process fills it, the tests fill it by hand.
struct GauntletCorpusSealInput: Equatable {
    var isTestHost: Bool
    var hostname: String
    /// From the account database (getpwuid), never $HOME.
    var realHome: String
    var catalogPath: String
    /// $HOME as the app sees it.
    var home: String
    /// FileManager's Application Support for this process.
    var applicationSupport: String
}

enum GauntletCorpusCatalog {

    static let seamKey = "gauntletCorpusCatalog"
    static let allowedHosts: Set<String> = ["ricksm4"]
    static let marker = "THIS_IS_TEST_DATA.txt"
    static let databaseFileName = "catalog.sqlite"
    static let latchFileName = "catalog.cutover"

    // MARK: - Paths

    /// The path with every symlink followed (realpath(3)); a path that does
    /// not exist yet is resolved through its deepest existing folder, the rest
    /// appended as written. nil — contained by nothing — for a relative path,
    /// a `..` anywhere (text would cancel `link/..` before the link is
    /// followed), or a path that cannot be resolved.
    static func resolved(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        var url = URL(fileURLWithPath: path)
        var tail: [String] = []
        var info = stat()
        while lstat(url.path, &info) != 0, url.path != "/" {
            tail.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
        guard let real = realpath(url.path, nil) else { return nil }
        defer { free(real) }
        return tail.reduce(String(cString: real)) { ($0 as NSString).appendingPathComponent($1) }
    }

    /// Strictly below `root` (not equal to it), both resolved.
    static func isStrictlyUnder(_ path: String, _ root: String) -> Bool {
        guard let p = resolved(path), let r = resolved(root) else { return false }
        return p.hasPrefix(r + "/")
    }

    static func shortHost(_ name: String) -> String {
        (name.split(separator: ".").first.map(String.init) ?? "").lowercased()
    }

    // MARK: - The seal

    /// nil when the seal holds; otherwise the refusal word (never a path).
    static func refusal(_ input: GauntletCorpusSealInput,
                        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard input.isTestHost else { return "not_a_test_host" }
        guard allowedHosts.contains(shortHost(input.hostname)) else { return "not_the_m4" }
        let corpus = input.realHome + "/corpus"
        guard fileExists(corpus + "/" + marker) else { return "no_test_data_marker" }
        guard let catalog = resolved(input.catalogPath),
              let state = resolved(corpus + "/state"),
              catalog == state + "/" + databaseFileName,
              fileExists(catalog) else { return "catalog_is_not_the_sealed_corpus_catalog" }
        guard fileExists(state + "/" + latchFileName) else { return "no_latch_beside_the_catalog" }
        // $HOME inside a run folder under ~/corpus/work (work/<run>/…, never work itself).
        guard homeIsInARunFolder(input) else { return "home_not_sealed" }
        guard isStrictlyUnder(input.applicationSupport, input.home) else { return "home_not_sealed" }
        return nil
    }

    /// $HOME resolves inside a run folder under the real ~/corpus/work.
    static func homeIsInARunFolder(_ input: GauntletCorpusSealInput) -> Bool {
        isStrictlyUnder(input.home, input.realHome + "/corpus/work")
    }

    /// Where the seam says what it did, for the lane to read back (the app
    /// log is a NullLogSink under a test host): `<HOME>/corpus-ui-seam.txt`,
    /// ONLY when HOME is proven inside a run folder — never anywhere else.
    static func statusFile(_ input: GauntletCorpusSealInput) -> String? {
        guard homeIsInARunFolder(input), let home = resolved(input.home) else { return nil }
        return home + "/" + statusFileName
    }

    static let statusFileName = "corpus-ui-seam.txt"

    /// One line of words and numbers ("refused home_not_sealed",
    /// "loaded records=234 volumes=9"), appended. Never a path.
    static func writeStatus(_ line: String, _ input: GauntletCorpusSealInput) {
        guard let file = statusFile(input) else { return }
        FileManager.default.createFile(atPath: file, contents: nil)   // no-op when it exists
        guard let handle = FileHandle(forWritingAtPath: file) else { return }
        handle.seekToEndOfFile()
        handle.write(Data((line + "\n").utf8))
        try? handle.close()
    }

    /// After the read: every record lies under ~/corpus/media. nil = holds.
    static func recordsRefusal(paths: [String], mediaRoot: String) -> String? {
        let root = mediaRoot.hasSuffix("/") ? mediaRoot : mediaRoot + "/"
        let outside = paths.contains { !$0.hasPrefix(root) || $0.split(separator: "/").contains("..") }
        return outside ? "a_record_is_outside_the_corpus" : nil
    }

    /// One scan target per corpus volume: `<media>/Volumes/<Name>` for a record
    /// laid out that way, else the media root itself. Sorted, unique.
    static func volumeRoots(paths: [String], mediaRoot: String) -> [String] {
        let volumes = mediaRoot + "/Volumes/"
        var roots = Set<String>()
        for path in paths {
            if path.hasPrefix(volumes), let name = path.dropFirst(volumes.count).split(separator: "/").first,
               path.dropFirst(volumes.count).contains("/") {
                roots.insert(volumes + name)
            } else {
                roots.insert(mediaRoot)
            }
        }
        return roots.sorted()
    }

    // MARK: - The process's facts

    static func realHome() -> String {
        guard let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir else { return "/nonexistent" }
        return String(cString: dir)
    }

    static func hostname() -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        guard gethostname(&buffer, buffer.count - 1) == 0 else { return "" }
        return String(bytes: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, encoding: .utf8) ?? ""
    }

    static func currentInput(catalogPath: String) -> GauntletCorpusSealInput {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path ?? "/"
        return GauntletCorpusSealInput(isTestHost: TestEnvironment.isTestHost, hostname: hostname(),
                                       realHome: realHome(), catalogPath: catalogPath,
                                       home: NSHomeDirectory(), applicationSupport: appSupport)
    }

    // MARK: - Install (restoreScanTargets' test-host branch)

    /// Seal, then read off the launch path and adopt: one scan target per
    /// corpus volume, the records, the search index. A refusal adopts nothing.
    @MainActor
    static func installIfRequested(into model: VideoScanModel) {
        guard let path = GauntletSeams.corpusCatalogPath else { return }
        let input = currentInput(catalogPath: path)
        if let word = refusal(input) {
            model.log("Gauntlet corpus catalog refused: \(word).")
            writeStatus("refused \(word)", input)
            return
        }
        let mediaRoot = realHome() + "/corpus/media"
        Task { @MainActor [weak model] in
            let outcome = await CatalogViewerSnapshot.load(URL(fileURLWithPath: path))
            guard let model else { return }
            guard case .loaded(let result) = outcome else {
                model.log("Gauntlet corpus catalog refused: would_not_open.")
                writeStatus("refused would_not_open", input)
                return
            }
            let paths = result.records.map(\.fullPath)
            if let word = recordsRefusal(paths: paths, mediaRoot: mediaRoot) {
                model.log("Gauntlet corpus catalog refused: \(word).")
                writeStatus("refused \(word)", input)
                return
            }
            let roots = volumeRoots(paths: paths, mediaRoot: mediaRoot)
            for root in roots where !model.scanTargets.contains(where: { $0.searchPath == root }) {
                let target = CatalogScanTarget(searchPath: root)
                target.lastScannedDate = Date()
                model.scanTargets.append(target)
            }
            model.records = result.records
            model.searchIndex.rebuild(records: model.records)
            model.log("Gauntlet corpus catalog: \(result.records.count) records, \(roots.count) volumes, read-only.")
            writeStatus("loaded records=\(result.records.count) volumes=\(roots.count)", input)
        }
    }
}
