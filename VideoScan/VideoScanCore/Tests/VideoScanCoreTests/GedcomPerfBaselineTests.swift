import XCTest
@testable import VideoScanCore

/// Perf baseline (2026-08-28). Prints timings; asserts nothing beyond
/// sanity so the numbers can be read from `swift test -c release`.
final class GedcomPerfBaselineTests: XCTestCase {
    static let bigTree = URL(fileURLWithPath:
        "/Volumes/FamilyArchive/Breen_Family_Archive/40_Family_Tree/GEDCOM/familysearch-tree-20generations.ged")

    func ms(_ body: () -> Void) -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    func report(_ label: String, _ graph: GedcomFamilyGraph, root: String?) {
        var r: [GedcomFamilyGraph.Person] = []
        print("BASE[\(label)] people=\(graph.people.count) fam=\(graph.familyCount)")
        print("BASE[\(label)] matching 'John Breen': \(ms { r = graph.people(matching: "John Breen") }) ms → \(r.count)")
        print("BASE[\(label)] matching 'Elizabeth': \(ms { r = graph.people(matching: "Elizabeth") }) ms → \(r.count)")
        print("BASE[\(label)] matching 'fred lamb' (dimin): \(ms { r = graph.people(matching: "fred lamb") }) ms → \(r.count)")
        print("BASE[\(label)] matching 'zzzq' (prefix miss): \(ms { r = graph.people(matching: "zzzq") }) ms → \(r.count)")
        print("BASE[\(label)] withSurname 'Breens': \(ms { r = graph.people(withSurname: "Breens") }) ms → \(r.count)")
        print("BASE[\(label)] namedLike 'Rick Breen': \(ms { r = graph.people(namedLike: "Rick Breen") }) ms → \(r.count)")
        var ni: GedcomFamilyGraph.NameIndex?
        print("BASE[\(label)] NameIndex build: \(ms { ni = GedcomFamilyGraph.NameIndex(graph: graph) }) ms")
        print("BASE[\(label)] NameIndex namedLike: \(ms { r = ni!.people(namedLike: "Rick Breen") }) ms → \(r.count)")
        guard let root else { return }
        var ai: GedcomFamilyGraph.AncestorIndex?
        print("BASE[\(label)] AncestorIndex(root) build: \(ms { ai = GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: root) }) ms")
        // pick a deep ancestor and a far cousin for kinship
        let far = graph.people.keys.sorted().last!
        var path: GedcomFamilyGraph.KinPath?
        print("BASE[\(label)] relationshipPath root↔last: \(ms { path = graph.relationshipPath(from: graph.people[root]!, to: graph.people[far]!) }) ms → \(path?.steps.count ?? -1) steps")
        var line: [GedcomFamilyGraph.AncestorGeneration] = []
        print("BASE[\(label)] ancestorLine both 25: \(ms { line = graph.ancestorLine(of: graph.people[root]!, line: .both, generations: 25) }) ms → \(line.count) gens, \(line.reduce(0) { $0 + $1.people.count }) people")
        _ = ai
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

    /// Resident size of a loaded 100k graph + index, measured alone in a
    /// fresh process (run with --filter testMemory100k).
    func testMemory100k() throws {
        let base = Self.residentMB()
        let text = GedcomSyntheticPedigree.gedcom(people: 100_000)
        let afterText = Self.residentMB()
        let graph = GedcomFamilyGraph(gedcomText: text)
        let afterParse = Self.residentMB()
        _ = graph.index
        let afterIndex = Self.residentMB()
        let data = GedcomCompiledTree.encode(graph)
        let decoded = try GedcomCompiledTree.decode(data)
        let afterDecode = Self.residentMB()
        print("MEM[100k] base \(base) MB; +gedcom text \(afterText - base) MB; +parse \(afterParse - afterText) MB; +index \(afterIndex - afterParse) MB; +encoded+decoded copy \(afterDecode - afterIndex) MB; total \(afterDecode) MB")
        XCTAssertEqual(decoded.people.count, 100_000)
        XCTAssertLessThan(afterIndex - afterText, 500)
    }

    func testMemoryReal() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path))
        let base = Self.residentMB()
        let graph = try XCTUnwrap(GedcomFamilyGraph(fileURL: Self.bigTree))
        let afterParse = Self.residentMB()
        _ = graph.index
        let afterIndex = Self.residentMB()
        let data = GedcomCompiledTree.encode(graph)
        let decodedOnly = try GedcomCompiledTree.decode(data)
        let afterDecode = Self.residentMB()
        print("MEM[real] base \(base) MB; parse (incl. transient text) \(afterParse - base) MB; +index \(afterIndex - afterParse) MB; +decoded copy \(afterDecode - afterIndex) MB; total \(afterDecode) MB")
        XCTAssertEqual(decodedOnly.people.count, 16383)
    }

    func testRealFileBaseline() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.bigTree.path))
        var graph: GedcomFamilyGraph?
        print("BASE[real] parse: \(ms { graph = GedcomFamilyGraph(fileURL: Self.bigTree) }) ms")
        report("real", graph!, root: graph!.rootPersonID)
    }

    func testSynthetic100kBaseline() throws {
        var text = ""
        print("BASE[100k] generate: \(ms { text = GedcomSyntheticPedigree.gedcom(people: 100_000) }) ms, \(text.utf8.count / 1_000_000) MB")
        var graph: GedcomFamilyGraph?
        print("BASE[100k] parse: \(ms { graph = GedcomFamilyGraph(gedcomText: text) }) ms")
        XCTAssertEqual(graph!.people.count, 100_000)
        report("100k", graph!, root: graph!.rootPersonID)
    }
}
