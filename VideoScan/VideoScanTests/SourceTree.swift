// SourceTree.swift — test support
//
// ONE way for a test to turn an enumerated file URL into a path relative
// to a root (repo root from #filePath, a scratch dir, …).
//
// Why this exists (M5 battery, 2026-09-22): `FileManager.enumerator(at:)`
// hands back REAL paths — enumerate "/tmp/vs-battery/VideoScan" and you
// get "/private/tmp/vs-battery/VideoScan/…" (likewise /var → /private/var).
// #filePath keeps whatever spelling the build was invoked with. A plain
// `replacingOccurrences(of: root + "/")` / `dropFirst(root.count + 1)`
// then silently produced "/privateVideoScan/…" and the source sensors
// compared garbage. `standardizedFileURL` / `resolvingSymlinksInPath`
// only half-fix it: both special-case a leading "/private" (they STRIP it,
// so /tmp and /var happen to line up) but neither helps a checkout reached
// through any other symlink. realpath(3) is the kernel's canonical
// spelling for every case, so both sides go through it.
//
// (For Rick: think of `realpath` exactly as in C — this is a thin wrapper
// so every call site shares one implementation instead of N hand-rolled
// string slices.)

import Foundation
import Testing

enum SourceTree {

    /// The canonical absolute path (symlinks resolved, "/private" kept).
    /// Falls back to the standardized spelling when the path does not
    /// exist (realpath needs a real file).
    static func canonicalPath(_ url: URL) -> String {
        let std = url.standardizedFileURL.path
        guard let resolved = realpath(std, nil) else { return std }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `url` relative to `root` ("VideoScan/Foo.swift"), comparing the
    /// canonical spellings of both. nil — and a recorded Issue, so a
    /// sensor can never pass by reading nothing — when `url` is not
    /// inside `root`.
    static func relativePath(_ url: URL, under root: URL,
                             sourceLocation: SourceLocation = #_sourceLocation) -> String? {
        let base = canonicalPath(root)
        let full = canonicalPath(url)
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix), full.count > prefix.count else {
            Issue.record("SourceTree: \(full) is not under \(base)", sourceLocation: sourceLocation)
            return nil
        }
        return String(full.dropFirst(prefix.count))
    }

    // MARK: - App sources by NAME (2026-09-29 source-folder reorg)
    //
    // The app sources live in feature folders (Archive/, Hallie/Voice/, …;
    // see docs/source_layout.md). A sensor that hard-codes
    // "VideoScan/Foo.swift" breaks — or, worse, reads nothing — the next
    // time a file moves. Look the file up by NAME instead: the name is
    // unique across the app tree, so a move cannot change the answer.

    /// `VideoScan/VideoScan` — the app target's synchronized source root.
    static let appSourceRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // VideoScanTests/
        .deletingLastPathComponent()        // VideoScan/ (project dir)
        .appendingPathComponent("VideoScan", isDirectory: true)

    struct NotFound: Error, CustomStringConvertible {
        let name: String
        let matches: [String]
        var description: String {
            "SourceTree: \(matches.count) app sources named \(name) (want exactly 1): \(matches)"
        }
    }

    /// Every .swift file under the app root, recursively, keyed by its path
    /// relative to that root ("Archive/ArchiveRefile.swift"). Built once —
    /// `static let` is lazily initialized and thread-safe (≈ a C++ function-
    /// local static).
    static let appSources: [(relative: String, url: URL)] = {
        guard let walk = FileManager.default.enumerator(at: appSourceRoot, includingPropertiesForKeys: nil)
        else { return [] }
        var out: [(String, URL)] = []
        let base = canonicalPath(appSourceRoot) + "/"
        for case let url as URL in walk where url.pathExtension == "swift" {
            let full = canonicalPath(url)
            guard full.hasPrefix(base) else { continue }
            out.append((String(full.dropFirst(base.count)), url))
        }
        return out.sorted { $0.0 < $1.0 }
    }()

    /// The ONE app source file called `name` ("ArchiveRefile.swift"), found
    /// anywhere under `VideoScan/VideoScan`. `name` may carry a folder
    /// suffix ("ArchiveAngel/Prepare/ArchiveAngelPlan.swift") to pin a file
    /// more tightly. nil — and a recorded Issue, so a sensor can never pass
    /// by reading nothing — when zero or several files match.
    static func appSourceURL(named name: String,
                             sourceLocation: SourceLocation = #_sourceLocation) -> URL? {
        let hits = appSources.filter { $0.relative == name || $0.relative.hasSuffix("/" + name) }
        guard hits.count == 1 else {
            Issue.record("\(NotFound(name: name, matches: hits.map(\.relative)))", sourceLocation: sourceLocation)
            return nil
        }
        return hits[0].url
    }

    /// The text of the ONE app source file called `name` (see
    /// `appSourceURL(named:)`); throws when it is missing or ambiguous.
    static func appSource(named name: String,
                          sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        guard let url = appSourceURL(named: name, sourceLocation: sourceLocation) else {
            throw NotFound(name: name, matches: [])
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}

// MARK: - The helper's own sensor (runs from any checkout location)

@Suite("SourceTree — relative paths survive /tmp → /private/tmp")
struct SourceTreeTests {

    @Test func enumeratedURLUnderASymlinkedRootIsRelativeToIt() throws {
        // "/tmp" is a symlink to "/private/tmp" on macOS: build the root with
        // the /tmp spelling (what #filePath carries for a /tmp checkout) and
        // let the enumerator hand back its /private spelling.
        let name = "vs-sourcetree-\(UUID().uuidString.prefix(8))"
        let real = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        FileManager.default.createFile(atPath: real.appendingPathComponent("Sub/A.swift").path, contents: Data())

        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent(name, isDirectory: true)
        let walked = (FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        #expect(walked.count == 1)
        // The naive strip the sensors used to do is exactly what breaks.
        let naive = walked.first.map { $0.path.replacingOccurrences(of: root.path + "/", with: "") }
        #expect(naive != "Sub/A.swift" || walked.first?.path.hasPrefix("/tmp/") == true,
                "fixture: the enumerator is expected to return the /private spelling")
        #expect(walked.first.flatMap { SourceTree.relativePath($0, under: root) } == "Sub/A.swift")
    }

    @Test func appSourcesAreFoundByNameInsideTheirFeatureFolder() throws {
        #expect(SourceTree.appSources.count > 600, "the index must see the whole app tree")
        let url = try #require(SourceTree.appSourceURL(named: "ArchiveRefile.swift"))
        #expect(url.path.hasSuffix("/VideoScan/Archive/ArchiveRefile.swift"))
        // A folder suffix pins a file more tightly.
        #expect(SourceTree.appSourceURL(named: "ArchiveAngel/Prepare/ArchiveAngelJob.swift") != nil)
        #expect(try SourceTree.appSource(named: "main.swift").contains("VideoScanApp.main()"))
    }

    /// Lookup by name is only well-defined while names are unique. A second
    /// file with an existing name must be renamed, not hidden in a folder.
    @Test func everyAppSourceNameIsUnique() {
        let names = SourceTree.appSources.map { ($0.relative as NSString).lastPathComponent }
        let dupes = Dictionary(grouping: names, by: { $0 }).filter { $0.value.count > 1 }.keys.sorted()
        #expect(dupes.isEmpty, "duplicate app source names: \(dupes)")
    }

    @Test func aMissingAppSourceIsRefusedLoudly() {
        withKnownIssue("appSourceURL records an Issue when no file has the name") {
            #expect(SourceTree.appSourceURL(named: "NoSuchFile-\(UUID().uuidString).swift") == nil)
        }
    }

    @Test func aFileOutsideTheRootIsRefusedLoudly() {
        withKnownIssue("relativePath records an Issue for a file outside the root") {
            #expect(SourceTree.relativePath(URL(fileURLWithPath: "/usr/bin/true"),
                                            under: URL(fileURLWithPath: "/tmp")) == nil)
        }
    }
}
