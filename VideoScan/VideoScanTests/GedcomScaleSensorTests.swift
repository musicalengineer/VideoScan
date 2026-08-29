import XCTest
@testable import VideoScan
import VideoScanCore

/// Scale sensors for the family tree (2026-08-26 parse/install; 2026-08-28
/// compiled index + artifact). Budgets are Release numbers ×3 for Debug,
/// per the feature-test checklist. The real 20-generation FamilySearch
/// export (16,383 people, 1.4M lines, 70 MB) is used when the archive is
/// mounted; the 100k synthetic pedigree always runs.
final class GedcomScaleSensorTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    #if DEBUG
    static let slack = 3.0
    /// The sub-millisecond lookups run ~9× slower unoptimized (generic
    /// Array/String specialization is off in Debug), measured 2026-08-28:
    /// token 0.8 ms Release vs 7.7 ms Debug on the M4 Max. ×3 would fail
    /// on the ratio alone; ×10 passed on the M4 but the M1 Max measured
    /// 10.9 ms for the token lookup (2026-08-28, codex nightly), so the
    /// Debug budget is 25 ms. Release stays at the true budget; a real
    /// regression (an O(n) scan is ~100+ ms) still trips it.
    static let microSlack = 25.0
    static let config = "Debug"
    #else
    static let slack = 1.0
    static let microSlack = 1.0
    static let config = "Release"
    #endif

    func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// Median of several runs so one scheduler hiccup does not fail a sensor.
    func medianMS(_ runs: Int = 7, _ body: () -> Void) -> Double {
        (0..<runs).map { _ in ms(body) }.sorted()[runs / 2]
    }

    static func residentMB() -> Double {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.resident_size) / 1_048_576 : -1
    }

    // MARK: Real export

    func testSeventyMegabyteGedcomParsesWithinBudget() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let t0 = Date()
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let parse = Date().timeIntervalSince(t0)
        print("SCALE[\(Self.config)] parse: \(String(format: "%.2f", parse))s people=\(graph.people.count)")
        XCTAssertEqual(graph.people.count, 16383)
        XCTAssertLessThan(parse, 10, "parse budget (measured 2.2 s Release, 2026-08-28)")
    }

    @MainActor
    func testSeventyMegabyteGedcomInstallsWithinBudget() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let index = ms { _ = graph.index }
        var bundle: FamilyTreeLaunchBundle?
        let offMain = ms { bundle = FamilyTreeLaunchBundle.build(graph: graph, settings: .fromDefaults()) }
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let install = ms { model.install(graph: graph, bundle: bundle) }
        print("SCALE[\(Self.config)] real index build: \(index) ms; launch bundle (background): \(offMain) ms; install (main actor): \(install) ms filtered=\(model.filteredPeople.count) cards=\(model.scene.cards.count)")
        XCTAssertLessThan(install, 100 * Self.slack, "main-actor install budget (2026-08-28)")
        let search = medianMS { model.searchText = "Breen"; model.searchText = "" }
        print("SCALE[\(Self.config)] real search keystroke pair: \(search) ms → \(model.filteredPeople.count)")
        XCTAssertLessThan(search, 10 * Self.slack)
    }

    func testRealExportCompiledArtifactLoadsFast() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path), "archive not mounted")
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let data = GedcomCompiledTree.encode(graph)
        let decode = medianMS(5) { _ = try? GedcomCompiledTree.decode(data) }
        print("SCALE[\(Self.config)] real artifact: \(data.count / 1024) KB, decode \(decode) ms")
        XCTAssertLessThan(decode, 100 * Self.slack, "decode budget (measured 9 ms Release)")
    }

    // MARK: Real promoted artifact (39k merged tree, 2026-08-29)
    //
    // Where the budgets come from (Release, real 39,250-person artifact;
    // "before" = codec 4 on the M4 Max, "after" = codec 5 on the M5 Pro
    // test host / M4 Max Core package, p50 of 10):
    //   decode                 42 ms → 24 ms (M5) / 20 ms (M4 Core)
    //   sidebar rows           38 ms →  5 ms
    //   identity directory    131 ms →  6.6 ms
    //   launch bundle (‖)       —   →  8.8 ms   (rows + identity + anchors)
    //   install (main actor)   14 ms →  0.07 ms warm / 4.9 ms cold
    //   100k install           25 ms →  0.67 ms
    //   100k decode            72 ms → 43 ms
    // Debug (M4 Max, Core): real decode 583 ms (in-app log) → 330 ms.

    static let compiledRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VideoScan/family-tree/compiled")

    /// The promoted `tree.vsft`, read-only, or nil when none is promoted.
    static func realArtifactURL() -> URL? {
        // `VS_TREE_ARTIFACT=<path/tree.vsft>` points the sensor at a
        // scratch compile (e.g. before the production generation has
        // been recompiled for a new codec).
        if let override = ProcessInfo.processInfo.environment["VS_TREE_ARTIFACT"] {
            return FileManager.default.fileExists(atPath: override) ? URL(fileURLWithPath: override) : nil
        }
        let pointer = compiledRoot.appendingPathComponent("current.json")
        guard let data = try? Data(contentsOf: pointer),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = json["current"] as? String else { return nil }
        let url = compiledRoot.appendingPathComponent(current).appendingPathComponent("tree.vsft")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// (cold, p50, p95) of `runs` timings; cold = the first.
    func profile(_ runs: Int = 10, _ body: () -> Void) -> (cold: Double, p50: Double, p95: Double) {
        let samples = (0..<runs).map { _ in ms(body) }
        let sorted = samples.sorted()
        return (samples[0], sorted[runs / 2], sorted[max(0, Int((Double(runs) * 0.95).rounded(.up)) - 1)])
    }

    /// The whole launch path on the REAL promoted artifact: decode → rows
    /// + identity (background) → install (main actor), each step printed
    /// cold / p50 / p95 over 10 runs. Budgets are Release; ×slack in Debug.
    @MainActor
    func testRealCompiledArtifactLaunchPathWithinBudget() throws {
        guard let url = Self.realArtifactURL() else { throw XCTSkip("no promoted artifact") }
        let data = try Data(contentsOf: url)
        // An older-codec generation is a skip until the app recompiles it.
        do { _ = try GedcomCompiledTree.decode(data) } catch let error as GedcomCompiledTree.CodecError {
            if case .versionMismatch = error { throw XCTSkip("promoted artifact is older than the current codec: \(error)") }
            throw error
        }
        var graph: GedcomFamilyGraph?
        let decode = profile { graph = try? GedcomCompiledTree.decode(data) }
        let g = try XCTUnwrap(graph)
        let settings = FamilyTreeLaunchBundle.Settings.fromDefaults()
        let rowsT = profile { _ = FamilyTreeLiveModel.sidebarRows(of: g) }
        let identityT = profile { _ = FamilyAssetIdentityDirectory(graph: g, speakers: settings.speakers) }
        var bundle: FamilyTreeLaunchBundle?
        let bundleT = profile { bundle = FamilyTreeLaunchBundle.build(graph: g, settings: settings) }
        let sink = InMemoryLogSink()
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let install = profile(5) { withAppLog(sink) { model.install(graph: g, bundle: bundle) } }
        let hallieWarm = profile {
            _ = g.commonAncestors(of: g.rootPersonIDs.first ?? "", and: g.rootPersonIDs.last ?? "", limit: 3)
        }
        print("LAUNCH[\(Self.config)] real \(g.people.count) people: decode cold \(decode.cold) p50 \(decode.p50) p95 \(decode.p95) ms; "
              + "rows cold \(rowsT.cold) p50 \(rowsT.p50) p95 \(rowsT.p95) ms; identity cold \(identityT.cold) p50 \(identityT.p50) p95 \(identityT.p95) ms; "
              + "bundle (parallel) cold \(bundleT.cold) p50 \(bundleT.p50) p95 \(bundleT.p95) ms; "
              + "install cold \(install.cold) p50 \(install.p50) p95 \(install.p95) ms; "
              + "common-ancestor (roots) p50 \(hallieWarm.p50) p95 \(hallieWarm.p95) ms")
        for line in sink.lines where line.contains("[family-tree]") { print("LAUNCH[\(Self.config)] log: \(line)") }
        XCTAssertLessThan(decode.p95, 60 * Self.slack, "decode p95 budget (measured 25 ms Release M4 Max, 2026-08-29)")
        XCTAssertLessThan(bundleT.p95, 60 * Self.slack, "launch bundle p95 budget")
        XCTAssertLessThan(install.p95, 20 * Self.slack, "main-actor install p95 budget (no O(people) work)")
        XCTAssertLessThan(hallieWarm.p95, 20 * Self.slack, "Hallie warm common-ancestor budget")
    }

    // MARK: 100k synthetic

    func testHundredThousandPersonTreeMeetsQueryBudgets() throws {
        let before = Self.residentMB()
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let build = ms { _ = graph.index }
        let after = Self.residentMB()
        print("SCALE[\(Self.config)] 100k index build: \(build) ms; resident graph+index ≈ \(after - before) MB (task \(after) MB)")
        XCTAssertLessThan(after - before, 500, "graph + index must stay under 500 MB resident")

        let token = medianMS { _ = graph.people(matching: "Elizabeth") }
        let surname = medianMS { _ = graph.people(withSurname: "Breens") }
        let like = medianMS { _ = graph.people(namedLike: "Rick Breen") }
        let given = medianMS { _ = graph.people(withGivenName: "John") }
        let sidebar = medianMS { _ = graph.index.sidebarRows(containing: "bre") }
        print("SCALE[\(Self.config)] 100k token \(token) ms, surname \(surname) ms, namedLike \(like) ms, given \(given) ms, sidebar 'bre' \(sidebar) ms")
        XCTAssertLessThan(token, 1 * Self.microSlack, "token lookup budget")
        XCTAssertLessThan(surname, 1 * Self.microSlack, "surname lookup budget")
        XCTAssertLessThan(like, 1 * Self.microSlack, "namedLike budget")
        XCTAssertLessThan(given, 1 * Self.microSlack, "given-name budget")
        XCTAssertLessThan(sidebar, 5 * Self.slack, "sidebar keystroke budget")

        let root = try XCTUnwrap(graph.rootPersonID)
        let far = graph.people.keys.sorted().last!
        let ancestors = medianMS { _ = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: root) }
        let common = medianMS {
            let a = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: root)
            let b = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: far)
            _ = (a, b)
        }
        let path = medianMS { _ = graph.relationshipPath(from: graph.people[root]!, to: graph.people[far]!) }
        let line = medianMS { _ = graph.ancestorLine(of: graph.people[root]!, line: .both, generations: 30) }
        print("SCALE[\(Self.config)] 100k AncestorIndex \(ancestors) ms, two-index common-ancestor build \(common) ms, relationshipPath \(path) ms, ancestorLine \(line) ms")
        XCTAssertLessThan(common, 20 * Self.slack, "commonAncestors budget")
        XCTAssertLessThan(path, 20 * Self.slack, "relationshipPath budget")
    }

    func testHundredThousandPersonArtifactDecodesWithinBudget() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let encode = ms { _ = GedcomCompiledTree.encode(graph) }
        let data = GedcomCompiledTree.encode(graph)
        let decode = medianMS(5) { _ = try? GedcomCompiledTree.decode(data) }
        print("SCALE[\(Self.config)] 100k artifact: \(data.count / 1024) KB, encode \(encode) ms, decode \(decode) ms")
        XCTAssertLessThan(decode, 150 * Self.slack, "snapshot load budget (measured 72 → 54 ms Release M4 Max, 2026-08-29)")
    }

    func testHallieNameRoutesOnHundredThousandPersonTree() async throws {
        // Keep the fixture local so its graph/index can be released before
        // the other 100k sensors allocate theirs. Index construction is
        // deliberately outside the query budget, matching a warmed app.
        let graph = GedcomFamilyGraph(
            gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let ownerID = try XCTUnwrap(graph.rootPersonID)
        let owner = try XCTUnwrap(graph.people[ownerID])
        let ownerGiven = try XCTUnwrap(FamilyIdentityText.tokens(owner.name).first)
        let ownerFSID = try XCTUnwrap(owner.familySearchID)
        _ = graph.index
        let context = HallieTurnExecutor.Context(
            profiles: [], graph: graph,
            speakers: .init(
                ownerName: owner.name,
                archivistName: "Hallie Mae",
                ownerFamilySearchID: ownerFSID))
        let ownerRequest = HallieTurnExecutor.Request(intent: .init(
            originalQuestion: "who is \(ownerGiven)?",
            ast: .graph(.init(
                people: [ownerGiven], operation: .biography))))
        let surnameRequest = HallieTurnExecutor.Request(intent: .init(
            originalQuestion: "tell me about Pa Breen",
            ast: .graph(.init(
                people: ["Pa Breen"], operation: .biography))))

        var ownerSamples: [Double] = []
        var surnameSamples: [Double] = []
        for _ in 0..<5 {
            var started = DispatchTime.now().uptimeNanoseconds
            let ownerResult = try await HallieTurnExecutor.execute(
                ownerRequest, context: context)
            ownerSamples.append(Double(
                DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            XCTAssertEqual(ownerResult.outcome, .answered, ownerResult.prose)
            XCTAssertTrue(ownerResult.basisLine.contains("FamilySearch ID \(ownerFSID)"))

            started = DispatchTime.now().uptimeNanoseconds
            let surnameResult = try await HallieTurnExecutor.execute(
                surnameRequest, context: context)
            surnameSamples.append(Double(
                DispatchTime.now().uptimeNanoseconds - started) / 1e6)
            XCTAssertEqual(surnameResult.outcome, .needsClarification, surnameResult.prose)
            XCTAssertEqual(surnameResult.clarification?.candidates.count, HallieWhichOne.cap)
            XCTAssertTrue(surnameResult.basisLine.contains("Breens offered"))
        }
        let ownerMedian = ownerSamples.sorted()[ownerSamples.count / 2]
        let surnameMedian = surnameSamples.sorted()[surnameSamples.count / 2]
        print("SCALE[\(Self.config)] Hallie 100k owner p50 \(ownerMedian) ms; surname p50 \(surnameMedian) ms")
        XCTAssertLessThan(ownerMedian, 50 * Self.slack, "100k bare-name owner binding budget")
        XCTAssertLessThan(surnameMedian, 250 * Self.slack, "100k surname-roster budget")
    }

    func testHundredThousandPersonPointerPinsHashTreeOnlyOnce() throws {
        // Ancestry/non-FamilySearch exports use pointer+fingerprint pins.
        // Thirty-two pins used to sort and SHA the entire tree once per
        // profile while constructing every Hallie overlay.
        let withoutFSIDs = GedcomSyntheticPedigree.gedcom(people: 100_000)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.contains("_FSFTID") }
            .joined(separator: "\n")
        let graph = GedcomFamilyGraph(gedcomText: withoutFSIDs)
        let fingerprint = FamilyKinshipOverlay.fingerprint(of: graph)
        let pinnedIDs = Array(graph.people.keys.sorted().prefix(32))
        let snapshots = pinnedIDs.enumerated().map { offset, id in
            ArchivistGraphProfileSnapshot(
                stableID: "pointer-profile-\(offset)",
                canonicalName: "Pointer Profile \(offset)",
                treeIdentity: .pointer(
                    pointer: id, sourceFingerprint: fingerprint))
        }

        var overlays: [FamilyKinshipOverlay] = []
        let samples = (0..<3).map { _ -> Double in
            let started = DispatchTime.now().uptimeNanoseconds
            overlays.append(FamilyKinshipOverlay(
                snapshots: snapshots, graph: graph))
            return Double(DispatchTime.now().uptimeNanoseconds - started) / 1e6
        }
        let median = samples.sorted()[samples.count / 2]
        let overlay = try XCTUnwrap(overlays.last)
        for snapshot in snapshots {
            guard let node = overlay.node(profileStableID: snapshot.stableID),
                  case .tree = node else {
                return XCTFail("pointer pin did not bridge: \(snapshot.stableID)")
            }
        }
        print("SCALE[\(Self.config)] Hallie 100k x 32 pointer-pin overlay p50 \(median) ms")
        XCTAssertLessThan(median, 500 * Self.slack,
                          "pointer pins must reuse one tree fingerprint")
    }

    @MainActor
    func testHundredThousandPersonSidebarKeystrokeWithinBudget() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let bundle = FamilyTreeLaunchBundle.build(graph: graph, settings: .fromDefaults())
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let install = ms { model.install(graph: graph, bundle: bundle) }
        // A narrowing needle (what typing does) and a broad one.
        let narrow = medianMS { model.searchText = "breen"; model.searchText = "bree" }
        let broad = medianMS { model.searchText = "a"; model.searchText = "" }
        print("SCALE[\(Self.config)] 100k install \(install) ms; keystroke narrow \(narrow / 2) ms, broad \(broad / 2) ms")
        XCTAssertLessThan(narrow / 2, 5 * Self.slack, "sidebar keystroke budget")
        XCTAssertLessThan(install, 50 * Self.slack, "main-actor install budget at 100k (no O(people) work; measured 25 ms Release before, 2026-08-29)")
    }
}
