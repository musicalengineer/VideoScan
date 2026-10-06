import Foundation
import Testing
@testable import VideoScan

// Split from HallieShellCLITests.swift (file-length limit); same suite, so
// the Harness and its serialization are shared. An extension of a
// @Suite struct ≈ adding members to a C++ class from another TU.
extension HallieShellCLITests {

    // MARK: - Profile store with non-person entries (regression 2026-10-06)
    //
    // e37f0a1d (family groups, 10/4) stores families at POI/Families/ —
    // `<uuid>.json` + photo, no profile.json. The read-only loader treated
    // every POI subfolder as a person, so that one folder made ALL profiles
    // "unavailable" and every age/aggregate question was declined.
    // Synthetic fixtures only — never the real App Support store.

    /// Write a synthetic POI store under `root/VideoScan/POI`.
    fileprivate func makeProfileStore(
        _ build: (URL) throws -> Void
    ) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hallie-poi-store-\(UUID().uuidString)",
                                    isDirectory: true)
        let poi = root.appendingPathComponent("VideoScan/POI", isDirectory: true)
        try FileManager.default.createDirectory(at: poi, withIntermediateDirectories: true)
        try build(poi)
        return root
    }

    fileprivate func writePerson(_ name: String, born: Date?, folder: String? = nil,
                             in poi: URL) throws {
        let dir = poi.appendingPathComponent(folder ?? name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let profile = POIProfile(name: name, referencePath: dir.path, birthdate: born)
        try JSONEncoder().encode(profile).write(to: dir.appendingPathComponent("profile.json"))
    }

    fileprivate func writeFamilyGroupFolder(in poi: URL) throws {
        let families = poi.appendingPathComponent("Families", isDirectory: true)
        try FileManager.default.createDirectory(at: families, withIntermediateDirectories: true)
        let id = UUID().uuidString
        try Data(#"{"name":"Synthetic Family","memberIDs":[]}"#.utf8)
            .write(to: families.appendingPathComponent("\(id).json"))
        try Data([0xFF, 0xD8, 0xFF]).write(to: families.appendingPathComponent("\(id)-photo.jpg"))
    }

    fileprivate var donnaBirth: Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        return utc.date(from: DateComponents(year: 1959, month: 6, day: 15, hour: 12))!
    }

    /// Repro: production loader + production shell against a store that
    /// holds the family-groups folder. Red before the fix ("People profiles
    /// are unavailable"), green after.
    @Test func familyGroupsFolderDoesNotMakeProfilesUnavailableForAgeQuestions() async throws {
        let root = try makeProfileStore { poi in
            try writePerson("Donna", born: donnaBirth, in: poi)
            try writeFamilyGroupFolder(in: poi)
            try Data("stray note".utf8).write(to: poi.appendingPathComponent("poi-m1.txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = HallieShellCLI.loadProfilesReadOnly(applicationSupportURL: root)
        guard case .loaded(let profiles) = loaded else {
            Issue.record("family-groups folder must not make People profiles unavailable: \(loaded)")
            return
        }
        #expect(profiles.map(\.name) == ["Donna"])

        let harness = Harness(translations: [.temporal(.init(
            subject: "Donna", operation: .age, reference: .explicitYear(2000)))])
        harness.profileLoadResult = loaded
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--diagnostics", "--once", "How old was Donna in 2000?",
        ])
        _ = await HallieShellCLI.run(
            options: options, output: { harness.output.append($0) },
            dependencies: harness.dependencies())

        #expect(!harness.output.contains { $0.contains("People profiles are unavailable") })
        #expect(harness.output.contains { $0.contains("40") })
    }

    /// Poisoned state (CLAUDE.md dimension 4): one corrupt profile, one
    /// person folder with no profile.json, the family-groups folder, an
    /// import staging copy and a stray file. The people still load; each
    /// bad PERSON folder is logged by path; non-person folders are silent.
    @Test func poisonedProfileStoreStillYieldsThePersonProfiles() throws {
        var corruptPath = ""
        var emptyPath = ""
        let root = try makeProfileStore { poi in
            try writePerson("Donna", born: donnaBirth, in: poi)
            try writePerson("Rick", born: nil, in: poi)
            let corrupt = poi.appendingPathComponent("Corrupt", isDirectory: true)
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            corruptPath = corrupt.appendingPathComponent("profile.json").path
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: corruptPath))
            let empty = poi.appendingPathComponent("NoProfile", isDirectory: true)
            try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            emptyPath = empty.appendingPathComponent("profile.json").path
            try writeFamilyGroupFolder(in: poi)
            // BundleImporter's left-behind staging copy: a second "Donna".
            try writePerson("Donna", born: donnaBirth,
                            folder: "Donna.import-\(UUID().uuidString)", in: poi)
            try Data("stray".utf8).write(to: poi.appendingPathComponent("poi-m1.txt"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        var logged: [String] = []
        let result = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: root, log: { logged.append($0) })
        guard case .loaded(let profiles) = result else {
            Issue.record("one bad profile must never make all profiles unavailable: \(result)")
            return
        }
        #expect(profiles.map(\.name) == ["Donna", "Rick"])
        #expect(logged.count == 2)
        #expect(logged.contains { $0.contains(corruptPath) && $0.contains("corrupt") })
        #expect(logged.contains { $0.contains(emptyPath) && $0.contains("unreadable") })
        #expect(!logged.contains { $0.contains("Families") || $0.contains(".import-") })
    }

    /// Absent really means absent: person folders exist but none can be
    /// read → `.unavailable`, and the caller's log line names the cause.
    @Test func allPersonProfilesBadStaysUnavailableAndLogNamesTheCause() throws {
        var corruptPath = ""
        let root = try makeProfileStore { poi in
            let corrupt = poi.appendingPathComponent("Corrupt", isDirectory: true)
            try FileManager.default.createDirectory(at: corrupt, withIntermediateDirectories: true)
            corruptPath = corrupt.appendingPathComponent("profile.json").path
            try Data("{ not json".utf8).write(to: URL(fileURLWithPath: corruptPath))
            try writeFamilyGroupFolder(in: poi)
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let result = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: root, log: { _ in })
        guard case .unavailable(.profileCorrupt(let path)) = result else {
            Issue.record("no readable person profile must stay unavailable: \(result)")
            return
        }
        #expect(path == corruptPath)

        var logged: [String] = []
        #expect(HallieShellCLI.profilesLoggingCause(result, log: { logged.append($0) }) == nil)
        #expect(logged == ["Hallie: People profiles unavailable — People profile is corrupt: \(corruptPath)"])

        // A store with only the family-groups folder has no people: an
        // honest empty list, not "unavailable".
        let familiesOnly = try makeProfileStore { try writeFamilyGroupFolder(in: $0) }
        defer { try? FileManager.default.removeItem(at: familiesOnly) }
        guard case .loaded(let none) = HallieShellCLI.loadProfilesReadOnly(
            applicationSupportURL: familiesOnly, log: { _ in }) else {
            Issue.record("family-groups-only store must load as empty")
            return
        }
        #expect(none.isEmpty)
    }
}
