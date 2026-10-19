// EventsFolderLog.swift
// One line per folder change, through the ONE sink (console, catalog.log,
// videoscan.log and the unified log — CLAUDE.md "Long operations"; Rick
// 2026-10-19):
//   Created folder Thanksgiving 1990 (event) with 3 files: a.mov, b.mov, c.mov
//   Added 2 files to folder Dad (person): a.mov, b.mov
//   Moved 2 files from folder Dad to folder Thanksgiving 1990: a.mov, b.mov
//   Removed 1 file from folder Dad: a.mov
//   Renamed folder Dad to Father (person), 3 files: …
//   Changed folder Dad's kind from event to person, 3 files: …
//   Deleted folder Dad (person), 3 files: … — the files are untouched
// catalog.log and videoscan.log list EVERY filename; the console stops at
// 20 and says "… and N more". (Rick asked for names in these lines; the
// older Events lines stay counts-only.)
//
// Pure words plus one main-actor sink. (For Rick: a formatter and a
// printf-to-three-places.)

import Foundation
import os

struct EventsFolderLogLine: Sendable, Equatable {
    /// "Created folder Dad (person) with 3 files" — everything before the list.
    let head: String
    let files: [String]
    /// After the list ("— the files are untouched"), may be empty.
    var tail = ""

    static let consoleCap = 20

    /// Every filename (catalog.log, videoscan.log).
    var full: String { compose(files) }

    /// At most `consoleCap` names, then "… and N more".
    var console: String {
        guard files.count > Self.consoleCap else { return full }
        return compose(Array(files.prefix(Self.consoleCap)), more: files.count - Self.consoleCap)
    }

    private func compose(_ names: [String], more: Int = 0) -> String {
        var line = head
        if !names.isEmpty { line += ": " + names.joined(separator: ", ") }
        if more > 0 { line += " … and \(more) more" }
        if !tail.isEmpty { line += " " + tail }
        return line
    }
}

enum EventsFolderLog {

    static func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }

    static func created(_ name: String, kind: FolderKind, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Created folder \(name) (\(kind.rawValue)) with \(files(names.count))", files: names)
    }

    static func added(to name: String, kind: FolderKind, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Added \(files(names.count)) to folder \(name) (\(kind.rawValue))", files: names)
    }

    static func moved(from source: String, to target: String, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Moved \(files(names.count)) from folder \(source) to folder \(target)", files: names)
    }

    static func removed(from name: String, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Removed \(files(names.count)) from folder \(name)", files: names,
                            tail: "— the files are untouched")
    }

    static func renamed(from old: String, to new: String, kind: FolderKind, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Renamed folder \(old) to \(new) (\(kind.rawValue)), \(files(names.count))", files: names)
    }

    static func kindChanged(_ name: String, from old: FolderKind, to new: FolderKind, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Changed folder \(name)'s kind from \(old.rawValue) to \(new.rawValue), \(files(names.count))",
                            files: names)
    }

    static func deleted(_ name: String, kind: FolderKind, files names: [String]) -> EventsFolderLogLine {
        EventsFolderLogLine(head: "Deleted folder \(name) (\(kind.rawValue)), \(files(names.count))", files: names,
                            tail: "— the label only; the files are untouched")
    }

    /// The filenames of the records whose content is in `keys`, by path
    /// (copies included — every file Rick sees in the folder). O(records):
    /// an event handler's one pass, never a view body.
    static func filenames(of keys: Set<String>, in records: [VideoRecord]) -> [String] {
        guard !keys.isEmpty else { return [] }
        return records.filter { r in EventsFolderMembers.contentKey(r).map(keys.contains) ?? false }
            .sorted { $0.fullPath < $1.fullPath }
            .map(\.filename)
    }

    /// Records → their filenames, by path.
    static func filenames(_ records: [VideoRecord]) -> [String] {
        records.sorted { $0.fullPath < $1.fullPath }.map(\.filename)
    }

    /// The one sink: the console gets the capped line, catalog.log and
    /// videoscan.log the whole one.
    @MainActor
    static func say(_ line: EventsFolderLogLine, model: VideoScanModel) {
        model.dashboard.log(console: "Folders: " + line.console, catalogLog: "Folders: " + line.full)
        appLog.write("[folders] " + line.full)
        foldersLog.notice("\(line.full, privacy: .public)")
    }
}

private let foldersLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "folders")
