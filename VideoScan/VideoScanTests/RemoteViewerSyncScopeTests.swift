// RemoteViewerSyncScopeTests.swift
// Phase 1 remote use, slice 1 — sync scope (docs/remote_use_design.md).
//
// What a porch Mac mirrors from the master: catalog + POI (as before) PLUS
// the compiled family tree (pointer + current generation + sources/), the
// originals, People/ enrichments (external — on the master's RAID), the
// CyberBrain, and Hallie's pronunciation files. Covered here:
//   - the rsync include rules name every scope entry and every ancestor
//     directory, with the exclude-all last;
//   - a full allow-list round trip through the injected rsync stub,
//     including the second rsync for the external People/ source the
//     master named in sync-sources.json;
//   - a partial sync (external rsync fails) and a corrupted staged
//     artifact both leave the viewer on its last-good set;
//   - a generation the viewer's build refuses for version reasons yields
//     the viewer banner state, never a Recompile / ingest;
//   - the viewer decodes the master's generation WITHOUT the raw sources
//     on disk (trusts the synced manifest) and refuses every store write;
//   - master mode is unchanged (sensor).
//
// All I/O is confined to NSTemporaryDirectory() subdirectories. Nothing
// touches ~/Library/Application Support/VideoScan/. The process-wide
// ViewerModeCenter is reset in every test that installs a role, and the
// suite is serialized so two tests cannot race on it.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

// MARK: - Helpers

private struct FixedHostname: HostnameSource {
    let value: String
    func currentHostname() -> String { value }
}

/// rsync stub that understands BOTH invocations the viewer makes: the main
/// mirror (source arg ends in "VideoScan/") copies `masterTree`; an
/// external-source run copies the directory that `externalMap` maps the
/// remote path to. Records every args list for assertions.
private final class MappingRsync: RsyncRunner, @unchecked Sendable {
    let masterTree: URL
    /// remote absolute path (as it appears in sync-sources.json) → local dir.
    var externalMap: [String: URL]
    var failExternal = false
    var failMain = false
    private(set) var invocations: [[String]] = []
    var postCopyHook: ((URL) -> Void)?

    init(masterTree: URL, externalMap: [String: URL] = [:]) {
        self.masterTree = masterTree
        self.externalMap = externalMap
    }

    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        invocations.append(args)
        let fm = FileManager.default
        guard let source = args.first(where: { $0.contains("@") }) else {
            return RsyncOutcome(succeeded: false, exitCode: 2, stderr: "no source")
        }
        let remotePath = String(source.drop(while: { $0 != ":" }).dropFirst())
            .replacingOccurrences(of: "\\ ", with: " ")
        if remotePath.hasSuffix("VideoScan/") {
            if failMain { return RsyncOutcome(succeeded: false, exitCode: 255, stderr: "stub main failure") }
            try? fm.removeItem(at: destDir)
            try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            // Honour the include rules loosely: copy every top-level entry
            // that some include rule names (the real rsync prunes the rest).
            let includes = args.filter { $0.hasPrefix("--include=") }.map { String($0.dropFirst("--include=".count)) }
            if let kids = try? fm.contentsOfDirectory(at: masterTree, includingPropertiesForKeys: nil) {
                for k in kids {
                    let name = k.lastPathComponent
                    let named = includes.contains { $0 == name || $0.hasPrefix(name + "/") }
                    guard named else { continue }
                    try? fm.copyItem(at: k, to: destDir.appendingPathComponent(name))
                }
            }
            postCopyHook?(destDir)
            return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
        }
        if failExternal { return RsyncOutcome(succeeded: false, exitCode: 23, stderr: "stub external failure") }
        let trimmed = remotePath.hasSuffix("/") ? String(remotePath.dropLast()) : remotePath
        guard let local = externalMap[trimmed] else {
            return RsyncOutcome(succeeded: false, exitCode: 23, stderr: "unmapped external \(trimmed)")
        }
        try? fm.removeItem(at: destDir)
        try? fm.createDirectory(at: destDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? fm.copyItem(at: local, to: destDir)
        return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
    }
}

@MainActor
private func scratch(_ tag: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
        .appendingPathComponent("videoscan_viewer_\(tag)_\(UUID().uuidString)", isDirectory: true)
}

@MainActor
private func makePaths(under root: URL) -> CatalogSyncPaths {
    CatalogSyncPaths(
        liveDir: root.appendingPathComponent("live", isDirectory: true),
        stagingDir: root.appendingPathComponent("staging", isDirectory: true),
        previousDir: root.appendingPathComponent("previous", isDirectory: true),
        lastSyncFile: root.appendingPathComponent("last_sync.txt"))
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

/// A master Application Support tree with EVERY phase-1 entry populated,
/// plus two out-of-scope files that must never reach a viewer. The
/// compiled generation is a real one (ingested from a synthetic pedigree)
/// so the viewer can decode it.
@MainActor
private func populateMaster(at root: URL, peopleOutside: URL) throws -> (gedcom: URL, generation: String) {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try write("{\"version\":4,\"records\":[]}", to: root.appendingPathComponent("catalog.json"))
    try write("{\"version\":4,\"records\":[],\"prev\":true}", to: root.appendingPathComponent("catalog.json.prev"))
    try write("fake-jpeg-A", to: root.appendingPathComponent("POI/donna/face_a.jpg"))
    try write("{\"name\":\"Donna\"}", to: root.appendingPathComponent("POI/donna/profile.json"))
    try write("{\"schema\":1,\"items\":[]}", to: root.appendingPathComponent("cyberbrain/cyberbrain.json"))
    try write("{\"entries\":[]}", to: root.appendingPathComponent("Hallie/pronunciations.json"))
    try write("{\"drill\":[]}", to: root.appendingPathComponent("Hallie/pronunciation-drill.json"))
    // Out of scope: per-machine caches and a stray backup.
    try write("sqlite-bytes", to: root.appendingPathComponent("metadata_cache.sqlite"))
    try write("{}", to: root.appendingPathComponent("catalog.manual-backup-1.json"))
    // Originals + a real compiled generation.
    let gedcom = root.appendingPathComponent("family-tree/originals/family.ged")
    try write(GedcomSyntheticPedigree.gedcom(people: 60, generations: 4), to: gedcom)
    var store = FamilyGraphCompiledStore(root: root.appendingPathComponent("family-tree/compiled", isDirectory: true))
    store.log = { _ in }
    let graph = try #require(GedcomFamilyGraph(fileURL: gedcom))
    #expect(store.ingest(graph: graph, sources: [gedcom]) != nil)
    let generation = try #require(store.readPointer()?.current)
    // External People/ enrichments, OUTSIDE the tree (the RAID on the master).
    try write("photo-bytes", to: peopleOutside.appendingPathComponent("Donna_Breen/portrait.jpg"))
    try write("{\"notes\":\"x\"}", to: peopleOutside.appendingPathComponent("Donna_Breen/enrichment.json"))
    return (gedcom, generation)
}

private func sha(_ url: URL) throws -> String { try CatalogSync.sha256Hex(of: url) }

@MainActor
private func makeSync(paths: CatalogSyncPaths, host: String, master: String = "RicksM4.local",
                      runner: RsyncRunner, external: [String: URL] = [:],
                      log: @escaping (String) -> Void = { _ in }) -> CatalogSync {
    try? FileManager.default.createDirectory(at: paths.liveDir, withIntermediateDirectories: true)
    return CatalogSync(paths: paths,
                       hostnameSource: FixedHostname(value: host),
                       rsyncRunner: runner,
                       masterHostname: master,
                       remoteUser: "rickb",
                       externalSources: { external },
                       log: log)
}

// MARK: - Scope rules

@MainActor
struct RemoteViewerScopeRuleTests {
    @Test func phase1IncludeRulesNameEveryEntryAndAncestor() {
        let rules = CatalogSyncScope.phase1.rsyncIncludeRules
        for expected in [
            "--include=manifest.sha256",
            "--include=catalog.json", "--include=catalog.json.prev",
            "--include=POI/", "--include=POI/**",
            "--include=family-tree/", "--include=family-tree/compiled/", "--include=family-tree/compiled/**",
            "--include=family-tree/originals/", "--include=family-tree/originals/**",
            "--include=family-tree/assets/", "--include=family-tree/assets/People/", "--include=family-tree/assets/People/**",
            "--include=cyberbrain/", "--include=cyberbrain/cyberbrain.json",
            "--include=Hallie/", "--include=Hallie/**",
            "--include=sync-sources.json",
        ] {
            #expect(rules.contains(expected), Comment(rawValue: expected))
        }
        #expect(rules.last == "--exclude=*", "exclude-all must be the final rule")
        // Ancestors are listed once even when several entries share them.
        #expect(rules.filter { $0 == "--include=family-tree/" }.count == 1)
    }

    @Test func viewerRsyncArgumentsCarryTheScopeAndTheEscapedRemoteRoot() {
        let paths = makePaths(under: scratch("args"))
        let sync = makeSync(paths: paths, host: "ricksm5.local", runner: MappingRsync(masterTree: paths.liveDir))
        let args = sync.rsyncArguments(stagingDir: URL(fileURLWithPath: "/tmp/staging"))
        #expect(args.contains("--include=family-tree/compiled/**"))
        #expect(args.contains("--include=cyberbrain/cyberbrain.json"))
        let excludeIndex = args.firstIndex(of: "--exclude=*")
        let lastInclude = args.lastIndex(where: { $0.hasPrefix("--include=") })
        #expect(excludeIndex != nil && lastInclude != nil && lastInclude! < excludeIndex!)
        let source = args.first(where: { $0.contains("@") })
        #expect(source?.hasPrefix("rickb@RicksM4.local:") == true)
        #expect(source?.contains(#"Application\ Support"#) == true)
        #expect(args.last == "/tmp/staging/")
    }

    @Test func externalRsyncArgumentsTargetTheStagedRelativePath() {
        let paths = makePaths(under: scratch("ext"))
        let sync = makeSync(paths: paths, host: "ricksm5.local", runner: MappingRsync(masterTree: paths.liveDir))
        let args = sync.rsyncArguments(externalSource: "/Volumes/Family Archive/40_Family_Tree/People",
                                       stagingDir: paths.stagingDir, relativePath: "family-tree/assets/People")
        let source = args.first(where: { $0.contains("@") })
        #expect(source == #"rickb@RicksM4.local:/Volumes/Family\ Archive/40_Family_Tree/People/"#)
        #expect(args.last == paths.stagingDir.appendingPathComponent("family-tree/assets/People").path + "/")
        #expect(args.contains("--exclude=.*"), "dotfiles (.DS_Store) never travel")
    }

    @Test func externalSourcesMapOnlyWhenPeopleLivesOutsideApplicationSupport() {
        let live = URL(fileURLWithPath: "/Users/rickb/Library/Application Support/VideoScan")
        let inside = live.appendingPathComponent("family-tree/assets")
        #expect(CatalogSync.externalSources(assetsRoot: inside, liveDir: live).isEmpty)
        let raid = URL(fileURLWithPath: "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree")
        let mapped = CatalogSync.externalSources(assetsRoot: raid, liveDir: live)
        #expect(mapped["family-tree/assets/People"]?.path == raid.appendingPathComponent("People").path)
    }

    @Test func compiledStoreManifestCoversPointerCurrentGenerationAndSourcesOnly() throws {
        let root = scratch("compiled-scope")
        defer { try? FileManager.default.removeItem(at: root) }
        let compiled = root.appendingPathComponent("family-tree/compiled")
        try write("{\"current\":\"gen-B\",\"previous\":\"gen-A\",\"schema\":3,\"codec\":5,\"index\":2,\"sourceKeys\":[]}",
                  to: compiled.appendingPathComponent("current.json"))
        try write("A", to: compiled.appendingPathComponent("gen-A/tree.vsft"))
        try write("B", to: compiled.appendingPathComponent("gen-B/tree.vsft"))
        try write("B", to: compiled.appendingPathComponent("gen-B/manifest.json"))
        try write("k", to: compiled.appendingPathComponent("sources/abc.sha256"))
        try write("lock", to: compiled.appendingPathComponent(".lock"))
        let lines = try CatalogSync.computeManifestLines(
            rootDir: root, scope: CatalogSyncScope(entries: [.compiledStore("family-tree/compiled")]))
        let paths = lines.map { String($0.split(separator: "  ", maxSplits: 1)[1]) }
        #expect(paths.contains("family-tree/compiled/current.json"))
        #expect(paths.contains("family-tree/compiled/gen-B/tree.vsft"))
        #expect(paths.contains("family-tree/compiled/gen-B/manifest.json"))
        #expect(paths.contains("family-tree/compiled/sources/abc.sha256"))
        #expect(!paths.contains { $0.contains("gen-A") }, "the previous generation is a rollback spare, not synced truth")
        #expect(!paths.contains { $0.contains(".lock") })
    }
}

// MARK: - Round trip, partial, corrupt, refused

@MainActor
@Suite(.serialized)
struct RemoteViewerSyncRoundTripTests {

    /// Master writes manifest (+ sync-sources.json); viewer mirrors,
    /// pulls the external People/, verifies, swaps. Every scope entry is
    /// live on the viewer; nothing out of scope is.
    @Test func allowListRoundTripThroughTheInjectedRsyncStub() async throws {
        let root = scratch("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        let raidPeople = root.appendingPathComponent("raid/40_Family_Tree/People", isDirectory: true)
        let (_, generation) = try populateMaster(at: masterTree, peopleOutside: raidPeople)

        // Master side: manifest with the external mapping.
        let masterPaths = CatalogSyncPaths(liveDir: masterTree,
                                           stagingDir: root.appendingPathComponent("m-staging"),
                                           previousDir: root.appendingPathComponent("m-previous"),
                                           lastSyncFile: root.appendingPathComponent("m-last.txt"))
        let master = makeSync(paths: masterPaths, host: "RicksM4", runner: MappingRsync(masterTree: masterTree),
                              external: ["family-tree/assets/People": raidPeople])
        #expect(master.mode == .master)
        master.writeManifestIfMaster()
        let manifest = try String(contentsOf: masterTree.appendingPathComponent("manifest.sha256"), encoding: .utf8)
        #expect(manifest.contains("family-tree/assets/People/Donna_Breen/portrait.jpg"))
        #expect(manifest.contains("family-tree/compiled/\(generation)/tree.vsft"))
        #expect(manifest.contains("cyberbrain/cyberbrain.json"))
        #expect(manifest.contains("Hallie/pronunciation-drill.json"))
        #expect(manifest.contains("sync-sources.json"))
        #expect(!manifest.contains("metadata_cache.sqlite"))
        #expect(CatalogSync.readExternalSourcesFile(in: masterTree) == ["family-tree/assets/People": raidPeople.standardizedFileURL.path])

        // Viewer side.
        let viewerPaths = makePaths(under: root.appendingPathComponent("viewer"))
        let runner = MappingRsync(masterTree: masterTree, externalMap: [raidPeople.standardizedFileURL.path: raidPeople])
        var lines: [String] = []
        let viewer = makeSync(paths: viewerPaths, host: "ricksm5.local", runner: runner, log: { lines.append($0) })
        #expect(viewer.mode == .viewer)
        await viewer.syncFromMaster()
        #expect(viewer.state.isSynced, "sync failed: \(lines.suffix(3))")
        #expect(runner.invocations.count == 2, "main mirror + one external rsync")

        let live = viewerPaths.liveDir
        for rel in ["catalog.json", "POI/donna/profile.json",
                    "family-tree/compiled/current.json", "family-tree/compiled/\(generation)/tree.vsft",
                    "family-tree/originals/family.ged",
                    "family-tree/assets/People/Donna_Breen/portrait.jpg",
                    "cyberbrain/cyberbrain.json", "Hallie/pronunciations.json", "Hallie/pronunciation-drill.json",
                    "sync-sources.json", "manifest.sha256"] {
            #expect(FileManager.default.fileExists(atPath: live.appendingPathComponent(rel).path), Comment(rawValue: rel))
        }
        for rel in ["metadata_cache.sqlite", "catalog.manual-backup-1.json"] {
            #expect(!FileManager.default.fileExists(atPath: live.appendingPathComponent(rel).path), Comment(rawValue: rel))
        }
        #expect(try sha(live.appendingPathComponent("family-tree/compiled/\(generation)/tree.vsft"))
                == sha(masterTree.appendingPathComponent("family-tree/compiled/\(generation)/tree.vsft")))
        // The swapped-in set verifies again in place.
        #expect(throws: Never.self) { try viewer.verifyManifest(in: live) }

        // Second sync rotates the first into .sync-previous, nested paths intact.
        await viewer.syncFromMaster()
        #expect(viewer.state.isSynced)
        #expect(FileManager.default.fileExists(atPath: viewerPaths.previousDir.appendingPathComponent("family-tree/compiled/current.json").path))
    }

    @Test func failedExternalRsyncLeavesLastGoodSetUntouched() async throws {
        let root = scratch("partial")
        defer { try? FileManager.default.removeItem(at: root) }
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        let raidPeople = root.appendingPathComponent("raid/People", isDirectory: true)
        _ = try populateMaster(at: masterTree, peopleOutside: raidPeople)
        try CatalogSync.computeAndWriteManifest(liveDir: masterTree, scope: .phase1,
                                                externalSources: ["family-tree/assets/People": raidPeople])

        let viewerPaths = makePaths(under: root.appendingPathComponent("viewer"))
        let runner = MappingRsync(masterTree: masterTree, externalMap: [raidPeople.standardizedFileURL.path: raidPeople])
        let viewer = makeSync(paths: viewerPaths, host: "ricksm5.local", runner: runner)
        await viewer.syncFromMaster()
        #expect(viewer.state.isSynced)
        let goodCatalog = try sha(viewerPaths.liveDir.appendingPathComponent("catalog.json"))
        let goodPeople = try sha(viewerPaths.liveDir.appendingPathComponent("family-tree/assets/People/Donna_Breen/portrait.jpg"))

        // Master changes, then the RAID goes away mid-sync.
        try write("{\"version\":4,\"records\":[{\"new\":true}]}", to: masterTree.appendingPathComponent("catalog.json"))
        try CatalogSync.computeAndWriteManifest(liveDir: masterTree, scope: .phase1,
                                                externalSources: ["family-tree/assets/People": raidPeople])
        runner.failExternal = true
        await viewer.syncFromMaster()
        guard case .failed(let reason) = viewer.state.phase else {
            Issue.record("expected failure, got \(viewer.state.phase)"); return
        }
        #expect(reason.contains("family-tree/assets/People"))
        #expect(try sha(viewerPaths.liveDir.appendingPathComponent("catalog.json")) == goodCatalog, "live catalog must be the last-good one")
        #expect(try sha(viewerPaths.liveDir.appendingPathComponent("family-tree/assets/People/Donna_Breen/portrait.jpg")) == goodPeople)
        #expect(viewer.state.lastSuccessfulSync != nil)
    }

    @Test func corruptedStagedArtifactFailsVerifyAndKeepsLastGood() async throws {
        let root = scratch("corrupt")
        defer { try? FileManager.default.removeItem(at: root) }
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        let raidPeople = root.appendingPathComponent("raid/People", isDirectory: true)
        let (_, generation) = try populateMaster(at: masterTree, peopleOutside: raidPeople)
        try CatalogSync.computeAndWriteManifest(liveDir: masterTree, scope: .phase1,
                                                externalSources: ["family-tree/assets/People": raidPeople])
        let viewerPaths = makePaths(under: root.appendingPathComponent("viewer"))
        let runner = MappingRsync(masterTree: masterTree, externalMap: [raidPeople.standardizedFileURL.path: raidPeople])
        let viewer = makeSync(paths: viewerPaths, host: "ricksm5.local", runner: runner)
        await viewer.syncFromMaster()
        #expect(viewer.state.isSynced)
        let good = try sha(viewerPaths.liveDir.appendingPathComponent("family-tree/compiled/\(generation)/tree.vsft"))

        runner.postCopyHook = { staging in
            try? Data("garbage".utf8).write(to: staging.appendingPathComponent("family-tree/compiled/\(generation)/tree.vsft"))
        }
        await viewer.syncFromMaster()
        guard case .failed(let reason) = viewer.state.phase else {
            Issue.record("expected failure, got \(viewer.state.phase)"); return
        }
        #expect(reason.contains("sha256 mismatch"))
        #expect(try sha(viewerPaths.liveDir.appendingPathComponent("family-tree/compiled/\(generation)/tree.vsft")) == good)
    }

    /// The master's pointer names a schema this build does not read. On a
    /// viewer that is the banner state: no graph, `needsRecompile` set,
    /// NO parse of the originals, NO ingest, and the banner names the
    /// master.
    @Test func versionRefusedGenerationOnViewerIsTheBannerStateNotARecompile() throws {
        let root = scratch("refused")
        defer { try? FileManager.default.removeItem(at: root); ViewerModeCenter.shared.reset() }
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        let (gedcom, generation) = try populateMaster(at: masterTree, peopleOutside: root.appendingPathComponent("raid/People"))
        let compiled = masterTree.appendingPathComponent("family-tree/compiled", isDirectory: true)
        // Bump the pointer's schema past what this build reads.
        let pointerURL = compiled.appendingPathComponent("current.json")
        var pointer = try JSONSerialization.jsonObject(with: Data(contentsOf: pointerURL)) as! [String: Any]
        pointer["schema"] = 999
        try JSONSerialization.data(withJSONObject: pointer).write(to: pointerURL)

        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        var logLines: [String] = []
        var store = FamilyGraphCompiledStore(root: compiled)
        store.log = { logLines.append($0) }
        store.trustsManifestSources = true
        store.refusesWrites = true
        var loader = FamilyGraphFileLoader(originalsDirectory: masterTree.appendingPathComponent("family-tree/originals"))
        loader.compiledStore = store
        loader.readOnly = true

        let outcome = loader.loadNewestOutcome()
        #expect(outcome.graph == nil)
        #expect(outcome.compiled == false)
        #expect(!outcome.needsRecompile.isEmpty)
        #expect(outcome.needsRecompile.contains { $0.path == gedcom.path })
        #expect(logLines.contains { $0.contains("viewer: compiled generation \(generation) was built by another version") })
        #expect(store.readPointer()?.current == generation, "the pointer is untouched")
        #expect(store.generations().count == 1, "no new generation was ingested")

        // The banner copy names the master; the Recompile path is refused.
        #expect(FamilyTreeViewerBanner.compiledElsewhereText() == "Family tree compiled on RicksM4 — sync again once the master is up to date.")
        #expect(loader.recompile(sources: outcome.needsRecompile) == nil)
        #expect(logLines.contains { $0.hasPrefix(FamilyGraphCompiledStore.refusedWritePrefix) && $0.contains("recompile") })
        // An ingest on this store is refused too, with the log line.
        let graph = try #require(GedcomFamilyGraph(fileURL: gedcom))
        #expect(store.ingest(graph: graph, sources: [gedcom]) == nil)
        #expect(logLines.contains { $0.hasPrefix(FamilyGraphCompiledStore.refusedWritePrefix) && $0.contains("ingest") })
        #expect(store.rollback() == false)
    }

    /// The viewer has the generation and its manifest but NOT the raw .ged
    /// at the master's recorded path. Trusting the synced manifest, it
    /// decodes; the master rule (re-hash the source) would miss.
    @Test func viewerDecodesTheMastersGenerationWithoutSourcesOnDisk() throws {
        let root = scratch("trust")
        defer { try? FileManager.default.removeItem(at: root) }
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        let (gedcom, _) = try populateMaster(at: masterTree, peopleOutside: root.appendingPathComponent("raid/People"))
        let expectedPeople = try #require(GedcomFamilyGraph(fileURL: gedcom)).people.count
        // Simulate "the source is on the master": remove the raw pull.
        try FileManager.default.removeItem(at: gedcom)
        let compiled = masterTree.appendingPathComponent("family-tree/compiled", isDirectory: true)

        var masterRule = FamilyGraphCompiledStore(root: compiled)
        masterRule.log = { _ in }
        #expect(masterRule.loadCurrent() == nil, "the master's rule misses when a source is gone")

        var viewerRule = FamilyGraphCompiledStore(root: compiled)
        viewerRule.log = { _ in }
        viewerRule.trustsManifestSources = true
        viewerRule.refusesWrites = true
        let current = try #require(viewerRule.loadCurrent())
        #expect(current.graph.people.count == expectedPeople)

        var loader = FamilyGraphFileLoader(originalsDirectory: masterTree.appendingPathComponent("family-tree/originals"))
        loader.compiledStore = viewerRule
        loader.readOnly = true
        let outcome = loader.loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(outcome.graph?.people.count == expectedPeople)
        #expect(outcome.needsRecompile.isEmpty)
    }

    /// Sensor: with the default (master) role nothing here changes the
    /// master's behaviour — the loader parses and promotes, the store
    /// re-hashes sources, the app store carries no viewer flags, the
    /// guard refuses nothing and logs nothing.
    @Test func masterModeIsUnchanged() throws {
        ViewerModeCenter.shared.reset()
        defer { ViewerModeCenter.shared.reset() }
        #expect(ViewerModeCenter.shared.isViewer == false)
        #expect(ViewerWriteGuard.refuse("sensor.probe") == false)
        #expect(ViewerModeCenter.shared.refusals.isEmpty)
        let app = FamilyGraphCompiledStore.app
        #expect(app.trustsManifestSources == false)
        #expect(app.refusesWrites == false)
        let loader = FamilyGraphFileLoader(originalsDirectory: URL(fileURLWithPath: "/nonexistent"))
        #expect(loader.readOnly == false)

        // A master with one pull and no generation still parses + promotes.
        let root = scratch("master-sensor")
        defer { try? FileManager.default.removeItem(at: root) }
        let originals = root.appendingPathComponent("originals")
        let ged = originals.appendingPathComponent("family.ged")
        try write(GedcomSyntheticPedigree.gedcom(people: 30, generations: 3), to: ged)
        var store = FamilyGraphCompiledStore(root: root.appendingPathComponent("compiled"))
        store.log = { _ in }
        var masterLoader = FamilyGraphFileLoader(originalsDirectory: originals)
        masterLoader.compiledStore = store
        let outcome = masterLoader.loadNewestOutcome()
        #expect(outcome.compiled == true)
        #expect(store.readPointer() != nil, "the master promoted a generation")

        // A master CatalogSync writes the manifest as before (catalog + POI
        // lines present) — the phase-1 entries are additive.
        let paths = makePaths(under: root.appendingPathComponent("sync"))
        try write("{\"version\":4,\"records\":[]}", to: paths.liveDir.appendingPathComponent("catalog.json"))
        try write("x", to: paths.liveDir.appendingPathComponent("POI/a/face.jpg"))
        let sync = makeSync(paths: paths, host: "RicksM4.local", runner: MappingRsync(masterTree: paths.liveDir))
        sync.writeManifestIfMaster()
        let manifest = try String(contentsOf: paths.liveDir.appendingPathComponent("manifest.sha256"), encoding: .utf8)
        #expect(manifest.contains("  catalog.json\n"))
        #expect(manifest.contains("  POI/a/face.jpg\n"))
        #expect(!FileManager.default.fileExists(atPath: paths.liveDir.appendingPathComponent("sync-sources.json").path),
                "no external sources → no map file")
        #expect(sync.viewerRole == .master)
    }
}
