// RemoteViewerIsolationTests.swift
// Phase 1 remote use, slice 5 — isolation (docs/remote_use_design.md §5).
//
// A viewer starting from a POISONED world: garbage catalog.json, a
// compiled pointer that is not JSON, a stale .sync-staging full of junk, a
// symlink where a directory should be, a defaults suite with the wrong
// types under every key this feature reads, and a hostname that decides
// the role (injected, never read from the machine). Expected: the role
// comes from the hostname alone; every reader answers sanely without
// writing; a successful sync replaces the poison with the master's
// verified set; a failed sync leaves whatever last-good there was; the
// master role over the same poison writes only its manifest.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

private struct FixedHostname: HostnameSource {
    let value: String
    func currentHostname() -> String { value }
}

/// Mirrors the master tree (honouring top-level include names) or fails.
private final class StubRsync: RsyncRunner, @unchecked Sendable {
    let masterTree: URL
    var fail = false
    init(masterTree: URL) { self.masterTree = masterTree }
    func run(args: [String], destDir: URL) async -> RsyncOutcome {
        if fail { return RsyncOutcome(succeeded: false, exitCode: 255, stderr: "master offline") }
        let fm = FileManager.default
        try? fm.removeItem(at: destDir)
        try? fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        let includes = args.filter { $0.hasPrefix("--include=") }.map { String($0.dropFirst("--include=".count)) }
        for k in (try? fm.contentsOfDirectory(at: masterTree, includingPropertiesForKeys: nil)) ?? [] {
            let name = k.lastPathComponent
            guard includes.contains(where: { $0 == name || $0.hasPrefix(name + "/") }) else { continue }
            try? fm.copyItem(at: k, to: destDir.appendingPathComponent(name))
        }
        return RsyncOutcome(succeeded: true, exitCode: 0, stderr: "")
    }
}

private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

@MainActor
private func poison(appSupport root: URL) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try write("not json at all {{{", to: root.appendingPathComponent("catalog.json"))
    try write("", to: root.appendingPathComponent("manifest.sha256"))
    try write("<html>", to: root.appendingPathComponent("family-tree/compiled/current.json"))
    try write("junk", to: root.appendingPathComponent("family-tree/compiled/gen-junk/tree.vsft"))
    try write("garbage", to: root.appendingPathComponent(".sync-staging/catalog.json"))
    try write("{\"items\":", to: root.appendingPathComponent("cyberbrain/cyberbrain.json"))
    try write("\u{0}\u{1}", to: root.appendingPathComponent("Hallie/pronunciations.json"))
    try write("{\"family-tree/assets/People\":\"../../etc\", \"/abs\":\"/x\", \"ok\":\"relative\"}",
              to: root.appendingPathComponent("sync-sources.json"))
    // A symlink where POI/ should be a directory.
    try fm.createDirectory(at: root.appendingPathComponent("elsewhere"), withIntermediateDirectories: true)
    try fm.createSymbolicLink(at: root.appendingPathComponent("POI"), withDestinationURL: root.appendingPathComponent("elsewhere"))
}

private func poisonedDefaults() -> (UserDefaults, String) {
    let suite = "RemoteViewerIsolation.\(UUID().uuidString)"
    let d = UserDefaults(suiteName: suite)!
    d.set(["FamilyArchive": 42, "X9": ["nested": true]], forKey: ViewerMediaSettings.mountedVolumesKey)
    d.set("eight-thousand", forKey: HallieWebAccess.portKey)
    d.set(12345, forKey: HallieWebAccess.passphraseKey)
    d.set(["not", "a", "string"], forKey: CatalogSyncDefaultsKey.masterHostname)
    d.set(NSNumber(value: 7), forKey: HallieRemoteClient.sessionKey)
    return (d, suite)
}

@MainActor
@Suite(.serialized)
struct RemoteViewerIsolationTests {

    @Test func viewerModeOverPoisonedAppSupportAndDefaults() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("viewer-iso-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); ViewerModeCenter.shared.reset() }
        let live = root.appendingPathComponent("AppSupport/VideoScan", isDirectory: true)
        try poison(appSupport: live)
        let (defaults, suite) = poisonedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        // Role is decided by the injected hostname, never by the poison.
        let paths = CatalogSyncPaths(liveDir: live,
                                     stagingDir: live.appendingPathComponent(".sync-staging"),
                                     previousDir: live.appendingPathComponent(".sync-previous"),
                                     lastSyncFile: live.appendingPathComponent("last_sync.txt"))
        let masterTree = root.appendingPathComponent("master", isDirectory: true)
        try write("{\"version\":4,\"records\":[]}", to: masterTree.appendingPathComponent("catalog.json"))
        try write("{\"entries\":[]}", to: masterTree.appendingPathComponent("Hallie/pronunciations.json"))
        try write("{\"schema\":1,\"items\":[]}", to: masterTree.appendingPathComponent("cyberbrain/cyberbrain.json"))
        try CatalogSync.computeAndWriteManifest(liveDir: masterTree, scope: .phase1)
        let runner = StubRsync(masterTree: masterTree)
        var log: [String] = []
        let sync = CatalogSync(paths: paths, hostnameSource: FixedHostname(value: "RicksM5"),
                               rsyncRunner: runner,
                               masterHostname: defaults.string(forKey: CatalogSyncDefaultsKey.masterHostname) ?? defaultMasterHostname,
                               remoteUser: "rickb", log: { log.append($0) })
        #expect(sync.mode == .viewer)
        #expect(sync.masterHostname == "RicksM4.local", "a non-string override falls back to the default master")
        ViewerModeCenter.shared.install(sync.viewerRole)
        #expect(ViewerModeCenter.shared.masterDisplayName == "RicksM4")

        // Every reader over the poison answers sanely and writes nothing.
        #expect(CatalogSync.readExternalSourcesFile(in: live).isEmpty, "unsafe keys and non-absolute values are dropped")
        #expect(CatalogSync.compiledStoreFiles(in: live.appendingPathComponent("family-tree/compiled")) == ["current.json", "sources"])
        let settings = ViewerMediaSettings(defaults: defaults)
        #expect(settings.mappedVolumes.isEmpty, "a non-[String: String] map reads as empty")
        let configuration = MediaStreamResolver.Configuration.fromDefaults(defaults, masterHostname: sync.masterHostname)
        #expect(configuration.port == HallieWebAccess.defaultPort)
        #expect(configuration.passphrase == "")
        #expect(HallieRemoteClient.sessionID(defaults).hasPrefix("viewer-"), "a non-string session is replaced")
        var store = FamilyGraphCompiledStore(root: live.appendingPathComponent("family-tree/compiled"))
        var storeLog: [String] = []
        store.log = { storeLog.append($0) }
        store.trustsManifestSources = true
        store.refusesWrites = true
        var loader = FamilyGraphFileLoader(originalsDirectory: live.appendingPathComponent("family-tree/originals"))
        loader.compiledStore = store
        loader.readOnly = true
        let outcome = loader.loadNewestOutcome()
        #expect(outcome.graph == nil && outcome.needsRecompile.isEmpty && outcome.compiled == false)
        #expect(store.readPointer() == nil, "the HTML pointer is unreadable, not repaired")
        #expect(try String(contentsOf: live.appendingPathComponent("family-tree/compiled/current.json"), encoding: .utf8) == "<html>")
        let resolver = MediaStreamResolver(role: sync.viewerRole, configuration: configuration,
                                           mappedVolumes: settings.mappedVolumes, masterReachable: false,
                                           isMounted: { _ in true })
        #expect(resolver.resolve(recordID: UUID(), fullPath: "/Volumes/FamilyArchive/x.mov", videoCodec: "h264")
                == .masterOffline(masterDisplayName: "RicksM4"))
        #expect(ViewerWriteGuard.refuse("isolation.probe") == true)

        // A failed sync leaves the poison as-is (it IS the last-good here).
        runner.fail = true
        await sync.syncFromMaster()
        guard case .failed = sync.state.phase else { Issue.record("expected failure"); return }
        #expect(try String(contentsOf: live.appendingPathComponent("catalog.json"), encoding: .utf8) == "not json at all {{{")

        // A successful sync replaces the poison with the verified master set,
        // rotates the poison into .sync-previous, and drops the junk staging.
        runner.fail = false
        await sync.syncFromMaster()
        #expect(sync.state.isSynced, "sync: \(log.suffix(3))")
        #expect(try String(contentsOf: live.appendingPathComponent("catalog.json"), encoding: .utf8) == "{\"version\":4,\"records\":[]}")
        #expect(try String(contentsOf: live.appendingPathComponent("Hallie/pronunciations.json"), encoding: .utf8) == "{\"entries\":[]}")
        #expect(try String(contentsOf: paths.previousDir.appendingPathComponent("catalog.json"), encoding: .utf8) == "not json at all {{{")
        #expect(!FileManager.default.fileExists(atPath: paths.stagingDir.path))
        // The poisoned compiled pointer was NOT in the master's set → it was rotated out, not kept.
        #expect(!FileManager.default.fileExists(atPath: live.appendingPathComponent("family-tree/compiled/current.json").path))
        #expect(FileManager.default.fileExists(atPath: paths.previousDir.appendingPathComponent("family-tree/compiled/current.json").path))
        #expect(throws: Never.self) { try sync.verifyManifest(in: live) }
        // Nothing in the poisoned defaults changed apart from the minted session id.
        #expect(defaults.object(forKey: HallieWebAccess.portKey) as? String == "eight-thousand")
        #expect(defaults.object(forKey: ViewerMediaSettings.mountedVolumesKey) != nil)
    }

    /// The same poison with the MASTER's hostname: master role, no sync,
    /// no swap; the only write is the manifest it owns, and stale staging
    /// junk is left alone.
    @Test func masterModeOverTheSamePoisonWritesOnlyItsManifest() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath()
            .appendingPathComponent("master-iso-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); ViewerModeCenter.shared.reset() }
        let live = root.appendingPathComponent("AppSupport/VideoScan", isDirectory: true)
        try poison(appSupport: live)
        let paths = CatalogSyncPaths(liveDir: live,
                                     stagingDir: live.appendingPathComponent(".sync-staging"),
                                     previousDir: live.appendingPathComponent(".sync-previous"),
                                     lastSyncFile: live.appendingPathComponent("last_sync.txt"))
        let runner = StubRsync(masterTree: root)
        let sync = CatalogSync(paths: paths, hostnameSource: FixedHostname(value: "ricksm4.local"),
                               rsyncRunner: runner, masterHostname: "RicksM4.local", remoteUser: "rickb", log: { _ in })
        #expect(sync.mode == .master)
        ViewerModeCenter.shared.install(sync.viewerRole)
        #expect(!ViewerModeCenter.shared.isViewer)
        await sync.syncFromMaster()                       // no-op on the master
        #expect(sync.state.phase == .idle)
        sync.writeManifestIfMaster()
        let manifest = try String(contentsOf: live.appendingPathComponent("manifest.sha256"), encoding: .utf8)
        #expect(manifest.contains("  catalog.json\n"))
        #expect(manifest.contains("  family-tree/compiled/current.json\n"), "an unreadable pointer is still hashed as a file")
        #expect(!manifest.contains("gen-junk"), "no generation is named by the pointer → none hashed")
        #expect(!FileManager.default.fileExists(atPath: live.appendingPathComponent("sync-sources.json").path),
                "no external sources on this master → the poisoned map is removed, not kept")
        #expect(try String(contentsOf: paths.stagingDir.appendingPathComponent("catalog.json"), encoding: .utf8) == "garbage",
                "the master never touches a viewer-side staging dir")
        #expect(try String(contentsOf: live.appendingPathComponent("catalog.json"), encoding: .utf8) == "not json at all {{{")
    }
}
