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
    // see docs/guides/source_layout.md). A sensor that hard-codes
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

    /// Something in a source text that `scan` does not understand — after
    /// it, what is a comment and what is code can no longer be told, so a
    /// code-only sensor must not trust the text (codex #258 r4-3).
    struct UnsupportedSyntax: Error, Equatable, CustomStringConvertible {
        /// 1-based.
        let line: Int
        let what: String
        var description: String { "line \(line): \(what)" }
    }

    /// `text` with its comments removed, so a sensor that matches CODE is
    /// never satisfied by the expected text surviving in a comment after
    /// the code itself was removed (codex #258 r2, r3):
    ///   • `// …` to the end of the line;
    ///   • `/* … */`, NESTED as Swift allows, across lines;
    ///   • a line that held nothing but a comment disappears altogether, so
    ///     the code on either side of it stays adjacent.
    /// Text inside a string literal — "…" with its escapes, `"""` blocks,
    /// and a string nested in an interpolation (`"\(n == 1 ? "y" : "ies")"`)
    /// — is not a comment and is kept.
    ///
    /// This is NOT a Swift lexer, and it FAILS CLOSED (codex #258 r4-3):
    /// whatever it does not understand is REPORTED in `unsupported`, never
    /// guessed at — because after such a construct a real comment could be
    /// kept as "code" and satisfy a sensor:
    ///   • a raw string or an extended regex literal (`#"…"#`, `#/…/#`);
    ///   • a comment inside a string interpolation (`"\(/* … */ 0)"`);
    ///   • what may be a bare regex literal (`/…/` where an expression can
    ///     begin — a conservative textual test; `a / b` and `a/b` are division).
    static func scan(_ text: String) -> (code: String, unsupported: [UnsupportedSyntax]) {
        enum Frame: Equatable {
            case string
            case textBlock
            /// The code of an interpolation, with its open-paren depth.
            case interpolation(Int)
        }
        let chars = Array(text)
        var out: [String] = []
        var unsupported: [UnsupportedSyntax] = []
        var line = ""
        var lineNumber = 1
        var lineHadComment = false
        var depth = 0
        var inLineComment = false
        var stack: [Frame] = []
        let regexMayFollow: Set<Character> = ["(", ",", "=", ":", "[", "{", "!", "&", "|", "?", ";", "<", ">", "+", "-", "*", "~", "^", "%"]
        func isTripleQuote(at i: Int) -> Bool {
            i + 2 < chars.count && chars[i] == "\"" && chars[i + 1] == "\"" && chars[i + 2] == "\""
        }
        func flag(_ what: String) { unsupported.append(UnsupportedSyntax(line: lineNumber, what: what)) }
        func endLine() {
            if !(lineHadComment && line.trimmingCharacters(in: .whitespaces).isEmpty) { out.append(line) }
            line = ""
            lineHadComment = depth > 0
            inLineComment = false
            // A "…" string (and an interpolation inside it) ends with its line.
            if let i = stack.firstIndex(of: .string) { stack.removeSubrange(i...) }
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
            if c == "\n" { endLine(); lineNumber += 1; i += 1; continue }
            if depth > 0 {
                lineHadComment = true
                if c == "/", next == "*" { depth += 1; i += 2 } else if c == "*", next == "/" { depth -= 1; i += 2 } else { i += 1 }
                continue
            }
            if inLineComment { i += 1; continue }
            switch stack.last {
            case .textBlock?, .string?:
                let inBlock = stack.last == .textBlock
                if c == "\\", next == "(" { stack.append(.interpolation(0)); line += "\\("; i += 2; continue }
                if c == "\\", let next, next != "\n" { line.append(c); line.append(next); i += 2; continue }
                if inBlock, isTripleQuote(at: i) { stack.removeLast(); line += "\"\"\""; i += 3; continue }
                if !inBlock, c == "\"" { stack.removeLast() }
                line.append(c)
                i += 1
                continue
            case .interpolation?, nil:
                break
            }
            // Code — the file's, or an interpolation's.
            var inInterpolation = false
            if case .interpolation? = stack.last { inInterpolation = true }
            if c == "#", next == "\"" || next == "/" || next == "#" {
                flag("a raw string or an extended regex literal (#\" or #/)")
                line.append(c); i += 1; continue
            }
            if isTripleQuote(at: i) { stack.append(.textBlock); line += "\"\"\""; i += 3; continue }
            if c == "\"" { stack.append(.string); line.append(c); i += 1; continue }
            if c == "/", next == "/" || next == "*" {
                if inInterpolation {
                    flag("a comment inside a string interpolation")
                    line.append(c); line.append(next ?? " "); i += 2; continue
                }
                lineHadComment = true
                if next == "/" { inLineComment = true } else { depth = 1 }
                i += 2
                continue
            }
            if c == "/", let next, next != " ", next != "\t", next != "\n", next != "=" {
                let previous: Character = i > 0 ? chars[i - 1] : "\n"
                if previous == " " || previous == "\t" || previous == "\n" || regexMayFollow.contains(previous) {
                    flag("what may be a regex literal (/…/)")
                }
            }
            if case .interpolation(let open)? = stack.last {
                if c == "(" {
                    stack[stack.count - 1] = .interpolation(open + 1)
                } else if c == ")" {
                    if open == 0 { stack.removeLast() } else { stack[stack.count - 1] = .interpolation(open - 1) }
                }
            }
            line.append(c)
            i += 1
        }
        endLine()
        return (out.joined(separator: "\n"), unsupported)
    }

    /// `scan(text).code` — for a text known to be plain (a test's own
    /// fixture). A sensor reading production source goes through `code(of:)`
    /// / `appCode(named:)`, which refuse what the stripper cannot read.
    static func strippingComments(_ text: String) -> String { scan(text).code }

    /// The CODE of `text`, comments removed — or a recorded Issue and a
    /// throw when the text holds a construct `scan` does not understand: a
    /// code-only sensor FAILS rather than trust such a text (r4-3).
    static func code(of text: String, named name: String,
                     sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let scanned = scan(text)
        if let first = scanned.unsupported.first {
            Issue.record("""
                SourceTree: \(name) holds syntax the comment stripper does not understand \
                (\(scanned.unsupported.map(\.description).joined(separator: "; "))). A code-only sensor cannot tell \
                its comments from its code — write that construct another way, or teach SourceTree.scan to read it.
                """, sourceLocation: sourceLocation)
            throw first
        }
        return scanned.code
    }

    /// The CODE of the ONE app source file called `name` — comments removed;
    /// refuses (fails the test) a file the stripper cannot read.
    static func appCode(named name: String,
                        sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        try code(of: try appSource(named: name, sourceLocation: sourceLocation), named: name, sourceLocation: sourceLocation)
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
