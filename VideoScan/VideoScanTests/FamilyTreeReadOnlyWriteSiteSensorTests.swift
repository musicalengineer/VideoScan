// FamilyTreeReadOnlyWriteSiteSensorTests.swift
// Source sensor for the Family Tree's read-only state (DECISIONS 2026-11-01),
// rebuilt after codex #193 to prove the PATTERN, not list spot checks:
//
//   Every byte a Family Tree writer puts on disk is lexically INSIDE a
//   `withWrite` — FamilyTreeWriteAuthority.withWrite, FamilyTreeAccessMode
//   .withWrite, FamilyAssetStore.withWrite, the compiled store's withWrite,
//   or Core's WritePermit.current.withWrite. Each re-asks the LIVE authority
//   at that point, after every lock and await, and binds it for nested Core
//   writers (CyberBrain under its root lock, the overlay store), so no write
//   can follow a captured Bool, a captured mode, or a check taken before a
//   wait.
//
// The scanner (a small lexer: comments, strings, braces) finds every
// byte-writing token in VideoScan/VideoScan/FamilyTree/*.swift and in Core's
// FamilyGraphCompiledStore.swift, and requires each to sit in a scope opened
// by a `withWrite` call. The exceptions are named, with why, in `exempt`.
// A new write outside the primitive fails this sensor.
//
// (For Rick: a lint pass written as a unit test — "every write() is inside a
// lock_guard-like RAII scope", checked by a tiny lexer.)

import Testing
import Foundation
@testable import VideoScan

struct FamilyTreeReadOnlyWriteSiteSensorTests {

    /// Byte-writing operations (file system, UserDefaults, and the Core
    /// writers whose own bytes live outside the scanned files).
    static let writeTokens: [String] = [
        #"\.write\(to"#, #"\.write\(contentsOf"#, #"Darwin\.write\("#, #"\bwrite\(descriptor"#,
        #"FileHandle\(forWriting"#, #"FileHandle\(forUpdating"#,
        #"createDirectory\("#, #"removeItem\("#, #"replaceItem"#, #"moveItem\("#, #"copyItem\("#,
        #"trashItem\("#, #"O_CREAT"#, #"unlinkat\("#, #"renamex?_np"#, #"setAttributes\("#,
        #"AtomicFilePublish\.write"#, #"appendDurable"#,
        #"\.set\([^)]*forKey"#, #"\.removeObject\(forKey"#,
        #"CyberBrainWriter\.(record|correct|setPronunciation)\("#, #"\.save\(to"#,
        #"TreeWalkStore\.save\("#, #"PersonRefreshAudit\.append\("#, #"\$0\.save\(\)"#,
        #"\bbase\.save\("#, #"script\.write\("#,
    ]

    /// The only writes allowed outside `withWrite`, each with its reason.
    static let exempt: [String: String] = [
        "FamilyTreeCanvasControls.swift:save": "UserDefaults UI preference: sidebar visibility / canvas appearance",
        "FamilyTreeRollCall.swift:advance": "UserDefaults UI preference: roll-call play count",
        "FamilyTreeView.swift:showInPeopleTab": "UserDefaults UI hand-off: the People-tab highlight",
        "FamilyTreeLiveModel.swift:rememberFocus": "UserDefaults UI preference: the last focused person",
        "FamilyTreeLineExport.swift:writePNG": "Export line…: the file the user named in a save panel",
        "TreeIdentityCenter.swift:var store": "the raw persistence closure; it is only ever called inside gatedStore's withWrite",
    ]

    static func sourcesUnderTheSensor() throws -> [(String, String)] {
        let core = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScanCore/Sources/VideoScanCore/FamilyGraphCompiledStore.swift")
        return try familyTreeSources()
            + [("FamilyGraphCompiledStore.swift", try String(contentsOf: core, encoding: .utf8))]
    }

    /// codex #196 (a): a writer method on ANOTHER object (the asset store)
    /// whose own wait would otherwise run without the caller's authority.
    static let delegatedWriters = #"\b(store|assetStore|source\.store)\.(removeDocument|importCrest|recordPhotoChoice|choosePhoto|saveCardPhoto|importPersonDocument|importPersonPhoto|excludePhoto)\("#
    /// codex #196 (c): launching a process / script.
    static let spawns = #"\b(launcher|workspace)\.open\(|\bProcess\(\)"#
    /// codex #196 (b): authority-carrying types a view or sheet item must
    /// not STORE (only a supplier closure).
    static let authorityTypes = #"(FamilyAssetStore|FamilyTreeAccessMode|FamilyTreeWriteAuthority|FamilyAssetStore\.Access)\??\s*$"#

    /// The violations in `files`: write tokens outside any `withWrite`, an
    /// `await` inside one, a delegated writer or a spawn outside one (a spawn
    /// must also declare its output path), and an authority stored in a
    /// view or sheet item.
    static func violations(in files: [(String, String)], exempt: [String: String]) throws -> [String] {
        let regex = try NSRegularExpression(pattern: writeTokens.joined(separator: "|"))
        let delegated = try NSRegularExpression(pattern: delegatedWriters)
        let spawn = try NSRegularExpression(pattern: spawns)
        var out: [String] = []
        var exemptSeen = Set<String>()
        for (name, text) in files {
            let scanned = scan(text)
            out += structuralViolations(name: name, scanned: scanned, delegated: delegated, spawn: spawn)
            for (i, line) in scanned.lines.enumerated() where matches(regex, line) && !line.contains("func ") {
                let key = "\(name):\(scanned.owner[i])"
                if exempt[key] != nil { exemptSeen.insert(key); continue }
                if !scanned.inWrite[i] {
                    out.append("\(key) line \(i + 1): `\(line.trimmingCharacters(in: .whitespaces))` "
                               + "is not inside withWrite — move the bytes into the primitive")
                }
            }
        }
        for key in exempt.keys.sorted() where !exemptSeen.contains(key) && files.contains(where: { key.hasPrefix($0.0 + ":") }) {
            out.append("stale exemption \(key): no write there any more — remove it")
        }
        return out
    }

    /// Rules (a), (b), (c) of codex #196, per file.
    static func structuralViolations(name: String, scanned: Scanned, delegated: NSRegularExpression,
                                     spawn: NSRegularExpression) -> [String] {
        var out: [String] = []
        let isStoreFile = name.hasPrefix("FamilyAssetStore")
        for (i, line) in scanned.lines.enumerated() where !line.contains("func ") {
            let key = "\(name):\(scanned.owner[i])"
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if scanned.inWrite[i], line.range(of: #"\bawait\b"#, options: .regularExpression) != nil {
                out.append("\(key) line \(i + 1): `await` inside withWrite — the authority must be asked after the wait")
            }
            if !isStoreFile, matches(delegated, line), !scanned.inWrite[i] {
                out.append("\(key) line \(i + 1): `\(trimmed)` calls another object's writer outside withWrite "
                           + "— its wait would run without the caller's authority")
            }
            if matches(spawn, line), !(scanned.inWrite[i] && scanned.writeDeclaresOutput[i]) {
                out.append("\(key) line \(i + 1): `\(trimmed)` launches a process outside a withWrite that declares "
                           + "its output path (\"… → <output>\")")
            }
        }
        out += storedAuthorityViolations(name: name, lines: scanned.lines)
        return out
    }

    /// (b): in a `View` or `Identifiable` (sheet item / picker) struct, a
    /// stored property whose type carries write authority.
    static func storedAuthorityViolations(name: String, lines: [String]) -> [String] {
        var out: [String] = []
        var depth = 0
        var holderDepth: Int?
        let holder = try! NSRegularExpression(pattern: #"\bstruct\s+\w+[^{]*:\s*[^{]*\b(View|Identifiable)\b"#)
        let stored = try! NSRegularExpression(pattern: #"^\s*(?:private\s+|fileprivate\s+|@State\s+|@Binding\s+)*(?:let|var)\s+\w+\s*:\s*"# + authorityTypes)
        for (i, line) in lines.enumerated() {
            if holderDepth == nil, matches(holder, line) { holderDepth = depth + 1 }
            if let d = holderDepth, depth == d, matches(stored, line) {
                out.append("\(name) line \(i + 1): `\(line.trimmingCharacters(in: .whitespaces))` stores a write "
                           + "authority in a view or sheet item — store a supplier closure instead")
            }
            for ch in line {
                if ch == "{" { depth += 1 }
                if ch == "}" {
                    depth -= 1
                    if let d = holderDepth, depth < d { holderDepth = nil }
                }
            }
        }
        return out
    }

    @Test func everyWriteIsInsideTheWritePrimitive() throws {
        let files = try Self.sourcesUnderTheSensor()
        #expect(files.count > 50, "found \(files.count) sources — wrong folder?")
        let problems = try Self.violations(in: files, exempt: Self.exempt)
        #expect(problems.isEmpty, "\(problems.count) problem(s):\n\(problems.joined(separator: "\n"))")
    }

    /// codex #190 F1: the model never lists the archive to resolve its
    /// sources before the access check.
    @Test func theModelNeverListsTheArchiveBeforeTheAccessCheck() throws {
        let files = try Self.familyTreeSources()
        for member in ["FamilyTreeLiveModel.swift:configure", "FamilyTreeLiveModel.swift:init"] {
            let body = try #require(try Self.body(of: member, in: files))
            #expect(!body.contains(".gedcomDirectory()"), "\(member) lists the archive before the access check")
        }
    }

    /// codex #192 F2: every compiled store handed to a loader or to the
    /// shared graph cache from app code carries the LIVE guard. These are
    /// all the hand-outs there are; a new one fails until it is guarded and
    /// listed. `.app` itself is guarded; nothing in FamilyTree/ builds a raw
    /// store (`FamilyGraphCompiledStore(root:` / `.production`).
    static let storeHandOuts: [String: [String]] = [
        // Pass-through: its callers (the shared cache) are listed below.
        "FamilyAssetStore.swift": ["loader.compiledStore = compiledStore"],
        "FamilySearchPullCoordinator.swift": ["loader.compiledStore = usingStore ? compiledStore()?.guarded"],
        "FamilyTreeRecompileCenter.swift": ["loader.compiledStore = guarded",
                                            "cache.needsRecompile(for: configuration, store: store)"],
        "FamilyTreeLiveModel.swift": ["loader.compiledStore = store", "loader.compiledStore = guarded",
                                      "loader.compiledStore = liveCompiledStore",
                                      "FamilyGraphSharedCache.shared.outcome(for: configuration, store: store"],
        "FamilyTreeReadOnlyLoad.swift": ["loader.compiledStore = store"],
        "FamilyTreeLaunchBundle.swift": ["FamilyGraphSharedCache.shared.load(for: configuration, store: .app)"],
        "KinshipDisplayCenter.swift": ["store: .app)"],
    ]

    @Test func everyCompiledStoreHandedOutCarriesTheLiveGuard() throws {
        let files = try Self.familyTreeSources()
        let handOut = try NSRegularExpression(pattern:
            #"loader\.compiledStore\s*=|SharedCache\.shared\.(outcome|load)\(|\.needsRecompile\(for:|store: \.app\)"#)
        var problems: [String] = []
        for (name, text) in files where name != "FamilyGraphCompiledStore+App.swift" {
            let code = Self.scan(text).lines
            for (i, line) in code.enumerated() where Self.matches(handOut, line) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let next = i + 1 < code.count ? code[i + 1].trimmingCharacters(in: .whitespaces) : ""
                let allowed = Self.storeHandOuts[name] ?? []
                if !allowed.contains(where: { trimmed.contains($0) || (trimmed + " " + next).contains($0) }) {
                    problems.append("\(name) line \(i + 1): unlisted store hand-out `\(trimmed)` — guard it and list it")
                }
            }
            for (i, line) in code.enumerated()
            where line.contains("FamilyGraphCompiledStore(root:") || line.contains(".production") && line.contains("compiledStore") {
                problems.append("\(name) line \(i + 1): a raw compiled store in app code `\(line.trimmingCharacters(in: .whitespaces))`")
            }
        }
        let app = try #require(try Self.body(of: "FamilyGraphCompiledStore+App.swift:var app", in: files))
        if !app.contains(".guarded") { problems.append("FamilyGraphCompiledStore.app is not guarded") }
        let model = try #require(files.first { $0.0 == "FamilyTreeLiveModel.swift" }?.1)
        let modelCode = Self.scan(model).lines.joined(separator: "\n")
        if modelCode.range(of: #"(?<!guard )let store = compiledStore\b"#, options: .regularExpression) != nil
            || modelCode.contains(", store = compiledStore") {
            problems.append("the model hands out its raw compiledStore (use liveCompiledStore)")
        }
        if !modelCode.contains("compiledStore?.guarded") { problems.append("liveCompiledStore is not guarded") }
        #expect(problems.isEmpty, "\(problems.count) problem(s):\n\(problems.joined(separator: "\n"))")
    }

    /// parseAndPromote's exemption rests on this ordering.
    @Test func loaderReadOnlyBranchComesFirst() throws {
        let files = try Self.familyTreeSources()
        let body = try #require(try Self.body(of: "FamilyGraphFileLoader.swift:loadNewestOutcome", in: files))
        let first = body.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("func ") }
        #expect(first == "if readOnly { return loadPromotedOnly() }")
        let model = try #require(try Self.body(of: "FamilyTreeReadOnlyLoad.swift:outcome", in: files))
        #expect(model.contains("store.refusesWrites = true"))
        #expect(model.contains("store.trustsManifestSources = true"))
        #expect(model.contains("loader.readOnly = true"))
        #expect(model.contains("canWrite: false"))
    }

    @Test func identityCenterWritesOnlyThroughTheGatedStore() throws {
        let files = try Self.familyTreeSources()
        let text = try #require(files.first { $0.0 == "TreeIdentityCenter.swift" }?.1)
        let code = Self.scan(text).lines.joined(separator: "\n")
        #expect(!code.contains("store: store"), "a TreeIdentityPinning call bypasses gatedStore")
        #expect(code.components(separatedBy: "store: gatedStore").count - 1 >= 4)
    }

    /// The sensor senses: a write outside the primitive — even after a check,
    /// or with `withWrite` only in a string or a comment — is flagged; one
    /// inside it (one-line, multi-line, nested) is not.
    @Test func theScannerFlagsAWriteOutsideThePrimitive() throws {
        let planted = """
        struct Planted {
            func inside() throws {
                try authority.withWrite(.bookmark, path: "p") {
                    try Data().write(to: URL(fileURLWithPath: "/tmp/a"))
                }
                try store.withWrite("x") { try FileManager.default.removeItem(at: url) }
                try FamilyTreeAccessMode.withWrite(.note, path: "q",
                                                   mode: mode) {
                    if ok { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
                }
            }
            func checkedThenWrote() throws {
                try FamilyTreeWriteGate.check(.bookmark, path: "p", mode: .full)
                try Data().write(to: URL(fileURLWithPath: "/tmp/b"))
            }
            func sneaky() throws {
                let s = "withWrite in a string does not count"
                // withWrite in a comment does not count
                try FileManager.default.moveItem(at: a, to: b)
            }
        }
        """
        let problems = try Self.violations(in: [("Planted.swift", planted)], exempt: [:])
        #expect(problems.count == 2, "\(problems)")
        #expect(problems.contains { $0.hasPrefix("Planted.swift:checkedThenWrote") })
        #expect(problems.contains { $0.hasPrefix("Planted.swift:sneaky") })
    }

    /// The #196 shapes are caught: an `await` inside withWrite, another
    /// object's writer called after a check, a spawn with no declared output,
    /// and an authority stored in a view.
    @Test func theScannerFlagsTheCodex196Shapes() throws {
        let planted = #"""
        struct Planted {
            func awaitInside() async throws {
                try authority.withWrite(.note, path: "p") {
                    await somethingElse()
                    try Data().write(to: url)
                }
            }
            func checkThenDelegate() throws {
                try authority.check(.document, path: "p")
                try store.removeDocument(document, from: folder, for: owner)
            }
            func delegateInside() throws {
                try authority.withWrite(.document, path: "p") {
                    try store.removeDocument(document, from: folder, for: owner)
                }
            }
            func spawnUndeclared() throws {
                try FamilyTreeAccessMode.withWrite(.personRefresh, path: "launch", mode: m) {
                    launcher.open(script)
                }
            }
            func spawnDeclared() throws {
                try FamilyTreeAccessMode.withWrite(.personRefresh, path: "launch → answer.ged in scratch",
                                                   mode: m) {
                    launcher.open(script)
                }
            }
        }
        struct PlantedPane: View {
            let store: FamilyAssetStore
            let makeStore: () -> FamilyAssetStore
            var body: some View { EmptyView() }
        }
        """#
        let problems = try Self.violations(in: [("Planted.swift", planted)], exempt: [:])
        #expect(problems.contains { $0.hasPrefix("Planted.swift:awaitInside") && $0.contains("await") }, "\(problems)")
        #expect(problems.contains { $0.hasPrefix("Planted.swift:checkThenDelegate") }, "\(problems)")
        #expect(!problems.contains { $0.hasPrefix("Planted.swift:delegateInside") }, "\(problems)")
        #expect(problems.contains { $0.hasPrefix("Planted.swift:spawnUndeclared") }, "\(problems)")
        #expect(!problems.contains { $0.hasPrefix("Planted.swift:spawnDeclared") }, "\(problems)")
        #expect(problems.contains { $0.contains("let store: FamilyAssetStore") }, "\(problems)")
        #expect(!problems.contains { $0.contains("makeStore") }, "\(problems)")
    }

    // MARK: Scanner

    static func familyTreeSources() throws -> [(String, String)] {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/FamilyTree", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
            .map { ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)) }
    }

    static func matches(_ regex: NSRegularExpression, _ line: String) -> Bool {
        regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
    }

    struct Scanned {
        /// Code per line: comments removed, string literal contents blanked.
        var lines: [String] = []
        /// The OUTERMOST member function (or `var NAME`) each line is in;
        /// "top" outside any.
        var owner: [String] = []
        /// The line that member starts on.
        var ownerStart: [Int] = []
        /// True when the line is inside a scope opened by a `withWrite` call
        /// (or the line itself calls it, a one-line `withWrite { … }`).
        var inWrite: [Bool] = []
        /// True when the enclosing write scope's `withWrite` call declares
        /// the spawned process's output path (its path text has a `→`).
        var writeDeclaresOutput: [Bool] = []
    }

    /// The text of one member's body (code only), or nil.
    static func body(of key: String, in files: [(String, String)]) throws -> String? {
        let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let text = files.first(where: { $0.0 == parts[0] })?.1 else { return nil }
        let s = scan(text)
        let rows = s.lines.indices.filter { s.owner[$0] == parts[1] }
        guard !rows.isEmpty else { return nil }
        return rows.map { s.lines[$0] }.joined(separator: "\n")
    }

    /// One file, line by line: code with comments removed and string
    /// contents blanked (Lexer), and the member each line belongs to
    /// (ScopeTracker).
    static func scan(_ text: String) -> Scanned {
        var out = Scanned()
        var lexer = Lexer()
        var scopes = ScopeTracker()
        for (lineNo, raw) in text.components(separatedBy: "\n").enumerated() {
            let code = lexer.code(of: raw)
            let owner = scopes.feed(code, line: lineNo, raw: raw)
            out.lines.append(code)
            out.owner.append(owner.name)
            out.ownerStart.append(owner.start)
            out.inWrite.append(owner.inWrite)
            out.writeDeclaresOutput.append(owner.declaresOutput)
        }
        return out
    }

    /// Comments out, string contents blanked. `ctx` is a stack — code ›
    /// string › \( … ) › string … — so an interpolation's quotes and
    /// parentheses never leak into the brace/paren count. Block comments and
    /// multi-line strings survive a line break; nothing else does.
    struct Lexer {
        enum Ctx { case string(multi: Bool, raw: Bool), interp(depth: Int) }
        var ctx: [Ctx] = []
        var inBlock = false
        private var chars: [Character] = []
        private var out = ""

        mutating func code(of raw: String) -> String {
            chars = Array(raw)
            out = ""
            var i = 0
            while i < chars.count {
                guard let next = step(at: i) else { break }   // nil = a `//` comment ends the line
                i = next
            }
            while let last = ctx.last {
                if case .string(let multi, _) = last, multi { break }
                ctx.removeLast()
            }
            return out
        }

        private func at(_ k: Int) -> Character? { k < chars.count ? chars[k] : nil }
        private func isTriple(_ k: Int) -> Bool { at(k) == "\"" && at(k + 1) == "\"" && at(k + 2) == "\"" }

        /// Consume from `i`; the index after, or nil when the rest is a comment.
        private mutating func step(at i: Int) -> Int? {
            if inBlock { return blockComment(i) }
            switch ctx.last {
            case .string(let multi, let raw)?: return string(i, multi: multi, raw: raw)
            case .interp(let depth)?: return interpolation(i, depth: depth)
            case nil: return codeChar(i)
            }
        }

        private mutating func blockComment(_ i: Int) -> Int {
            if chars[i] == "*", at(i + 1) == "/" { inBlock = false; return i + 2 }
            return i + 1
        }

        private mutating func open(_ i: Int, raw: Bool) -> Int {
            let start = raw ? i + 1 : i
            let multi = isTriple(start)
            ctx.append(.string(multi: multi, raw: raw))
            out += "\""
            return start + (multi ? 3 : 1)
        }

        private mutating func string(_ i: Int, multi: Bool, raw: Bool) -> Int {
            let c = chars[i]
            if c == "\\" {
                let interp = raw ? (at(i + 1) == "#" && at(i + 2) == "(") : at(i + 1) == "("
                if interp { ctx.append(.interp(depth: 1)); out += "   "; return i + (raw ? 3 : 2) }
                if !raw { out += "  "; return i + 2 }
            }
            let width = multi ? 3 : 1
            let closes = (multi ? isTriple(i) : c == "\"") && (!raw || at(i + width) == "#")
            guard closes else { out += " "; return i + 1 }
            ctx.removeLast()
            out += "\""
            return i + width + (raw ? 1 : 0)
        }

        private mutating func interpolation(_ i: Int, depth: Int) -> Int {
            let c = chars[i]
            out += " "
            if c == "\"" { return open(i, raw: false) }
            if c == "(" { ctx[ctx.count - 1] = .interp(depth: depth + 1) }
            if c == ")" {
                if depth == 1 { ctx.removeLast() } else { ctx[ctx.count - 1] = .interp(depth: depth - 1) }
            }
            return i + 1
        }

        private mutating func codeChar(_ i: Int) -> Int? {
            let c = chars[i]
            if c == "/", at(i + 1) == "/" { return nil }
            if c == "/", at(i + 1) == "*" { inBlock = true; return i + 2 }
            if c == "#", at(i + 1) == "\"" { return open(i, raw: true) }
            if c == "\"" { return open(i, raw: false) }
            out.append(c)
            return i + 1
        }
    }

    /// Braces and parentheses on code-only text, and the declarations that
    /// own a body. A line's owner is the OUTERMOST member function (nested
    /// helpers belong to it), else a member `var`, else "top".
    struct ScopeTracker {
        struct Scope { let name: String?; let isMember: Bool; let start: Int; var isWrite = false
                       var declaresOutput = false }
        struct Pending { let name: String; let parens: Int; let isFunc: Bool; let line: Int }
        var stack: [Scope] = []
        var pending: Pending?
        var parens = 0
        /// A `withWrite(` call whose `{` has not opened yet (multi-line call).
        var pendingWrite = false
        var pendingDeclares = false
        static let decl = try! NSRegularExpression(
            pattern: #"(?<![.\w])(?:func\s+([A-Za-z_]\w*)|(init)\??\s*[(<]|(?:var|let)\s+([A-Za-z_]\w*)\b)"#)

        mutating func feed(_ code: String, line: Int, raw: String = "")
            -> (name: String, start: Int, inWrite: Bool, declaresOutput: Bool) {
            noteDeclaration(in: code, line: line)
            var owner = currentOwner(line: line)
            let callsWrite = code.contains("withWrite")
            var inWrite = callsWrite || stack.contains { $0.isWrite }
            // The declared output lives in the path STRING, so it is read
            // from the raw line (the lexer blanks string contents).
            let declares = callsWrite && raw.contains("→")
            var declaresOutput = declares || stack.contains { $0.isWrite && $0.declaresOutput }
            var seenWrite = false
            var prefix = ""
            for ch in code {
                prefix.append(ch)
                if !seenWrite, prefix.hasSuffix("withWrite") { seenWrite = true }
                let opensWrite = ch == "{" && (pendingWrite || seenWrite)
                count(ch)
                if opensWrite, !stack.isEmpty {
                    stack[stack.count - 1].isWrite = true
                    stack[stack.count - 1].declaresOutput = declares || pendingDeclares
                    if pendingDeclares { declaresOutput = true }
                    pendingWrite = false
                    pendingDeclares = false
                    seenWrite = false
                    inWrite = true
                }
            }
            // `withWrite(` on this line, its `{` on a later one.
            if seenWrite { pendingWrite = true; pendingDeclares = pendingDeclares || declares }
            if pendingWrite, raw.contains("→") { pendingDeclares = true }
            // A member that opened on this line owns this line.
            if owner.name == "top" || owner.name.hasPrefix("var ") {
                let now = currentOwner(line: line)
                if now.name != "top" { owner = now }
            }
            // A `var`/`let` owns a body only if it opens on its own line
            // (`if case .x(let y) = z {` is not a declaration with a body); a
            // func whose parentheses closed below its own level is gone.
            if let p = pending, !p.isFunc || parens < p.parens { pending = nil }
            return (owner.name, owner.start, inWrite, declaresOutput)
        }

        private mutating func noteDeclaration(in code: String, line: Int) {
            let ns = code as NSString
            guard let m = Self.decl.firstMatch(in: code, range: NSRange(location: 0, length: ns.length)) else { return }
            // A func pending with no body (a protocol requirement) gives way.
            if let p = pending, p.line != line, parens == p.parens { pending = nil }
            guard pending == nil else { return }
            let prefix = ns.substring(to: m.range.location)
            let level = parens + prefix.filter { $0 == "(" }.count - prefix.filter { $0 == ")" }.count
            func group(_ g: Int) -> String? {
                let r = m.range(at: g)
                return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            if let f = group(1) { pending = Pending(name: f, parens: level, isFunc: true, line: line) }
            else if group(2) != nil { pending = Pending(name: "init", parens: level, isFunc: true, line: line) }
            else if let v = group(3) { pending = Pending(name: "var \(v)", parens: level, isFunc: false, line: line) }
        }

        private var insideFunc: Bool { stack.contains { $0.isMember && $0.name?.hasPrefix("var ") == false } }

        private func currentOwner(line: Int) -> (name: String, start: Int) {
            if let f = stack.first(where: { $0.isMember && $0.name?.hasPrefix("var ") == false }), let name = f.name {
                return (name, f.start)
            }
            if let v = stack.first(where: { $0.isMember }), let name = v.name { return (name, v.start) }
            if let p = pending, p.line == line { return (p.name, line) }
            return ("top", line)
        }

        private mutating func count(_ ch: Character) {
            switch ch {
            case "(": parens += 1
            case ")": parens -= 1
            case "{":
                if let p = pending, parens == p.parens {
                    // Members only: a func nested in a func belongs to the outer one.
                    stack.append(Scope(name: p.name, isMember: !insideFunc, start: p.line))
                    pending = nil
                } else {
                    stack.append(Scope(name: nil, isMember: false, start: 0))
                }
            case "}":
                if !stack.isEmpty { stack.removeLast() }
            default: break
            }
        }
    }
}
