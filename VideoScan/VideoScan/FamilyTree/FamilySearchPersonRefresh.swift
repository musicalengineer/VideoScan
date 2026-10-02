// FamilySearchPersonRefresh.swift
// "Refresh from FamilySearch…" for ONE person — the pure value logic.
//
// Rick, 2026-09-21: "I have to edit FS then refresh so it helps me with the
// research to keep the FS and the app's FT in sync. We don't want to do a
// whole gedcom dump when we can just get the one." A full pull took 9.5 h
// (2026-08-25) and "last time was fraught"; this fetches one person in
// seconds and changes FACTS ONLY, through an overlay.
//
// THE SAME TERMINAL SEAM AS "Get Family Tree" (FamilySearchPull.swift):
// VideoScan writes a `.command` file, Terminal runs it, getmyancestors asks
// for the username AND the password itself. VideoScan never collects,
// stores, forwards or logs either (docs/research/familysearch_api_notes.md). This
// file does not even pass `-u`: the tool prompts for it.
//
// THE COMMAND (checked against getmyancestors 1.2.0's own source,
// getmyancestors.py `main()`):
//   -i <FSID>   start individual
//   -a 0        `for i in range(args.ascend)` — zero iterations: no parents
//   -d 0        same for descendants (the tool's default, stated explicitly)
//   -m          `tree.add_spouses(...)` + `Fam.add_marriage`: spouses as
//               INDI records and the couple's MARR facts. Marriage dates
//               only come through this flag, so it is on.
//   --no-sources --no-notes --no-memories
//               skip the per-person source/note/memory fetches: a refresh
//               applies facts only, and these are most of the requests.
//   -o <staging>/person.ged
// argparse opens `-o` for writing BEFORE the login prompt, so the file
// exists (empty) from the first second; `0 TRLR` is written last, in the
// tool's `finally:` — the coordinator waits for that trailer.
//
// STAGING, AND THE 2026-09-17 NARROWING: the loader once rebuilt the whole
// tree from a single visible .ged. A one-person .ged therefore lives ONLY
// in `family-tree/person-refresh/<FSID>-<stamp>/` — a sibling of
// `originals/` and `compiled/`, never inside the archive's GEDCOM folder,
// never a candidate for "newest valid .ged wins", never fed to a compile.
// PersonRefreshNarrowingSensorTests pins that.

import Foundation
import VideoScanCore

// MARK: - Paths

enum PersonRefreshPaths {
    /// App Support/VideoScan/family-tree/person-refresh — production.
    /// Under a test host: a per-process scratch folder, never the real one
    /// (the MediaLedger / POIProfileAudit discipline).
    nonisolated static var defaultRoot: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/person-refresh-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return productionRoot(applicationSupport: support)
    }

    /// `<App Support>/VideoScan/family-tree/person-refresh` — a sibling of
    /// `originals/` (the legacy GEDCOM folder), `assets/` (whose `GEDCOM/`
    /// is the no-archive GEDCOM folder) and `compiled/`. Pure, so the
    /// narrowing sensor can prove it is inside none of them.
    nonisolated static func productionRoot(applicationSupport support: URL) -> URL {
        support
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent("person-refresh", isDirectory: true)
    }

    nonisolated static var productionOverlayStore: PersonFactOverlayStore {
        PersonFactOverlayStore(directory: defaultRoot, log: { appLog.write($0) })
    }

    /// `<root>/<FSID>-<yyyyMMdd-HHmmss>/` — one folder per refresh, kept
    /// as the record of what FamilySearch said (a few KB each).
    nonisolated static func stagingFolder(root: URL, familySearchID: String, at date: Date) -> URL {
        root.appendingPathComponent("\(familySearchID)-\(stamp(date))", isDirectory: true)
    }

    nonisolated static let outputFileName = "person.ged"
    nonisolated static let scriptFileName = "refresh-person.command"
    nonisolated static let journalFileName = "person-refresh-journal.jsonl"

    nonisolated static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - Command

/// The validated one-person command line. Construction is the only way to
/// get arguments, so the forbidden-flag rule cannot be bypassed.
struct FamilySearchPersonRefreshCommand: Equatable {
    let toolURL: URL
    let familySearchID: String
    let outputURL: URL
    let arguments: [String]

    /// Deliberately gentle: one person is a handful of requests.
    static let rateLimit = 2
    static let concurrency = 2

    init(toolURL: URL, familySearchID raw: String, outputURL: URL) throws {
        let fsid = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard FamilySearchPullCommand.isPersonID(fsid) else {
            throw FamilySearchPullError.invalidPersonID(raw)
        }
        guard outputURL.pathExtension.lowercased() == "ged" else {
            throw FamilySearchPullError.outputNotGedcom(outputURL)
        }
        let arguments = [
            "-i", fsid,
            "-a", "0",
            "-d", "0",
            "-m",
            "--no-sources", "--no-notes", "--no-memories",
            "-v",
            "--rate-limit", String(Self.rateLimit),
            "--concurrency", String(Self.concurrency),
            "-o", outputURL.path,
        ]
        let offenders = arguments.filter { FamilySearchPullCommand.forbiddenArguments.contains($0) }
        guard offenders.isEmpty else {
            throw FamilySearchPullError.scriptWriteFailed("refusing to emit \(offenders.joined(separator: ", "))")
        }
        self.toolURL = toolURL
        self.familySearchID = fsid
        self.outputURL = outputURL
        self.arguments = arguments
    }

    var displayLine: String {
        ([toolURL.path] + arguments).map(FamilySearchPullCommand.quoted).joined(separator: " ")
    }
}

/// The `.command` file Terminal opens. Same shape as Get Family Tree's —
/// the pause before running is the verification step Rick asked for
/// ("we see it we verify it we type in the pw").
struct FamilySearchPersonRefreshScript {
    let command: FamilySearchPersonRefreshCommand
    let personName: String
    let scriptURL: URL

    var contents: String {
        let line = command.displayLine
        let title = "VideoScan — Refresh \(personName) (\(command.familySearchID)) from FamilySearch"
        return """
        #!/bin/zsh
        # Written by VideoScan — Refresh from FamilySearch (one person).
        # VideoScan does not know your FamilySearch username or password and
        # never will. getmyancestors asks for both below, on this terminal.

        set -u

        printf '\\n'
        printf '  %s\\n\\n' \(FamilySearchPullCommand.quoted(title))
        printf '  About to run:\\n\\n'
        printf '    %s\\n\\n' \(FamilySearchPullCommand.quoted(line))
        printf '  getmyancestors will ask for your FamilySearch username and password.\\n'
        printf '  Type them here — they are never sent to VideoScan, never stored,\\n'
        printf '  and never written to this file or your shell history.\\n\\n'
        printf '  Press Return to run, or Control-C to cancel: '
        read -r confirm
        printf '\\n'

        \(line)
        exit_status=$?

        printf '\\n'
        if [ $exit_status -eq 0 ]; then
          printf '  Done. Switch back to VideoScan to review what changed.\\n'
        else
          printf '  getmyancestors exited with status %s. Nothing was changed.\\n' "$exit_status"
        fi
        printf '  You can close this window.\\n\\n'
        """
    }

    @discardableResult
    func write(fileManager: FileManager = .default) throws -> URL {
        do {
            try fileManager.createDirectory(at: scriptURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            try contents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        } catch {
            throw FamilySearchPullError.scriptWriteFailed(error.localizedDescription)
        }
        return scriptURL
    }
}

// MARK: - Overlay at read time

/// The one function every tree read path calls to lay the overlay over a
/// loaded graph (FamilyGraphSharedCache in production; an injected Family
/// Tree model in tests). Superseded entries are retired first.
enum PersonRefreshOverlayReader {
    nonisolated static func apply(to graph: GedcomFamilyGraph, store: PersonFactOverlayStore?,
                                  discoveryDirectory: URL, canWrite: Bool,
                                  log: (String) -> Void) -> GedcomFamilyGraph {
        guard let store else { return graph }
        let overlay = store.effective(
            newestPullAt: PersonFactOverlayStore.newestPullDate(in: discoveryDirectory),
            canWrite: canWrite && !ViewerModeCenter.shared.isViewer)
        guard !overlay.entries.isEmpty else { return graph }
        let (overlaid, report) = graph.applyingFactOverlay(overlay)
        var line = "[fs-refresh] overlay applied: \(report.fieldsChanged) field(s) on \(report.peopleChanged) "
            + "of \(overlay.entries.count) refreshed people"
        if !report.missingFamilySearchIDs.isEmpty {
            line += "; not in this tree: \(report.missingFamilySearchIDs.joined(separator: ", "))"
        }
        if report.indexDropped { line += "; name/sex changed — search index rebuilt" }
        log(line)
        return overlaid
    }
}

extension FamilyGraphFileLoader.Outcome {
    /// The same outcome carrying a different graph (the overlaid one).
    func replacingGraph(_ graph: GedcomFamilyGraph) -> Self {
        FamilyGraphFileLoader.Outcome(graph: graph, selectedURL: selectedURL, rejectedURLs: rejectedURLs,
                                      candidateCount: candidateCount, compiled: compiled,
                                      needsRecompile: needsRecompile)
    }
}

// MARK: - Audit sink (GH #198)

/// THE one place a "Refresh from FamilySearch" line leaves from. Rick,
/// 2026-09-26, after the Ellen Ronan refresh: "I looked at the log and
/// don't see the expected 'Refresh Ellen Ronan … from …'. This kind of
/// change needs better logging if we were to go back and see what
/// happened." The five `[fs-refresh]` lines had gone to videoscan.log
/// only — never the in-app console he reads, never catalog.log.
///
/// The SAME sentence goes to every destination:
///   • `videoscanLog` → videoscan.log, prefixed `[fs-refresh]` (kept for
///     grep; the coordinator never writes the tag itself)
///   • `console`      → the in-app console + catalog.log (DashboardState
///     .log, reached through `PersonRefreshCenter.console`); nil under
///     tests and before the app has wired it
/// The journal (`PersonRefreshAudit.append`) is the third copy: the log
/// lines for an Apply / Undo are DERIVED from the journal entry
/// (`PersonRefreshAudit.lines`), so the two can never disagree.
///
/// `@MainActor` because every caller already is (the coordinator, the
/// center, the review sheet) and the console sink is main-actor state;
/// a C++ reader can think of it as "must be called on the UI thread".
@MainActor
struct PersonRefreshNoteSink {
    static let tag = "[fs-refresh]"

    let videoscanLog: (String) -> Void
    let console: ((String) -> Void)?

    init(videoscanLog: @escaping (String) -> Void, console: ((String) -> Void)? = nil) {
        self.videoscanLog = videoscanLog
        self.console = console
    }

    /// Production: `appLog` (videoscan.log) plus whatever console the app
    /// has attached to the center.
    static func production(console: ((String) -> Void)?) -> PersonRefreshNoteSink {
        PersonRefreshNoteSink(videoscanLog: { appLog.write($0) }, console: console)
    }

    func note(_ line: String) {
        videoscanLog("\(Self.tag) \(line)")
        console?(line)
    }
}

/// The wording, pure. Every line begins `Refresh from FamilySearch: <name>
/// (<FSID>) — ` so one grep for the name or the id finds the whole run,
/// and reads as plain English in the console. Outcomes are one of
/// `done:` / `refused:` / `failed:` / `cancelled` — a run leaves exactly
/// one of them (PersonRefreshAuditSensorTests pins it).
enum PersonRefreshAuditLines {
    static func subject(person: String, familySearchID: String) -> String {
        "Refresh from FamilySearch: \(person) (\(familySearchID)) — "
    }

    /// "22 s" / "3 min 5 s" / "1 h 2 min".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded()))
        if s < 60 { return "\(s) s" }
        if s < 3600 { return "\(s / 60) min \(s % 60) s" }
        return "\(s / 3600) h \((s % 3600) / 60) min"
    }

    /// `/Users/rick/Library/…` → `~/Library/…` for the done line.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    static func revertHint(person: String) -> String {
        "right-click \(person) in the Family Tree ▸ Undo last refresh for this person"
    }

    /// The first line of every run, written before anything can refuse it.
    static func started(answerFile: String) -> String {
        "started; the answer will land in \(answerFile)"
    }

    static func couldNotStart(_ reason: String) -> String {
        "failed: could not start — \(reason)"
    }

    static func received(people: Int, after seconds: TimeInterval, file: String) -> String {
        "received \(people) \(people == 1 ? "person" : "people") from FamilySearch in \(elapsed(seconds)) (\(file))"
    }

    static func differences(fields: [String], relationshipNotes: Int) -> String {
        "\(fields.count) \(plural(fields.count, "field")) differ: \(fields.joined(separator: ", ")); "
            + "\(relationshipNotes) relationship \(plural(relationshipNotes, "note")) — waiting for review"
    }

    static func alreadyMatches(relationshipNotes: Int) -> String {
        "done: already matches FamilySearch, nothing to apply; "
            + "\(relationshipNotes) relationship \(plural(relationshipNotes, "note")); nothing was changed"
    }

    static func nothingTicked() -> String {
        "done: 0 fields applied (nothing was ticked); nothing was changed"
    }

    static func refused(_ sentence: String) -> String { "refused: \(sentence)" }
    static func failed(_ reason: String) -> String { "failed: \(reason)" }

    static func cancelled(pendingFields: [String]?, stage: String) -> String {
        var line = "cancelled \(stage); nothing was changed"
        if let pendingFields, !pendingFields.isEmpty {
            line += " (pending review: \(pendingFields.joined(separator: ", ")))"
        }
        return line
    }

    static func overlayUnreadable(action: String, reason: String, keptAs: String?, setAsideError: String?) -> String {
        "\(action) failed: \(PersonFactOverlayStore.fileName) can't be read (\(reason)); nothing was changed; "
            + (keptAs.map { "the file is set aside as \($0)" }
               ?? "it could not be set aside (\(setAsideError ?? "unknown")) and is left in place")
    }

    static func overlayWriteFailed(_ message: String) -> String {
        "failed: could not save the refreshed facts — \(message); nothing was changed"
    }

    static func journalNotWritten(_ error: String) -> String {
        "note: the journal line was not written (\(error)); the lines above are the record"
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? word : word + "s" }

    static func quote(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return "'\(value)'"
    }

    /// `2026-09-26` — the date FamilySearch was asked, on every applied line.
    static func dateStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `26 Sep 2026` — the person card's "Refreshed on" line.
    static func cardDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "d MMM yyyy"
        return formatter.string(from: date)
    }
}

// MARK: - Audit journal

/// One JSON line per Apply / Undo, beside the overlay (append-only), plus
/// the app-log lines — the POIProfileAudit shape. Before AND after values,
/// so any change can be reversed by hand from the journal alone.
enum PersonRefreshAudit {
    enum Action: String, Codable, Sendable { case applied, undone }

    struct FieldChange: Codable, Equatable, Sendable {
        let field: String
        let before: String?
        let after: String?
    }

    struct Entry: Codable, Sendable {
        let at: Date
        let action: Action
        let familySearchID: String
        let person: String
        let changes: [FieldChange]
        /// The staging folder the facts came from (applies only).
        let source: String?
        /// Relationship differences FamilySearch showed that were NOT
        /// applied (applies only; nil in journals written before GH #198 —
        /// an optional `let` decodes a missing key as nil).
        var relationshipNotes: Int? = nil
    }

    /// The log lines for one journal entry — the journal is the source,
    /// the lines are its reading. An Apply: one `applied …` line per
    /// field, then the `done:` line with the overlay path and the way
    /// back. An Undo: one `undone:` line naming every restored field.
    static func lines(_ entry: Entry, overlayPath: String, tail: String? = nil) -> [String] {
        let subject = PersonRefreshAuditLines.subject(person: entry.person, familySearchID: entry.familySearchID)
        let q = PersonRefreshAuditLines.quote
        switch entry.action {
        case .applied:
            let stamp = PersonRefreshAuditLines.dateStamp(entry.at)
            let fields = entry.changes.map {
                subject + "applied \($0.field) \(q($0.before)) → \(q($0.after)) (from FamilySearch, \(stamp))"
            }
            let notes = entry.relationshipNotes ?? 0
            let done = subject + "done: \(entry.changes.count) \(PersonRefreshAuditLines.plural(entry.changes.count, "field")) changed, "
                + "\(notes) relationship \(PersonRefreshAuditLines.plural(notes, "note")). "
                + "Overlay: \(PersonRefreshAuditLines.abbreviated(overlayPath)). "
                + "Revert: \(PersonRefreshAuditLines.revertHint(person: entry.person))"
            return fields + [done]
        case .undone:
            let pairs = entry.changes.map { "\($0.field) \(q($0.before)) → \(q($0.after))" }
            var line = subject + "undone: \(entry.changes.count) \(PersonRefreshAuditLines.plural(entry.changes.count, "field")) restored"
            if !pairs.isEmpty { line += ": " + pairs.joined(separator: "; ") }
            if let tail { line += " — " + tail }
            return [line]
        }
    }

    /// An Apply: exactly the diff rows that were ticked — what the tree
    /// showed, what it shows now.
    static func applyChanges(_ changes: [PersonRefreshChange]) -> [FieldChange] {
        changes.map { FieldChange(field: $0.field.key, before: $0.old, after: $0.new) }
    }

    /// An Undo of `undone` (the entry as it stood) back to `restored` (the
    /// previous state, nil = entry removed). A field the previous state
    /// also had goes back to that value; a field it lacked goes back to
    /// what the tree showed before it was applied (`Fact.before`).
    static func undoChanges(undone: PersonFactOverlay.Entry, restored: PersonFactOverlay.Entry?) -> [FieldChange] {
        undone.facts.keys.sorted().compactMap { key in
            let now = undone.facts[key]!.value
            let back = restored?.facts[key].map { $0.value } ?? undone.facts[key]!.before
            return now == back ? nil : FieldChange(field: key, before: now, after: back)
        }
    }

    nonisolated static func append(_ entry: Entry, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MediaLedger.appendDurable(data, to: directory.appendingPathComponent(PersonRefreshPaths.journalFileName))
    }

    /// Every readable journal line, oldest first. A missing journal is
    /// simply empty; any other read failure, and every line that will not
    /// decode, is still skipped — but now counted and logged one line
    /// (reflection review F3, 2026-09-21), never silently dropped.
    nonisolated static func entries(directory: URL,
                                    log: (String) -> Void = { appLog.write($0) }) -> [Entry] {
        let url = directory.appendingPathComponent(PersonRefreshPaths.journalFileName)
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) { return [] }
            log("[fs-refresh] journal \(url.lastPathComponent) can't be read (\(error.localizedDescription)); showing no entries")
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var entries: [Entry] = []
        var dropped = 0
        var firstReason: String?
        for line in text.split(whereSeparator: \.isNewline) {
            do {
                entries.append(try decoder.decode(Entry.self, from: Data(line.utf8)))
            } catch {
                dropped += 1
                if firstReason == nil { firstReason = error.localizedDescription }
            }
        }
        if dropped > 0 {
            log("[fs-refresh] journal \(url.lastPathComponent): skipped \(dropped) unreadable line(s) of "
                + "\(dropped + entries.count) (first: \(firstReason ?? "unknown")); the file is left as it is")
        }
        return entries
    }
}

// MARK: - What the card shows (GH #198)

/// "Refreshed from FamilySearch on 26 Sep 2026 — 2 fields", with the
/// field diffs, for one person — read from the JOURNAL, never the log.
struct PersonRefreshSummary: Equatable, Sendable {
    let familySearchID: String
    let person: String
    let at: Date
    let changes: [PersonRefreshAudit.FieldChange]

    var headline: String {
        "Refreshed from FamilySearch on \(PersonRefreshAuditLines.cardDate(at)) — "
            + "\(changes.count) \(PersonRefreshAuditLines.plural(changes.count, "field"))"
    }

    /// One row per field: `birthDate: '1883' → '18 March 1882'`.
    var diffLines: [String] {
        changes.map { "\($0.field): \(PersonRefreshAuditLines.quote($0.before)) → \(PersonRefreshAuditLines.quote($0.after))" }
    }

    /// Headline plus diffs on their own lines — the card chip's tooltip.
    var tooltip: String { ([headline] + diffLines).joined(separator: "\n") }
}

/// The journal replayed: an Apply pushes, an Undo pops — the same stack
/// the overlay keeps (`PersonFactOverlay.undoLast`), so after "undo the
/// latest of two" the card shows the earlier refresh, not nothing.
enum PersonRefreshHistory {
    nonisolated static func current(_ entries: [PersonRefreshAudit.Entry]) -> [String: PersonRefreshSummary] {
        var stacks: [String: [PersonRefreshSummary]] = [:]
        for entry in entries {
            let fsid = entry.familySearchID.uppercased()
            switch entry.action {
            case .applied:
                stacks[fsid, default: []].append(PersonRefreshSummary(
                    familySearchID: fsid, person: entry.person, at: entry.at, changes: entry.changes))
            case .undone:
                _ = stacks[fsid]?.popLast()
            }
        }
        return stacks.compactMapValues(\.last)
    }
}
