// PersonOfTheDayHistory.swift (VideoScanCore)
// The small recent-picks list behind Person of the Day's rotation and its
// "same person all day" stability, and the store it lives in.
//
// WHERE: `~/Library/Application Support/VideoScan/family-tree/
// person-of-the-day.json` in the app — NOT UserDefaults (a test host shares
// the app's defaults domain; the settings-pollution class). The store is a
// protocol so tests and the test host inject an in-memory or scratch-file
// store and never touch the real one.
//
// SHAPE: { "version": 1, "entries": [ { "day": "2026-10-01", "personID":
// "@I12@" }, … ] }, newest day first, at most `historyLimit` (400) days —
// about 20 KB. Nothing else grows.
//
// POISON-PROOF (the isolation dimension): the file is a CACHE of past
// choices, never data. A file that is too big (> 256 KB), not JSON, the
// wrong shape, or full of nonsense loads as an EMPTY or cleaned history:
// malformed day keys and blank ids are dropped, a day listed twice keeps
// its first entry, the list is re-sorted and capped. Days in the FUTURE
// (a clock that went backwards) are kept but ignored by both rotation and
// stability (`entry(on:)` / `recentIDs` only look at today and earlier).
// The worst a poisoned file can do is forget the rotation for a while.

import Foundation

extension PersonOfTheDay {

    public struct History: Sendable, Equatable, Codable {
        public struct Entry: Sendable, Equatable, Codable {
            public let day: String
            public let personID: String

            public init(day: String, personID: String) {
                self.day = day
                self.personID = personID
            }
        }

        public static let currentVersion = 1

        public var version: Int
        /// Newest day first, one entry per day, capped.
        public private(set) var entries: [Entry]

        public init(entries: [Entry] = [], limit: Int = Options().historyLimit) {
            version = Self.currentVersion
            self.entries = Self.sanitize(entries, limit: limit)
        }

        public static let empty = History()

        /// Drop malformed rows, keep the first entry for a day, newest
        /// first, at most `limit`.
        static func sanitize(_ raw: [Entry], limit: Int) -> [Entry] {
            var seen = Set<Int>()
            var kept: [(ordinal: Int, entry: Entry)] = []
            kept.reserveCapacity(min(raw.count, limit))
            for e in raw {
                let id = e.personID.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !id.isEmpty, id.count <= 128, let day = Day(key: e.day),
                      seen.insert(day.ordinal).inserted else { continue }
                kept.append((day.ordinal, Entry(day: day.key, personID: id)))
            }
            kept.sort { $0.ordinal > $1.ordinal }
            return kept.prefix(max(1, limit)).map(\.entry)
        }

        /// The entry recorded for `day`, if any.
        public func entry(on day: Day) -> Entry? {
            let key = day.key
            return entries.first { $0.day == key }
        }

        /// People featured in the `n` days before `day` (today excluded,
        /// future days ignored).
        public func recentIDs(before day: Day, withinDays n: Int) -> Set<String> {
            guard n > 0 else { return [] }
            let today = day.ordinal
            var out = Set<String>()
            for e in entries {
                guard let d = Day(key: e.day) else { continue }
                let age = today - d.ordinal
                if age >= 1 && age <= n { out.insert(e.personID) }
            }
            return out
        }

        /// Record (or replace) the pick for `day`.
        public mutating func record(_ personID: String, on day: Day, limit: Int = Options().historyLimit) {
            var raw = entries.filter { $0.day != day.key }
            raw.insert(Entry(day: day.key, personID: personID), at: 0)
            entries = Self.sanitize(raw, limit: limit)
        }

        enum CodingKeys: String, CodingKey { case version, entries }

        /// One row that may fail to decode on its own — a bad row is
        /// dropped, the good rows around it survive (≈ a lossy parse).
        private struct LossyEntry: Decodable {
            let entry: Entry?
            init(from decoder: Decoder) throws { entry = try? Entry(from: decoder) }
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // `try?` flattens Optional<Optional<T>> to Optional<T> (Swift 5).
            let rows = try? c.decodeIfPresent([LossyEntry].self, forKey: .entries)
            version = (try? c.decodeIfPresent(Int.self, forKey: .version)) ?? Self.currentVersion
            entries = Self.sanitize((rows ?? []).compactMap(\.entry), limit: Options().historyLimit)
        }
    }
}

// MARK: - Stores

/// Where the history lives. A protocol so the app's test host and the
/// tests inject their own (≈ a C++ abstract base with two concrete stores).
public protocol PersonOfTheDayHistoryStore: Sendable {
    /// Never throws: an absent or damaged history is an empty one.
    func load() -> PersonOfTheDay.History
    func save(_ history: PersonOfTheDay.History) throws
}

/// The JSON file store (production: App Support, see the header).
public struct PersonOfTheDayFileStore: PersonOfTheDayHistoryStore {
    public static let fileName = "person-of-the-day.json"
    /// Anything bigger is not a file we wrote (400 entries ≈ 20 KB).
    public static let maximumBytes = 256 * 1024

    public let url: URL
    public let limit: Int

    public init(url: URL, limit: Int = PersonOfTheDay.Options().historyLimit) {
        self.url = url
        self.limit = limit
    }

    /// `<Application Support>/VideoScan/family-tree/person-of-the-day.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("family-tree", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    public func load() -> PersonOfTheDay.History {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: url.path),
              (attributes[.type] as? FileAttributeType) == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size <= Self.maximumBytes,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(PersonOfTheDay.History.self, from: data)
        else { return .empty }
        return PersonOfTheDay.History(entries: decoded.entries, limit: limit)
    }

    /// Atomic replace (temp file + rename); creates the directory.
    public func save(_ history: PersonOfTheDay.History) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(PersonOfTheDay.History(entries: history.entries, limit: limit))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// In-memory store for tests and the app's test host. `@unchecked
/// Sendable` with a lock ≈ a C++ class whose members are guarded by a mutex.
public final class PersonOfTheDayMemoryStore: PersonOfTheDayHistoryStore, @unchecked Sendable {
    private let lock = NSLock()
    private var history: PersonOfTheDay.History
    private var saves = 0

    public init(_ history: PersonOfTheDay.History = .empty) {
        self.history = history
    }

    /// How many saves landed — read under the same lock as the writes.
    public var saveCount: Int { lock.withLock { saves } }

    public func load() -> PersonOfTheDay.History { lock.withLock { history } }

    public func save(_ history: PersonOfTheDay.History) throws {
        lock.withLock {
            self.history = history
            saves += 1
        }
    }
}

// MARK: - The service (the API Hallie calls)

/// Today's pick with the clock and the store injected: load the history,
/// pick, record today's choice (once per day), save. The app's card and —
/// later — Hallie's opener both go through this, so they always agree.
public struct PersonOfTheDayService: Sendable {
    public let store: any PersonOfTheDayHistoryStore
    public let calendar: Calendar
    public let now: @Sendable () -> Date
    public let options: PersonOfTheDay.Options

    /// `calendar` defaults to `.autoupdatingCurrent` so a time-zone or
    /// locale change while the app runs moves "today" with it.
    public init(store: any PersonOfTheDayHistoryStore, calendar: Calendar = .autoupdatingCurrent,
                now: @escaping @Sendable () -> Date = { Date() },
                options: PersonOfTheDay.Options = PersonOfTheDay.Options()) {
        self.store = store
        self.calendar = calendar
        self.now = now
        self.options = options
    }

    public var today: PersonOfTheDay.Day { PersonOfTheDay.Day(date: now(), calendar: calendar) }

    /// Today's person (recorded so a relaunch shows the same one), or nil
    /// when nobody may be featured. A save failure is reported in `saved`
    /// and never loses the pick. `isCancelled` is polled before the pick
    /// and again before the save: a superseded computation records nothing
    /// and returns no pick (QA P3-3).
    public func todaysPick(from candidates: [PersonOfTheDay.Candidate],
                           isCancelled: () -> Bool = { false },
                           life: (PersonOfTheDay.Candidate) -> PersonOfTheDay.Life)
        -> (pick: PersonOfTheDay.Pick?, saved: Bool) {
        let day = today
        var history = store.load()
        if isCancelled() { return (nil, true) }
        guard let pick = PersonOfTheDay.pick(from: candidates, on: day, history: history,
                                             options: options, life: life) else { return (nil, true) }
        guard history.entry(on: day)?.personID != pick.personID else { return (pick, true) }
        if isCancelled() { return (nil, true) }
        history.record(pick.personID, on: day, limit: options.historyLimit)
        do { try store.save(history); return (pick, true) } catch { return (pick, false) }
    }

    /// Hallie's one-liner for today, or nil.
    public func opener(from candidates: [PersonOfTheDay.Candidate],
                       life: (PersonOfTheDay.Candidate) -> PersonOfTheDay.Life) -> String? {
        todaysPick(from: candidates, life: life).pick.map(PersonOfTheDay.opener(for:))
    }
}
