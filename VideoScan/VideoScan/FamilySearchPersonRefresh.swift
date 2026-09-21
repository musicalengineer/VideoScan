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
// stores, forwards or logs either (docs/familysearch_api_notes.md). This
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

// MARK: - Audit journal

/// One JSON line per Apply / Undo, beside the overlay (append-only), plus
/// one app-log line — the POIProfileAudit shape. Before AND after values,
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

    static func line(_ entry: Entry) -> String {
        let fields = entry.changes.map { "\($0.field) \(quote($0.before)) → \(quote($0.after))" }
        return "[fs-refresh] \(entry.action == .applied ? "applied" : "undid") \(entry.changes.count) field(s) for "
            + "\(entry.person) (\(entry.familySearchID))"
            + (fields.isEmpty ? "" : ": " + fields.joined(separator: "; "))
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

    nonisolated static func entries(directory: URL) -> [Entry] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(PersonRefreshPaths.journalFileName),
                                     encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    private static func quote(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        return "'\(value)'"
    }
}
