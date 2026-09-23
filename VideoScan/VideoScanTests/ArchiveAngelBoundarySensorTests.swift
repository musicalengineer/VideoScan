// ArchiveAngelBoundarySensorTests.swift
// The Archive Angel's module boundary, enforced by a test instead of the
// compiler (docs/archive_angel_consolidation_plan.md, Packaging option A).
//
// RATCHET: each table below is today's list of leaks. A count may only go
// DOWN; a new leak (or a leak in a new place) fails. When you remove one,
// lower the baseline in the same commit — the test prints the current table
// in paste-ready form.
//
//   INBOUND   app code OUTSIDE VideoScan/ArchiveAngel/ naming anything of the
//             Angel's but the public surface (the façade `ArchiveAngel` /
//             `model.archiveAngel`, and the five public views/types listed
//             in `publicSurface`), or reading an "archiveAngel.*" defaults key.
//   OUTBOUND  Angel code reaching for app globals it should get from a seam:
//             tab navigation ("selectedTab" / MainWindowHelper), O(n)
//             `records.first {…}` scans, TestEnvironment.isTestHost,
//             UserDefaults / @AppStorage outside the settings file, the
//             hard-coded buffer root. The seam files themselves are exempt.
//   COUPLING  (informational, may only shrink) concrete VideoScanModel /
//             MediaFileOperationsCenter references in the Angel's CORE
//             (Recommend/Prepare/Review/Promote) — the work S6 (pure core →
//             package) has left. Views and the composition root are exempt.
//
// Comments are stripped before scanning: a doc comment that mentions a type
// is not a dependency.

import Foundation
import Testing

@Suite("Archive Angel boundary sensor — leaks may only shrink")
struct ArchiveAngelBoundarySensorTests {

    // MARK: Baselines (lower these as leaks are removed; never raise them)

    // S1 (2026-09-22): inbound 68 in 48 places, outbound 18 in 13 places.
    // S2 (2026-09-22): ZERO — the seams, the façade and the strip took
    // every one. Keep them empty: a new leak fails here.
    static let inboundBaseline: [String: Int] = [:]
    /// QA 2026-09-22 widened the O(n) rule to `for … in records` and
    /// `records.filter{…}.first`. The two it found are legitimate today:
    /// the companion-retirement entry point and the launch reconciliation
    /// each make ONE catalog pass per call (never per record). Listed so the
    /// ratchet can only shrink; a catalog seam for "records under a folder"
    /// would take them to zero.
    static let outboundBaseline: [String: Int] = [
        "Prepare/VideoScanModel+ArchiveAngelCompanions.swift | O(n) records scan": 2,
    ]
    /// The CORE (Recommend/, Prepare/, Review/, Promote/) naming the concrete
    /// VideoScanModel / MediaFileOperationsCenter instead of a seam — S6's
    /// work before the pure core can become a package. 29 at S1 and S2.
    /// (UI/ views take the app's environment objects by design, and the
    /// façade + seam files are the composition root — not counted.)
    static let couplingBaseline = 29

    // MARK: The public surface

    static let publicSurface: Set<String> = [
        "ArchiveAngel", "archiveAngel",   // the façade type, `model.archiveAngel`, the MFO kind `.archiveAngel`
        "ArchiveAngelStrip", "ArchiveAngelCatalogBadgeView", "ArchiveAngelMenuItems",
        "ArchiveAngelJobDetailView", "ArchiveAngelRecommendationClass",
    ]

    /// Angel files that ARE the seams: they may touch app globals.
    static let seamFiles: Set<String> = [
        "Seams/AppConformances.swift", "Facade/AngelEnvironment.swift", "Facade/ArchiveAngelSettings.swift",
    ]

    // MARK: Scanning

    static func appDir(_ file: String = #filePath) -> URL {
        URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan", isDirectory: true)
    }
    static var angelDir: URL { appDir().appendingPathComponent("ArchiveAngel", isDirectory: true) }

    static func swiftFiles(under dir: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        var out: [URL] = []
        while let u = e?.nextObject() as? URL {
            if u.pathExtension == "swift" { out.append(u) }
        }
        return out.sorted { $0.path < $1.path }
    }

    /// Source text with `//` line comments and `/* */` blocks removed. Crude
    /// (a `//` inside a string literal cuts the line) — it can only HIDE a
    /// token, and none of the patterns below live in URL strings.
    static func code(of url: URL) -> String {
        guard var s = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        s = s.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        return s.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            guard let r = line.range(of: "//") else { return String(line) }
            return String(line[..<r.lowerBound])
        }.joined(separator: "\n")
    }

    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    static func relative(_ url: URL, to base: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count + 1))
    }

    /// The inbound leaks in one file's (comment-stripped) code, one string
    /// per occurrence (QA 2026-09-22 widened the scan):
    ///   • an identifier naming the Angel beyond the public surface
    ///     (`ArchiveAngelEvidenceStore`, `archiveAngelStore`, …);
    ///   • a chain PAST the façade into its parts
    ///     (`.archiveAngel.store`, `.sweep`, `.attention`, `.environment`, `.policy`);
    ///   • a seam / environment type (`AngelEnvironment`, `AngelCatalog`…) —
    ///     app code reaches those through the façade, never by name;
    ///   • an "archiveAngel.*" defaults key.
    static func inboundTokens(in text: String) -> [String] {
        var out: [String] = []
        for token in matches(#"\b[A-Za-z_][A-Za-z0-9_]*\b"#, in: text)
        where (token.contains("ArchiveAngel") || token.contains("archiveAngel")
               || token == "isMediaFileOperationBusyForAngel") && !publicSurface.contains(token) {
            out.append(token)
        }
        for chain in matches(#"\.archiveAngel\s*\.\s*(store|sweep|attention|environment|policy)\b"#, in: text) {
            out.append("chain " + chain.replacingOccurrences(of: " ", with: ""))
        }
        for type in matches(#"\bAngel[A-Z][A-Za-z0-9_]*"#, in: text) {
            out.append("seam type " + type)
        }
        for key in matches(#""archiveAngel\.[A-Za-z]+""#, in: text) {
            out.append("defaults key " + key.replacingOccurrences(of: "\"", with: ""))
        }
        return out
    }

    /// "File.swift | Token" → count.
    static func inbound() -> [String: Int] {
        var out: [String: Int] = [:]
        let angel = angelDir.standardizedFileURL.path + "/"
        for url in swiftFiles(under: appDir()) where !url.standardizedFileURL.path.hasPrefix(angel) {
            let name = relative(url, to: appDir())
            for token in inboundTokens(in: code(of: url)) { out["\(name) | \(token)", default: 0] += 1 }
        }
        return out
    }

    static let outboundRules: [(name: String, pattern: String)] = [
        ("navigation", #""selectedTab"|MainWindowHelper\.shared"#),
        ("O(n) records scan", #"records\.first\s*[\{\(]|records\.filter\s*\{[^}]*\}\s*\.first|\bfor\s+[A-Za-z_][A-Za-z0-9_]*\s+in\s+(self\.|model\.)?records\b"#),
        ("TestEnvironment.isTestHost", #"TestEnvironment\.isTestHost"#),
        ("UserDefaults / @AppStorage", #"UserDefaults\.standard|@AppStorage\("#),
        ("hard-coded buffer root", #"(?<!var )\bdefaultBufferRoot\b"#),
    ]

    /// Outbound rule name → occurrences in one file's (comment-stripped) code.
    static func outboundHits(in text: String) -> [String: Int] {
        var out: [String: Int] = [:]
        for rule in outboundRules {
            let n = matches(rule.pattern, in: text).count
            if n > 0 { out[rule.name] = n }
        }
        return out
    }

    /// "Folder/File.swift | rule" → count.
    static func outbound() -> [String: Int] {
        var out: [String: Int] = [:]
        for url in swiftFiles(under: angelDir) {
            let name = relative(url, to: angelDir)
            guard !seamFiles.contains(name) else { continue }
            for (rule, n) in outboundHits(in: code(of: url)) { out["\(name) | \(rule)", default: 0] += n }
        }
        return out
    }

    static let coreFolders: Set<String> = ["Recommend", "Prepare", "Review", "Promote"]

    static func coupling() -> Int {
        var n = 0
        for url in swiftFiles(under: angelDir) {
            let rel = relative(url, to: angelDir)
            guard let folder = rel.split(separator: "/").first, coreFolders.contains(String(folder)) else { continue }
            n += matches(#"\b(VideoScanModel|MediaFileOperationsCenter)\b"#, in: code(of: url)).count
        }
        return n
    }

    static func literal(_ table: [String: Int]) -> String {
        table.isEmpty ? "[:]" : "[\n" + table.keys.sorted().map { "        \"\($0)\": \(table[$0] ?? 0)," }
            .joined(separator: "\n") + "\n    ]"
    }

    /// Entries that grew or appeared relative to the baseline.
    static func regressions(_ now: [String: Int], baseline: [String: Int]) -> [String] {
        now.keys.sorted().compactMap { key in
            let n = now[key] ?? 0, b = baseline[key] ?? 0
            return n > b ? "\(key): \(n) (baseline \(b))" : nil
        }
    }

    // MARK: Tests

    @Test("the scanner sees the app and the Angel folder (a moved folder must not make this vacuous)")
    func scannerSeesFiles() {
        #expect(Self.swiftFiles(under: Self.appDir()).count > 300)
        #expect(Self.swiftFiles(under: Self.angelDir).count >= 35)
        #expect(FileManager.default.fileExists(atPath: Self.angelDir.appendingPathComponent("Facade/ArchiveAngel.swift").path))
    }

    @Test("INBOUND: app code outside ArchiveAngel/ names only the public surface — ratchet")
    func inboundRatchet() {
        let now = Self.inbound()
        print("[angel-boundary] inbound total \(now.values.reduce(0, +)) in \(now.count) places\n    static let inboundBaseline: [String: Int] = \(Self.literal(now))")
        let worse = Self.regressions(now, baseline: Self.inboundBaseline)
        #expect(worse.isEmpty, "new or grown inbound leaks: \(worse)")
    }

    @Test("OUTBOUND: Angel code gets app globals only through its seams — ratchet")
    func outboundRatchet() {
        let now = Self.outbound()
        print("[angel-boundary] outbound total \(now.values.reduce(0, +)) in \(now.count) places\n    static let outboundBaseline: [String: Int] = \(Self.literal(now))")
        let worse = Self.regressions(now, baseline: Self.outboundBaseline)
        #expect(worse.isEmpty, "new or grown outbound leaks: \(worse)")
    }

    @Test("COUPLING (informational): concrete model / center references inside the Angel may only shrink")
    func couplingRatchet() {
        let n = Self.coupling()
        print("[angel-boundary] coupling \(n) (baseline \(Self.couplingBaseline))")
        #expect(n <= Self.couplingBaseline, "Angel → VideoScanModel/MediaFileOperationsCenter references grew: \(n) > \(Self.couplingBaseline)")
    }

    @Test("the sensor catches a planted leak — through the SAME functions the ratchets use")
    func catchesPlantedLeak() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("angel-sensor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let f = dir.appendingPathComponent("Leak.swift")
        try """
        // ArchiveAngelEvidenceStore in a comment is fine
        let x = model.archiveAngelStore.candidateIDs   // a leak
        let y: ArchiveAngelStrip? = nil                // public surface
        let z = model.archiveAngel.candidateIDs        // public surface
        let k = UserDefaults.standard.bool(forKey: "archiveAngel.makeLossless")
        let c = model.records.filter { $0.id == id }.first
        for r in records where r.isPurged { }
        """.write(to: f, atomically: true, encoding: .utf8)
        let text = Self.code(of: f)
        #expect(Self.inboundTokens(in: text) == ["archiveAngelStore", "defaults key archiveAngel.makeLossless"])
        let out = Self.outboundHits(in: text)
        #expect(out["UserDefaults / @AppStorage"] == 1)
        #expect(out["O(n) records scan"] == 2)
    }

    @Test("QA RED: INBOUND misses façade-member chains and Angel* seam types")
    func inboundCatchesChainedLeaks() {
        let text = "let a = model.archiveAngel.store.candidateIDs\nmodel.archiveAngel.sweep.rescoreNow()\nlet r = AngelEnvironment.currentBufferRoot"
        #expect(Self.inboundTokens(in: text).count >= 3)
    }
}
