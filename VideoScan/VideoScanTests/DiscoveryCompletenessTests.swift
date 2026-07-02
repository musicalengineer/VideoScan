// DiscoveryCompletenessTests.swift
// Red/green suite for the discovery-completeness feature (2026-07-02):
//
//   Feature 1 — "Scan Unrecognized File Types": walker admits unknown-ext
//     files (gated by the toggle), the probe engine's magic sniff keeps
//     ffprobe off junk, and the 11e7ad0 junk gate extends to unknown-ext
//     ffprobe failures.
//   Feature 2 — "Look Inside Video Project Bundles": walker descends
//     .fcpbundle-class packages, media inside is tagged with the bundle
//     path (ScanContext.bundleContainer, additive JSON); photo libraries
//     stay skipped regardless.
//   Feature 3 — Discovery audit: per-scan counts + per-path lists for
//     media-candidate skip classes, directory-ENUMERATION-ERROR capture
//     (the June-30 incident sensor), sidecar JSON, and the honesty hook:
//     enumeration errors ⇒ scanWasComplete=false ⇒ upsert-never-prune.
//
// Red/green: most tests fail to COMPILE at 3628e07 (new API — the accepted
// red convention, see ScanMergeScopeTests header). The behavioral reds:
//   * unknownExtensionAdmissionIsGatedByToggle — pre-feature, the .videofile
//     candidate is never admitted regardless of toggle;
//   * bundle descent — pre-feature, skipMediaBundles=true skips .fcpbundle
//     with no way back in;
//   * unreadableSubdirectoryForcesIncompleteScan — pre-feature, the merge
//     runs as COMPLETE and prunes the seeded record (silent data loss).
//
// Isolation (settings-pollution class): scan options are pinned IN-MEMORY
// (makePipelineModel pattern from ScanMergeScopeTests); ScanOptions.save()
// is never called; the audit sidecar is only written where a test injects
// discoveryAuditDirectoryOverride (finalize skips the real
// ~/Library/Logs/VideoScan in test hosts).

import Testing
import Foundation
@testable import VideoScan

// MARK: - Walker admission (Feature 1, walker level)

@Suite("Unknown-extension admission — Scan Unrecognized File Types")
struct UnknownExtensionAdmissionTests {

    private let videoExtensions: Set<String> = ["mov", "mp4", "mxf"]
    private let audioExtensions: Set<String> = ["wav", "aif", "mp3"]

    /// Temp dir: a known video file, an unknown-extension file, a known-junk
    /// file, and an extensionless file.
    private func makeFixture() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_unknownext_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0, count: 16)
        try bytes.write(to: dir.appendingPathComponent("clip.mov"))
        try bytes.write(to: dir.appendingPathComponent("holiday.videofile"))  // unknown ext
        try bytes.write(to: dir.appendingPathComponent("notes.txt"))          // known junk
        try bytes.write(to: dir.appendingPathComponent("t2-v"))               // extensionless
        return dir
    }

    @Test("Default scan skips unknown-extension files (current behavior, preserved)")
    func defaultScanSkipsUnknownExtensions() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: false, audioExtensions: audioExtensions,
            scanAudioFiles: false, scanUnknownExtensions: false
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names == ["clip.mov"])
    }

    @Test("Unknown-extension scan admits the unknown file but never known-junk (RED pre-feature)")
    func unknownExtensionAdmissionIsGatedByToggle() async throws {
        let dir = try makeFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let audit = DiscoveryAuditCollector(scanRoot: dir.path, volumeName: "test")
        let found = await FilesystemWalker.walkDirectory(
            root: dir.path, videoExtensions: videoExtensions,
            skipDirs: [], skipBundleExtensions: [], skipSmallFiles: false,
            probeExtensionless: false, audioExtensions: audioExtensions,
            scanAudioFiles: false, scanUnknownExtensions: true,
            audit: audit
        )
        let names = Set(found.map { $0.lastPathComponent })
        #expect(names.contains("holiday.videofile"),
                "unknown-extension media candidates must be admitted when the toggle is on")
        #expect(names.contains("clip.mov"), "additive: video allowlist still honored")
        #expect(!names.contains("notes.txt"), "known-junk extensions are never admitted")
        #expect(!names.contains("t2-v"),
                "extensionless admission stays governed by ITS toggle, not this one")

        let snapshot = audit.finish(cataloged: 0)
        #expect(snapshot.filesEnumerated == 4)
        #expect(snapshot.filesAdmitted == 2)
        // notes.txt (junk ext) + t2-v (extensionless, option off) each land
        // in their own counter.
        #expect(snapshot.skippedNonMediaExtension == 1)
        #expect(snapshot.skippedExtensionlessOff == 1)
    }

    @Test("classifyFile reasons — audio off vs junk vs extensionless off")
    func classifyReasons() {
        func classify(_ ext: String, audio: Bool = false, extless: Bool = false,
                      unknown: Bool = false) -> FilesystemWalker.FileAdmission {
            FilesystemWalker.classifyFile(
                extension: ext, videoExtensions: videoExtensions,
                audioExtensions: audioExtensions, probeExtensionless: extless,
                scanAudioFiles: audio, scanUnknownExtensions: unknown)
        }
        #expect(classify("mov") == .admit)
        #expect(classify("wav") == .reject(.audioScanningOff))
        #expect(classify("wav", audio: true) == .admit)
        #expect(classify("") == .reject(.extensionlessScanningOff))
        #expect(classify("", extless: true) == .admit)
        #expect(classify("txt", unknown: true) == .reject(.nonMediaExtension))
        #expect(classify("videofile") == .reject(.nonMediaExtension))
        #expect(classify("videofile", unknown: true) == .admit)
        // Audio extensions are KNOWN media — the unknown-ext toggle must
        // never smuggle them past a deliberate scanAudioFiles=off.
        #expect(classify("wav", unknown: true) == .reject(.audioScanningOff))
    }
}

// MARK: - Pro-video bundle helpers (Feature 2, pure level)

@Suite("ProVideoBundles — container tagging + skip-set carve-out")
struct ProVideoBundleHelperTests {

    @Test func containerForPath() {
        #expect(ProVideoBundles.container(forPath: "/Vol/Projects/Trip.fcpbundle/Original Media/clip.mov")
                == "/Vol/Projects/Trip.fcpbundle")
        #expect(ProVideoBundles.container(forPath: "/Vol/iMovie/Family.imovielibrary/2015/clip.mov")
                == "/Vol/iMovie/Family.imovielibrary")
        #expect(ProVideoBundles.container(forPath: "/Vol/Movies/clip.mov") == nil)
        // The FILE component itself is never a container.
        #expect(ProVideoBundles.container(forPath: "/Vol/odd/file.fcpbundle") == nil)
        // Nested bundles: the OUTERMOST wins (one honest answer).
        #expect(ProVideoBundles.container(forPath: "/V/A.fcpbundle/B.rcproject/c.mov") == "/V/A.fcpbundle")
        // Photo libraries are NOT pro-video containers.
        #expect(ProVideoBundles.container(forPath: "/Vol/Photos.photoslibrary/originals/x.mov") == nil)
    }

    @Test @MainActor
    func skipSnapshotCarveOut() {
        let model = VideoScanModel()
        var opts = ScanOptions()
        opts.skipMediaBundles = true
        opts.scanVideoProjectBundles = true
        model.scanOptions = opts
        let skips = model.skipBundleExtensionsSnapshot()
        #expect(!skips.contains("fcpbundle"), "pro-video bundles carved back out of the skip set")
        #expect(!skips.contains("imovielibrary"))
        #expect(skips.contains("photoslibrary"), "photo libraries stay skipped regardless of the toggle")
        #expect(skips.contains("lrdata"), "Lightroom caches stay skipped regardless of the toggle")
    }

    @Test func scanContextDecodesWithoutBundleContainer() throws {
        // Additive-JSON contract: catalogs written before the field existed
        // must decode to the default.
        let legacy = #"{"scanHost":"MacStudio","volumeUUID":"ABC"}"#.data(using: .utf8)!
        let ctx = try JSONDecoder().decode(ScanContext.self, from: legacy)
        #expect(ctx.bundleContainer.isEmpty)
        #expect(ctx.scanHost == "MacStudio")

        // Round-trip when populated.
        var out = ScanContext()
        out.bundleContainer = "/Vol/Trip.fcpbundle"
        let redecoded = try JSONDecoder().decode(ScanContext.self,
                                                 from: JSONEncoder().encode(out))
        #expect(redecoded.bundleContainer == "/Vol/Trip.fcpbundle")
    }
}

// MARK: - Junk-gate extension (Feature 1, gate level)

@Suite("Catalog gate — unknown-extension ffprobe failures")
struct UnknownExtensionGateTests {

    @Test func unknownExtensionFailuresAreGatedWhenSetProvided() {
        let known: Set<String> = ["mov", "mxf", "wav"]
        // Known-extension damaged media stays visible (existing contract).
        #expect(VideoScanModel.shouldCatalogProbeResult(
            ext: "MXF", streamTypeRaw: StreamType.ffprobeFailed.rawValue,
            knownMediaExtensions: known))
        // Unknown-extension junk that slipped past the sniff must not
        // flood the catalog as "damaged media".
        #expect(!VideoScanModel.shouldCatalogProbeResult(
            ext: "VIDEOFILE", streamTypeRaw: StreamType.ffprobeFailed.rawValue,
            knownMediaExtensions: known))
        // …but ffprobe SUCCESS is always cataloged, whatever the extension.
        #expect(VideoScanModel.shouldCatalogProbeResult(
            ext: "VIDEOFILE", streamTypeRaw: StreamType.videoOnly.rawValue,
            knownMediaExtensions: known))
        // Extensionless behavior identical with or without the set.
        #expect(!VideoScanModel.shouldCatalogProbeResult(
            ext: "", streamTypeRaw: StreamType.ffprobeFailed.rawValue,
            knownMediaExtensions: known))
        // The 2-arg form keeps the ORIGINAL contract (extensioned failures
        // cataloged) — pinned separately by ProbeResultCatalogingTests.
        #expect(VideoScanModel.shouldCatalogProbeResult(
            ext: "VIDEOFILE", streamTypeRaw: StreamType.ffprobeFailed.rawValue))
    }
}

// MARK: - Pipelines (Features 1+3 end-to-end)

@Suite("Discovery-completeness pipelines",
       .enabled(if: TestMediaGenerator.isAvailable))
struct DiscoveryCompletenessPipelineTests {

    // MARK: Helpers (ScanMergeScopeTests conventions)

    /// Canonicalized temp dir (walker yields /private/var/… realpaths).
    private func makeTempDir(_ label: String) throws -> URL {
        var dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_disccomp_\(label)_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            dir = URL(fileURLWithPath: canonical, isDirectory: true)
        }
        return dir
    }

    /// Deterministic in-memory scan policy — never `.save()`d.
    @MainActor
    private func makePipelineModel(_ configure: (inout ScanOptions) -> Void = { _ in }) -> VideoScanModel {
        let model = VideoScanModel()
        var opts = ScanOptions()
        opts.skipSmallFiles = false
        opts.skipChecksums = true
        configure(&opts)
        model.scanOptions = opts
        model.scanTargets.removeAll()
        return model
    }

    @MainActor
    private func runScan(_ model: VideoScanModel, root: String) async {
        let target = CatalogScanTarget(searchPath: root)
        model.scanTargets.append(target)
        model.startTarget(target)
        _ = await target.scanTask?.value
    }

    // MARK: Feature 1 + 3 — the TripAcrossCountry shape

    @Test @MainActor
    func tripAcrossCountryShapeCatalogsExactlyTheValidMedia() async throws {
        let fm = FileManager.default
        let vol = try makeTempDir("trip")
        let auditDir = try makeTempDir("auditout")
        defer {
            try? fm.removeItem(at: vol)
            try? fm.removeItem(at: auditDir)
        }

        // Mirror of /Volumes/LaCieWorkspace/…/TripAcrossCountry_1995_video-only:
        //   t2-v            — VALID extensionless QuickTime (real ffmpeg bytes)
        //   t1-v            — 4 KB truncated stub: 'wide'+'mdat' atoms then
        //                     zeros, no moov (passes sniff, fails ffprobe)
        //   holiday.videofile — VALID media under an unknown extension
        //   random-blob     — extensionless zeros (fails the sniff)
        //   notes.txt       — known-junk extension (never admitted, never sniffed)
        let tripDir = vol.appendingPathComponent("TripAcrossCountry_1995_video-only", isDirectory: true)
        try fm.createDirectory(at: tripDir, withIntermediateDirectories: true)
        let t2v = tripDir.appendingPathComponent("t2-v").path
        try fm.moveItem(atPath: TestMediaGenerator.generate(
            container: "mov", streams: .videoOnly, duration: 1.0, prefix: "disccomp_t2v"),
                        toPath: t2v)
        let t1v = tripDir.appendingPathComponent("t1-v").path
        try MediaSignaturesTests.t1vStubData().write(to: URL(fileURLWithPath: t1v))
        let videofile = tripDir.appendingPathComponent("holiday.videofile").path
        try fm.moveItem(atPath: TestMediaGenerator.generate(
            container: "mov", streams: .videoOnly, duration: 1.0, prefix: "disccomp_vf"),
                        toPath: videofile)
        let blob = tripDir.appendingPathComponent("random-blob").path
        try Data(repeating: 0, count: 4096).write(to: URL(fileURLWithPath: blob))
        try Data("just notes\n".utf8).write(to: tripDir.appendingPathComponent("notes.txt"))

        let model = makePipelineModel { opts in
            opts.probeExtensionless = true
            opts.scanUnknownExtensions = true
        }
        model.discoveryAuditDirectoryOverride = auditDir

        await runScan(model, root: tripDir.path)

        // Catalog: exactly the two valid media files.
        let cataloged = Set(model.records
            .filter { PathScope.contains($0.fullPath, within: tripDir.path) }
            .map(\.fullPath))
        #expect(cataloged == [t2v, videofile],
                "exactly the valid extensionless + unknown-ext media must be cataloged (got \(cataloged))")

        // Audit: the stub and the sniff-fail are visible, with reasons.
        let audit = try #require(model.lastDiscoveryAudit, "finalize must publish the discovery audit")
        #expect(audit.filesEnumerated == 5)
        #expect(audit.filesAdmitted == 4, "t2-v, t1-v, holiday.videofile, random-blob")
        #expect(audit.filesCataloged == 2)
        #expect(audit.skippedNonMediaExtension == 1, "notes.txt")
        #expect(audit.sniffRejected == 1 && audit.sniffRejectedPaths == [blob],
                "the zero blob must be sniff-rejected (ffprobe skipped)")
        #expect(audit.probeRejected == 1 && audit.probeRejectedPaths == [t1v],
                "the t1-v stub passes the sniff ('wide' atom) but must be junk-gated after ffprobe fails — and the audit must say so")
        #expect(audit.directoryEnumerationErrors == 0 && audit.discoveryComplete)

        // Sidecar: machine-readable, decodes back to the same audit.
        let sidecars = try fm.contentsOfDirectory(atPath: auditDir.path)
            .filter { $0.hasPrefix("scan-audit-") && $0.hasSuffix(".json") }
        #expect(sidecars.count == 1, "exactly one scan-audit sidecar per scan (found \(sidecars))")
        if let name = sidecars.first {
            let data = try Data(contentsOf: auditDir.appendingPathComponent(name))
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let decoded = try dec.decode(DiscoveryAudit.self, from: data)
            #expect(decoded.filesAdmitted == audit.filesAdmitted)
            #expect(decoded.sniffRejectedPaths == audit.sniffRejectedPaths)
            #expect(decoded.probeRejectedPaths == audit.probeRejectedPaths)
        }
    }

    // MARK: Feature 2 — bundle descent pipeline

    @Test @MainActor
    func bundleDescentCatalogsInsideFcpBundleButNeverPhotosLibrary() async throws {
        let fm = FileManager.default
        let vol = try makeTempDir("bundles")
        defer { try? fm.removeItem(at: vol) }

        // Junk-byte .mov files: ffprobe fails but extensioned damaged media
        // is still cataloged — discovery, not decodability, is under test.
        let fcp = vol.appendingPathComponent("Trip.fcpbundle/Original Media", isDirectory: true)
        try fm.createDirectory(at: fcp, withIntermediateDirectories: true)
        let insideBundle = fcp.appendingPathComponent("clip.mov").path
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: insideBundle))

        let photos = vol.appendingPathComponent("Family.photoslibrary/originals", isDirectory: true)
        try fm.createDirectory(at: photos, withIntermediateDirectories: true)
        let insidePhotos = photos.appendingPathComponent("pic.mov").path
        try Data(repeating: 0, count: 64).write(to: URL(fileURLWithPath: insidePhotos))

        // Toggle OFF (skipMediaBundles ON): the bundle stays sealed.
        let modelOff = makePipelineModel { opts in
            opts.skipMediaBundles = true
            opts.scanVideoProjectBundles = false
        }
        await runScan(modelOff, root: vol.path)
        #expect(!modelOff.records.contains { $0.fullPath == insideBundle },
                "with the toggle off and Skip Media Bundles on, .fcpbundle must stay skipped")
        #expect(modelOff.lastDiscoveryAudit?.skippedBundleDirs == 2,
                ".fcpbundle and .photoslibrary both counted as bundle skips")

        // Toggle ON: pro-video bundle opens; photo library stays sealed.
        let modelOn = makePipelineModel { opts in
            opts.skipMediaBundles = true
            opts.scanVideoProjectBundles = true
        }
        await runScan(modelOn, root: vol.path)
        let rec = try #require(
            modelOn.records.first { $0.fullPath == insideBundle },
            "media inside a .fcpbundle must be cataloged when Look Inside Video Project Bundles is on (RED pre-feature)")
        #expect(rec.scanContext.bundleContainer == vol.appendingPathComponent("Trip.fcpbundle").path,
                "the record must be tagged with its enclosing bundle path")
        #expect(!modelOn.records.contains { $0.fullPath == insidePhotos },
                "photo libraries stay skipped REGARDLESS of the pro-video toggle")
        #expect(modelOn.lastDiscoveryAudit?.skippedBundleDirs == 1,
                "only the photo library remains a bundle skip")
    }

    // MARK: Feature 3 — enumeration errors force the incomplete-scan path

    @Test @MainActor
    func unreadableSubdirectoryForcesIncompleteScan() async throws {
        let fm = FileManager.default
        let vol = try makeTempDir("enumerr")
        let locked = vol.appendingPathComponent("locked", isDirectory: true)
        try fm.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 64).write(to: locked.appendingPathComponent("hidden.mov"))
        try Data(repeating: 0, count: 64).write(to: vol.appendingPathComponent("visible.mov"))
        // Make the subdirectory unreadable — restore FIRST in the defer or
        // the cleanup itself fails.
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fm.removeItem(at: vol)
        }

        let model = makePipelineModel()
        // Seed a record whose file is genuinely gone: a COMPLETE scan would
        // prune it. Discovery couldn't read `locked`, so this scan must NOT
        // be complete — the seed's survival proves the flag was wired
        // through to the merge honestly. RED pre-feature (silently pruned).
        let seedGone = VideoRecord()
        seedGone.fullPath = vol.appendingPathComponent("gone.mov").path
        seedGone.filename = "gone.mov"
        seedGone.directory = vol.path
        seedGone.streamTypeRaw = StreamType.videoAndAudio.rawValue
        model.records = [seedGone]

        await runScan(model, root: vol.path)

        let audit = try #require(model.lastDiscoveryAudit)
        #expect(audit.directoryEnumerationErrors == 1,
                "the unreadable subdirectory must be counted (got \(audit.directoryEnumerationErrors))")
        #expect(!audit.discoveryComplete)
        #expect(audit.unreadableDirectories.count == 1
                && audit.unreadableDirectories[0].contains("locked"),
                "the audit must name the unreadable directory (got \(audit.unreadableDirectories))")
        #expect(model.records.contains { $0.fullPath == seedGone.fullPath },
                "enumeration errors ⇒ scanWasComplete=false ⇒ the merge must upsert WITHOUT pruning (RED pre-feature)")
        #expect(model.records.contains { $0.fullPath == vol.appendingPathComponent("visible.mov").path },
                "the readable part of the tree is still cataloged")
        #expect(!model.records.contains { $0.fullPath == locked.appendingPathComponent("hidden.mov").path },
                "fixture sanity: nothing inside the unreadable directory was discovered")
    }
}
