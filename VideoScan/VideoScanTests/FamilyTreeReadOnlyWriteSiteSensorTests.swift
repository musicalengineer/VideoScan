// FamilyTreeReadOnlyWriteSiteSensorTests.swift
// Source sensor for DECISIONS 2026-11-01 (the Family Tree's read-only state):
// EVERY write site in VideoScan/VideoScan/FamilyTree/ checks the access state.
//
// The scanner finds each line that can write (file/dir creation, rename,
// remove, CyberBrain writes, bookmark/ruling saves, journals, UserDefaults,
// compiled-store ingest) and names the member function it is in. Each
// (file, function) must be listed in `inventory` below as one of:
//   .gated            — the function itself calls the gate before the write
//                       (checkWrite / refusesWrite / FamilyTreeWriteGate /
//                       requireWriteAccess / gatedStore);
//   .via([...])       — a helper whose callers (listed, with the call) each
//                       gate before calling it; `exhaustive` = no other
//                       caller exists anywhere in FamilyTree/;
//   .exempt(reason)   — not a family-data write (a UI preference in
//                       UserDefaults, a file the user picked in a save
//                       panel), or a write reachable only from a gated path
//                       with the reason saying which.
// A NEW write site that is not listed fails this sensor: gate it, then list
// it here with its rule. A listed entry with no write site left fails too,
// so the list stays the truth.
//
// (For Rick: this is a lint pass written as a unit test — a tiny lexer that
// tracks braces, strings and comments, like a pre-commit grep with scope.)

import Testing
import Foundation
@testable import VideoScan

struct FamilyTreeReadOnlyWriteSiteSensorTests {

    enum Rule {
        case gated
        case via([(caller: String, call: String)], exhaustive: Bool)
        case exempt(String)
    }

    static let writeTokens: [String] = [
        #"\.write\(to"#, #"\bwrite\(to:"#, #"createDirectory\("#, #"moveItem\("#, #"copyItem\("#,
        #"replaceItem"#, #"removeItem\("#, #"trashItem\("#, #"O_CREAT"#, #"unlinkat\("#, #"renamex?_np"#,
        #"CyberBrainWriter\.(record|correct|setPronunciation)\("#, #"\.save\(to"#,
        #"AtomicFilePublish\.write"#, #"PersonRefreshAudit\.append\("#, #"TreeWalkStore\.save\("#,
        #"\.set\([^)]*forKey"#, #"\.removeObject\(forKey"#, #"\.ingest\("#, #"\.recompile\(sources"#,
        #"\$0\.save\(\)"#, #"\btry store\("#, #"overlay\.record\("#, #"\.update\s*\{"#, #"appendDurable"#,
        #"writeAtomically\("#, #"\b(store|base)\.save\("#,
    ]

    /// Functions with no write site of their own that hand a write on to a
    /// listed helper; their callers are checked the same way.
    static let chains: [String: [(caller: String, call: String)]] = [
        "FamilyAssetStore+Documents.swift:rollBackWrittenDocument": [
            ("FamilyAssetStore+Documents.swift:importPersonDocument", "rollBackWrittenDocument("),
        ],
        "FamilyAssetStore.swift:writableChosenPhotoFolder": [
            ("FamilyAssetStore.swift:choosePhoto", "writableChosenPhotoFolder("),
            ("FamilyAssetStore.swift:recordPhotoChoice", "writableChosenPhotoFolder("),
        ],
    ]

    static let gateTokens = ["checkWrite(", "refusesWrite(", "FamilyTreeWriteGate.", "requireWriteAccess()",
                             "gatedStore", "authority.check("]

    /// Every write site in FamilyTree/, by (file, member function).
    static let inventory: [String: Rule] = [
        // CouplePortrait — App Support/VideoScan/portrait + its preference.
        "CouplePortrait.swift:saveCaption": .gated,
        "CouplePortrait.swift:importPhoto": .gated,
        "CouplePortrait.swift:remove": .gated,
        // The asset store (archive 40_Family_Tree): every public writer
        // calls requireWriteAccess(), which refuses .unavailable and .readOnly.
        "FamilyAssetStore.swift:importCrest": .gated,
        "FamilyAssetStore.swift:recordPhotoChoice": .gated,
        "FamilyAssetStore.swift:publishExclusion": .via([("FamilyAssetStore.swift:excludePhoto", "publishExclusion(")],
                                                        exhaustive: true),
        "FamilyAssetStore.swift:writePersonPhotoData": .via([
            ("FamilyAssetStore.swift:importPersonPhoto", "writePersonPhotoData("),
            ("FamilyAssetStore.swift:choosePhoto", "writePersonPhotoData("),
            ("FamilyAssetStore.swift:saveCardPhoto", "writePersonPhotoData("),
            ("FamilyAssetStore+Documents.swift:importPersonDocument", "writePersonPhotoData("),
        ], exhaustive: true),
        "FamilyAssetStore.swift:ensureSafeDirectory": .via([
            ("FamilyAssetStore.swift:folderForPhotoRequest", "ensureSafeDirectory("),
            ("FamilyAssetStore.swift:ensureCrestsDirectory", "ensureSafeDirectory("),
            ("FamilyAssetStore.swift:ensureGEDCOMDirectory", "ensureSafeDirectory("),
            ("FamilyAssetStore.swift:writableChosenPhotoFolder", "ensureSafeDirectory("),
            ("FamilyAssetStore+Documents.swift:importPersonDocument", "ensureSafeDirectory("),
        ], exhaustive: true),
        "FamilyAssetStore+Documents.swift:writeDocumentSidecar": .via([
            ("FamilyAssetStore+Documents.swift:importPersonDocument", "writeDocumentSidecar("),
            ("FamilyAssetStore+Documents.swift:removeDocument", "writeDocumentSidecar("),
        ], exhaustive: true),
        "FamilyAssetStore+Documents.swift:moveToTrash": .via([
            ("FamilyAssetStore+Documents.swift:removeDocument", "moveToTrash("),
            ("FamilyAssetStore+Documents.swift:rollBackWrittenDocument", "moveToTrash("),
        ], exhaustive: true),
        // Compiled store writes (App Support/family-tree/compiled).
        "FamilyGraphFileLoader.swift:recompile": .via([
            ("FamilyTreeLiveModel.swift:recompile", "loader.recompile(sources"),
            ("FamilyTreeRecompileCenter.swift:recompile", "loader.recompile(sources"),
        ], exhaustive: true),
        "FamilyGraphFileLoader.swift:parseAndPromote": .exempt(
            "full mode only: loadNewestOutcome returns loadPromotedOnly() first when readOnly, and the "
            + "read-only load (FamilyTreeReadOnlyLoad) sets readOnly + refusesWrites (pinned by loaderReadOnlyBranchComesFirst)"),
        // Refresh from FamilySearch (script, overlay, journal).
        "FamilySearchPersonRefresh.swift:write": .via([
            ("FamilySearchPersonRefreshCoordinator.swift:launch", "script.write("),
        ], exhaustive: false),
        "FamilySearchPersonRefresh.swift:append": .via([
            ("FamilySearchPersonRefreshCoordinator.swift:apply", "PersonRefreshAudit.append("),
            ("FamilySearchPersonRefreshCoordinator.swift:undoLast", "PersonRefreshAudit.append("),
        ], exhaustive: true),
        "FamilySearchPersonRefreshCoordinator.swift:apply": .gated,
        "FamilySearchPersonRefreshCoordinator.swift:undoLast": .gated,
        // Get Family Tree (script, staging, GEDCOM install, sidecars).
        "FamilySearchPull.swift:write": .via([
            ("FamilySearchPullCoordinator.swift:launch", "script.write("),
        ], exhaustive: false),
        // codex #190 F2: no longer exempt — removing staging is a write too.
        "FamilySearchPullCoordinator.swift:cancel": .gated,
        "FamilySearchPullCoordinator.swift:install": .gated,
        "FamilySearchPullCoordinator.swift:performMerge": .via([
            ("FamilySearchPullCoordinator.swift:installMerged", "performMerge("),
        ], exhaustive: true),
        "FamilySearchPullCoordinator.swift:sha256Sidecar": .via([
            ("FamilySearchPullCoordinator.swift:stageMerge", "sha256Sidecar("),
        ], exhaustive: true),
        // Staging re-asks the authority before its first byte (codex #190 F2).
        "FamilySearchPullCoordinator.swift:stageMerge": .gated,
        // Bookmarks (beside the GEDCOM, on the archive).
        "FamilyTreeBookmarks.swift:save": .via([
            ("FamilyTreeLiveModel.swift:toggleBookmark", "bookmarks.save(to"),
        ], exhaustive: true),
        // UI preferences and user-chosen files — not family data.
        "FamilyTreeCanvasControls.swift:save": .exempt("UserDefaults: sidebar visibility / canvas appearance"),
        "FamilyTreeLineExport.swift:writePNG": .exempt("Export line…: the file the user named in a save panel"),
        "FamilyTreeRollCall.swift:advance": .exempt("UserDefaults: roll-call play count"),
        "FamilyTreeView.swift:showInPeopleTab": .exempt("UserDefaults: the cross-tab highlight hand-off"),
        "FamilyTreeLiveModel.swift:rememberFocus": .exempt("UserDefaults: the last focused person"),
        // The tree model: every writer gates first.
        "FamilyTreeLiveModel.swift:recompile": .gated,
        "FamilyTreeLiveModel.swift:addNote": .gated,
        "FamilyTreeLiveModel.swift:correctNote": .gated,
        "FamilyTreeLiveModel.swift:recordTestimony": .gated,
        "FamilyTreeLiveModel.swift:cyberBrainRecorder": .gated,
        "FamilyTreeLiveModel.swift:setPronunciation": .gated,
        "FamilyTreeLiveModel.swift:toggleBookmark": .gated,
        "FamilyTreeLiveModel.swift:setRecordHidden": .gated,
        "FamilyTreeRecompileCenter.swift:recompile": .gated,
        // Walk decorations, research, Person of the Day.
        "FamilyTreeWalkCenter.swift:save": .gated,
        "ResearchStore.swift:saveDossier": .gated,
        "ResearchStore.swift:retireDossierFile": .gated,
        "ResearchStore.swift:cache": .gated,
        "ResearchStore.swift:writeAtomically": .via([
            ("ResearchStore.swift:saveDossier", "writeAtomically("),
            ("ResearchStore.swift:cache", "writeAtomically("),
        ], exhaustive: true),
        "PersonOfTheDayCenter.swift:save": .gated,
        // People ↔ tree pins: one gated store.
        "TreeIdentityCenter.swift:var store": .exempt(
            "the raw persistence closure; every use goes through gatedStore (pinned by "
            + "identityCenterWritesOnlyThroughTheGatedStore)"),
        "TreeIdentityCenter.swift:var gatedStore": .gated,
        "TreeIdentityShowInTree.swift:pin": .exempt("persists through the injected `store`; TreeIdentityCenter passes gatedStore"),
        "TreeIdentityShowInTree.swift:unpin": .exempt("persists through the injected `store`; TreeIdentityCenter passes gatedStore"),
        "TreeIdentityShowInTree.swift:markNotInTree": .exempt("persists through the injected `store`; TreeIdentityCenter passes gatedStore"),
        "TreeIdentityShowInTree.swift:mirrorOwner": .exempt("runs only after `store` succeeded inside pin (a refusal returns first)"),
    ]

    // MARK: The sensor

    @Test func everyWriteSiteInFamilyTreeChecksTheAccessState() throws {
        let files = try Self.familyTreeSources()
        #expect(files.count > 50, "found \(files.count) FamilyTree sources — wrong folder?")
        let regex = try NSRegularExpression(pattern: Self.writeTokens.joined(separator: "|"))
        var found: [String: [Int]] = [:]
        var failures: [String] = []
        for (name, text) in files {
            let scanned = Self.scan(text)
            for (index, line) in scanned.lines.enumerated() where Self.matches(regex, line) {
                let key = "\(name):\(scanned.owner[index])"
                found[key, default: []].append(index + 1)
                guard let rule = Self.inventory[key] else {
                    failures.append("NEW write site \(key) line \(index + 1): `\(line.trimmingCharacters(in: .whitespaces))` "
                                    + "— gate it (FamilyTreeWriteGate) and list it in the inventory")
                    continue
                }
                if case .gated = rule {
                    let body = scanned.lines[scanned.ownerStart[index]...index].joined(separator: "\n")
                    if !Self.gateTokens.contains(where: body.contains) {
                        failures.append("\(key) line \(index + 1) writes with no access check before it")
                    }
                }
            }
        }
        for key in Self.inventory.keys.sorted() where found[key] == nil {
            failures.append("stale inventory entry \(key): no write site there any more — remove or rename it")
        }
        // Helpers: each listed caller gates before its call; an exhaustive
        // helper has no other caller.
        var helpers: [(String, [(caller: String, call: String)], Bool)] = Self.chains.map { ($0.key, $0.value, true) }
        for (key, rule) in Self.inventory {
            if case .via(let callers, let exhaustive) = rule { helpers.append((key, callers, exhaustive)) }
        }
        for (key, callers, exhaustive) in helpers {
            for (caller, call) in callers {
                guard let body = try Self.body(of: caller, in: files) else {
                    failures.append("\(key): caller \(caller) not found"); continue
                }
                guard let at = body.range(of: call) else {
                    failures.append("\(key): \(caller) no longer calls `\(call)`"); continue
                }
                let before = String(body[..<at.lowerBound])
                // A caller that is itself a listed helper is checked as one.
                let chained: Bool = {
                    if Self.chains[caller] != nil { return true }
                    if case .via? = Self.inventory[caller] { return true }
                    return false
                }()
                if !chained, !Self.gateTokens.contains(where: before.contains) {
                    failures.append("\(key): caller \(caller) does not check the access state before `\(call)`")
                }
            }
            if exhaustive, let call = callers.first?.call {
                let allowed = Set(callers.map(\.caller))
                for (name, text) in files {
                    let scanned = Self.scan(text)
                    for (index, line) in scanned.lines.enumerated() where line.contains(call)
                        && !line.contains("func \(call.dropLast())") {
                        let owner = "\(name):\(scanned.owner[index])"
                        if owner != key, !allowed.contains(owner) {
                            failures.append("\(key) is called from \(owner) line \(index + 1), which is not a listed gated caller")
                        }
                    }
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.count) problem(s):\n\(failures.joined(separator: "\n"))")
    }

    /// codex #190 F2: a writer that does async work asks the authority
    /// AGAIN at the moment it writes, not only at its entry. Each pair is
    /// (member, the in-flight re-check it must contain).
    static let inFlightRechecks: [(String, String)] = [
        ("FamilyTreeLiveModel.swift:recompile", "store.guarded {"),
        ("FamilyTreeLiveModel.swift:removeDocument", "authority.check(.document"),
        ("FamilyTreeLiveModel.swift:cyberBrainRecorder", "try authority.check(.note"),
        ("FamilyAssetStore.swift:writePersonPhotoData", "try requireWriteAccess()"),
        ("FamilyAssetStore.swift:ensureSafeDirectory", "try requireWriteAccess()"),
        ("FamilyTreeRecompileCenter.swift:recompile", "guarded.writeGuard"),
        ("FamilyTreeWalkCenter.swift:save", "FamilyTreeWriteGate.check(.walkDecorations"),
        ("FamilySearchPersonRefreshCoordinator.swift:writeOverlay", "FamilyTreeWriteGate.refuse(.personRefresh"),
        ("FamilySearchPersonRefreshCoordinator.swift:apply", "\"PersonRefresh.journal\""),
        ("FamilySearchPersonRefreshCoordinator.swift:undoLast", "\"PersonRefresh.journal\""),
        ("FamilySearchPullCoordinator.swift:stageMerge", "\"FamilySearchPull.merge (sidecars + staging)\""),
        ("FamilySearchPullCoordinator.swift:abandonIfRevoked", "\"FamilySearchPull.activate\""),
        ("FamilySearchPullCoordinator.swift:performMerge", "abandonIfRevoked(staged"),
        ("RecordFinderFiling.swift:writeDocument", "\"RecordFinderFiler.file (write)\""),
        // Asset-store writers started from the view: a LIVE store re-reads
        // the published authority inside every write.
        ("FamilyTreeView.swift:persistPhotoChoice", "makeLiveStore()"),
        ("FamilyTreeView.swift:presentAdjustPhoto", "makeLiveStore()"),
        ("FamilyTreeDocumentsUI.swift:add", "makeLiveStore()"),
        ("RecordFinderFoundSheet.swift:file", "makeLiveStore()"),
        ("FamilyTreeLiveModel.swift:revealOriginalsFolder", "makeLiveStore()"),
    ]

    @Test func everyAsyncWriterRechecksAtTheMomentOfTheWrite() throws {
        let files = try Self.familyTreeSources()
        for (member, token) in Self.inFlightRechecks {
            let raw = try #require(files.first { $0.0 == member.split(separator: ":")[0].description }?.1)
            // String tokens are matched in the raw member text (the lexer
            // blanks string contents); code tokens in the code-only text.
            let scanned = Self.scan(raw)
            let name = String(member.split(separator: ":")[1])
            let rows = scanned.lines.indices.filter { scanned.owner[$0] == name }
            let rawLines = raw.components(separatedBy: "\n")
            let body = rows.map { rawLines[$0] }.joined(separator: "\n")
            #expect(!rows.isEmpty, "\(member) not found")
            #expect(body.contains(token), "\(member) has no in-flight re-check `\(token)`")
        }
        // F1: the model never lists the archive to resolve its sources.
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

    /// The test can see a planted ungated writer (the sensor senses).
    @Test func theScannerFlagsAnUngatedWriter() throws {
        let planted = """
        struct Planted {
            func gated() throws {
                try FamilyTreeWriteGate.check(.bookmark, path: "p", mode: .full)
                try Data().write(to: URL(fileURLWithPath: "/tmp/x"))
            }
            func sneaky() throws {
                let s = "FamilyTreeWriteGate. in a string does not count"
                // FamilyTreeWriteGate.check in a comment does not count
                try Data().write(to: URL(fileURLWithPath: "/tmp/y"))
            }
        }
        """
        let scanned = Self.scan(planted)
        let regex = try NSRegularExpression(pattern: Self.writeTokens.joined(separator: "|"))
        var verdicts: [String: Bool] = [:]
        for (i, line) in scanned.lines.enumerated() where Self.matches(regex, line) {
            let body = scanned.lines[scanned.ownerStart[i]...i].joined(separator: "\n")
            verdicts[scanned.owner[i]] = Self.gateTokens.contains(where: body.contains)
        }
        #expect(verdicts == ["gated": true, "sneaky": false])
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
            let owner = scopes.feed(code, line: lineNo)
            out.lines.append(code)
            out.owner.append(owner.name)
            out.ownerStart.append(owner.start)
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
        struct Scope { let name: String?; let isMember: Bool; let start: Int }
        struct Pending { let name: String; let parens: Int; let isFunc: Bool; let line: Int }
        var stack: [Scope] = []
        var pending: Pending?
        var parens = 0
        static let decl = try! NSRegularExpression(
            pattern: #"(?<![.\w])(?:func\s+([A-Za-z_]\w*)|(init)\??\s*[(<]|(?:var|let)\s+([A-Za-z_]\w*)\b)"#)

        mutating func feed(_ code: String, line: Int) -> (name: String, start: Int) {
            noteDeclaration(in: code, line: line)
            var owner = currentOwner(line: line)
            for ch in code { count(ch) }
            // A member that opened on this line owns this line.
            if owner.name == "top" || owner.name.hasPrefix("var ") {
                let now = currentOwner(line: line)
                if now.name != "top" { owner = now }
            }
            // A `var`/`let` owns a body only if it opens on its own line
            // (`if case .x(let y) = z {` is not a declaration with a body); a
            // func whose parentheses closed below its own level is gone.
            if let p = pending, !p.isFunc || parens < p.parens { pending = nil }
            return owner
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
