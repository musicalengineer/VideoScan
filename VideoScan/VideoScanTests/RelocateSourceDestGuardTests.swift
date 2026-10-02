// RelocateSourceDestGuardTests.swift
// GH #109 — the Migrate sheet allowed source == destination
// (LaCieWorkspace → itself, an 18,878-record reconcile). The 2026-08-17
// check compared path STRINGS in the sheet only: a symlinked alias, the
// data-volume firmlink spelling or a different letter case slipped past
// it, and the model's `enqueueRelocate` accepted anything.
//
// Isolation: scratch directories under the test temp dir; the catalog is
// a private CatalogStore(directory:); no /Volumes path is created or
// written. Real-filesystem cases (symlink, firmlink, case) resolve the
// scratch directories themselves.

import Foundation
import Testing
@testable import VideoScan

@Suite("GH #109 — Migrate refuses source == destination, however it is spelled", .serialized)
@MainActor
struct RelocateSourceDestGuardTests {

    /// root/real (the source), root/alias → root/real (a symlink).
    private func workspace() throws -> (root: URL, real: URL, alias: URL, other: URL, catalog: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("test_109_guard_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = root.appendingPathComponent("SourceVol", isDirectory: true)
        let other = root.appendingPathComponent("OtherDest", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        for u in [real, other, catalog] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let alias = root.appendingPathComponent("AliasToSource")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        return (root, real, alias, other, catalog)
    }

    private func resolved(_ url: URL) -> String {
        guard let raw = realpath(url.path, nil) else { return url.path }
        defer { free(raw) }
        return String(cString: raw)
    }

    // MARK: Sheet check (the UI gate)

    @Test("a symlinked alias of the source is the source")
    func symlinkAliasIdentical() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: ws.alias) != nil)
    }

    @Test("a folder under a symlinked alias of the source is inside the source")
    func symlinkAliasNested() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.alias.appendingPathComponent("from_SourceVol")) != nil)
        #expect(RelocateSheet.destinationProblem(source: ws.alias.appendingPathComponent("sub").path,
                                                 destination: ws.real) != nil,
                "source inside the destination, spelled through the alias")
    }

    @Test("the data-volume firmlink spelling of the source is the source")
    func firmlinkSpelling() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let firm = "/System/Volumes/Data" + resolved(ws.real)
        try #require(FileManager.default.fileExists(atPath: firm), "firmlink spelling not present on this host")
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: URL(fileURLWithPath: firm + "/nested")) != nil)
    }

    @Test("a different letter case on a case-insensitive volume is the same folder")
    func caseFolded() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let caseSensitive = try ws.real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try #require(!caseSensitive, "scratch volume is case-sensitive")
        let upper = ws.root.appendingPathComponent("SOURCEVOL", isDirectory: true)
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: upper) != nil)
    }

    @Test("a sibling folder is still a valid destination (no over-refusal)")
    func siblingAllowed() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: ws.other) == nil)
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.other.appendingPathComponent("from_SourceVol/not-yet-created")) == nil)
        // A prefix-sharing name is not containment.
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.root.appendingPathComponent("SourceVol 1")) == nil)
    }

    // MARK: Physical-path semantics (codex 2026-10-02 #3, P1)
    //
    // `..` after a symlink means "the parent of the symlink's TARGET" to the
    // kernel. Collapsing `..` lexically first (standardizedFileURL) turned
    // other/alias/.. into `other` — a sibling — while the filesystem means
    // source itself.

    /// root/source/sub, root/other, root/other/alias → root/source/sub.
    private func dotDotWorkspace() throws -> (root: URL, source: URL, other: URL, alias: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("test_109_dotdot_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let other = root.appendingPathComponent("other", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent("sub", isDirectory: true), withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let alias = other.appendingPathComponent("alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: source.appendingPathComponent("sub", isDirectory: true))
        return (root, source, other, alias)
    }

    @Test("symlink followed by `..` is the symlink TARGET's parent: other/alias/.. ⇒ the source itself")
    func symlinkThenDotDotIsPhysical() throws {
        let ws = try dotDotWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocatePathGuard.refusal(source: ws.source.path, destination: ws.alias.path + "/..") == .identical)
        #expect(RelocatePathGuard.refusal(source: ws.source.path,
                                          destination: ws.alias.path + "/../not_yet_created") == .destinationInsideSource)
        // The sheet and the model share the resolver.
        #expect(RelocateSheet.destinationProblem(source: ws.source.path,
                                                 destination: URL(fileURLWithPath: ws.alias.path + "/..")) != nil)
        // No over-refusal: plain `..` with no symlink still means the lexical parent.
        #expect(RelocatePathGuard.refusal(source: ws.source.path,
                                          destination: ws.other.path + "/../other/new_dest") == nil)
    }

    @Test("a symlink LOOP in the destination is refused (unresolvable), never treated as a new folder")
    func symlinkLoopRefused() throws {
        let ws = try dotDotWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let a = ws.other.appendingPathComponent("loop_a"), b = ws.other.appendingPathComponent("loop_b")
        try FileManager.default.createSymbolicLink(atPath: a.path, withDestinationPath: b.path)
        try FileManager.default.createSymbolicLink(atPath: b.path, withDestinationPath: a.path)
        let r1 = RelocatePathGuard.refusal(source: ws.source.path, destination: a.path)
        let r2 = RelocatePathGuard.refusal(source: ws.source.path, destination: a.path + "/new_dest")
        guard case .unresolvable = r1 else { Issue.record("loop leaf: \(String(describing: r1))"); return }
        guard case .unresolvable = r2 else { Issue.record("loop prefix: \(String(describing: r2))"); return }
    }

    @Test("a DANGLING symlink pointing into the source is refused, never treated as a new folder beside it")
    func danglingSymlinkIntoSourceRefused() throws {
        let ws = try dotDotWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let dangling = ws.other.appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(atPath: dangling.path,
                                                   withDestinationPath: ws.source.appendingPathComponent("not_yet").path)
        #expect(RelocatePathGuard.refusal(source: ws.source.path, destination: dangling.path) != nil)
        #expect(RelocatePathGuard.refusal(source: ws.source.path, destination: dangling.path + "/deeper") != nil)
    }

    @Test("a folder we cannot search (EACCES) is refused — it may hide a symlink into the source")
    func unsearchableFolderRefused() throws {
        let ws = try dotDotWorkspace()
        let locked = ws.other.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: locked.appendingPathComponent("hidden").path,
                                                   withDestinationPath: ws.source.path)
        #expect(chmod(locked.path, 0o000) == 0)
        defer {
            _ = chmod(locked.path, 0o755)
            try? FileManager.default.removeItem(at: ws.root)
        }
        let r = RelocatePathGuard.refusal(source: ws.source.path, destination: locked.path + "/hidden/new_dest")
        guard case .unresolvable = r else { Issue.record("an unsearchable folder was guessed: \(String(describing: r))"); return }
    }

    // MARK: Model / job layer (the gate that cannot be bypassed)

    private func model(ws: (root: URL, real: URL, alias: URL, other: URL, catalog: URL)) throws -> VideoScanModel {
        let file = ws.real.appendingPathComponent("clip.bin")
        try Data(repeating: 7, count: 512).write(to: file)
        let rec = VideoRecord()
        rec.filename = "clip.bin"
        rec.fullPath = file.path
        rec.directory = ws.real.path
        rec.sizeBytes = 512
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: ws.catalog)
        m.records = [rec]
        return m
    }

    private func options(_ source: String, _ dest: URL) -> RelocateOptions {
        RelocateOptions(sourceVolumeRootPath: source, destinationRoot: dest,
                        maxConcurrency: 1, dryRun: true, skipAlreadyRelocated: true)
    }

    @Test("enqueueRelocate refuses source == destination before queuing anything")
    func enqueueRefusesIdentical() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let m = try model(ws: ws)
        let id = m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: ws.real,
                                   options: options(ws.real.path, ws.real))
        #expect(id == nil)
        #expect(m.relocateQueue.isEmpty, "a refused Migrate must not queue a job")
    }

    @Test("enqueueRelocate refuses a symlinked alias and a nested destination")
    func enqueueRefusesAliasAndNested() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let m = try model(ws: ws)
        #expect(m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: ws.alias,
                                  options: options(ws.real.path, ws.alias)) == nil)
        let nested = ws.real.appendingPathComponent("from_SourceVol")
        #expect(m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: nested,
                                  options: options(ws.real.path, nested)) == nil)
        #expect(m.relocateQueue.isEmpty)
    }
}

// MARK: - Volume identity (RelocatePathGuard)

@Suite("GH #109 — same volume under different names", .serialized)
@MainActor
struct RelocatePathGuardIdentityTests {

    /// One volume (UUID TEST-VOL-U) seen as "/Volumes/LaCieWorkspace" AND
    /// "/Volumes/LaCieWorkspace 1"; a different volume that happens to
    /// share a folder name.
    private static let stub: @Sendable (String) -> RelocatePathLocation? = { path in
        let comps = URL(fileURLWithPath: path).standardizedFileURL.pathComponents
        guard comps.count >= 3, comps[1] == "Volumes" else { return nil }
        let below = Array(comps.dropFirst(3))
        switch comps[2] {
        case "LaCieWorkspace", "LaCieWorkspace 1":
            return RelocatePathLocation(volumeKey: "TEST-VOL-U", components: below,
                                        caseInsensitive: true, resolvedPath: path)
        case "OtherVolume":
            return RelocatePathLocation(volumeKey: "TEST-VOL-OTHER", components: below,
                                        caseInsensitive: true, resolvedPath: path)
        default:
            return nil
        }
    }

    @Test("two mount names of one volume: identical, nested, containing")
    func sameVolumeDifferentNames() {
        RelocatePathGuard.$locate.withValue(Self.stub) {
            #expect(RelocatePathGuard.refusal(source: "/Volumes/LaCieWorkspace",
                                              destination: "/Volumes/LaCieWorkspace 1") == .identical)
            #expect(RelocatePathGuard.refusal(source: "/Volumes/LaCieWorkspace",
                                              destination: "/Volumes/LaCieWorkspace 1/from_LaCieWorkspace")
                    == .destinationInsideSource)
            #expect(RelocatePathGuard.refusal(source: "/Volumes/LaCieWorkspace 1/Projects/2004",
                                              destination: "/Volumes/LaCieWorkspace/projects")
                    == .sourceInsideDestination, "case-folded on a case-insensitive volume")
        }
    }

    @Test("different volumes never overlap, even with matching folder names")
    func differentVolumes() {
        RelocatePathGuard.$locate.withValue(Self.stub) {
            #expect(RelocatePathGuard.refusal(source: "/Volumes/LaCieWorkspace/A",
                                              destination: "/Volumes/OtherVolume/A") == nil)
        }
    }

    @Test("a path that cannot be located is refused, not guessed")
    func unresolvableRefused() {
        RelocatePathGuard.$locate.withValue(Self.stub) {
            #expect(RelocatePathGuard.refusal(source: "/Volumes/LaCieWorkspace",
                                              destination: "/Volumes/NoSuchThing/x")
                    == .unresolvable("/Volumes/NoSuchThing/x"))
        }
        #expect(RelocatePathGuard.refusal(source: "", destination: "/tmp") != nil)
    }

    @Test("the model refuses a same-volume-different-name Migrate before queuing")
    func modelRefusesSameVolumeAlias() throws {
        let catalog = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_109_identity_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: catalog) }
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: catalog)
        let rec = VideoRecord()
        rec.filename = "clip.mov"
        rec.fullPath = "/Volumes/LaCieWorkspace/clip.mov"
        m.records = [rec]
        let dest = URL(fileURLWithPath: "/Volumes/LaCieWorkspace 1")
        let opts = RelocateOptions(sourceVolumeRootPath: "/Volumes/LaCieWorkspace", destinationRoot: dest,
                                   maxConcurrency: 1, dryRun: true, skipAlreadyRelocated: true)
        let id = RelocatePathGuard.$locate.withValue(Self.stub) {
            m.enqueueRelocate(sourceRootPath: "/Volumes/LaCieWorkspace", destinationRoot: dest, options: opts)
        }
        #expect(id == nil)
        #expect(m.relocateQueue.isEmpty)
    }
}

// MARK: - Sensor

@Suite("GH #109 — sensor: every Migrate gate consults the path guard")
struct RelocatePathGuardSensor {
    @Test("enqueueRelocate, runRelocate(jobID:) and the sheet go through the path guard")
    func gatesWired() throws {
        let queue = try SourceTree.appSource(named: "VideoScanModel+RelocateQueue.swift")
        let run = try SourceTree.appSource(named: "VideoScanModel+Relocate.swift")
        let sheet = try SourceTree.appSource(named: "RelocateSheet.swift")
        let gate = try SourceTree.appSource(named: "RelocatePathGuard.swift")
        #expect(queue.contains("refuseOverlappingMigrate("))
        #expect(run.contains("refuseOverlappingMigrate("))
        #expect(gate.contains("RelocatePathGuard.refusal(source: source, destination: destination.path)"))
        #expect(sheet.contains("RelocatePathGuard.refusal("))
        #expect(!sheet.contains("dst.hasPrefix(src"), "the string-prefix check must not come back")
    }
}
