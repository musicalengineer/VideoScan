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
// LOGGING (GH #198, Rick 2026-09-26): every step is ONE sentence through
// ONE sink — `PersonRefreshNoteSink` — which writes the same line to
// videoscan.log (tagged `[fs-refresh]`), the in-app console and
// catalog.log. Each run leaves exactly one `started` line and exactly one
// outcome (`done:` / `refused:` / `failed:` / `cancelled`), every line
// carrying the person's name and FamilySearch ID. Each Apply and Undo also
// appends a before/after entry to person-refresh-journal.jsonl, and the
// applied/undone log lines are derived from that entry.

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
    private let sink: PersonRefreshNoteSink
    private let now: () -> Date
    private var watchTask: Task<Void, Never>?
    private var parseTask: Task<Void, Never>?
    /// Monotonic token: a parse that finishes after cancel()/a newer parse
    /// finds itself stale and publishes nothing.
    private var generation = 0
    private var launchDate: Date = .distantPast
    /// True once a `done:` / `refused:` / `failed:` line has gone out, so
    /// a Cancel after the outcome (closing a no-changes banner) does not
    /// log a second outcome.
    private var outcomeNoted = false

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
         sink: PersonRefreshNoteSink = .production(console: nil),
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
        self.sink = sink
        self.now = now
    }

    var isSettled: Bool {
        switch phase {
        case .idle, .applied, .refused, .failed: return true
        case .waiting, .parsing, .ready: return false
        }
    }

    // MARK: Logging

    /// "Refresh from FamilySearch: Ellen Ronan (G9P1-3PZ) — " + `line`.
    private var subject: String {
        PersonRefreshAuditLines.subject(person: target.personName, familySearchID: target.familySearchID)
    }

    private func note(_ line: String) { sink.note(subject + line) }

    /// An outcome line: at most one per run.
    private func noteOutcome(_ line: String) {
        outcomeNoted = true
        note(line)
    }

    // MARK: Launch

    /// Write the script into a fresh staging folder, open it in Terminal
    /// and start watching. Nothing runs until Return is pressed there.
    func launch() {
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
        // The attempt is on record BEFORE anything can refuse it: a run that
        // could not start still reads `started` … `failed: could not start`.
        note(PersonRefreshAuditLines.started(answerFile: Self.relative(output)))
        if ViewerWriteGuard.refuse("PersonRefresh.launch") {
            let message = "Refresh from FamilySearch runs on the master Mac, not on a viewer."
            phase = .failed(message: message)
            noteOutcome(PersonRefreshAuditLines.couldNotStart(message))
            return
        }
        do {
            guard let toolURL = locator.locate() else { throw FamilySearchPullError.toolNotFound }
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
            startWatching(output: output)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            phase = .failed(message: message)
            noteOutcome(PersonRefreshAuditLines.couldNotStart(message))
        }
    }

    /// Stop watching. The Terminal process is not ours to kill; the staging
    /// folder stays as the record of what was asked for.
    func cancel() {
        watchTask?.cancel(); watchTask = nil
        parseTask?.cancel(); parseTask = nil
        generation &+= 1
        quietSince = nil
        if !isSettled, !outcomeNoted {
            let stage: String
            var pending: [String]?
            switch phase {
            case .waiting: stage = "while waiting for Terminal"
            case .parsing: stage = "while reading the answer"
            case .ready(let diff):
                stage = "at review"
                pending = diff.changes.map(\.field.key)
            case .idle, .applied, .refused, .failed: stage = ""
            }
            noteOutcome(PersonRefreshAuditLines.cancelled(pendingFields: pending, stage: stage))
        }
        phase = .idle
    }

    /// `<FSID>-<stamp>/person.ged` — the answer file, relative to the root.
    private nonisolated static func relative(_ output: URL) -> String {
        output.deletingLastPathComponent().lastPathComponent + "/" + output.lastPathComponent
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
                        let message = "\(output.lastPathComponent) was removed before it finished. Nothing was changed."
                        self.phase = .failed(message: message)
                        self.noteOutcome(PersonRefreshAuditLines.failed(message))
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
            let message = "Stopped waiting for FamilySearch after an hour. Nothing was changed — try Refresh again."
            self.phase = .failed(message: message)
            self.noteOutcome(PersonRefreshAuditLines.failed(message))
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
            let waited = self.now().timeIntervalSince(self.startedAt ?? self.now())
            self.note(PersonRefreshAuditLines.received(people: people, after: waited, file: Self.relative(output)))
            switch result {
            case .failure(let refusal):
                self.phase = .refused(message: refusal.sentence)
                self.noteOutcome(PersonRefreshAuditLines.refused(refusal.sentence))
            case .success(let incoming):
                guard let installed = self.installedFacts() else {
                    let message = "\(self.target.personName) (\(requested)) is no longer in the loaded tree, so there is nothing to compare. Nothing was changed."
                    self.phase = .failed(message: message)
                    self.noteOutcome(PersonRefreshAuditLines.failed(message))
                    return
                }
                let diff = PersonRefreshDiff.compute(installed: installed, incoming: incoming)
                if diff.changes.isEmpty {
                    // Nothing to apply: this IS the outcome. The banner's
                    // Cancel afterwards is a dismissal, not a cancellation.
                    self.noteOutcome(PersonRefreshAuditLines.alreadyMatches(relationshipNotes: diff.relationshipNotes.count))
                } else {
                    self.note(PersonRefreshAuditLines.differences(
                        fields: diff.changes.map(\.field.key), relationshipNotes: diff.relationshipNotes.count))
                }
                self.phase = .ready(diff)
            }
        }
    }

    // MARK: Apply

    /// What one read-modify-write of the overlay came to. Sendable: it is
    /// built on a worker thread and read back on the main actor.
    enum OverlayWrite<T: Sendable>: Sendable {
        case written(T)
        /// Nothing to write (e.g. no refresh to undo).
        case nothingToDo
        /// overlay.json exists but cannot be read; nothing was written.
        /// `keptAs` is where it was set aside (nil when even that failed).
        case unreadable(reason: String, keptAs: String?, setAsideError: String?)
        case failed(String)
    }

    /// Load → mutate → fsync'd save, entirely OFF the main actor, and the
    /// unreadable-file refusal (reflection review F1/F5, 2026-09-21).
    ///
    /// Idiom: `Task.detached { … }.value` ≈ post a job to a worker thread
    /// and co_await its result — the main actor is free (UI keeps drawing)
    /// for the length of the full fsync. Only Sendable values cross: the
    /// store (a struct of a URL and a @Sendable closure), the mutation
    /// closure (@Sendable — it captures only value types) and the result.
    nonisolated static func writeOverlay<T: Sendable>(
        _ store: PersonFactOverlayStore, now: Date,
        _ mutate: @escaping @Sendable (inout PersonFactOverlay) -> T?) async -> OverlayWrite<T> {
        await Task.detached(priority: .userInitiated) { () -> OverlayWrite<T> in
            do {
                guard let result = try store.update(mutate) else { return .nothingToDo }
                return .written(result)
            } catch let unreadable as PersonFactOverlayStore.UnreadableOverlay {
                // Never saved over, never deleted: moved aside so the bytes
                // survive and the NEXT apply can start a fresh record.
                do {
                    let kept = try store.setAsideUnreadable(at: now)
                    return .unreadable(reason: unreadable.reason, keptAs: kept.lastPathComponent, setAsideError: nil)
                } catch {
                    return .unreadable(reason: unreadable.reason, keptAs: nil,
                                       setAsideError: error.localizedDescription)
                }
            } catch {
                return .failed(error.localizedDescription)
            }
        }.value
    }

    /// The honest strip sentence for an unreadable refresh record.
    nonisolated static func unreadableSentence(keptAs: String?) -> String {
        keptAs.map { "The refresh record can't be read, so nothing was changed — it's kept as \($0)." }
            ?? "The refresh record can't be read, so nothing was changed — it's left in place as \(PersonFactOverlayStore.fileName)."
    }

    /// True while an Apply's write is in flight — a second click is ignored.
    private(set) var isApplying = false

    /// Write the ticked facts to the overlay. Returns false (and says why
    /// in `phase`) when nothing could be written. Relationship notes are
    /// never in `changes`, so nothing selectable here can change a link.
    /// `async` because the fsync'd write runs off the main actor.
    @discardableResult
    func apply(selectedFieldKeys: Set<String>) async -> Bool {
        guard case .ready(let diff) = phase, !isApplying else { return false }
        if ViewerWriteGuard.refuse("PersonRefresh.apply") {
            let message = "This Mac is a viewer; the tree is refreshed on the master."
            phase = .failed(message: message)
            noteOutcome(PersonRefreshAuditLines.failed(message))
            return false
        }
        let chosen = diff.changes.filter { selectedFieldKeys.contains($0.field.key) }
        guard !chosen.isEmpty else {
            noteOutcome(PersonRefreshAuditLines.nothingTicked())
            phase = .applied(fields: 0)
            return true
        }
        isApplying = true
        defer { isApplying = false }
        let fsid = target.familySearchID, name = target.personName, at = now()
        let outcome = await Self.writeOverlay(overlayStore, now: at) { overlay -> Bool? in
            overlay.record(chosen, familySearchID: fsid, displayName: name, at: at)
            return true
        }
        switch outcome {
        case .written, .nothingToDo:
            break
        case .unreadable(let reason, let keptAs, let setAsideError):
            phase = .failed(message: Self.unreadableSentence(keptAs: keptAs))
            noteOutcome(PersonRefreshAuditLines.overlayUnreadable(
                action: "apply", reason: reason, keptAs: keptAs, setAsideError: setAsideError))
            return false
        case .failed(let message):
            phase = .failed(message: "Could not save the refreshed facts: \(message). Nothing was changed.")
            noteOutcome(PersonRefreshAuditLines.overlayWriteFailed(message))
            return false
        }
        let entry = PersonRefreshAudit.Entry(
            at: now(), action: .applied, familySearchID: fsid, person: name,
            changes: PersonRefreshAudit.applyChanges(chosen),
            source: stagingFolder.map { $0.lastPathComponent + "/" + PersonRefreshPaths.outputFileName },
            relationshipNotes: diff.relationshipNotes.count)
        // The journal entry is the record; the lines are its reading.
        // Lines first: if the journal cannot be written, the log still has
        // every before/after value.
        outcomeNoted = true
        for line in PersonRefreshAudit.lines(entry, overlayPath: overlayStore.fileURL.path) { sink.note(line) }
        do { try PersonRefreshAudit.append(entry, directory: journalDirectory) } catch {
            note(PersonRefreshAuditLines.journalNotWritten(error.localizedDescription))
        }
        phase = .applied(fields: chosen.count)
        return true
    }

    // MARK: Undo (static — no download involved)

    /// "Undo last refresh for this person": pop the newest overlay state
    /// for `familySearchID`. Returns the sentence to show. `async` because
    /// the fsync'd write runs off the main actor.
    @discardableResult
    static func undoLast(familySearchID: String, personName: String,
                         overlayStore: PersonFactOverlayStore, journalDirectory: URL,
                         sink: PersonRefreshNoteSink = .production(console: nil), now: Date = Date()) async -> String {
        let subject = PersonRefreshAuditLines.subject(person: personName, familySearchID: familySearchID)
        if ViewerWriteGuard.refuse("PersonRefresh.undo") {
            return "This Mac is a viewer; the tree is refreshed on the master."
        }
        typealias Popped = (undone: PersonFactOverlay.Entry, restored: PersonFactOverlay.Entry?)
        let outcome = await writeOverlay(overlayStore, now: now) { overlay -> Popped? in
            overlay.undoLast(familySearchID: familySearchID).map { (undone: $0.before, restored: $0.after) }
        }
        let undone: PersonFactOverlay.Entry, restored: PersonFactOverlay.Entry?
        switch outcome {
        case .written(let popped):
            (undone, restored) = (popped.undone, popped.restored)
        case .nothingToDo:
            return "There is no FamilySearch refresh to undo for \(personName)."
        case .unreadable(let reason, let keptAs, let setAsideError):
            sink.note(subject + PersonRefreshAuditLines.overlayUnreadable(
                action: "undo", reason: reason, keptAs: keptAs, setAsideError: setAsideError))
            return unreadableSentence(keptAs: keptAs)
        case .failed(let message):
            sink.note(subject + "undo failed: \(message); nothing was changed")
            return "Could not undo: \(message)"
        }
        let sentence = restored == nil
            ? "Undid the FamilySearch refresh for \(personName); the tree shows the pulled facts again."
            : "Undid the latest FamilySearch refresh for \(personName); the earlier one still applies."
        let entry = PersonRefreshAudit.Entry(
            at: now, action: .undone, familySearchID: undone.familySearchID, person: personName,
            changes: PersonRefreshAudit.undoChanges(undone: undone, restored: restored), source: nil)
        for line in PersonRefreshAudit.lines(
            entry, overlayPath: overlayStore.fileURL.path,
            tail: restored == nil ? "the tree shows the pulled facts again" : "the earlier refresh still applies") {
            sink.note(line)
        }
        do { try PersonRefreshAudit.append(entry, directory: journalDirectory) } catch {
            sink.note(subject + PersonRefreshAuditLines.journalNotWritten(error.localizedDescription))
        }
        return sentence
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
    /// The current refresh per FamilySearch ID, replayed from the journal
    /// (GH #198) and limited to people the overlay still carries — what
    /// the card and the inspector show. Rebuilt on launch and after every
    /// Apply / Undo; a card reads it with one dictionary lookup.
    @Published private(set) var summaries: [String: PersonRefreshSummary] = [:]
    /// The last Undo's sentence, shown in the banner until dismissed.
    @Published var notice: String?
    /// The in-app console + catalog.log destination (VideoScanModel.log →
    /// DashboardState.log). The app attaches it once at launch; nil under
    /// tests, so nothing reaches the real console from a test host.
    var console: ((String) -> Void)?

    let root: URL
    let overlayStore: PersonFactOverlayStore
    typealias CoordinatorFactory = @MainActor (PersonRefreshCoordinator.Target,
                                               @escaping @MainActor () -> PersonFacts?,
                                               PersonRefreshNoteSink) -> PersonRefreshCoordinator
    private let makeCoordinator: CoordinatorFactory
    private var phaseSubscription: AnyCancellable?

    init(root: URL = PersonRefreshPaths.defaultRoot,
         overlayStore: PersonFactOverlayStore? = nil,
         makeCoordinator: CoordinatorFactory? = nil) {
        self.root = root
        let store = overlayStore ?? PersonFactOverlayStore(directory: root, log: { appLog.write($0) })
        self.overlayStore = store
        self.makeCoordinator = makeCoordinator ?? { target, facts, sink in
            PersonRefreshCoordinator(target: target, root: root, overlayStore: store, installedFacts: facts, sink: sink)
        }
        reloadRefreshedIDs()
    }

    /// videoscan.log + whatever console is attached right now.
    var sink: PersonRefreshNoteSink { .production(console: console) }

    /// Start a refresh (one at a time: a new one replaces an unfinished one,
    /// which is cancelled and logged).
    @discardableResult
    func begin(target: PersonRefreshCoordinator.Target,
               installedFacts: @escaping @MainActor () -> PersonFacts?) -> PersonRefreshCoordinator {
        coordinator?.cancel()
        notice = nil
        let fresh = makeCoordinator(target, installedFacts, sink)
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

    func undoLast(familySearchID: String, personName: String) async -> String {
        let message = await PersonRefreshCoordinator.undoLast(
            familySearchID: familySearchID, personName: personName,
            overlayStore: overlayStore, journalDirectory: root, sink: sink)
        reloadRefreshedIDs()
        notice = message
        return message
    }

    func hasRefresh(for familySearchID: String?) -> Bool {
        guard let familySearchID else { return false }
        return refreshedFamilySearchIDs.contains(familySearchID.uppercased())
    }

    /// O(1) per card. Nil when the person has no current refresh, or when
    /// the journal could not be read (the log has said so).
    func summary(for familySearchID: String?) -> PersonRefreshSummary? {
        guard let familySearchID else { return nil }
        return summaries[familySearchID.uppercased()]
    }

    private func reloadRefreshedIDs() {
        let ids = Set(overlayStore.load().entries.keys)
        refreshedFamilySearchIDs = ids
        let replayed = PersonRefreshHistory.current(PersonRefreshAudit.entries(directory: root, log: { appLog.write($0) }))
        summaries = replayed.filter { ids.contains($0.key) }
    }
}
