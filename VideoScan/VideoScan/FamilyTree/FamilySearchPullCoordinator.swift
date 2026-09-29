// FamilySearchPullCoordinator.swift
// Lifecycle for "Get Family Tree": write the script, hand it to Terminal,
// wait for the export to appear, verify it parses, then install it into the
// archive's 40_Family_Tree/GEDCOM folder.
//
// The coordinator never touches credentials — see FamilySearchPull.swift for
// why the run happens in Terminal at all. From VideoScan's side this is
// simply "a file is going to show up at a path I chose".

import AppKit
import Combine
import CryptoKit
import Foundation
import OSLog
import VideoScanCore

private let fsLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "familysearch.pull")

@MainActor
final class FamilySearchPullCoordinator: ObservableObject, Identifiable {
    /// Identity for `.sheet(item:)` — one pull per presentation.
    nonisolated let id = UUID()

    enum Phase: Equatable {
        /// Sheet is open, nothing launched yet.
        case idle
        /// Terminal has the script; we're watching for the .ged to land.
        case waiting(output: URL)
        /// The file is complete (or was handed to us) and is being parsed
        /// off the main actor. Not settled: a sheet dismiss here must not
        /// drop the coordinator (codex #707 item 2).
        case parsing(output: URL)
        /// The file arrived and parsed. Ready to install — shown as a
        /// REPLACE decision against the tree currently loaded (Rick
        /// 2026-08-25: "Would you like to replace the existing gedcom data?").
        case ready(output: URL, new: TreeSummary, current: TreeSummary?, unmatchedFolderIDs: Int)
        /// Installed into the archive; `installed` is the archive copy.
        case installed(installed: URL, people: Int)
        case failed(message: String)
    }

    /// What a GEDCOM file amounts to, for the side-by-side.
    struct TreeSummary: Equatable {
        let fileName: String
        let people: Int
        let families: Int
        /// Nil when the summary came from a compiled generation's MANIFEST
        /// rather than a parsed graph — depth needs the graph, and reading
        /// the manifest is what keeps the sheet from promoting anything
        /// (codex, 2026-09-17). The sheet shows "—" rather than a number
        /// it does not have.
        let generations: Int?
    }

    @Published private(set) var phase: Phase = .idle
    /// When `launch()` handed the script to Terminal — the sidebar shows
    /// "since 7:36 PM" from this. Nil until a launch happens.
    @Published private(set) var startedAt: Date?
    /// Echoed under the sheet's button so the user reads the exact command
    /// before it runs — the verification step Rick asked for.
    @Published private(set) var previewLine: String = ""
    /// Set when the output file has stopped growing (no trailer yet) for
    /// `pollsBeforeQuiet` polls; nil once it grows again or completes. A
    /// pause is NOT failure — the tool waits on a password prompt, an API
    /// rate limit, or just a slow page — so the sheet shows a soft "may be
    /// waiting for you" note and the watcher keeps watching (codex #707
    /// item 3). Failure needs evidence: the file disappearing.
    @Published private(set) var quietSince: Date?
    @Published var request: FamilySearchPullRequest
    /// True while Add-to-current-tree is writing. Replace and a second Add
    /// are refused (not queued) until it settles — one install at a time,
    /// deterministic (codex #773 item 1).
    @Published private(set) var isInstalling = false

    /// Where the archive wants the finished file. Injected so tests never
    /// write near a real archive.
    private let gedcomDirectory: URL
    /// Where a merge is written BEFORE it is activated. Injected so tests
    /// stage under their own temp root; production: App Support
    /// family-tree/staging/. Nothing here is ever read by the loader.
    private let stagingDirectory: URL
    /// The staging folder of the merge in flight, so `cancel()` can drop it.
    private var stagingInFlight: URL?
    private var installTask: Task<Void, Never>?
    private let scriptURL: URL
    private let locator: FamilySearchToolLocator
    private let fileManager: FileManager
    private let workspace: FamilySearchPullLauncher

    /// Only a file at least this recent counts as "the one we just asked
    /// for" — otherwise a leftover export from last week would be adopted
    /// the instant the sheet opened.
    private var launchDate: Date = .distantPast
    private var watchTask: Task<Void, Never>?
    /// The parse/compare work is owned here, not fire-and-forget: cancel()
    /// drops it, and a result from a superseded parse is discarded by
    /// generation (same idea as `FamilyTreeLiveModel.loadGeneration` — a
    /// monotonically increasing token; a stale worker compares its copy
    /// against the current one and bails).
    private var parseTask: Task<Void, Never>?
    private var parseGeneration = 0
    /// Test pacing only: an artificial wait before the parse so a sensor
    /// can forget/dismiss/re-parse *during* it. Zero in production.
    let parseDelay: Duration

    /// Poll interval and give-up horizon. A real 20-generation pull took
    /// ~2 h (2026-08-25) and the coordinator now outlives the sheet, so
    /// the horizon is a safety net, not a UX budget. Stall detection
    /// (below) is what catches a run that actually died.
    private let pollInterval: Duration
    let timeout: Duration

    /// 7 days — effectively "never". A real 20-generation pull took 9.5 h
    /// (2026-08-25 19:36 → 08-26 05:07); the poll is a 2 s stat(), so a clock
    /// deadline only adds a way to give up on a run that is still working.
    /// Completion is the `0 TRLR` trailer; death is the stall detector.
    /// Pinned by `FamilySearchPullCenterTests.defaultTimeoutCoversAnOvernightPull`.
    static let defaultTimeout: Duration = .seconds(7 * 24 * 60 * 60)

    init(
        gedcomDirectory: URL,
        defaultUsername: String = "",
        scriptURL: URL? = nil,
        stagingDirectory: URL? = nil,
        locator: FamilySearchToolLocator = FamilySearchToolLocator(),
        fileManager: FileManager = .default,
        launcher: FamilySearchPullLauncher = WorkspaceLauncher(),
        pollInterval: Duration = .seconds(2),
        timeout: Duration = FamilySearchPullCoordinator.defaultTimeout,
        parseDelay: Duration = .zero
    ) {
        self.parseDelay = parseDelay
        self.gedcomDirectory = gedcomDirectory
        self.locator = locator
        self.fileManager = fileManager
        self.workspace = launcher
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.scriptURL = scriptURL ?? Self.defaultScriptURL(fileManager: fileManager)
        self.stagingDirectory = stagingDirectory
            ?? Self.defaultScriptURL(fileManager: fileManager).deletingLastPathComponent()
                .appendingPathComponent("staging", isDirectory: true)
        self.request = FamilySearchPullRequest(
            username: defaultUsername,
            outputURL: Self.defaultOutputURL(fileManager: fileManager))
    }

    // MARK: Defaults

    static func defaultScriptURL(fileManager: FileManager = .default) -> URL {
        let support = fileManager.urls(for: .applicationSupportDirectory,
                                       in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return support
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent("get-family-tree.command")
    }

    /// Staging, not the archive: nothing enters 40_Family_Tree until it has
    /// parsed. Downloads is somewhere the user can actually find it.
    static func defaultOutputURL(fileManager: FileManager = .default) -> URL {
        let downloads = fileManager.urls(for: .downloadsDirectory,
                                         in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return downloads.appendingPathComponent("familysearch-tree.ged")
    }

    var toolIsInstalled: Bool { locator.locate() != nil }

    // MARK: Preview

    /// Rebuild the previewed command. Returns the validation error (if any)
    /// so the sheet can show it inline next to the offending field.
    @discardableResult
    func refreshPreview() -> FamilySearchPullError? {
        guard let toolURL = locator.locate() else {
            previewLine = ""
            return .toolNotFound
        }
        do {
            previewLine = try FamilySearchPullCommand(
                toolURL: toolURL, request: request).displayLine
            return nil
        } catch let error as FamilySearchPullError {
            previewLine = ""
            return error
        } catch {
            previewLine = ""
            return .scriptWriteFailed(error.localizedDescription)
        }
    }

    // MARK: Launch

    /// Write the script, open it in Terminal, and start watching for output.
    /// Nothing runs until the user presses Return in that window.
    func launch() {
        if ViewerWriteGuard.refuse("FamilySearchPull.launch") { return }
        do {
            guard let toolURL = locator.locate() else {
                throw FamilySearchPullError.toolNotFound
            }
            let command = try FamilySearchPullCommand(toolURL: toolURL, request: request)
            let outputDirectory = request.outputURL.deletingLastPathComponent()
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: outputDirectory.path,
                                         isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw FamilySearchPullError.outputDirectoryMissing(outputDirectory)
            }

            previewLine = command.displayLine
            let script = FamilySearchPullScript(command: command, scriptURL: scriptURL)
            try script.write(fileManager: fileManager)

            launchDate = Date()
            startedAt = launchDate
            quietSince = nil
            workspace.open(scriptURL)
            phase = .waiting(output: request.outputURL)
            startWatching(output: request.outputURL)
        } catch let error as FamilySearchPullError {
            phase = .failed(message: error.localizedDescription)
        } catch {
            phase = .failed(message: error.localizedDescription)
        }
    }

    func cancel() {
        watchTask?.cancel()
        watchTask = nil
        parseTask?.cancel()
        parseTask = nil
        // Bump so a detached parse that cannot observe cancellation mid-
        // GEDCOM still finds itself stale when it comes back.
        parseGeneration &+= 1
        quietSince = nil
        phase = .idle
        // A merge still writing to staging finds its generation stale
        // after the write and cleans up itself; a finished-but-unactivated
        // one is dropped here.
        if let staging = stagingInFlight {
            try? fileManager.removeItem(at: staging)
            stagingInFlight = nil
        }
    }

    /// A .ged the user already has (a Terminal run the sheet was not
    /// watching, a MacFamilyTree export, an Ancestry download): same parse,
    /// same replace prompt, same install. Nothing is copied until Replace.
    func installFromFile(_ url: URL) {
        if ViewerWriteGuard.refuse("FamilySearchPull.installFromFile") { return }
        watchTask?.cancel()
        watchTask = nil
        guard url.pathExtension.lowercased() == "ged" else {
            phase = .failed(message: FamilySearchPullError.outputNotGedcom(url).localizedDescription)
            return
        }
        beginParse(output: url)
    }

    // MARK: Watching

    private func startWatching(output: URL) {
        watchTask?.cancel()
        quietSince = nil
        let deadline = ContinuousClock.now.advanced(by: timeout)
        watchTask = Task { [weak self] in
            guard let self else { return }
            var lastSize: Int64 = -1
            var stableCount = 0
            let interval = self.pollInterval
            let since = self.launchDate
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                guard let size = await Self.fileSize(at: output, newerThan: since) else {
                    // The tool creates the file eagerly (argparse opens `-o`
                    // before it even prompts for the password), so "missing"
                    // here usually means "not ours yet" — unless we had
                    // already seen it. A file that was there and is now
                    // gone is the one hard piece of evidence we have that
                    // the run is over (user deleted it, tool cleaned up).
                    if lastSize >= 0 {
                        self.quietSince = nil
                        self.phase = .failed(message:
                            "\(output.lastPathComponent) was removed before it finished. Nothing was installed — run Get Family Tree again, or use Install from file if you have the export somewhere else.")
                        return
                    }
                    stableCount = 0
                    continue
                }
                // getmyancestors writes `0 TRLR` as the final line of a
                // complete GEDCOM. That is a real end-of-file marker, so we
                // never have to guess from timing whether a long pause in
                // the middle of a big write means "finished".
                if size > 0, await Self.hasGedcomTrailer(at: output) {
                    self.quietSince = nil
                    self.beginParse(output: output)
                    return
                }
                if size > 0, size == lastSize {
                    stableCount += 1
                    // No growth for a while and still no trailer. That is
                    // NOT proof the run died — the tool pauses on password
                    // entry, API throttling, and simply between pages — so
                    // keep watching and let the sheet say "may be waiting
                    // for you". The user can Forget it; the deadline is
                    // the backstop.
                    if stableCount >= Self.pollsBeforeQuiet, self.quietSince == nil {
                        self.quietSince = Date()
                    }
                } else {
                    stableCount = 0
                    self.quietSince = nil
                }
                lastSize = size
            }
            if !Task.isCancelled {
                self.quietSince = nil
                self.phase = .failed(message:
                    "Timed out waiting for \(output.lastPathComponent). If the Terminal window is still working, leave it running and use Install from file when it finishes.")
            }
        }
    }

    /// Polls with no growth and no trailer before `quietSince` is set.
    /// 15 × 2s ≈ 30 seconds. Informational only — never a failure.
    static let pollsBeforeQuiet = 15

    /// Wording for the sheet's soft stall note. Pure so a test can pin it.
    nonisolated static func quietMessage(fileName: String, since: Date, now: Date = Date()) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(since) / 60))
        let span = minutes < 1 ? "under a minute" : (minutes == 1 ? "1 min" : "\(minutes) min")
        return "No change to \(fileName) for \(span) — Terminal may be waiting for you (password prompt, or a pause between pages). Still watching."
    }

    /// True when the file ends with GEDCOM's `0 TRLR` trailer — the last
    /// line getmyancestors writes. Reads only the tail, so this costs the
    /// same on a 200 MB export as on a 2 KB one.
    nonisolated static func hasGedcomTrailer(at url: URL) async -> Bool {
        await Task.detached(priority: .utility) { () -> Bool in
            guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
            defer { try? handle.close() }
            guard let end = try? handle.seekToEnd() else { return false }
            let window: UInt64 = 64
            let start = end > window ? end - window : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd(),
                  let tail = String(data: data, encoding: .utf8)
            else { return false }
            return tail
                .split(separator: "\n", omittingEmptySubsequences: true)
                .last?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased() == "0 TRLR"
        }.value
    }

    /// Size of the output file, but only if it post-dates the launch —
    /// a stale export from an earlier run must never be adopted silently.
    /// `nonisolated static` with everything passed in: no actor hop per
    /// poll, and nothing here can accidentally read main-actor state.
    ///
    /// Deliberately `FileManager.attributesOfItem` (a fresh stat(2) each
    /// call) and NOT `URL.resourceValues`: the latter caches per URL value,
    /// so polling the same URL reported the FIRST size forever — growth and
    /// deletion were both invisible (found by the #707 item-3 sensor).
    nonisolated static func fileSize(at url: URL, newerThan since: Date) async -> Int64? {
        await Task.detached(priority: .utility) { () -> Int64? in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  (attributes[.type] as? FileAttributeType) == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  // A couple of seconds of slack: the tool may create the
                  // file a moment before our launch stamp settles.
                  modified >= since.addingTimeInterval(-2),
                  let size = (attributes[.size] as? NSNumber)?.int64Value
            else { return nil }
            return size
        }.value
    }

    /// Start (or restart) the parse. Only the newest generation may
    /// publish; anything older that is still running is cancelled and, if
    /// it cannot observe that, its result is dropped on return.
    private func beginParse(output: URL) {
        parseTask?.cancel()
        parseGeneration &+= 1
        let generation = parseGeneration
        phase = .parsing(output: output)
        parseTask = Task { [weak self] in
            guard let self else { return }
            await self.finish(output: output, generation: generation)
        }
    }

    /// Parse before offering to install. A truncated download — the tool
    /// killed halfway, the borrowed app key revoked mid-run — must not be
    /// installed over a good tree.
    private func finish(output: URL, generation: Int) async {
        if parseDelay > .zero {
            // `try?` here is deliberate: a cancelled sleep throws, and a
            // cancelled parse has nothing left to do.
            guard (try? await Task.sleep(for: parseDelay)) != nil else { return }
        }
        let gedcomDirectory = self.gedcomDirectory
        let fileManager = self.fileManager
        let folderIDs = FamilyAssetConfigurationCenter.shared.snapshot().makeStore().personFolderGEDCOMIDs()
        // A SUMMARY IS A READ. It needs a count and a filename, not a
        // graph — so take them from the compiled generation's MANIFEST,
        // which cannot promote anything (codex, 2026-09-17: the
        // store-aware loader narrowed a live generation 54/2 → 20/1 merely
        // by being consulted for the sheet). `readOnly` was the wrong
        // lever: it means "decode only a promoted generation", so with no
        // store the sheet showed nothing at all.
        let currentGeneration = compiledStore()?.loadCurrent()?.manifest
        // Fallback for a tree that has never been compiled: a loader with
        // NO store, which is inherently non-promoting.
        let summaryLoader = currentTreeLoader(promoting: false, usingStore: false)
        let parsed = await Task.detached(priority: .userInitiated) {
            () -> (new: TreeSummary, current: TreeSummary?, unmatched: Int)? in
            guard let graph = GedcomFamilyGraph(fileURL: output),
                  !graph.people.isEmpty else { return nil }
            let new = TreeSummary(
                fileName: output.lastPathComponent, people: graph.people.count,
                families: graph.familyCount, generations: Self.deepestAncestorDepth(in: graph))
            // The tree Hallie reads today — via the STORE-AWARE loader, so
            // the "current" people count the sheet shows is the compiled
            // multi-source tree and not the newest single file. Before
            // 2026-09-16 this under-reported Rick's tree as 16,383 when it
            // is 39,250.
            let current: TreeSummary?
            if let g = currentGeneration {
                // The compiled tree, from its manifest: the number Rick is
                // actually running. Before 2026-09-16 the sheet showed the
                // newest SINGLE file — 16,383 for a 39,250-person tree —
                // so he decided on a wrong count.
                current = TreeSummary(
                    fileName: g.sources.map(\.fileName).sorted().joined(separator: " + "),
                    people: g.peopleCount, families: g.familyCount, generations: nil)
            } else {
                let outcome = summaryLoader.loadNewestOutcome()
                current = outcome.graph.map {
                    TreeSummary(fileName: outcome.selectedURL?.lastPathComponent ?? "current tree",
                                people: $0.people.count, families: $0.familyCount,
                                generations: Self.deepestAncestorDepth(in: $0))
                }
            }
            let newIDs = Set(graph.people.keys.map(Self.idKey))
            let unmatched = folderIDs.filter { !newIDs.contains($0) }.count
            return (new, current, unmatched)
        }.value

        // Back on the main actor. Superseded (a newer parse started) or
        // cancelled (forget / Keep current) → this result is nobody's.
        guard generation == parseGeneration, !Task.isCancelled else { return }
        parseTask = nil

        guard let parsed else {
            phase = .failed(message:
                FamilySearchPullError.downloadedFileUnreadable(output).localizedDescription)
            return
        }
        phase = .ready(output: output, new: parsed.new, current: parsed.current,
                       unmatchedFolderIDs: parsed.unmatched)
    }

    /// GEDCOM pointer normalised for comparison (`@I42@` / `I42` / `i42`).
    nonisolated static func idKey(_ raw: String) -> String {
        raw.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// How many generations the export actually reaches — the number Rick
    /// actually cares about, and the one the sheet reports.
    /// Iterative on purpose. This runs on a detached task (≈512 KB of
    /// stack), and a pedigree deep enough to matter — or a malformed one
    /// with a long spurious chain — would overflow a recursive walk long
    /// before it produced an answer. Explicit stack + memo keeps it O(people)
    /// in time and heap-bounded in space.
    nonisolated static func deepestAncestorDepth(in graph: GedcomFamilyGraph) -> Int {
        var memo: [String: Int] = [:]
        memo.reserveCapacity(graph.people.count)
        var onPath: Set<String> = []
        var deepest = 0

        for root in graph.people.values {
            if let known = memo[root.id] {
                deepest = max(deepest, known)
                continue
            }
            // (person, hasBeenExpanded)
            var stack: [(GedcomFamilyGraph.Person, Bool)] = [(root, false)]
            while let (person, expanded) = stack.last {
                if memo[person.id] != nil {
                    stack.removeLast()
                    continue
                }
                if !expanded {
                    stack[stack.count - 1].1 = true
                    onPath.insert(person.id)
                    for parent in graph.relatives(.parents, of: person)
                    where memo[parent.id] == nil && !onPath.contains(parent.id) {
                        stack.append((parent, false))
                    }
                } else {
                    // A parent still on the current path is a cycle (people
                    // recorded as their own ancestor do occur in user-
                    // submitted trees); it contributes nothing rather than
                    // looping forever.
                    let best = graph.relatives(.parents, of: person)
                        .compactMap { memo[$0.id] }
                        .max() ?? 0
                    memo[person.id] = best + 1
                    deepest = max(deepest, best + 1)
                    onPath.remove(person.id)
                    stack.removeLast()
                }
            }
        }
        return deepest
    }

    // MARK: Install

    /// Copy the verified export into the archive's GEDCOM folder. The
    /// loader takes the newest valid file, so this is additive — the
    /// previous tree stays on disk as its own history.
    func install() {
        if ViewerWriteGuard.refuse("FamilySearchPull.install") { return }
        guard case .ready(let output, let new, _, _) = phase, !isInstalling else { return }
        let people = new.people
        do {
            try fileManager.createDirectory(
                at: gedcomDirectory, withIntermediateDirectories: true)
            let stamp = Self.timestampFormatter.string(from: Date())
            var destination = gedcomDirectory
                .appendingPathComponent("familysearch-\(stamp).ged")
            var suffix = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = gedcomDirectory
                    .appendingPathComponent("familysearch-\(stamp)-\(suffix).ged")
                suffix += 1
            }
            try fileManager.copyItem(at: output, to: destination)
            phase = .installed(installed: destination, people: people)
        } catch {
            phase = .failed(message:
                FamilySearchPullError.installFailed(error.localizedDescription)
                    .localizedDescription)
        }
    }


    /// The loader the MERGE and the sheet's "current tree" summary must
    /// use — the one that can see a multi-source compiled generation.
    ///
    /// P1, 2026-09-16. Both sites built `FamilyGraphFileLoader` with NO
    /// `compiledStore`, so the `if let store = compiledStore` branch never
    /// ran and the loader fell through to parsing the newest single .ged.
    /// Rick's compiled tree is TWO pulls — his 16,383 people and Donna's —
    /// 39,250 together. A Refresh therefore rebased silently onto his file
    /// alone and Donna's whole line, Edward III included, vanished from the
    /// artifact. He noticed within minutes; nothing was lost on disk, but
    /// the active tree was wrong.
    ///
    /// The loader's own doc states the rule this broke (codex #826): "the
    /// loader never demotes an N-pull tree to the newest single file". It
    /// cannot honour that without the store.
    /// `promoting: false` is a READ. `loadNewestOutcome` can call
    /// `parseAndPromote`, so a loader handed a store has a SIDE EFFECT —
    /// it may compile and promote a fallback generation (codex, 2026-09-17).
    /// Two places must never do that:
    ///   • the sheet's "current tree" summary, which runs before the user
    ///     has chosen anything at all;
    ///   • any read whose result the fail-closed guard is about to compare
    ///     against, because a promote here would narrow the tree and the
    ///     guard would then see 1-vs-1 and wave it through — the read
    ///     defeating the check that follows it.
    /// A non-promoting loader decodes the promoted generation and stops.
    private func currentTreeLoader(promoting: Bool = true,
                                   usingStore: Bool = true) -> FamilyGraphFileLoader {
        var loader = FamilyGraphFileLoader(originalsDirectory: gedcomDirectory,
                                           fileManager: fileManager)
        loader.compiledStore = usingStore ? compiledStore() : nil
        loader.readOnly = !promoting && usingStore
        // The production store's logger is a no-op, so anything the loader
        // says while compiling would vanish (codex, 2026-09-17).
        loader.compiledStore?.log = { appLog.write($0) }
        return loader
    }

    /// The compiled store the base is read through. INJECTED rather than
    /// reaching for `.production` inline: a hardcoded production root is
    /// the wrong store in tests and absent on a read-only viewer, and a
    /// guard nobody can exercise is a guard nobody can trust — which is
    /// the whole reason this P1 shipped in the first place.
    var compiledStore: @Sendable () -> FamilyGraphCompiledStore? = { .production }

    /// "Add to current tree": build a DERIVED merge artifact from the
    /// verified export and the tree the loader reads today, keyed by
    /// FamilySearch ID, and activate it as a NEW file in the archive's
    /// GEDCOM folder. The raw pulls remain the truth: neither is modified
    /// or moved; a `.sha256` sidecar is written beside each (if missing)
    /// so they can be verified later. The artifact is lossy (names,
    /// vitals, links, FSIDs — see GedcomFamilyGraph+Writer) and says so
    /// in its HEAD NOTE.
    ///
    /// Staged and atomic (codex #773 item 1): the file is written under
    /// `stagingDirectory/<uuid>/`; only if the generation token is still
    /// current AFTER the write (no Keep current / Forget / newer parse in
    /// between) is it moved into the active folder — first under a
    /// `.partial` name the loader ignores, then a same-directory rename.
    /// One install at a time: `isInstalling` refuses a second Add and any
    /// Replace until this settles. Returns the task so a caller can await
    /// the outcome; the phase carries it.
    ///
    /// Memory: three graphs (current, new, merged) plus the merged text —
    /// for 16k + 16k people well under 200 MB, released on return. SHA-256
    /// streams the sources in 1 MB chunks.
    @discardableResult
    func installMerged(
        policy: GedcomFamilyGraph.MergePolicy = .unionKeepingFirst
    ) -> Task<Void, Never> {
        if ViewerWriteGuard.refuse("FamilySearchPull.installMerged") { return Task {} }
        if let running = installTask { return running }
        guard case .ready(let output, _, _, _) = phase else { return Task {} }
        isInstalling = true
        let generation = parseGeneration
        let staging = stagingDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        stagingInFlight = staging
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performMerge(output: output, generation: generation,
                                    staging: staging, policy: policy)
        }
        installTask = task
        return task
    }

    /// "Refresh from FamilySearch": the SAME operation as Add to current
    /// tree, with the one difference that decides whether a re-pull is
    /// worth doing at all — where both files describe one person, the
    /// NEWER pull's values win, because it is a fresher snapshot of the
    /// same authority rather than a second opinion (Rick, 2026-09-16; see
    /// GedcomFamilyGraph.MergePolicy).
    ///
    /// People the newer pull does not mention are kept, so a 3-generation
    /// refresh updates the close family and leaves the deep ancestry alone.
    @discardableResult
    func installRefreshed() -> Task<Void, Never> {
        installMerged(policy: .refreshFromNewer)
    }

    private func performMerge(output: URL, generation: Int, staging: URL,
                              policy: GedcomFamilyGraph.MergePolicy = .unionKeepingFirst) async {
        defer {
            isInstalling = false
            installTask = nil
        }
        let gedcomDirectory = self.gedcomDirectory
        let fileManager = self.fileManager
        let stamp = Self.timestampFormatter.string(from: Date())
        let verb = policy == .refreshFromNewer ? "refreshed" : "merged"
        let fileName = "familysearch-\(verb)-\(stamp).ged"
        // Two-case outcome (C++: a tagged union), because the failure is
        // a sentence for the sheet, not an `Error`.
        enum Staged { case written(URL, Int, GedcomFamilyGraph.MergeOutcome), failed(String) }
        let loader = currentTreeLoader()
        let compiledStore = self.compiledStore
        // THE BASELINE IS READ BEFORE THE LOAD (codex, 2026-09-17).
        // `loadNewestOutcome` below may itself compile and promote a
        // fallback when a source of a multi-source generation is missing
        // or changed. If the guard then read the generation AFTER that, it
        // would compare the already-narrowed tree against itself, see
        // 1-vs-1 and pass — the read defeating the check it feeds. Take
        // the picture first.
        let baselineGeneration = self.compiledStore()?.loadCurrent()?.manifest
        let staged = await Task.detached(priority: .userInitiated) { () -> Staged in
            guard var new = GedcomFamilyGraph(fileURL: output), !new.people.isEmpty else {
                return .failed(FamilySearchPullError.downloadedFileUnreadable(output).localizedDescription)
            }
            let outcome = loader.loadNewestOutcome()
            guard var current = outcome.graph, let currentURL = outcome.selectedURL else {
                return .failed("There is no current tree to add to — use Install family tree instead.")
            }
            // WHAT WE ARE REBASING ONTO — say it before a byte moves, so a
            // surprising artifact can be explained from the log alone
            // (Rick, 2026-09-16: "we also need good logging so we know what
            // happened if something weird/bad shows up").
            let baseSources = current.sourceProvenance.map(\.name).sorted()
            appLog.write("Family Tree \(verb): base = \(currentURL.lastPathComponent) — "
                + "\(current.people.count) people from \(baseSources.count) source(s): "
                + "\(baseSources.joined(separator: ", "))"
                + (outcome.compiled ? " [compiled generation]" : " [single parsed file]"))
            appLog.write("Family Tree \(verb): incoming = \(output.lastPathComponent) — \(new.people.count) people")

            // FAIL CLOSED. A base that is one parsed file while the compiled
            // generation has more sources means the loader could not see the
            // generation, and merging would silently narrow the tree — the
            // P1 of 2026-09-16, where Donna's 23k people and her Edward III
            // line disappeared from the artifact. Refuse instead.
            if let generation = baselineGeneration,
               generation.sources.count > baseSources.count {
                let names = generation.sources.map(\.fileName).sorted()
                appLog.write("Family Tree \(verb): REFUSED — the compiled tree has "
                    + "\(generation.sources.count) sources (\(names.joined(separator: ", "))) "
                    + "but the base only has \(baseSources.count). Merging would drop the rest.")
                return .failed(
                    "Your tree is built from \(generation.sources.count) files "
                    + "(\(names.joined(separator: ", "))), but only "
                    + "\(baseSources.count) could be loaded as the base. Merging now would "
                    + "silently drop the others. Recompile the family tree first, then try again.")
            }
            // Sidecars beside the raw sources (never touching the sources);
            // the hashes are also the merge's source fingerprints.
            let currentSHA = Self.sha256Sidecar(for: currentURL, fileManager: fileManager)
            let newSHA = Self.sha256Sidecar(for: output, fileManager: fileManager)
            current.sourceFingerprint = currentSHA
            new.sourceFingerprint = newSHA
            let merge = current.merge(with: new, policy: policy)
            let provenance = Self.provenanceNote(
                stamp: stamp, merge: merge,
                current: (currentURL, current.people.count, currentSHA),
                added: (output, new.people.count, newSHA))
            let text = merge.graph.gedcomText(provenance: provenance)
            let stagedFile = staging.appendingPathComponent(fileName)
            do {
                try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
                try text.write(to: stagedFile, atomically: true, encoding: .utf8)
            } catch {
                try? fileManager.removeItem(at: staging)
                return .failed(FamilySearchPullError.installFailed(error.localizedDescription).localizedDescription)
            }
            return .written(stagedFile, merge.graph.people.count, merge)
        }.value

        if parseDelay > .zero {
            // Test pacing (see `parseDelay`): lets a sensor cancel BETWEEN
            // the staged write and the activation check.
            try? await Task.sleep(for: parseDelay)
        }
        // Validate AFTER the write: Keep current / Forget / a newer parse
        // since we started means this artifact is nobody's — drop it.
        var stillReady = false
        if case .ready = phase { stillReady = true }
        guard generation == parseGeneration, stillReady else {
            try? fileManager.removeItem(at: staging)
            if stagingInFlight == staging { stagingInFlight = nil }
            return
        }
        switch staged {
        case .failed(let message):
            stagingInFlight = nil
            phase = .failed(message: message)
        case .written(let stagedFile, let people, let merge):
            do {
                try fileManager.createDirectory(at: gedcomDirectory, withIntermediateDirectories: true)
                var destination = gedcomDirectory.appendingPathComponent(fileName)
                var suffix = 2
                while fileManager.fileExists(atPath: destination.path) {
                    destination = gedcomDirectory.appendingPathComponent("familysearch-\(verb)-\(stamp)-\(suffix).ged")
                    suffix += 1
                }
                // Cross-volume copy lands under a name the loader ignores
                // (not ".ged"); the final step is a same-directory rename.
                let partial = destination.appendingPathExtension("partial")
                try? fileManager.removeItem(at: partial)
                try fileManager.moveItem(at: stagedFile, to: partial)
                try fileManager.moveItem(at: partial, to: destination)
                try? fileManager.removeItem(at: staging)
                stagingInFlight = nil
                appLog.write("Family Tree: merge artifact \(destination.lastPathComponent): \(merge.sharedPeopleCount) shared + \(merge.addedPeopleCount) added people; \(merge.conflicts.count) conflicts kept for review")
                phase = .installed(installed: destination, people: people)
            } catch {
                try? fileManager.removeItem(at: staging)
                stagingInFlight = nil
                phase = .failed(message: FamilySearchPullError.installFailed(error.localizedDescription).localizedDescription)
            }
        }
    }

    /// The HEAD NOTE of a merge artifact: what it is (derived, lossy),
    /// what it came from (both sources with their SHA-256), roots, counts,
    /// and every conflict the merge left for a human.
    nonisolated static func provenanceNote(
        stamp: String, merge: GedcomFamilyGraph.MergeOutcome,
        current: (URL, Int, String?), added: (URL, Int, String?)
    ) -> String {
        let roots = merge.graph.roots.map { r in r.name + (r.familySearchID.map { " (\($0))" } ?? "") }
        var lines = [
            "Derived VideoScan merge artifact (lossy: names, vitals, links, FSIDs) written \(stamp) UTC; the source files remain the record.",
            // File names + SHA-256 only — never an absolute path (codex #780).
            "sources: \(current.0.lastPathComponent) (sha256 \(current.2 ?? "unavailable"); \(current.1) people; current tree), "
                + "\(added.0.lastPathComponent) (sha256 \(added.2 ?? "unavailable"); \(added.1) people; added)",
            "Roots: " + roots.joined(separator: "; "),
            "Shared people: \(merge.sharedPeopleCount); added: \(merge.addedPeopleCount); unmatched (no FamilySearch ID): \(merge.unmatched.count); "
                + "field disagreements (first source kept): \(merge.fieldConflictCount); conflicts kept for review: \(merge.conflicts.count)",
            "Loss: \(merge.droppedLineCount) source lines (other events, sources, notes, media) are not carried by this artifact.",
        ]
        for c in merge.conflicts.prefix(50) {
            lines.append("conflict \(c.kind.rawValue) [\(c.ids.joined(separator: ", "))]: \(c.resolution)")
        }
        if merge.conflicts.count > 50 { lines.append("… and \(merge.conflicts.count - 50) more conflicts") }
        return lines.joined(separator: "\n")
    }

    /// SHA-256 of the exact bytes at `url`, streamed in 1 MB chunks. Writes
    /// (or corrects) `<file>.sha256` beside it in sha256sum format
    /// ("<hex>  <name>"); the source is only ever READ.
    ///
    /// codex #790: the digest is ALWAYS recomputed from the current bytes.
    /// The sidecar is a record for humans and `shasum -c`, never a cache
    /// the merge trusts — a download path is reused from pull to pull, so
    /// a stale sidecar would hand a NEW export the OLD fingerprint and let
    /// `merge(with:)` pointer-match FSID-less records across two different
    /// files. A read failure at any point (open or mid-file) yields nil,
    /// never a prefix hash, and leaves any existing sidecar untouched; the
    /// merge then falls back to FSID-only matching (`sameSource` false).
    ///
    /// `openChunks` is the read seam: it opens the file and returns a
    /// pull-closure yielding the next chunk, nil at EOF, throwing on I/O
    /// error (C++: an input iterator whose `++` can throw). Tests inject a
    /// reader that fails mid-file.
    nonisolated static func sha256Sidecar(
        for url: URL, fileManager: FileManager,
        openChunks: (URL) throws -> (() throws -> Data?) = FamilySearchPullCoordinator.fileHandleChunks
    ) -> String? {
        let sidecar = url.appendingPathExtension("sha256")
        var hasher = SHA256()
        do {
            let next = try openChunks(url)
            while let chunk = try next() {
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
            }
        } catch {
            fsLog.error("SHA-256 of \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public); no fingerprint recorded.")
            return nil
        }
        let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let line = "\(hex)  \(url.lastPathComponent)\n"
        // Only write when the sidecar is missing or disagrees with the bytes.
        if (try? String(contentsOf: sidecar, encoding: .utf8)) != line {
            try? line.write(to: sidecar, atomically: true, encoding: .utf8)
        }
        return hex
    }

    /// Default chunk source: a `FileHandle` read 1 MB at a time. Opening
    /// a directory succeeds on macOS but the first read throws (EISDIR),
    /// which the caller turns into "no fingerprint" — not the empty hash.
    nonisolated static func fileHandleChunks(_ url: URL) throws -> (() throws -> Data?) {
        let handle = try FileHandle(forReadingFrom: url)
        return {
            let chunk = try handle.read(upToCount: 1 << 20)
            if chunk == nil || chunk!.isEmpty { try handle.close() }
            return chunk
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: - Launcher seam

/// Opening Terminal is the one side effect tests must not perform.
protocol FamilySearchPullLauncher: Sendable {
    func open(_ url: URL)
}

struct WorkspaceLauncher: FamilySearchPullLauncher {
    func open(_ url: URL) {
        NSWorkspace.shared.open(url)
    }
}
