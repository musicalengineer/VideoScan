import XCTest
@testable import VideoScanCore

/// Launch-path perf sensors for the compiled family tree (2026-08-29).
/// Reads the REAL promoted artifact read-only when present, and the
/// synthetic 39,250 / 100k pedigrees always. Prints cold and warm (p95 of
/// 10) decode times; Release budgets apply only in Release.
final class GedcomLaunchPerfTests: XCTestCase {
    static let compiledRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/VideoScan/family-tree/compiled")

    #if DEBUG
    static let config = "Debug"
    static let slack = 5.0
    #else
    static let config = "Release"
    static let slack = 1.0
    #endif

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

    func ms(_ body: () throws -> Void) rethrows -> Double {
        let t0 = DispatchTime.now().uptimeNanoseconds
        try body()
        return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
    }

    /// (cold, p50, p95) over `runs` — cold = the first call.
    func profile(_ runs: Int = 10, _ body: () throws -> Void) rethrows -> (cold: Double, p50: Double, p95: Double) {
        var samples: [Double] = []
        for _ in 0..<runs { samples.append(try ms(body)) }
        let cold = samples[0]
        let sorted = samples.sorted()
        return (cold, sorted[runs / 2], sorted[min(runs - 1, Int((Double(runs) * 0.95).rounded(.up)) - 1)])
    }

    func testRealArtifactDecode() throws {
        guard let url = Self.realArtifactURL() else { throw XCTSkip("no promoted artifact") }
        var data = Data()
        let read = ms { data = try! Data(contentsOf: url) }
        // A promoted generation compiled by an older build is a skip, not
        // a failure: the app recompiles it (Recompile button) on its next
        // launch, and until then there is nothing to measure.
        do { _ = try GedcomCompiledTree.decode(data) } catch let error as GedcomCompiledTree.CodecError {
            if case .versionMismatch = error { throw XCTSkip("promoted artifact is older than the current codec: \(error)") }
            throw error
        }
        var people = 0
        let d = try profile { people = try GedcomCompiledTree.decode(data).people.count }
        print("LAUNCH[\(Self.config)] real artifact \(data.count / 1024) KB read \(read) ms; decode cold \(d.cold) ms p50 \(d.p50) ms p95 \(d.p95) ms (\(people) people)")
        XCTAssertLessThan(d.p95, 60 * Self.slack, "decode p95 budget (measured 28 ms Release, M4 Max, 2026-08-29)")
    }

    func testSynthetic39kAnd100kDecode() throws {
        for n in [39_250, 100_000] {
            let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: n))
            let data = GedcomCompiledTree.encode(graph)
            let d = try profile { _ = try GedcomCompiledTree.decode(data) }
            print("LAUNCH[\(Self.config)] synthetic \(n) artifact \(data.count / 1024) KB decode cold \(d.cold) ms p50 \(d.p50) ms p95 \(d.p95) ms")
            XCTAssertLessThan(d.p95, (n == 100_000 ? 120 : 50) * Self.slack,
                              "decode p95 budget (measured 19 / 56 ms Release, M4 Max, 2026-08-29)")
        }
    }
}
