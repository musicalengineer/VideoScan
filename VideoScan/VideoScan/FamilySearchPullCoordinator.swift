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
import Foundation
import VideoScanCore

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
        let generations: Int
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

    /// Where the archive wants the finished file. Injected so tests never
    /// write near a real archive.
    private let gedcomDirectory: URL
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
    }

    /// A .ged the user already has (a Terminal run the sheet was not
    /// watching, a MacFamilyTree export, an Ancestry download): same parse,
    /// same replace prompt, same install. Nothing is copied until Replace.
    func installFromFile(_ url: URL) {
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
        let parsed = await Task.detached(priority: .userInitiated) {
            () -> (new: TreeSummary, current: TreeSummary?, unmatched: Int)? in
            guard let graph = GedcomFamilyGraph(fileURL: output),
                  !graph.people.isEmpty else { return nil }
            let new = TreeSummary(
                fileName: output.lastPathComponent, people: graph.people.count,
                families: graph.familyCount, generations: Self.deepestAncestorDepth(in: graph))
            // The tree Hallie reads today: newest valid file in the archive's
            // GEDCOM folder, exactly as the loader will choose it.
            let outcome = FamilyGraphFileLoader(originalsDirectory: gedcomDirectory, fileManager: fileManager).loadNewestOutcome()
            let current = outcome.graph.map {
                TreeSummary(fileName: outcome.selectedURL?.lastPathComponent ?? "current tree",
                            people: $0.people.count, families: $0.familyCount,
                            generations: Self.deepestAncestorDepth(in: $0))
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
        guard case .ready(let output, let new, _, _) = phase else { return }
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
