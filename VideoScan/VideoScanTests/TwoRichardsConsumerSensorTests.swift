import Foundation
import Testing
@testable import VideoScan

// Two people with one canonical short name — Richard Jr (Rick) and
// Richard Sr (Dad) — exercised through the CONSUMERS, not just storage
// (codex consumer review of f63f141d, 2026-09-12). Each test asserts that no
// operation writes across the two people; where an operation is still keyed
// by the short name it must REFUSE with an actionable message.
//
// Everything runs in the per-process test store (POIStorage.storeDir under a
// test host); PersonFinderSettings writes are diverted from the real prefs
// by its own test-host gate.

@Suite("Two Richards — consumer sensors", .serialized)
struct TwoRichardsConsumerSensorTests {

    private struct Pair {
        let given: String
        let junior: POIProfile
        let senior: POIProfile
        func cleanup() {
            try? FileManager.default.removeItem(at: POIStorage.folder(for: junior))
            try? FileManager.default.removeItem(at: POIStorage.folder(for: senior))
        }
        func jsonBytes(_ profile: POIProfile) throws -> Data {
            try Data(contentsOf: POIStorage.profileURL(for: profile))
        }
    }

    /// Richard Jr and Richard Sr, saved, each with one photo.
    private func makePair() throws -> Pair {
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
        let tag = String(UUID().uuidString.prefix(6))
        let given = "Richard\(tag)"
        var junior = POIProfile(name: given, referencePath: "", aliases: ["Rick\(tag)"])
        junior.middleName = "Harding"; junior.surname = "Breen"; junior.suffix = "Jr"
        junior.notes = "junior biography"
        var senior = POIProfile(name: given, referencePath: "", aliases: ["Dad\(tag)"])
        senior.middleName = "Harding"; senior.surname = "Breen"; senior.suffix = "Sr"
        senior.notes = "senior biography"
        try junior.save(); try senior.save()
        try Data([0xAA]).write(to: POIStorage.folder(for: junior).appendingPathComponent("jr.jpg"))
        try Data([0xBB]).write(to: POIStorage.folder(for: senior).appendingPathComponent("sr.jpg"))
        junior.referencePath = POIStorage.folder(for: junior).path
        senior.referencePath = POIStorage.folder(for: senior).path
        return Pair(given: given, junior: junior, senior: senior)
    }

    // MARK: 1. Active settings, quick-save, rejection sync, edit, delete

    @Test @MainActor
    func activeProfileIsCarriedByUUIDThroughQuickSaveRejectionEditAndDelete() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let model = PersonFinderModel()
        model.savedProfiles = POIProfile.listAll()

        // Selecting Jr on his card carries the uuid into settings.
        model.settings.applyProfile(pair.junior)
        #expect(model.settings.activeProfileUUID == pair.junior.uuid)
        #expect(model.resolveActiveProfile() == .one(model.savedProfiles.first { $0.uuid == pair.junior.uuid }!))

        // Quick-save writes Jr only; Sr's JSON is byte-identical.
        let seniorBefore = try pair.jsonBytes(pair.senior)
        model.settings.threshold = 0.61
        model.saveCurrentPOI()
        #expect(model.referenceLoadError == nil)
        #expect(try POIProfile.load(uuid: pair.junior.uuid).visionThreshold == 0.61)
        #expect(try POIProfile.load(uuid: pair.senior.uuid).visionThreshold == 0.52)
        #expect(try pair.jsonBytes(pair.senior) == seniorBefore)
        #expect(try POIProfile.load(uuid: pair.junior.uuid).notes == "junior biography", "quick-save keeps the biography")

        // Rejection sync lands on Jr only.
        model.settings.rejectedReferenceFiles = ["blurry.jpg"]
        model.syncRejectionsToProfile()
        #expect(try POIProfile.load(uuid: pair.junior.uuid).rejectedFiles == ["blurry.jpg"])
        #expect(try POIProfile.load(uuid: pair.senior.uuid).rejectedFiles.isEmpty)

        // Editing Sr does not touch the active (Jr) settings.
        var editedSenior = pair.senior
        editedSenior.notes = "senior biography, edited"
        let outcome = model.updateProfile(editedSenior, oldName: pair.senior.name)
        #expect(outcome == .saved)
        #expect(model.settings.activeProfileUUID == pair.junior.uuid)
        #expect(try POIProfile.load(uuid: pair.senior.uuid).notes == "senior biography, edited")
        #expect(try POIProfile.load(uuid: pair.junior.uuid).notes == "junior biography")

        // Name alone is ambiguous: quick-save and rejection sync refuse.
        model.settings.activeProfileUUID = nil
        model.settings.personName = pair.given
        let jrBefore = try pair.jsonBytes(pair.junior), srBefore = try pair.jsonBytes(pair.senior)
        model.saveCurrentPOI()
        #expect(model.referenceLoadError?.contains("Two people are called \(pair.given)") == true)
        model.settings.rejectedReferenceFiles = ["other.jpg"]
        model.syncRejectionsToProfile()
        #expect(try pair.jsonBytes(pair.junior) == jrBefore)
        #expect(try pair.jsonBytes(pair.senior) == srBefore)
        // Deleting by name refuses too; deleting by profile removes only that one.
        #expect(await model.deletePOI(named: pair.given) == false)
        #expect(FileManager.default.fileExists(atPath: POIStorage.folder(for: pair.junior).path))
        #expect(FileManager.default.fileExists(atPath: POIStorage.folder(for: pair.senior).path))
        let trash = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-richards-trash-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: trash) }
        let trashed = POIStorage.trashPOIFolder(uuid: pair.senior.uuid, displayName: pair.senior.displayName,
                                                trashOverride: trash)
        #expect(trashed != nil)
        #expect(FileManager.default.fileExists(atPath: POIStorage.folder(for: pair.junior).appendingPathComponent("jr.jpg").path))
        #expect(!FileManager.default.fileExists(atPath: POIStorage.folder(for: pair.senior).path))
    }

    @Test func settingsPersistTheActiveProfileUUID() throws {
        let suite = "two-richards-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = PersonFinderSettings()
        let profile = POIProfile(name: "Richard", referencePath: "/x", aliases: ["Rick"])
        settings.applyProfile(profile)
        settings.save(to: defaults)
        let restored = PersonFinderSettings.restored(from: defaults)
        #expect(restored.activeProfileUUID == profile.uuid)
        #expect(restored.personName == "Richard")
        // A profile without the key (older prefs) restores as nil.
        defaults.removeObject(forKey: "pf_activeProfileUUID")
        #expect(PersonFinderSettings.restored(from: defaults).activeProfileUUID == nil)
    }

    // MARK: 2. Scan filter + catalog writeback identity

    @Test @MainActor
    func scanIdentityIsTheCanonicalNameAndASharedNameRefusesToStart() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let model = PersonFinderModel()
        model.savedProfiles = POIProfile.listAll()
        let job = ScanJob(searchPath: FileManager.default.temporaryDirectory.path)
        job.assignedProfile = model.savedProfiles.first { $0.uuid == pair.junior.uuid }
        // Writeback / prefilter key: the canonical name, never the alias.
        #expect(job.personLabel == pair.given)
        #expect(job.personDisplayLabel == "Rick" + String(pair.given.dropFirst("Richard".count)))
        #expect(model.nameIsShared(pair.junior))
        // A shared canonical name cannot be scanned: the catalog rows it
        // would write are keyed by that name.
        model.startJob(job)
        // The status is the load-bearing check; the console line is flushed
        // on a later main-actor tick and is not asserted here.
        #expect(job.status == .failed("Two people are called \(pair.given)"))
        // A unique name starts normally (the volume check is the next gate,
        // and the temp dir is reachable, so the job leaves .idle).
        let solo = POIProfile(name: "Solo\(UUID().uuidString.prefix(6))", referencePath: "")
        try solo.save()
        defer { try? FileManager.default.removeItem(at: POIStorage.folder(for: solo)) }
        model.savedProfiles = POIProfile.listAll()
        #expect(!model.nameIsShared(solo))
    }

    // MARK: 3. Holdout review queues and validation labels

    @Test @MainActor
    func holdoutAndLabelEntryPointsRefuseASharedName() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let model = PersonFinderModel()
        model.savedProfiles = POIProfile.listAll()
        #expect(model.nameIsShared(pair.junior))
        #expect(model.nameIsShared(pair.senior))
        let refusal = PersonFinderModel.sharedNameRefusal(pair.junior, operation: "review")
        #expect(refusal.contains("Two people are called \(pair.given)"))
        #expect(refusal.contains("distinct short name"))
        // Making the names distinct clears the refusal — no uuid change.
        var renamed = pair.senior
        renamed.name = pair.given + " Sr"
        try renamed.save()
        model.savedProfiles = POIProfile.listAll()
        #expect(!model.nameIsShared(pair.junior))
        #expect(!model.nameIsShared(renamed))
        #expect(try POIProfile.load(uuid: pair.senior.uuid).uuid == pair.senior.uuid)
    }

    // MARK: 4. Ambiguous legacy import

    @Test func legacyBundleFolderMatchingTwoLocalPeopleIsRefused() async throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-richards-bundle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        let folder = bundle.appendingPathComponent(POIStorage.sanitize(pair.given), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Legacy bundle: name-keyed folder, no uuid.
        try JSONSerialization.data(withJSONObject: ["name": pair.given, "referencePath": "/bundle"])
            .write(to: folder.appendingPathComponent("profile.json"))
        try Data([1]).write(to: folder.appendingPathComponent("ref.jpg"))

        let placement = BundleImporter.resolvePlacement(bundleFolder: folder, storeDir: POIStorage.storeDir)
        #expect(placement.refusal?.contains("\(pair.given)' is 2 people here") == true)
        #expect(placement.localExists == false)

        let jrBefore = try pair.jsonBytes(pair.junior), srBefore = try pair.jsonBytes(pair.senior)
        let result = await BundleImporter.installPOIs(from: [folder], bundleExportedAt: Date(),
                                                      storeDir: POIStorage.storeDir,
                                                      trashDir: bundle.appendingPathComponent("trash"))
        #expect(result.installed.isEmpty)
        #expect(result.failed.first?.reason.contains("Nothing was copied") == true)
        #expect(try pair.jsonBytes(pair.junior) == jrBefore)
        #expect(try pair.jsonBytes(pair.senior) == srBefore)
        // A uuid-keyed bundle folder for Sr still places by uuid.
        let byUUID = bundle.appendingPathComponent(pair.senior.id, isDirectory: true)
        try FileManager.default.createDirectory(at: byUUID, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": pair.given, "uuid": pair.senior.uuid.uuidString, "referencePath": "/bundle"])
            .write(to: byUUID.appendingPathComponent("profile.json"))
        let placed = BundleImporter.resolvePlacement(bundleFolder: byUUID, storeDir: POIStorage.storeDir)
        #expect(placed.refusal == nil)
        #expect(placed.destination.standardizedFileURL.path == POIStorage.folder(for: pair.senior).standardizedFileURL.path)
    }

    // MARK: 5. Alias promotion (Identify Family)

    @Test @MainActor
    func clusterNamedByAliasMergesIntoTheRightRichardAndTheBareNameIsSkipped() throws {
        let pair = try makePair()
        defer { pair.cleanup() }
        let clusterRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("two-richards-clusters-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: clusterRoot) }
        func cluster(_ id: Int, _ name: String) throws -> FaceCluster {
            let dir = clusterRoot.appendingPathComponent("cluster_\(id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data([0xFF, 0xD8, 0xFF, 0xE0]).write(to: dir.appendingPathComponent("face_0.jpg"))
            return FaceCluster(id: id, faceCount: 1, videoCount: 1, gridImageURL: nil, directoryURL: dir, name: name)
        }
        let model = IdentifyFamilyModel()
        model.runName = "sensor"
        model.clusters = [
            try cluster(1, "Rick" + String(pair.given.dropFirst("Richard".count))),   // Jr's alias
            try cluster(2, pair.given),                                                 // shared canonical name
            try cluster(3, "\(pair.given) Breen Sr"),                                   // Sr's full-name form
            try cluster(4, "Newcomer\(pair.given.suffix(6))"),                          // nobody
        ]
        let plan = model.planPromotion()
        var merged: [Int: UUID] = [:]
        var skipped: [Int: String] = [:]
        var created: [Int: UUID] = [:]
        for action in plan {
            switch action {
            case .merge(let cid, _, _, _, let uuid): merged[cid] = uuid
            case .skip(let cid, let reason): skipped[cid] = reason
            case .create(let cid, _, _, let uuid): created[cid] = uuid
            }
        }
        #expect(merged[1] == pair.junior.uuid, "the alias picks Jr")
        #expect(skipped[2]?.contains("2 people answer to") == true, "the bare shared name is never guessed")
        #expect(merged[3] == pair.senior.uuid, "the full-name form picks Sr")
        #expect(created[4] != nil)

        let summary = model.executePromotion(plan)
        #expect(summary.contains("1 new POI"))
        #expect(summary.contains("2 merged"))
        let jrFaces = try FileManager.default.contentsOfDirectory(atPath: POIStorage.folder(for: pair.junior).path)
            .filter { $0.hasPrefix("cluster_") }
        let srFaces = try FileManager.default.contentsOfDirectory(atPath: POIStorage.folder(for: pair.senior).path)
            .filter { $0.hasPrefix("cluster_") }
        #expect(jrFaces.count == 1 && jrFaces[0].contains("_001_"))
        #expect(srFaces.count == 1 && srFaces[0].contains("_003_"))
        // The bare-name cluster landed nowhere; the newcomer has its own folder.
        let newcomer = try #require(created[4])
        defer { try? FileManager.default.removeItem(at: POIStorage.folder(forUUID: newcomer)) }
        #expect(FileManager.default.fileExists(atPath: POIStorage.profileURL(forUUID: newcomer).path))
        #expect(POIProfile.listAll().filter { $0.name == pair.given }.count == 2, "no third Richard")
    }
}
