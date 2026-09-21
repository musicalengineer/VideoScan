// FamilySearchPersonRefreshCoordinator.swift
// Lifecycle for "Refresh from FamilySearch…" on one tree person
// (Rick, 2026-09-21):
//
//   right-click → Refresh from FamilySearch… → Terminal asks for the
//   username + password → the one-person .ged lands in its own staging
//   folder → VideoScan checks it, diffs it against the tree, shows old |
//   new per field → Apply writes the ticked FACTS to the overlay.
//
// The coordinator never touches credentials (FamilySearchPersonRefresh.swift
// header). From VideoScan's side this is "a small file will show up at a
// path I chose" — the same watcher contract as Get Family Tree: the tool's
// `0 TRLR` trailer means complete; a pause is not failure.
//
// NON-BLOCKING: the wait is shown in a banner on the Family Tree tab with a
// Cancel button (PersonRefreshCenter owns the coordinator so the watch
// survives the tab). The review sheet appears only once the file has been
// read — never a modal over long work.
//
// One app-log line per step, all prefixed `[fs-refresh]`: started,
// received, diff, applied / refused / cancelled / undone. Each Apply and
// Undo also appends a before/after line to person-refresh-journal.jsonl.

import AppKit
import Combine
import Foundation
import VideoScanCore

@MainActor
final class PersonRefreshCoordinator: ObservableObject, Identifiable {
    /// `.sheet(item:)` identity.
    nonisolated let id = UUID()

    /// Who is being refreshed. The tree pointer is kept only to re-select
    /// the person after the reload; the FamilySearch ID is the key.
    struct Target: Equatable, Sendable {
        let personID: String
        let familySearchID: String
        let personName: String
    }

    enum Phase: Equatable {
        case idle
        /// Terminal has the script; watching for the trailer.
        case waiting(output: URL)
        /// The file is complete and is being read off the main actor.
        case parsing(output: URL)
        /// Read and diffed; waiting for Apply / Cancel.
        case ready(PersonRefreshDiff)
        case applied(fields: Int)
        /// The export was read and REFUSED (merged ID, wrong person, too
        /// many people, not a GEDCOM). `message` is the honest sentence.
        case refused(message: String)
        case failed(message: String)
    }

    let target: Target
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var startedAt: Date?
    /// No growth and no trailer for `pollsBeforeQuiet` polls — "Terminal
    /// may be waiting for you" (a note, never a failure).
    @Published private(set) var quietSince: Date?
    @Published private(set) var previewLine = ""
    /// This refresh's own folder (`<root>/<FSID>-<stamp>/`).
    private(set) var stagingFolder: URL?

    private let root: URL
    private let overlayStore: PersonFactOverlayStore
    private let journalDirectory: URL
    private let installedFacts: @MainActor () -> PersonFacts?
    private let locator: FamilySearchToolLocator
    private let launcher: FamilySearchPullLauncher
    private let pollInterval: Duration
    private let timeout: Duration
    private let log: (String) -> Void
    private let now: () -> Date
    private var watchTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    /// Monotonic token: a parse that finishes after cancel()/a newer parse
    /// finds itself stale and publishes nothing.
    private var generation = 0
    private var launchDate: Date = .distantPast

    /// 30 s at the default 1 s poll.
    nonisolated static let pollsBeforeQuiet = 30
    /// One person is seconds of work once the password is in; the horizon
    /// only exists so a forgotten Terminal window does not watch forever.
    nonisolated static let defaultTimeout: Duration = .seconds(60 * 60)

    init(target: Target,
         root: URL = PersonRefreshPaths.defaultRoot,
         overlayStore: PersonFactOverlayStore? = nil,
         journalDirectory: URL? = nil,
         installedFacts: @escaping @MainActor () -> PersonFacts?,
         locator: FamilySearchToolLocator = FamilySearchToolLocator(),
         launcher: FamilySearchPullLauncher = WorkspaceLauncher(),
         pollInterval: Duration = .seconds(1),
         timeout: Duration = PersonRefreshCoordinator.defaultTimeout,
         log: @escaping (String) -> Void = { appLog.write($0) },
         now: @escaping () -> Date = Date.init) {
        self.target = target
        self.root = root
        self.overlayStore = overlayStore ?? PersonFactOverlayStore(directory: root, log: { appLog.write($0) })
        self.journalDirectory = journalDirectory ?? root
        self.installedFacts = installedFacts
        self.locator = locator
        self.launcher = launcher
        self.pollInterval = pollInterval
        self.timeout = timeout
        self.log = log
        self.now = now
    }

    var isSettled: Bool {
        switch phase {
        case .idle, .applied, .refused, .failed: return true
        case .waiting, .parsing, .ready: return false
        }
    }

    // MARK: Launch

    /// Write the script into a fresh staging folder, open it in Terminal
    /// and start watching. Nothing runs until Return is pressed there.
    func launch() {
        if ViewerWriteGuard.refuse("PersonRefresh.launch") {
            phase = .failed(message: "Refresh from FamilySearch runs on the master Mac, not on a viewer.")
            return
        }
        do {
            guard let toolURL = locator.locate() else { throw FamilySearchPullError.toolNotFound }
            let started = now()
            // Never reuse a folder: a leftover person.ged from a refresh in
            // the same second would otherwise be read as this one's answer.
            var folder = PersonRefreshPaths.stagingFolder(root: root, familySearchID: target.familySearchID, at: started)
            var suffix = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = folder.deletingLastPathComponent()
                    .appendingPathComponent(PersonRefreshPaths.stagingFolder(
                        root: root, familySearchID: target.familySearchID, at: started).lastPathComponent + "-\(suffix)",
                        isDirectory: true)
                suffix += 1
            }
            let output = folder.appendingPathComponent(PersonRefreshPaths.outputFileName)
            let command = try FamilySearchPersonRefreshCommand(
                toolURL: toolURL, familySearchID: target.familySearchID, outputURL: output)
            let script = FamilySearchPersonRefreshScript(
                command: command, personName: target.personName,
                scriptURL: folder.appendingPathComponent(PersonRefreshPaths.scriptFileName))
            try script.write()
            stagingFolder = folder
            previewLine = command.displayLine
            launchDate = Date()
            startedAt = started
            quietSince = nil
            launcher.open(script.scriptURL)
            phase = .waiting(output: output)
            log("[fs-refresh] started \(target.personName) (\(target.familySearchID)) → \(folder.lastPathComponent)/\(output.lastPathComponent)")
            startWatching(output: output)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message: message)
            log("[fs-refresh] could not start for \(target.familySearchID): \(message)")
        }
    }

    /// Stop watching. The Terminal process is not ours to kill; the staging
    /// folder stays as the record of what was asked for.
    func cancel() {
        watchTask?.cancel(); watchTask = nil
        parseTask?.cancel(); parseTask = nil
        generation &+= 1
        quietSince = nil
        if !isSettled {
            log("[fs-refresh] cancelled \(target.personName) (\(target.familySearchID)); nothing was changed")
        }
        phase = .idle
    }

    // MARK: Watching

    private func startWatching(output: URL) {
        watchTask?.cancel()
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let interval = pollInterval
        let since = launchDate
        watchTask = Task { [weak self] in
            var lastSize: Int64 = -1
            var stable = 0
            while !Task.isCancelled, ContinuousClock.now < deadline {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled, let self else { return }
                guard let size = await FamilySearchPullCoordinator.fileSize(at: output, newerThan: since) else {
                    if lastSize >= 0 {
                        self.quietSince = nil
                        self.phase = .failed(message: "\(output.lastPathComponent) was removed before it finished. Nothing was changed.")
                        self.log("[fs-refresh] refused reason=file-removed for \(self.target.familySearchID)")
                        return
                    }
                    continue
                }
                if size > 0, await FamilySearchPullCoordinator.hasGedcomTrailer(at: output) {
                    self.quietSince = nil
                    self.read(output: output)
                    return
                }
                if size == lastSize {
                    stable += 1
                    if stable >= Self.pollsBeforeQuiet, self.quietSince == nil { self.quietSince = Date() }
                } else {
                    stable = 0
                    self.quietSince = nil
                }
                lastSize = size
            }
            guard !Task.isCancelled, let self else { return }
            self.quietSince = nil
            self.phase = .failed(message: "Stopped waiting for FamilySearch after an hour. Nothing was changed — try Refresh again.")
            self.log("[fs-refresh] refused reason=timeout for \(self.target.familySearchID)")
        }
    }

    // MARK: Read + diff

    /// Parse the export off the main actor, accept or refuse it, and diff
    /// it against what the tree shows now (overlay included, so a second
    /// refresh after an Apply reads "Already matches FamilySearch.").
    /// Internal so tests (and a future "use this file") can hand a file in.
    func read(output: URL) {
        parseTask?.cancel()
        generation &+= 1
        let token = generation
        phase = .parsing(output: output)
        let requested = target.familySearchID
        parseTask = Task { [weak self] in
            // `Task.detached` ≈ run on a worker thread; only Sendable values
            // cross (the URL and the ID in, a Result and a count out).
            let (result, people) = await Task.detached(priority: .userInitiated) {
                () -> (Result<PersonFacts, PersonRefreshRefusal>, Int) in
                let graph = GedcomFamilyGraph(fileURL: output)
                return (PersonRefreshFile.evaluate(graph, fileName: output.lastPathComponent,
                                                   requestedFamilySearchID: requested),
                        graph?.people.count ?? 0)
            }.value
            guard let self, token == self.generation, !Task.isCancelled else { return }
            self.parseTask = nil
            self.log("[fs-refresh] received \(output.deletingLastPathComponent().lastPathComponent)/"
                     + "\(output.lastPathComponent) (\(people) people) for \(requested)")
            switch result {
            case .failure(let refusal):
                self.phase = .refused(message: refusal.sentence)
                self.log("[fs-refresh] refused reason=\(refusal.logReason) for \(requested)")
            case .success(let incoming):
                guard let installed = self.installedFacts() else {
                    self.phase = .failed(message: "\(self.target.personName) (\(requested)) is no longer in the loaded tree, so there is nothing to compare. Nothing was changed.")
                    self.log("[fs-refresh] refused reason=not-in-tree for \(requested)")
                    return
                }
                let diff = PersonRefreshDiff.compute(installed: installed, incoming: incoming)
                self.log("[fs-refresh] diff \(diff.changes.count) field(s)"
                         + (diff.changes.isEmpty ? "" : " [\(diff.changes.map(\.field.key).joined(separator: ", "))]")
                         + ", \(diff.relationshipNotes.count) relationship note(s) for \(requested)")
                self.phase = .ready(diff)
            }
        }
    }

    // MARK: Apply

    /// Write the ticked facts to the overlay. Returns false (and says why
    /// in `phase`) when nothing could be written. Relationship notes are
    /// never in `changes`, so nothing selectable here can change a link.
    @discardableResult
    func apply(selectedFieldKeys: Set<String>) -> Bool {
        guard case .ready(let diff) = phase else { return false }
        if ViewerWriteGuard.refuse("PersonRefresh.apply") {
            phase = .failed(message: "This Mac is a viewer; the tree is refreshed on the master.")
            return false
        }
        let chosen = diff.changes.filter { selectedFieldKeys.contains($0.field.key) }
        guard !chosen.isEmpty else {
            log("[fs-refresh] applied 0 fields for \(target.familySearchID) (nothing ticked)")
            phase = .applied(fields: 0)
            return true
        }
        var overlay = overlayStore.load()
        overlay.record(chosen, familySearchID: target.familySearchID, displayName: target.personName, at: now())
        do {
            try overlayStore.save(overlay)
        } catch {
            phase = .failed(message: "Could not save the refreshed facts: \(error.localizedDescription). Nothing was changed.")
            log("[fs-refresh] refused reason=overlay-write-failed for \(target.familySearchID): \(error.localizedDescription)")
            return false
        }
        let entry = PersonRefreshAudit.Entry(
            at: now(), action: .applied, familySearchID: target.familySearchID, person: target.personName,
            changes: PersonRefreshAudit.applyChanges(chosen),
            source: stagingFolder.map { $0.lastPathComponent + "/" + PersonRefreshPaths.outputFileName })
        log(PersonRefreshAudit.line(entry))
        do { try PersonRefreshAudit.append(entry, directory: journalDirectory) } catch {
            log("[fs-refresh] journal not written — \(error.localizedDescription) (the app-log line above has the before/after values)")
        }
        phase = .applied(fields: chosen.count)
        return true
    }

    // MARK: Undo (static — no download involved)

    /// "Undo last refresh for this person": pop the newest overlay state
    /// for `familySearchID`. Returns the sentence to show.
    @discardableResult
    static func undoLast(familySearchID: String, personName: String,
                         overlayStore: PersonFactOverlayStore, journalDirectory: URL,
                         log: (String) -> Void = { appLog.write($0) }, now: Date = Date()) -> String {
        if ViewerWriteGuard.refuse("PersonRefresh.undo") {
            return "This Mac is a viewer; the tree is refreshed on the master."
        }
        var overlay = overlayStore.load()
        guard let (undone, restored) = overlay.undoLast(familySearchID: familySearchID) else {
            return "There is no FamilySearch refresh to undo for \(personName)."
        }
        do { try overlayStore.save(overlay) } catch {
            return "Could not undo: \(error.localizedDescription)"
        }
        let entry = PersonRefreshAudit.Entry(
            at: now, action: .undone, familySearchID: undone.familySearchID, person: personName,
            changes: PersonRefreshAudit.undoChanges(undone: undone, restored: restored), source: nil)
        log(PersonRefreshAudit.line(entry))
        do { try PersonRefreshAudit.append(entry, directory: journalDirectory) } catch {
            log("[fs-refresh] journal not written — \(error.localizedDescription)")
        }
        return restored == nil
            ? "Undid the FamilySearch refresh for \(personName); the tree shows the pulled facts again."
            : "Undid the latest FamilySearch refresh for \(personName); the earlier one still applies."
    }
}

// MARK: - Center

/// App-wide owner of the one person refresh in flight (the Get Family Tree
/// lesson, 2026-08-25: a watcher owned by a view dies with the view), plus
/// the set of people who currently have refreshed facts — kept here, not
/// read from disk in a view body, so a card's context menu costs a set
/// lookup.
@MainActor
final class PersonRefreshCenter: ObservableObject {
    static let shared = PersonRefreshCenter()

    @Published private(set) var coordinator: PersonRefreshCoordinator?
    /// Bumps on every phase change of the current coordinator, so a view
    /// observing only the center still redraws its banner.
    @Published private(set) var revision = 0
    /// FamilySearch IDs with an overlay entry (enables "Undo last refresh").
    @Published private(set) var refreshedFamilySearchIDs: Set<String> = []
    /// The last Undo's sentence, shown in the banner until dismissed.
    @Published var notice: String?

    let root: URL
    let overlayStore: PersonFactOverlayStore
    private let makeCoordinator: @MainActor (PersonRefreshCoordinator.Target, @escaping @MainActor () -> PersonFacts?) -> PersonRefreshCoordinator
    private var phaseSubscription: AnyCancellable?

    init(root: URL = PersonRefreshPaths.defaultRoot,
         overlayStore: PersonFactOverlayStore? = nil,
         makeCoordinator: (@MainActor (PersonRefreshCoordinator.Target, @escaping @MainActor () -> PersonFacts?) -> PersonRefreshCoordinator)? = nil) {
        self.root = root
        let store = overlayStore ?? PersonFactOverlayStore(directory: root, log: { appLog.write($0) })
        self.overlayStore = store
        self.makeCoordinator = makeCoordinator ?? { target, facts in
            PersonRefreshCoordinator(target: target, root: root, overlayStore: store, installedFacts: facts)
        }
        reloadRefreshedIDs()
    }

    /// Start a refresh (one at a time: a new one replaces an unfinished one,
    /// which is cancelled and logged).
    @discardableResult
    func begin(target: PersonRefreshCoordinator.Target,
               installedFacts: @escaping @MainActor () -> PersonFacts?) -> PersonRefreshCoordinator {
        coordinator?.cancel()
        notice = nil
        let fresh = makeCoordinator(target, installedFacts)
        coordinator = fresh
        phaseSubscription = fresh.$phase.sink { [weak self] _ in
            // `$phase` fires on willSet; defer the bump to after the set.
            Task { @MainActor [weak self] in self?.revision &+= 1 }
        }
        fresh.launch()
        return fresh
    }

    func cancel() {
        coordinator?.cancel()
        dismiss()
    }

    func dismiss() {
        phaseSubscription = nil
        coordinator = nil
        revision &+= 1
    }

    /// After an Apply: the overlay changed.
    func noteApplied() { reloadRefreshedIDs() }

    func undoLast(familySearchID: String, personName: String) -> String {
        let message = PersonRefreshCoordinator.undoLast(
            familySearchID: familySearchID, personName: personName,
            overlayStore: overlayStore, journalDirectory: root)
        reloadRefreshedIDs()
        notice = message
        return message
    }

    func hasRefresh(for familySearchID: String?) -> Bool {
        guard let familySearchID else { return false }
        return refreshedFamilySearchIDs.contains(familySearchID.uppercased())
    }

    private func reloadRefreshedIDs() {
        refreshedFamilySearchIDs = Set(overlayStore.load().entries.keys)
    }
}
