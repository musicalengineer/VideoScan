// EventsFolderInspector.swift
// Selecting a folder fills the inspector pane (Rick 2026-10-19: "never
// empty"): its name and kind, when it was made and last changed, how many
// files, how long, how big, the dates its contents span, which volumes
// they are on and how many are online now.
//
// Pure: the facts are computed ONCE per selection (and per folder or
// catalog revision) in an event handler, from one small value per member
// file, and the view only reads them — no O(records) work in a body.
//
// Counting rules (the folder row's own, FootageFolders.folder):
//   files       every member file shown in the folder — copies included;
//   recordings  distinct contents (a copy is the same recording);
//   duration    once per recording (a copy adds no running time);
//   size        every file (bytes on disk);
//   dates       the earliest and latest dated file;
//   volumes     the distinct volume names, sorted;
//   online      member files whose volume is mounted now.
//
// Memory: the facts are a few strings; the input is one ~100 B value per
// member file, dropped after the pass.

import Foundation

struct FolderInspectorFacts: Sendable, Equatable {

    /// One member file as the facts read it.
    struct Member: Sendable, Equatable {
        var contentKey: String
        var sizeBytes: Int64
        var durationSeconds: Double
        /// nil = undated.
        var date: Date?
        var volume: String
        var isOnline: Bool
    }

    let id: UUID
    let name: String
    let kind: FolderKind
    let createdAt: Date
    let updatedAt: Date
    let files: Int
    let recordings: Int
    let totalSeconds: Double
    let totalBytes: Int64
    let earliest: Date?
    let latest: Date?
    let volumes: [String]
    let online: Int

    init(event: EventRecord, title: String, members: [Member]) {
        id = event.id
        name = title
        kind = event.kind
        createdAt = event.createdAt
        updatedAt = event.updatedAt
        var seconds: [String: Double] = [:]
        var bytes: Int64 = 0
        var first: Date?
        var last: Date?
        var volumeSet = Set<String>()
        var onlineCount = 0
        for m in members {
            seconds[m.contentKey] = max(seconds[m.contentKey] ?? 0, m.durationSeconds)
            bytes += m.sizeBytes
            if let d = m.date {
                first = min(first ?? d, d)
                last = max(last ?? d, d)
            }
            if !m.volume.isEmpty { volumeSet.insert(m.volume) }
            if m.isOnline { onlineCount += 1 }
        }
        files = members.count
        recordings = seconds.count
        totalSeconds = seconds.values.reduce(0, +)
        totalBytes = bytes
        earliest = first
        latest = last
        volumes = volumeSet.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        online = onlineCount
    }

    // MARK: Words (the inspector's rows)

    var filesWords: String {
        "\(files) file\(files == 1 ? "" : "s") · \(recordings) recording\(recordings == 1 ? "" : "s")"
    }

    var onlineWords: String {
        files == 0 ? "—" : (online == files ? "all \(files) online" : "\(online) of \(files) online")
    }

    var volumesWords: String { volumes.isEmpty ? "—" : volumes.joined(separator: ", ") }

    /// "Nov 26, 2009 – Nov 28, 2009", one day alone, "undated".
    var dateRangeWords: String {
        guard let earliest else { return "undated" }
        return FootageFolderWords.dateRange(earliest, latest ?? earliest)
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}
