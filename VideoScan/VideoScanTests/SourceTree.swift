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

    @Test func aFileOutsideTheRootIsRefusedLoudly() {
        withKnownIssue("relativePath records an Issue for a file outside the root") {
            #expect(SourceTree.relativePath(URL(fileURLWithPath: "/usr/bin/true"),
                                            under: URL(fileURLWithPath: "/tmp")) == nil)
        }
    }
}
