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
        var rows: [FamilyTreePersonSummary] = []
        var identity: FamilyAssetIdentityDirectory?
        let offMain = ms {
            rows = FamilyTreeLiveModel.sidebarRows(of: graph)
            identity = FamilyAssetIdentityDirectory(graph: graph, speakers: .fromDefaults())
        }
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let install = ms { model.install(graph: graph, rows: rows, identity: identity) }
        print("SCALE[\(Self.config)] real index build: \(index) ms; rows+identity (background): \(offMain) ms; install (main actor): \(install) ms filtered=\(model.filteredPeople.count) cards=\(model.scene.cards.count)")
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
        XCTAssertLessThan(decode, 300 * Self.slack, "snapshot load budget (measured 44 ms Release)")
    }

    @MainActor
    func testHundredThousandPersonSidebarKeystrokeWithinBudget() throws {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        let rows = FamilyTreeLiveModel.sidebarRows(of: graph)
        let identity = FamilyAssetIdentityDirectory(graph: graph, speakers: .fromDefaults())
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        let install = ms { model.install(graph: graph, rows: rows, identity: identity) }
        // A narrowing needle (what typing does) and a broad one.
        let narrow = medianMS { model.searchText = "breen"; model.searchText = "bree" }
        let broad = medianMS { model.searchText = "a"; model.searchText = "" }
        print("SCALE[\(Self.config)] 100k install \(install) ms; keystroke narrow \(narrow / 2) ms, broad \(broad / 2) ms")
        XCTAssertLessThan(narrow / 2, 5 * Self.slack, "sidebar keystroke budget")
        XCTAssertLessThan(install, 500 * Self.slack, "main-actor install budget at 100k")
    }
}
