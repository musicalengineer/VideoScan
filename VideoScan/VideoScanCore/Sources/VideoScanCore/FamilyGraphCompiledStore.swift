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
    public var keepPrevious = 1
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

    public static var productionRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent("compiled", isDirectory: true)
    }

    public static var production: FamilyGraphCompiledStore { FamilyGraphCompiledStore(root: productionRoot) }

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
    private func prune(keeping pointer: Pointer?) {
        var keep: Set<String> = []
        if let pointer {
            keep.insert(pointer.current)
            if let previous = pointer.previous, keepPrevious > 0 { keep.insert(previous) }
        }
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

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
