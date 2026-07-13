// BundleImportFieldMergeTests.swift
// Regression + logic tests for the 2026-07-10 bundle-import data-loss bug:
// POI birthdates (dan, donna, rick) exported from the M4 silently did not
// land on import. Root cause: `decideWinner` resolves POI conflicts by
// reference-photo count with an mtime tiebreak — it is structurally blind
// to profile.json-only edits (birthdate/deathdate/notes/…). A birthdate
// edit changes no photos, so counts tie; the local folder mtime was newer,
// so the whole bundle folder was skipped and the birthdate lost. The same
// blindness exists in the preferBundle direction (local-only fields
// clobbered).
//
// Fix under test: after the folder-level winner is decided/installed,
// `BundleImporter.mergeIdentityFields` (pure, mirrors decideWinner's
// testability) fills nil/empty identity fields on the winner from the
// loser. Winner's value is kept when both sides are set and differ.
//
// ISOLATION (settings-pollution class): everything here runs in per-test
// temp dirs — `installPOIs` is driven with explicit storeDir/trashDir
// overrides so the real POI store (~/Library/Application Support/VideoScan/
// POI) and the repo .trash/ are never touched. No UserDefaults access.

import Testing
import Foundation
@testable import VideoScan

struct BundleImportFieldMergeTests {

    // MARK: - Fixture helpers

    private func date(_ y: Int, _ m: Int = 6, _ d: Int = 15) -> Date {
        var dc = DateComponents()
        dc.year = y; dc.month = m; dc.day = d; dc.hour = 12
        dc.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: dc) ?? .distantPast
    }

    /// Fresh scratch dir under the system temp root — never App Support.
    private func makeTempDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_import_merge_\(label)_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Write a POI folder (profile.json + N non-empty jpg reference photos)
    /// under `root`. Uses plain JSONEncoder — the store's Double-timestamp
    /// date encoding, deliberately NOT iso8601.
    @discardableResult
    private func writePOI(under root: URL, profile: POIProfile,
                          photoCount: Int) throws -> URL {
        let dir = root.appendingPathComponent(POIStorage.sanitize(profile.name),
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder().encode(profile)
            .write(to: dir.appendingPathComponent("profile.json"))
        for i in 0..<photoCount {
            try Data("not-really-a-photo-\(i)".utf8)
                .write(to: dir.appendingPathComponent("ref_\(i).jpg"))
        }
        return dir
    }

    /// Force every file under `dir` (and the dir itself) to a given mtime so
    /// effectiveMTime(of:) — max mtime over the subtree — is deterministic.
    private func setMTimes(under dir: URL, to when: Date) throws {
        let fm = FileManager.default
        var paths = [dir.path]
        if let it = fm.enumerator(at: dir, includingPropertiesForKeys: nil) {
            for case let url as URL in it { paths.append(url.path) }
        }
        for p in paths {
            try fm.setAttributes([.modificationDate: when], ofItemAtPath: p)
        }
    }

    private func loadProfile(at dir: URL) throws -> POIProfile {
        try JSONDecoder().decode(
            POIProfile.self,
            from: Data(contentsOf: dir.appendingPathComponent("profile.json")))
    }

    /// One-call scenario harness: local POI in a temp store, same-named POI
    /// in a temp bundle people/ dir, bundle mtimes forced into the past
    /// (local is "newer" unless the test overrides).
    private struct Scenario {
        var store: URL
        var trash: URL
        var people: URL
        var localDir: URL
        var bundleDir: URL
        func cleanup() {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: trash)
            try? FileManager.default.removeItem(at: people)
        }
    }

    private func makeScenario(local: POIProfile, localPhotos: Int,
                              bundle: POIProfile, bundlePhotos: Int,
                              bundleMtime: Date) throws -> Scenario {
        let store = try makeTempDir("store")
        let trash = try makeTempDir("trash")
        let people = try makeTempDir("people")
        let localDir = try writePOI(under: store, profile: local, photoCount: localPhotos)
        let bundleDir = try writePOI(under: people, profile: bundle, photoCount: bundlePhotos)
        try setMTimes(under: bundleDir, to: bundleMtime)
        return Scenario(store: store, trash: trash, people: people,
                        localDir: localDir, bundleDir: bundleDir)
    }

    // MARK: - Pure merge function (logic dimension)

    @Test func pureMergeFillsEveryNilIdentityFieldFromLoser() {
        let winner = POIProfile(name: "Donna", referencePath: "/w")
        let loser = POIProfile(
            name: "Donna", referencePath: "/l",
            notes: "married Rick in 1982", aliases: ["Goldilocks"],
            birthdate: date(1959), deathdate: date(2200),
            sex: .female, hairColor: .blonde, eyeColor: .blue,
            identityNotes: "long golden hair, big smile"
        )

        let (merged, filled) = BundleImporter.mergeIdentityFields(winner: winner,
                                                                  loser: loser)

        #expect(merged.birthdate == date(1959))
        #expect(merged.deathdate == date(2200))
        #expect(merged.sex == .female)
        #expect(merged.hairColor == .blonde)
        #expect(merged.eyeColor == .blue)
        #expect(merged.identityNotes == "long golden hair, big smile")
        #expect(merged.notes == "married Rick in 1982")
        #expect(merged.aliases == ["Goldilocks"])
        #expect(Set(filled) == Set(["birthdate", "deathdate", "sex", "hairColor",
                                    "eyeColor", "identityNotes", "notes", "aliases"]))
        // Non-identity fields stay the winner's.
        #expect(merged.referencePath == "/w")
    }

    @Test func pureMergeKeepsWinnerValueWhenBothSidesDiffer() {
        var winner = POIProfile(name: "Dan", referencePath: "/w",
                                notes: "winner notes",
                                birthdate: date(1984))
        winner.aliases = ["Danny"]
        let loser = POIProfile(name: "Dan", referencePath: "/l",
                               notes: "loser notes", aliases: ["Daniel"],
                               birthdate: date(1985))

        let (merged, filled) = BundleImporter.mergeIdentityFields(winner: winner,
                                                                  loser: loser)

        #expect(merged.birthdate == date(1984), "winner's birthdate must be kept")
        #expect(merged.notes == "winner notes")
        #expect(merged.aliases == ["Danny"])
        #expect(filled.isEmpty, "a conflict is not a fill — nothing should be reported merged")
        #expect(merged == winner)
    }

    @Test func pureMergeIsNoOpWhenLoserHasNothingToOffer() {
        let winner = POIProfile(name: "Rick", referencePath: "/w",
                                birthdate: date(1961), sex: .male)
        let loser = POIProfile(name: "Rick", referencePath: "/l")

        let (merged, filled) = BundleImporter.mergeIdentityFields(winner: winner,
                                                                  loser: loser)
        #expect(merged == winner)
        #expect(filled.isEmpty)
    }

    // MARK: - (a) Poisoned case: local newer but field-poorer (the real bug)

    @Test func localNewerEqualPhotos_bundleBirthdateStillLands() async throws {
        // Equal photo counts + local mtime newer ⇒ decideWinner skips the
        // bundle folder. Before the fix, the bundle's birthdate died here.
        let sc = try makeScenario(
            local: POIProfile(name: "dan", referencePath: "/local"), localPhotos: 2,
            bundle: POIProfile(name: "dan", referencePath: "/bundle",
                               birthdate: date(1984)), bundlePhotos: 2,
            bundleMtime: Date(timeIntervalSinceNow: -86_400))
        defer { sc.cleanup() }

        // Pin the precondition: folder-level policy really does prefer local.
        let decision = BundleImporter.decideWinner(
            bundleRefCount: 2, localRefCount: 2,
            bundleMtime: Date(timeIntervalSinceNow: -86_400), localMtime: Date(),
            localExists: true)
        guard case .preferLocal = decision else {
            Issue.record("precondition broken: expected preferLocal, got \(decision)")
            return
        }

        let result = await BundleImporter.installPOIs(
            from: [sc.bundleDir],
            bundleExportedAt: Date(timeIntervalSinceNow: -86_400),
            storeDir: sc.store, trashDir: sc.trash)

        #expect(result.skipped.map { $0.name } == ["dan"],
                "folder-level skip is still correct — only the FIELD must merge")
        #expect(result.installed.isEmpty)

        let after = try loadProfile(at: sc.localDir)
        #expect(after.birthdate == date(1984),
                "bundle birthdate must land on the skipped local profile")
        #expect(result.fieldMerged.count == 1)
        #expect(result.fieldMerged.first?.name == "dan")
        #expect(result.fieldMerged.first?.fields == ["birthdate"])
    }

    // MARK: - (b) Reverse direction: preferBundle must not clobber local-only fields

    @Test func bundleWinsInstall_localOnlyFieldsSurvive() async throws {
        // Bundle has MORE photos ⇒ preferBundle replaces the folder. The
        // local profile carried notes + sex the bundle lacks — they survive.
        let sc = try makeScenario(
            local: POIProfile(name: "donna", referencePath: "/local",
                              notes: "maiden name Smith",
                              sex: .female), localPhotos: 1,
            bundle: POIProfile(name: "donna", referencePath: "/bundle",
                               birthdate: date(1959)), bundlePhotos: 3,
            bundleMtime: Date(timeIntervalSinceNow: -86_400))
        defer { sc.cleanup() }

        let result = await BundleImporter.installPOIs(
            from: [sc.bundleDir],
            bundleExportedAt: Date(timeIntervalSinceNow: -86_400),
            storeDir: sc.store, trashDir: sc.trash)

        #expect(result.installed == ["donna"])
        let after = try loadProfile(at: sc.localDir)
        #expect(after.birthdate == date(1959), "bundle's own field is there")
        #expect(after.notes == "maiden name Smith", "local-only notes must survive the folder swap")
        #expect(after.sex == .female, "local-only sex must survive the folder swap")
        #expect(result.fieldMerged.first?.name == "donna")
        #expect(Set(result.fieldMerged.first?.fields ?? []) == Set(["notes", "sex"]))

        // Isolation: the displaced local folder went to OUR trash, not the repo's.
        let trashed = (try? FileManager.default.contentsOfDirectory(atPath: sc.trash.path)) ?? []
        #expect(trashed.contains { $0.hasPrefix("POI-donna-") })
    }

    // MARK: - (c) Negative: both sides set and different ⇒ winner kept, no silent overwrite

    @Test func conflictingBirthdates_winnerValueKept_noMergeReported() async throws {
        let sc = try makeScenario(
            local: POIProfile(name: "dan", referencePath: "/local",
                              birthdate: date(1984)), localPhotos: 2,
            bundle: POIProfile(name: "dan", referencePath: "/bundle",
                               birthdate: date(1990)), bundlePhotos: 2,
            bundleMtime: Date(timeIntervalSinceNow: -86_400))
        defer { sc.cleanup() }

        let result = await BundleImporter.installPOIs(
            from: [sc.bundleDir],
            bundleExportedAt: Date(timeIntervalSinceNow: -86_400),
            storeDir: sc.store, trashDir: sc.trash)

        let after = try loadProfile(at: sc.localDir)
        #expect(after.birthdate == date(1984),
                "winning (local) birthdate must not be silently overwritten")
        #expect(result.fieldMerged.isEmpty, "a kept conflict is not a merge")
        #expect(result.skipped.count == 1)
    }

    // MARK: - (d) Regression sensor: the 2026-07-10 M4 export, both directions

    /// Pins the whole install+merge behavior at incident shape: three POIs
    /// whose bundle side carries birthdates the local side lacks (equal
    /// photos, local mtimes newer — exactly the skip path that lost data on
    /// 2026-07-10), plus one POI going the other way (bundle folder wins,
    /// local-only field must survive). If this ever goes red, the importer
    /// is losing profile-only edits again.
    @Test func regressionSensor_m4BundleImport_profileEditsSurviveBothDirections() async throws {
        let store = try makeTempDir("store")
        let trash = try makeTempDir("trash")
        let people = try makeTempDir("people")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: trash)
            try? FileManager.default.removeItem(at: people)
        }
        let past = Date(timeIntervalSinceNow: -86_400)

        // The three incident POIs: birthdate only in the bundle.
        let births = ["dan": date(1984), "donna": date(1959), "rick": date(1961)]
        var bundleDirs: [URL] = []
        var localDirs: [String: URL] = [:]
        for (name, birth) in births {
            localDirs[name] = try writePOI(
                under: store,
                profile: POIProfile(name: name, referencePath: "/local/\(name)"),
                photoCount: 2)
            let b = try writePOI(
                under: people,
                profile: POIProfile(name: name, referencePath: "/bundle/\(name)",
                                    birthdate: birth),
                photoCount: 2)
            bundleDirs.append(b)
        }
        // Plus one preferBundle-direction POI: local-only identityNotes.
        localDirs["matt"] = try writePOI(
            under: store,
            profile: POIProfile(name: "matt", referencePath: "/local/matt",
                                identityNotes: "wore glasses since 1998"),
            photoCount: 1)
        bundleDirs.append(try writePOI(
            under: people,
            profile: POIProfile(name: "matt", referencePath: "/bundle/matt",
                                birthdate: date(1988)),
            photoCount: 4))
        for d in bundleDirs { try setMTimes(under: d, to: past) }

        let result = await BundleImporter.installPOIs(
            from: bundleDirs, bundleExportedAt: past,
            storeDir: store, trashDir: trash)

        // Folder-level outcomes unchanged from the shipping policy.
        #expect(Set(result.skipped.map { $0.name }) == Set(births.keys))
        #expect(result.installed == ["matt"])
        #expect(result.failed.isEmpty)

        // The incident assertion: every bundle birthdate landed locally.
        for (name, birth) in births {
            let p = try loadProfile(at: localDirs[name]!)
            #expect(p.birthdate == birth, "\(name)'s birthdate must never be lost again")
        }
        // And the mirror direction: matt's local-only note survived.
        let matt = try loadProfile(at: localDirs["matt"]!)
        #expect(matt.birthdate == date(1988))
        #expect(matt.identityNotes == "wore glasses since 1998")

        // Four merge reports, and the audit trail mentions each one.
        #expect(result.fieldMerged.count == 4)
        let mergeAudit = result.auditLines.filter { $0.contains("filled missing detail") }
        #expect(mergeAudit.count == 4)
    }
}
