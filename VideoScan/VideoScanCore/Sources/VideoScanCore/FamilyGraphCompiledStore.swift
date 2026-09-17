// FamilyGraphCompiledStore.swift
// Where compiled family-tree artifacts live and how one becomes "current"
// (Rick 2026-08-28, via codex #771): raw pulls are immutable and get a
// SHA-256 sidecar; ingest = parse → validate → (merge) → compile → VERIFY
// → atomic promote; the previous generation is kept for rollback (N=2);
// a generation that fails verification is never promoted; runtime reads
// only the promoted artifact and falls back to the previous generation,
// then to a plain parse, with a log line each time.
//
// Layout under `root` (production: Application Support/VideoScan/
// family-tree/compiled/):
//   current.json              pointer: schema/codec/index versions,
//                             current + previous generation, source keys
//   gen-<stamp>/tree.vsft     the artifact (GedcomCompiledTree)
//   gen-<stamp>/manifest.json provenance + verification report
//   sources/<key>.sha256      full-file SHA-256 sidecar per raw pull
//   .lock                     advisory flock(2) for every writer
//
// Sidecars are written HERE, not beside the raw pull: the pull directory
// may be the read-only Master Archive, and "never rewrite the raw" is
// easiest to honour by never opening its folder for writing.
//
// Invalidation (codex #792 / #797): a source key IS the file's full
// SHA-256. The pointer's keys and the three version numbers must all
// match; anything else is a miss and the caller recompiles. Size and
// mtime are recorded in the manifest for humans only — they never decide
// hit/miss, so a same-size mtime-preserving edit cannot reuse a stale
// artifact.
//
// Writers (ingest / promote / prune / rollback / fallback repoint) hold
// an exclusive flock on root/.lock. The CLI `videoscan-tree-ingest` and
// the app share the root, so a process-wide lock would not be enough;
// flock is per open-file-description, so it also serializes two threads
// of one process. Readers need no lock: the pointer is replaced by
// rename, so a reader sees the old or the new pointer, never a torn one.

import Foundation

// Lives in VideoScanCore (2026-08-28) so the one-time ingest CLI
// (videoscan-tree-ingest), HallieShellCLI and the app all promote and read
// the SAME generations. Logging is injected; the app wires appLog.
public struct FamilyGraphCompiledStore {

    public init(root: URL) { self.root = root }

    /// App-level manifest/pointer schema. Bump with the layout here;
    /// the codec and index carry their own versions.
    /// 2 (2026-08-28): source keys became full-file SHA-256 (were
    /// size+mtime+edge hashes); an older pointer logs "schema changed"
    /// and is recompiled instead of silently missing.
    /// 3 (2026-08-28, codex #812/#816): manifest sources carry
    /// `droppedLineCount` and are bound POSITIONALLY to the artifact's
    /// provenance; the manifest carries the local + total loss. Goes with
    /// codec 4 — a codec-3 pointer is refused by `versionsMatch` too.
    /// 3, additive (2026-08-28, codex #822): `sources` are the PHYSICAL
    /// files the store hashed (the pointer's keys); `logicalSources` is
    /// the artifact's provenance list (what the tree was merged from).
    /// For a CLI multi-source ingest the two lists are equal; for an app
    /// merge artifact (one ab.ged listing A and B) they differ. A
    /// manifest written before the field existed decodes with
    /// `logicalSources == sources`, which is exactly what those
    /// generations were (an artifact file could not be promoted then),
    /// so no schema bump: Rick's compiled two-pull tree stays current.
    public static let schemaVersion: UInt32 = 3
    static let pointerName = "current.json"
    static let lockName = ".lock"

    public let root: URL
    public var fileManager: FileManager = .default
    /// Generations kept after a promote: current + this many previous.
    ///
    /// FIVE, NOT ONE (2026-09-16). At 1, exactly one mistake was
    /// recoverable and two in a row were not. Rick ran Refresh twice
    /// against a bug that rebased onto a single source:
    ///
    ///   gen A  39,250 people, 2 sources   — the tree he wanted
    ///   gen B  16,383, refresh #1         — A becomes `previous`, kept
    ///   gen C  16,383, refresh #2         — B becomes `previous`, A PRUNED
    ///
    /// By the time the narrowing was noticed, the generation worth going
    /// back to had been deleted, and recovery meant a full re-ingest from
    /// the raw 70 MB + 133 MB pulls rather than a rollback. Nothing was
    /// lost — his sources are immutable and he keeps copies on two other
    /// machines — but that is his discipline covering for this default.
    ///
    /// An artifact is ~18 MB for a 39k-person tree, so five costs about
    /// 90 MB: trivial beside the sources it protects, and it buys a
    /// window of several mistakes instead of one.
    public var keepPrevious = 5
    public var log: (String) -> Void = { _ in }
    /// The ingest gate. Injected so a test can force a failure.
    public var verify: (_ decoded: GedcomFamilyGraph, _ source: GedcomFamilyGraph) -> [String]
        = GedcomCompiledTree.verify(decoded:against:)
    /// Remote-viewer read mode (docs/remote_use_design.md Phase 1): the
    /// generation was compiled on the MASTER and arrived by verified sync,
    /// so its raw sources are not on this disk (they name master paths).
    /// True skips the per-source re-hash in `usableManifest` — the sync
    /// manifest already proved the artifact's bytes. False (default) keeps
    /// the master's rule: a source missing or changed on disk is a miss.
    public var trustsManifestSources = false
    /// Remote-viewer write refusal: `ingest`, `rollback` and every other
    /// pointer/generation writer return "not promoted" without touching
    /// the root, and say so in the log. The app sets it from
    /// ViewerModeCenter; a CLI never sets it.
    public var refusesWrites = false
    /// The log line every refused write starts with (test sensor).
    public static let refusedWritePrefix = "[family-tree] refused write on a viewer:"

    public struct Pointer: Codable, Equatable {
        public var schema: UInt32
        public var codec: UInt32
        public var index: UInt32
        public var current: String
        public var previous: String?
        public var sourceKeys: [String]
    }

    public struct Source: Codable, Equatable {
        public var fileName: String
        public var path: String
        public var size: Int
        public var modifiedAt: Date?
        /// Full-file SHA-256 (hex) — the invalidation key.
        public var key: String
        /// Same value as `key`; kept as its own field for the sidecar /
        /// provenance readers that predate the key change.
        public var sha256: String
        /// Lines this source's parse dropped (= the artifact's
        /// `sourceProvenance[i].droppedLineCount`, same position).
        public var droppedLineCount: Int
    }

    /// One entry of the artifact's LOGICAL provenance (what the tree was
    /// merged from), as recorded in the manifest beside the physical
    /// `sources`. Positional; names may repeat (identity = position + sha).
    public struct LogicalSource: Codable, Equatable {
        public var fileName: String
        /// Nil when that source was never fingerprinted (older artifact).
        public var sha256: String?
        public var droppedLineCount: Int
        public init(fileName: String, sha256: String?, droppedLineCount: Int) {
            self.fileName = fileName; self.sha256 = sha256; self.droppedLineCount = droppedLineCount
        }
        init(_ p: GedcomFamilyGraph.SourceProvenance) {
            self.init(fileName: p.name, sha256: p.sha256, droppedLineCount: p.droppedLineCount)
        }
    }

    public struct Manifest: Codable, Equatable {
        public var schema: UInt32
        public var codec: UInt32
        public var index: UInt32
        public var generation: String
        public var createdAt: Date
        /// PHYSICAL sources: the files hashed and bound at ingest, in
        /// position order; `map(\.key)` == the pointer's `sourceKeys`.
        public var sources: [Source]
        /// LOGICAL provenance of the artifact (`graph.sourceProvenance`).
        /// Equal to `sources` (name/sha/dropped) for a CLI or single-file
        /// ingest; the merged-from list for an app merge artifact.
        public var logicalSources: [LogicalSource]
        public var peopleCount: Int
        public var familyCount: Int
        /// Empty when verification passed. A failed generation keeps its
        /// manifest (for diagnosis) but is never pointed at.
        public var verification: [String]
        public var mergeReport: String?
        /// The artifact's graph-local loss and its total (local + Σ
        /// sources) — the two numbers the codec carries, for humans.
        public var localDroppedLineCount: Int
        public var totalDroppedLineCount: Int

        public init(schema: UInt32, codec: UInt32, index: UInt32, generation: String, createdAt: Date,
                    sources: [Source], logicalSources: [LogicalSource], peopleCount: Int, familyCount: Int,
                    verification: [String], mergeReport: String?, localDroppedLineCount: Int, totalDroppedLineCount: Int) {
            self.schema = schema; self.codec = codec; self.index = index; self.generation = generation
            self.createdAt = createdAt; self.sources = sources; self.logicalSources = logicalSources
            self.peopleCount = peopleCount; self.familyCount = familyCount; self.verification = verification
            self.mergeReport = mergeReport; self.localDroppedLineCount = localDroppedLineCount
            self.totalDroppedLineCount = totalDroppedLineCount
        }

        /// Hand-written so a manifest written before `logicalSources`
        /// existed (same schema 3) reads back as logical == physical.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schema = try c.decode(UInt32.self, forKey: .schema)
            codec = try c.decode(UInt32.self, forKey: .codec)
            index = try c.decode(UInt32.self, forKey: .index)
            generation = try c.decode(String.self, forKey: .generation)
            createdAt = try c.decode(Date.self, forKey: .createdAt)
            sources = try c.decode([Source].self, forKey: .sources)
            logicalSources = try c.decodeIfPresent([LogicalSource].self, forKey: .logicalSources)
                ?? sources.map { LogicalSource(fileName: $0.fileName, sha256: $0.sha256, droppedLineCount: $0.droppedLineCount) }
            peopleCount = try c.decode(Int.self, forKey: .peopleCount)
            familyCount = try c.decode(Int.self, forKey: .familyCount)
            verification = try c.decode([String].self, forKey: .verification)
            mergeReport = try c.decodeIfPresent(String.self, forKey: .mergeReport)
            localDroppedLineCount = try c.decode(Int.self, forKey: .localDroppedLineCount)
            totalDroppedLineCount = try c.decode(Int.self, forKey: .totalDroppedLineCount)
        }
    }

    public enum StoreError: Error {
        case lockFailed(errno: Int32)
    }

    /// Environment override for the compiled root (an eval or test may
    /// point the shell at a tree compiled elsewhere — 2026-09-02, when
    /// main's codec had moved past the installed artifact and an overnight
    /// run must not write into Application Support). Unset in the app.
    public static let compiledRootEnvironmentKey = "VIDEOSCAN_FAMILY_TREE_COMPILED_ROOT"

    public static var productionRoot: URL {
        if let override = ProcessInfo.processInfo.environment[compiledRootEnvironmentKey],
           !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent("compiled", isDirectory: true)
    }

    /// True when this process is a test host. Detected in Core, without
    /// the app target's `TestEnvironment`, by the markers XCTest and Swift
    /// Testing both set.
    static var isRunningInATestHost: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["SWIFT_TESTING_ENABLED"] != nil
    }

    /// THE REAL STORE IS UNREACHABLE FROM A TEST HOST (2026-09-17).
    ///
    /// Isolation used to be opt-OUT: every test that built something
    /// store-aware had to remember to inject a scratch store, and any that
    /// forgot silently read and WROTE Rick's actual family tree. That was
    /// survivable only while nothing much was store-aware. The moment the
    /// pull coordinator became store-aware it stopped being survivable:
    /// three generations of two-person test fixtures — one of them named
    /// `current.ged` — were promoted into his production compiled store in
    /// a single morning, the pointer moved, and his 39,250-person tree was
    /// replaced by a 16,383-person one. codex flagged the shape (#1525); it
    /// then happened again from a file neither of us had checked.
    ///
    /// So a test host gets a private per-process root instead, unless it
    /// sets `compiledRootEnvironmentKey` deliberately. Tests that want a
    /// store still inject one; tests that forget now pollute a temp
    /// directory instead of a family archive.
    public static var production: FamilyGraphCompiledStore {
        guard isRunningInATestHost,
              ProcessInfo.processInfo.environment[compiledRootEnvironmentKey]?.isEmpty != false
        else { return FamilyGraphCompiledStore(root: productionRoot) }
        let sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoScan-test-compiled-\(ProcessInfo.processInfo.processIdentifier)",
                                    isDirectory: true)
        var store = FamilyGraphCompiledStore(root: sandbox)
        store.log = { _ in }
        return store
    }

    // MARK: Read side

    public var pointerURL: URL { root.appendingPathComponent(Self.pointerName) }
    public var lockURL: URL { root.appendingPathComponent(Self.lockName) }
    public func generationURL(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }
    public func artifactURL(_ name: String) -> URL { generationURL(name).appendingPathComponent("tree.vsft") }
    public func manifestURL(_ name: String) -> URL { generationURL(name).appendingPathComponent("manifest.json") }

    public func readPointer() -> Pointer? {
        guard let data = try? Data(contentsOf: pointerURL) else { return nil }
        return try? JSONDecoder().decode(Pointer.self, from: data)
    }

    public func readManifest(_ generation: String) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(generation)) else { return nil }
        return try? Self.decoder.decode(Manifest.self, from: data)
    }

    public static var versionsMatch: (Pointer) -> Bool {
        { $0.schema == schemaVersion && $0.codec == GedcomCompiledTree.codecVersion
            && $0.index == GedcomFamilyGraph.TreeIndex.formatVersion }
    }

    /// The promoted artifact for exactly these sources, or nil (a miss:
    /// the caller parses and ingests). A current artifact that no longer
    /// decodes falls back to the previous generation when THAT was built
    /// from the same sources; otherwise nil.
    public func load(sources: [URL]) -> GedcomFamilyGraph? {
        guard let pointer = readPointer() else { return nil }
        guard Self.versionsMatch(pointer) else {
            log("[family-tree] compiled artifact schema changed (pointer \(pointer.schema)/\(pointer.codec)/\(pointer.index)); recompiling")
            return nil
        }
        guard let keys = try? sourceKeys(for: sources), keys == pointer.sourceKeys else {
            return nil
        }
        if let graph = decode(generation: pointer.current) { return graph }
        if let previous = pointer.previous,
           readManifest(previous)?.sources.map(\.key) == keys,
           let graph = decode(generation: previous) {
            log("[family-tree] compiled generation \(pointer.current) unreadable; rolled back to \(previous)")
            repoint(from: pointer, current: previous, sourceKeys: keys)
            return graph
        }
        log("[family-tree] compiled generation \(pointer.current) unreadable and no usable previous; falling back to parse")
        return nil
    }

    /// The promoted artifact when EVERY source its manifest records is
    /// still on disk with the same full SHA-256 — the one-time ingest
    /// model (Rick 2026-08-28): the CLI compiles N pulls once; the app
    /// then loads that generation without needing to know which files to
    /// name. Nil on any miss (the caller falls back to its newest-file
    /// path), with the reason logged.
    ///
    /// Same rollback rule as `load(sources:)` (codex #789): when current
    /// is corrupt or unreadable and the previous generation verified
    /// clean AND its sources all still match on disk, decode previous,
    /// repoint (current = previous, previous = nil, sourceKeys = that
    /// manifest's keys) and return it.
    /// THE BOOT CHECK (Rick, 2026-09-16: "should we have a check at
    /// boot/runtime that verifies the tree is not accidentally
    /// compromised").
    ///
    /// Compares the generation currently pointed at against the one before
    /// it and returns what changed. The promote path already does this for
    /// a tree it is about to write; this is for a tree that is ALREADY
    /// written — so a narrowing that happened in a previous session, or
    /// through something other than a compile (a hand-edited pointer, a
    /// half-finished sync, a restore from the wrong place), is still seen.
    ///
    /// Read-only and cheap: two manifests, no artifact decode. Safe to call
    /// at every launch. Returns [] when there is no previous generation to
    /// compare against — a first-ever tree cannot have lost anything.
    public func auditCurrentGeneration() -> [TreeIntegrityCheck.Finding] {
        guard let pointer = readPointer(),
              let current = readManifest(pointer.current) else { return [] }
        guard let previousName = pointer.previous,
              let previous = readManifest(previousName) else { return [] }
        return TreeIntegrityCheck.compare(incoming: current, against: previous)
    }

    /// `auditCurrentGeneration`, written to the log, with the rollback
    /// target named when something alarms. One call at launch is the whole
    /// intended use.
    @discardableResult
    public func logCurrentGenerationAudit() -> [TreeIntegrityCheck.Finding] {
        let findings = auditCurrentGeneration()
        for finding in findings where finding.severity != .note {
            let tag = finding.severity == .alarm ? "startup tree ALARM" : "startup tree warning"
            log("[family-tree] \(tag): \(finding.message)")
        }
        if TreeIntegrityCheck.hasAlarm(findings), let previous = readPointer()?.previous {
            log("[family-tree] the tree in use is smaller than the one before it. "
                + "If that was not intended, roll back to \(previous).")
        }
        return findings
    }

    public func loadCurrent() -> (graph: GedcomFamilyGraph, manifest: Manifest)? {
        guard let pointer = readPointer() else { return nil }
        guard Self.versionsMatch(pointer) else {
            log("[family-tree] compiled artifact schema changed (pointer \(pointer.schema)/\(pointer.codec)/\(pointer.index)); recompiling")
            return nil
        }
        guard let manifest = usableManifest(pointer.current) else { return nil }
        guard manifest.sources.map(\.key) == pointer.sourceKeys else { return nil }
        if let graph = decode(generation: pointer.current) { return (graph, manifest) }

        if let previous = pointer.previous, let previousManifest = usableManifest(previous),
           let graph = decode(generation: previous) {
            log("[family-tree] compiled generation \(pointer.current) unreadable; rolled back to \(previous)")
            repoint(from: pointer, current: previous, sourceKeys: previousManifest.sources.map(\.key))
            return (graph, previousManifest)
        }
        log("[family-tree] compiled generation \(pointer.current) unreadable and no usable previous; falling back to parse")
        return nil
    }

    /// codex #826 — a multi-source generation that is refused ONLY for
    /// version reasons (schema/codec/index bump) while every physical
    /// source it records still exists unchanged. The loader must not
    /// quietly recompile the newest single file over it (Donna's tree
    /// vanished that way); it reports these sources so the UI can offer
    /// "Recompile". Checks current, then previous. Nil when the pointer
    /// matches the running versions, or when no such generation exists.
    public func multiSourceGenerationNeedingRecompile() -> (generation: String, sources: [URL])? {
        guard let pointer = readPointer(), !Self.versionsMatch(pointer) else { return nil }
        for generation in [pointer.current, pointer.previous].compactMap({ $0 }) {
            guard let manifest = usableManifest(generation), manifest.sources.count > 1 else { continue }
            return (generation, manifest.sources.map { URL(fileURLWithPath: $0.path) })
        }
        return nil
    }

    /// A recovery candidate: a multi-source generation that is source-intact
    /// AND decodes, carried together with the pointer as it was when the
    /// decision was made. That pointer is the compare-and-swap baseline --
    /// reading it later would let an ingest that won the race in between be
    /// overwritten by this older generation (rule 3b review, finding 3).
    public struct RecoveryCandidate {
        public let generation: String
        public let manifest: Manifest
        /// Already decoded during lookup. Public because a caller that cannot
        /// adopt must still be able to SERVE this rather than fall back to a
        /// single file (rule 3b re-review, finding 2).
        public let graph: GedcomFamilyGraph
        let pointerAtLookup: Pointer?
    }

    /// What adopting a candidate did.
    ///
    /// `superseded` and `couldNotPersist` are deliberately NOT the same
    /// outcome (rule 3b re-review, finding 2): the first means someone else
    /// promoted a generation and this graph is stale, the second means the
    /// graph is sound and only the pointer write failed. Collapsing them let
    /// a failed flock look like a competing writer and end in the
    /// single-file fallback -- the narrowing this whole rule exists to stop.
    public enum Adoption {
        /// The pointer names the candidate, or a viewer kept it without writing.
        case adopted(GedcomFamilyGraph)
        /// A DIFFERENT generation is current now; reload, do not use this graph.
        case superseded
        /// The pointer could not be written, with no competing writer. Serve
        /// the graph; recovery will run again next launch.
        case couldNotPersist(GedcomFamilyGraph)
    }

    /// The newest generation that records MORE THAN ONE physical source,
    /// whose every source is still intact on disk, AND whose artifact
    /// decodes -- whatever state the pointer is in.
    ///
    /// `multiSourceGenerationNeedingRecompile` covers exactly ONE reason a
    /// multi-source generation stops being used: a codec/schema bump. It can
    /// stop being used for others -- a pointer left on a different
    /// generation, an artifact that will not decode -- and the loader's
    /// rule 4 then rebuilds the tree from whatever single .ged happens to be
    /// visible in the scanned directory.
    ///
    /// 2026-09-17, live: that turned Rick's 39,250-person tree into a
    /// 16,383-person one and dropped his wife's entire line, because her
    /// pull lives in a `pulls/` subdirectory the non-recursive listing never
    /// sees. Same rule as codex #826, wider trigger: never silently demote N
    /// pulls to one.
    ///
    /// The decode happens HERE, inside the candidate loop, so a corrupt
    /// newest generation falls through to an older healthy one instead of
    /// authorising a narrowing (rule 3b review, finding 2).
    ///
    /// Two bounded passes, NO RECURSION: manifests first (cheap), then
    /// verify-and-decode in newest-first order, stopping at the first fully
    /// usable candidate -- so the expensive pass normally touches exactly one
    /// generation, and only on a path that is already broken.
    public func intactMultiSourceGeneration() -> RecoveryCandidate? {
        let pointerAtLookup = readPointer()
        let candidates = generations()
            .compactMap { readManifest($0) }
            .filter { $0.sources.count > 1 && $0.verification.isEmpty }
            .sorted { $0.createdAt > $1.createdAt }
        for manifest in candidates where usableManifest(manifest.generation) != nil {
            guard let graph = decode(generation: manifest.generation) else {
                log("[family-tree] recovery candidate \(manifest.generation) will not decode; "
                    + "trying an older multi-source generation")
                continue
            }
            return RecoveryCandidate(generation: manifest.generation, manifest: manifest,
                                     graph: graph, pointerAtLookup: pointerAtLookup)
        }
        return nil
    }

    /// Self-heal: leave the pointer naming the candidate. The compare-and-swap
    /// baseline is the pointer as it was at LOOKUP, so a competing ingest that
    /// promoted something in between wins and we report `superseded` instead of
    /// clobbering it. A viewer keeps the graph without writing.
    ///
    /// The CAS runs even when the pointer already NAMES this generation: it
    /// may name it with different source keys (which is why `loadCurrent`
    /// failed and we are here at all), and something may have been promoted
    /// since (rule 3b re-review, finding 1). Returning early there handed the
    /// caller a stale graph while the pointer on disk said otherwise.
    public func adopt(_ found: RecoveryCandidate) -> Adoption {
        guard !refusesWrites else {
            log("\(Self.refusedWritePrefix) adopt \(found.generation) — pointer untouched")
            return .adopted(found.graph)
        }
        enum Attempt { case won, moved, failed(String) }
        var attempt = Attempt.moved
        do {
            try withLock {
                guard readPointer() == found.pointerAtLookup else {
                    attempt = .moved
                    return
                }
                var repointed = found.pointerAtLookup
                    ?? Pointer(schema: found.manifest.schema, codec: found.manifest.codec,
                               index: found.manifest.index, current: found.generation,
                               previous: nil, sourceKeys: [])
                repointed.current = found.generation
                repointed.previous = nil
                repointed.sourceKeys = found.manifest.sources.map(\.key)
                do {
                    try writePointer(repointed)
                    attempt = .won
                } catch {
                    attempt = .failed("\(error)")
                }
            }
        } catch {
            // The lock itself failed: nobody else necessarily won.
            attempt = .failed("\(error)")
        }
        switch attempt {
        case .won:
            return .adopted(found.graph)
        case .moved:
            log("[family-tree] not adopting \(found.generation): the pointer moved while it was being recovered")
            return .superseded
        case .failed(let reason):
            log("[family-tree] recovered \(found.generation) but could NOT write the pointer: \(reason) — "
                + "serving the recovered tree; recovery will run again next launch")
            return .couldNotPersist(found.graph)
        }
    }

    /// Remote viewer (Phase 1): the pointer names a generation this build
    /// refuses for VERSION reasons (schema/codec/index). Unlike
    /// `multiSourceGenerationNeedingRecompile` it does not require the
    /// sources on disk or more than one of them — a viewer cannot
    /// recompile anyway; it can only show "compiled on the master — sync
    /// again". Nil when the pointer matches or there is no pointer.
    public func generationRefusedForVersion() -> (generation: String, sources: [URL])? {
        guard let pointer = readPointer(), !Self.versionsMatch(pointer) else { return nil }
        let manifest = readManifest(pointer.current)
        let sources = manifest?.sources.map { URL(fileURLWithPath: $0.path) } ?? []
        return (pointer.current, sources)
    }

    /// The generation's manifest when it verified clean and every source
    /// it records is still on disk with the same key; nil (logged) otherwise.
    /// With `trustsManifestSources` the on-disk check is skipped (viewer).
    private func usableManifest(_ generation: String) -> Manifest? {
        guard let manifest = readManifest(generation), manifest.verification.isEmpty else { return nil }
        if trustsManifestSources { return manifest }
        for source in manifest.sources {
            let url = URL(fileURLWithPath: source.path)
            guard let key = try? sourceKeys(for: [url]).first, key == source.key else {
                log("[family-tree] compiled generation \(generation) source \(source.fileName) missing or changed; not using it")
                return nil
            }
        }
        return manifest
    }

    private func decode(generation: String) -> GedcomFamilyGraph? {
        guard let data = try? Data(contentsOf: artifactURL(generation)) else { return nil }
        do {
            return try GedcomCompiledTree.decode(data)
        } catch {
            log("[family-tree] compiled artifact \(generation) corrupt: \(error)")
            return nil
        }
    }

    /// Full-hash keys for `sources`, with the measured cost logged (the
    /// reviewer asked for it to be visible: ~0.4 s for both real pulls).
    func sourceKeys(for sources: [URL]) throws -> [String] {
        let t0 = DispatchTime.now().uptimeNanoseconds
        var bytes = 0
        let keys = try sources.map { url -> String in
            bytes += (try? GedcomCompiledTree.sourceStat(url).size) ?? 0
            return try GedcomCompiledTree.sourceKey(for: url)
        }
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        log("[family-tree] hashed \(sources.count) source\(sources.count == 1 ? "" : "s") "
            + "(\(bytes / 1_048_576) MB) in \(Int(ms)) ms")
        return keys
    }

    /// Fallback repoint from a read path: under the lock, and only when
    /// the pointer on disk is still the one we based the decision on (an
    /// ingest may have promoted a fresh generation meanwhile).
    private func repoint(from seen: Pointer, current: String, sourceKeys: [String]) {
        if refusesWrites {
            log("\(Self.refusedWritePrefix) repoint to \(current) — pointer untouched")
            return
        }
        do {
            try withLock {
                guard readPointer() == seen else { return }
                var repointed = seen
                repointed.current = current
                repointed.previous = nil
                repointed.sourceKeys = sourceKeys
                try writePointer(repointed)
            }
        } catch {
            log("[family-tree] repoint to \(current) failed: \(error)")
        }
    }

    // MARK: Ingest

    /// Compile `graph` (already parsed, validated and — when there were
    /// several pulls — merged by the caller), verify the written artifact
    /// against it, and promote. Returns the DECODED artifact on success so
    /// the runtime consumes only what was promoted; nil when verification
    /// or any write failed (logged) — the caller keeps the parsed graph.
    ///
    /// `sources` binds POSITIONALLY to the graph's PHYSICAL sources (codex
    /// #816/#822): `sources[i]` must be the file `graph.physicalSources[i]`
    /// names, and its FRESH full SHA-256 must equal the hash the graph
    /// carried from its parse (codex #817 — a rewrite between parse and
    /// ingest is refused). For a merge artifact read from disk that is
    /// ONE file (the artifact); its logical provenance is recorded as the
    /// manifest's `logicalSources`. Any mismatch: not promoted, logged,
    /// pointer untouched. The physical sources are hashed AGAIN right
    /// before the manifest and pointer are written (codex #822 item 2):
    /// a file replaced during compile/verify is refused the same way.
    ///
    /// Holds the store lock for the whole compile → verify → promote →
    /// prune sequence (codex #792): two ingests into one root run one
    /// after the other, so the second sees the first's pointer, keeps it
    /// as `previous`, and prune never deletes a freshly promoted sibling.
    public func ingest(graph: GedcomFamilyGraph, sources: [URL], mergeReport: String? = nil,
                       progress: (String) -> Void = { _ in }) -> GedcomFamilyGraph? {
        if refusesWrites {
            log("\(Self.refusedWritePrefix) ingest (\(sources.count) sources) — the tree is compiled on the master")
            return nil
        }
        do {
            return try withLock { ingestLocked(graph: graph, sources: sources, mergeReport: mergeReport, progress: progress) }
        } catch {
            log("[family-tree] compile failed before a generation was started: \(error)")
            return nil
        }
    }

    private func ingestLocked(graph: GedcomFamilyGraph, sources: [URL], mergeReport: String?,
                              progress: (String) -> Void) -> GedcomFamilyGraph? {
        let generation = freshGenerationName()
        do {
            try fileManager.createDirectory(at: generationURL(generation), withIntermediateDirectories: true)
            // Hash the sources FIRST (fresh read), then bind them to the
            // graph's provenance by position: count, basename and the hash
            // the graph carried from its own parse must all agree (codex
            // #816/#817). The bound, canonical graph is what gets compiled
            // and what the artifact is verified against.
            let keys = try sourceKeys(for: sources)
            var graph = graph
            do {
                try graph.bindSources(Array(zip(sources.map(\.lastPathComponent), keys)).map { (name: $0.0, sha256: $0.1) })
            } catch {
                log("[family-tree] compiled generation \(generation) REFUSED, not promoted: sources do not bind to the graph's provenance — \(error)")
                try? fileManager.removeItem(at: generationURL(generation))
                return nil
            }
            progress("Compiling family tree (\(graph.people.count.formatted()) people)…")
            let data = GedcomCompiledTree.encode(graph)
            try data.write(to: artifactURL(generation), options: .atomic)

            progress("Verifying compiled tree…")
            let decoded = try GedcomCompiledTree.decode(try Data(contentsOf: artifactURL(generation)))
            var problems = verify(decoded, graph)
            let sourceRecords = try zip(sources, zip(keys, graph.physicalSources)).map { url, bound -> Source in
                let stat = try GedcomCompiledTree.sourceStat(url)
                return Source(fileName: url.lastPathComponent, path: url.path,
                              size: stat.size, modifiedAt: Date(timeIntervalSince1970: stat.mtime),
                              key: bound.0, sha256: bound.0, droppedLineCount: bound.1.droppedLineCount)
            }
            let logicalRecords = graph.sourceProvenance.map(LogicalSource.init)
            // Two assertions, not assumptions (codex #816/#822): the
            // artifact's PHYSICAL binding IS the manifest's source list and
            // its LOGICAL provenance IS the manifest's logicalSources
            // (name, sha, dropped, order).
            func line(_ name: String, _ sha: String?, _ dropped: Int) -> String { "\(name):\(sha ?? "-"):\(dropped)" }
            let artifactPhysical = decoded.physicalSources.map { line($0.name, $0.sha256, $0.droppedLineCount) }
            let manifestPhysical = sourceRecords.map { line($0.fileName, $0.sha256, $0.droppedLineCount) }
            if artifactPhysical != manifestPhysical {
                problems.append("artifact physical binding ≠ manifest sources (\(artifactPhysical) ≠ \(manifestPhysical))")
            }
            let artifactLogical = decoded.sourceProvenance.map { line($0.name, $0.sha256, $0.droppedLineCount) }
            let manifestLogical = logicalRecords.map { line($0.fileName, $0.sha256, $0.droppedLineCount) }
            if artifactLogical != manifestLogical {
                problems.append("artifact logical provenance ≠ manifest logicalSources (\(artifactLogical) ≠ \(manifestLogical))")
            }
            // Late-rewrite guard (codex #822 item 2): the first hash bound
            // the graph; compile + verify took time; hash the same files
            // again NOW, before anything durable is written. A source that
            // changed meanwhile is refused exactly like one that changed
            // before the bind — no manifest, no pointer, generation removed.
            let rehashed = try sourceKeys(for: sources)
            if rehashed != keys {
                let changed = zip(sources, zip(keys, rehashed)).filter { $0.1.0 != $0.1.1 }.map(\.0.lastPathComponent)
                log("[family-tree] compiled generation \(generation) REFUSED, not promoted: "
                    + "source\(changed.count == 1 ? "" : "s") \(changed.joined(separator: ", ")) changed during compile/verify (hash differs from the bound hash)")
                try? fileManager.removeItem(at: generationURL(generation))
                return nil
            }
            let manifest = Manifest(
                schema: Self.schemaVersion, codec: GedcomCompiledTree.codecVersion,
                index: GedcomFamilyGraph.TreeIndex.formatVersion, generation: generation,
                createdAt: Date(), sources: sourceRecords, logicalSources: logicalRecords,
                peopleCount: decoded.people.count, familyCount: decoded.familyCount,
                verification: problems, mergeReport: mergeReport,
                localDroppedLineCount: decoded.droppedLineCount,
                totalDroppedLineCount: decoded.totalDroppedLineCount)
            try Self.encoder.encode(manifest).write(to: manifestURL(generation), options: .atomic)

            guard problems.isEmpty else {
                log("[family-tree] compiled generation \(generation) FAILED verification, not promoted: "
                    + problems.joined(separator: "; "))
                prune(keeping: readPointer())
                return nil
            }
            // INTEGRITY AUDIT (2026-09-16). Verification above proves the
            // artifact is internally consistent; it says nothing about
            // whether this tree is SMALLER than the one it replaces. That
            // gap is exactly how a Refresh promoted 16,383 people over
            // 39,250 with every step reporting success. Compare the two
            // generations and write the answer to the log ALWAYS — a note
            // when it grew, an alarm when a source or a tenth of the people
            // went missing.
            //
            // It reports, it does not refuse: a smaller tree can be
            // deliberate ("Replace family tree" with a shorter pull), and
            // trading a silent loss for a silent block would be no better.
            // The rollback the store has always had is the remedy.
            let previousManifest = readPointer().flatMap { readManifest($0.current) }
            let integrity = TreeIntegrityCheck.compare(incoming: manifest, against: previousManifest)
            for finding in integrity {
                let tag: String
                switch finding.severity {
                case .note:    tag = "tree integrity"
                case .warning: tag = "tree integrity WARNING"
                case .alarm:   tag = "tree integrity ALARM"
                }
                log("[family-tree] \(tag): \(finding.message)")
            }
            if TreeIntegrityCheck.hasAlarm(integrity) {
                log("[family-tree] generation \(generation) is being promoted DESPITE the alarm above. "
                    + "If this was not intended, roll back to \(previousManifest?.generation ?? "the previous generation").")
            }

            try writeSidecars(sourceRecords)
            let old = readPointer()
            let pointer = Pointer(schema: Self.schemaVersion, codec: GedcomCompiledTree.codecVersion,
                                  index: GedcomFamilyGraph.TreeIndex.formatVersion,
                                  current: generation,
                                  previous: old.map { $0.current == generation ? nil : $0.current } ?? nil,
                                  sourceKeys: keys)
            try writePointer(pointer)
            prune(keeping: pointer)
            log("[family-tree] compiled generation \(generation) promoted (\(decoded.people.count) people, "
                + "\(data.count / 1024) KB, sources: \(sourceRecords.map(\.fileName).joined(separator: ", ")))")
            return decoded
        } catch {
            log("[family-tree] compile of generation \(generation) failed: \(error)")
            try? fileManager.removeItem(at: generationURL(generation))
            return nil
        }
    }

    /// Swap current and previous. False when there is no previous, when
    /// the previous manifest did not verify clean, or when the previous
    /// artifact no longer decodes (codex #797-6) — the pointer is left
    /// untouched in every false case.
    @discardableResult
    public func rollback() -> Bool {
        if refusesWrites {
            log("\(Self.refusedWritePrefix) rollback — pointer untouched")
            return false
        }
        do {
            return try withLock {
                guard var pointer = readPointer(), let previous = pointer.previous,
                      let manifest = readManifest(previous), manifest.verification.isEmpty else { return false }
                guard decode(generation: previous) != nil else {
                    log("[family-tree] rollback refused: previous generation \(previous) does not decode; pointer untouched")
                    return false
                }
                pointer.previous = pointer.current
                pointer.current = previous
                pointer.sourceKeys = manifest.sources.map(\.key)
                try writePointer(pointer)
                log("[family-tree] rolled back to compiled generation \(previous)")
                return true
            }
        } catch {
            log("[family-tree] rollback failed: \(error)")
            return false
        }
    }

    /// Every generation directory, newest stamp first.
    public func generations() -> [String] {
        ((try? fileManager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0.hasPrefix("gen-") }
            .sorted(by: >)
    }

    // MARK: Locking

    /// Run `body` holding an exclusive advisory lock on root/.lock.
    /// open(2) + flock(2), like a scoped std::lock_guard over a file:
    /// closing the descriptor releases the lock even if `body` throws.
    /// Blocks until the lock is free (an ingest is seconds at most).
    func withLock<T>(_ body: () throws -> T) throws -> T {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw StoreError.lockFailed(errno: errno) }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw StoreError.lockFailed(errno: errno) }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: Private

    private func writePointer(_ pointer: Pointer) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        // `.atomic` = write a temp file then rename over the old pointer, so
        // a reader sees the old or the new pointer, never a torn one.
        try JSONEncoder().encode(pointer).write(to: pointerURL, options: .atomic)
    }

    private func writeSidecars(_ sources: [Source]) throws {
        let dir = root.appendingPathComponent("sources", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        for source in sources {
            let url = dir.appendingPathComponent(source.key + ".sha256")
            // sha256sum format, plus the file the hash belongs to.
            try "\(source.sha256)  \(source.fileName)\n".write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Delete every generation except the pointer's current + previous
    /// (bounded on disk: at most 1 + keepPrevious artifacts). A failed
    /// generation is removed as soon as it is not the pointer's.
    /// Callers hold the lock.
    /// KEEP: the current generation, plus at most `keepPrevious` others.
    /// Nothing else. The bound is therefore `keepPrevious + 1`, which is
    /// what the name promises and what the sensor asserts.
    ///
    /// Three corrections live here, all from the 2026-09-16 incident and
    /// codex's review of the fix:
    ///
    /// 1. `keepPrevious` USED TO BE A BOOLEAN. The old body kept
    ///    `pointer.current` and `pointer.previous` and nothing else, so
    ///    retention was structurally two whatever the number said — and
    ///    exactly one mistake was recoverable. Rick made two.
    /// 2. ORDER BY `createdAt`, NOT BY NAME. Names are
    ///    "gen-<second-resolution stamp>-<RANDOM suffix>", so two ingests
    ///    in one second sort by the random part and lexical order stops
    ///    being chronological. codex's review saw the OLDEST generation
    ///    retained by a name sort.
    /// 3. CURRENT MUST NOT SPEND THE QUOTA, and `pointer.previous` must
    ///    not be added on top of it — either mistake makes the real bound
    ///    larger than the promise.
    ///
    /// Generations that FAILED verification are never kept: they can never
    /// be promoted and must never be a rollback target.
    private func prune(keeping pointer: Pointer?) {
        var keep: Set<String> = []
        guard let pointer else {
            for name in generations() { try? fileManager.removeItem(at: generationURL(name)) }
            return
        }
        keep.insert(pointer.current)

        // Newest verified first, current excluded — the candidates for the
        // previous-generation quota.
        let candidates = generations()
            .compactMap { name -> (name: String, at: Date)? in
                guard name != pointer.current,
                      let m = readManifest(name), m.verification.isEmpty else { return nil }
                return (name, m.createdAt)
            }
            .sorted { $0.at == $1.at ? $0.name > $1.name : $0.at > $1.at }
            .map(\.name)

        // `pointer.previous` first so rollback always has its target, then
        // fill the rest of the quota with the newest.
        var previousKeep: [String] = []
        if let previous = pointer.previous, candidates.contains(previous) {
            previousKeep.append(previous)
        }
        for name in candidates where !previousKeep.contains(name) && previousKeep.count < keepPrevious {
            previousKeep.append(name)
        }
        keep.formUnion(previousKeep.prefix(keepPrevious))

        for name in generations() where !keep.contains(name) {
            try? fileManager.removeItem(at: generationURL(name))
        }
    }

    /// A stamp no existing generation directory uses (two ingests in the
    /// same second draw different random suffixes; on the 1-in-65536
    /// collision, draw again). Callers hold the lock.
    private func freshGenerationName() -> String {
        var name = "gen-" + Self.stamp()
        while fileManager.fileExists(atPath: generationURL(name).path) { name = "gen-" + Self.stamp() }
        return name
    }

    static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss"
        return formatter.string(from: Date()) + "-" + String(UInt32.random(in: 0...0xFFFF), radix: 16)
    }

    /// ISO-8601 WITH FRACTIONAL SECONDS, read tolerantly.
    ///
    /// Plain `.iso8601` truncates to whole seconds, so a manifest's
    /// `createdAt` came back at one-second resolution — and retention,
    /// which orders generations by that field, could not tell apart two
    /// ingests in the same second. The tiebreak then fell through to the
    /// generation name, whose suffix is RANDOM, so which generation
    /// survived a prune was non-deterministic. It surfaced as
    /// testRetentionStillPrunesBeyondTheWindow passing alone and failing
    /// in the full suite, where promotes land fast enough to collide.
    ///
    /// Writing fractional seconds fixes the ordering; the DECODER accepts
    /// both spellings so every manifest written before today still reads.
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // Tolerant BOTH ways: fractional (written from 2026-09-17) and
        // whole-second (every manifest before it).
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: text) ?? plain.date(from: text) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "not an ISO-8601 date: \(text)"))
        }
        return d
    }()
}
