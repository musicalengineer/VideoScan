// HallieQueryBench.swift
// A repeatable benchmark for Hallie's DETERMINISTIC query path, at the
// scale Rick's real export has (16,383 people), in two shapes:
//
//   SINGLE  — one query at a time, N iterations, p50 / p95 / max, plus a
//             phase breakdown so a number is a work item and not a mood.
//   MULTI   — K concurrent sessions (K = 1, 2, 5, 10) asking at once, as
//             several family members on the web client would. Reports
//             per-query latency AND throughput at each K, plus how long a
//             main-actor hop takes while the load runs (that is the Mac
//             UI's responsiveness, measured rather than asserted).
//
// Deliberate measurement decisions, so the numbers mean something:
//
//   * NO MODEL. `translateAST` / `interpretTurn` / `composeAnswer` are
//     stubs. A live Ollama turn is seconds of network and sampling noise
//     that would bury every millisecond this suite exists to find.
//     Questions that need the model are reported as `model-required` and
//     excluded from the deterministic totals rather than silently timed.
//   * NO DISK, and the count of disk-shaped calls is recorded instead.
//     Production's `loadProfiles` walks Application Support/VideoScan/POI
//     and decodes a JSON file per person; `loadCyberBrain` loads and
//     indexes the whole archive. Both are uncached per call, so the
//     interesting figure is HOW MANY TIMES ONE TURN ASKS — a structural
//     number that is the same on any machine — multiplied by whatever a
//     load costs on the day. The bench pins the count.
//   * NO UserDefaults. `loadSpeakers` is injected; the default reads real
//     `archivist.*` prefs and would make the result depend on Rick's Mac.
//
// Timing budgets follow the house rule (PerformanceLane): a loose,
// always-on ceiling that only catches scan-shaped regressions, and tight
// wall-clock budgets ONLY under Release + opt-in + coverage off.

import Testing
import Foundation
@testable import VideoScan
import VideoScanCore

// MARK: - Instrumentation

/// Per-phase wall-clock accumulator. Dependency closures run on detached
/// tasks, so this is lock-protected — the Swift equivalent of a small spy
/// guarded by `std::mutex`.
final class HalliePhaseLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: [String: Double] = [:]
    private var calls: [String: Int] = [:]

    func record(_ phase: String, _ elapsed: Double) {
        lock.withLock {
            seconds[phase, default: 0] += elapsed
            calls[phase, default: 0] += 1
        }
    }

    func measure<T>(_ phase: String, _ body: () throws -> T) rethrows -> T {
        let start = ContinuousClock.now
        defer { record(phase, HallieBenchClock.seconds(since: start)) }
        return try body()
    }

    func measureAsync<T>(_ phase: String, _ body: () async throws -> T) async rethrows -> T {
        let start = ContinuousClock.now
        let value = try await body()
        record(phase, HallieBenchClock.seconds(since: start))
        return value
    }

    func reset() { lock.withLock { seconds = [:]; calls = [:] } }

    var snapshot: (seconds: [String: Double], calls: [String: Int]) {
        lock.withLock { (seconds, calls) }
    }

    func callCount(_ phase: String) -> Int { lock.withLock { calls[phase] ?? 0 } }
    func totalSeconds(_ phase: String) -> Double { lock.withLock { seconds[phase] ?? 0 } }
}

enum HallieBenchClock {
    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

enum HallieBenchStats {
    /// Nearest-rank percentile over an UNSORTED sample.
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank - 1, 0), sorted.count - 1)]
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.2f", seconds * 1000) }

    static func line(_ label: String, _ values: [Double]) -> String {
        let total = values.reduce(0, +)
        return String(
            format: "%-26@ n=%-4d p50 %8@ ms  p95 %8@ ms  max %8@ ms  mean %8@ ms",
            label as NSString, values.count,
            ms(percentile(values, 50)) as NSString,
            ms(percentile(values, 95)) as NSString,
            ms(values.max() ?? 0) as NSString,
            ms(total / Double(max(values.count, 1))) as NSString)
    }
}

/// Latency of hopping onto the main actor while load runs. This is the
/// number the Mac UI feels: HallieWebBridge and the coordinator's entry
/// point are `@MainActor`, so every concurrent web turn queues on the same
/// actor that draws Rick's windows.
final class MainActorHopProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var task: Task<Void, Never>?

    func start(intervalMilliseconds: UInt64 = 2) {
        task = Task.detached(priority: .userInitiated) { [self] in
            while !Task.isCancelled {
                let start = ContinuousClock.now
                await MainActor.run { }
                let elapsed = HallieBenchClock.seconds(since: start)
                lock.withLock { samples.append(elapsed) }
                try? await Task.sleep(nanoseconds: intervalMilliseconds * 1_000_000)
            }
        }
    }

    func stop() -> [Double] {
        task?.cancel()
        task = nil
        return lock.withLock { samples }
    }
}

// MARK: - Fixture

/// A production-scale synthetic tree plus a handful of UNIQUELY named
/// people. The stock generator draws from 40 given names and 40 surnames,
/// so every name is shared by dozens — realistic for postings, but every
/// question would end in "which one do you mean?". Renaming five people
/// gives the bench both shapes: answered and clarification.
enum HallieBenchTree {

    struct Fixture: Sendable {
        let graph: GedcomFamilyGraph
        let rootName: String
        let fatherName: String
        let motherName: String
        let grandfatherName: String
        let distantName: String
        /// A name the stock pools DO produce many of.
        let ambiguousName: String
    }

    static let peopleCount = 16_383

    private static func rename(_ text: String, _ names: [String: String]) -> String {
        var lines = text.components(separatedBy: "\n")
        var pending: String?
        for i in lines.indices {
            let line = lines[i]
            if line.hasPrefix("0 @"), line.hasSuffix(" INDI") {
                let id = String(line.dropFirst(2).dropLast(5))
                pending = names[id] == nil ? nil : id
            } else if let id = pending, line.hasPrefix("1 NAME ") {
                let full = names[id]!  // swiftlint:disable:this force_unwrapping
                let parts = full.split(separator: " ")
                lines[i] = "1 NAME \(parts.dropLast().joined(separator: " ")) /\(parts.last ?? "")/"
                pending = nil
            }
        }
        return lines.joined(separator: "\n")
    }

    static func make() -> Fixture {
        let base = GedcomSyntheticPedigree.gedcom(people: peopleCount)
        let probe = GedcomFamilyGraph(gedcomText: base)
        guard let root = probe.rootPerson else {
            fatalError("synthetic pedigree produced no root")
        }
        let father = probe.relatives(.father, of: root).first
        let mother = probe.relatives(.mother, of: root).first
        let grandfather = father.flatMap { probe.relatives(.father, of: $0).first }
        // Six generations up the paternal line, for the deep walks.
        var distant = grandfather
        for _ in 0..<4 {
            distant = distant.flatMap { probe.relatives(.father, of: $0).first } ?? distant
        }
        var names: [String: String] = [root.id: "Ricklin Ashgrove"]
        if let father { names[father.id] = "Bertram Ashgrove" }
        if let mother { names[mother.id] = "Winifred Coldbrook" }
        if let grandfather { names[grandfather.id] = "Osgood Ashgrove" }
        if let distant { names[distant.id] = "Thaddeus Farwell" }
        let graph = GedcomFamilyGraph(gedcomText: rename(base, names))
        return Fixture(
            graph: graph,
            rootName: "Ricklin Ashgrove",
            fatherName: father == nil ? "Ricklin Ashgrove" : "Bertram Ashgrove",
            motherName: mother == nil ? "Ricklin Ashgrove" : "Winifred Coldbrook",
            grandfatherName: grandfather == nil ? "Ricklin Ashgrove" : "Osgood Ashgrove",
            distantName: distant == nil ? "Ricklin Ashgrove" : "Thaddeus Farwell",
            ambiguousName: "John Breen")
    }
}

// MARK: - Deterministic dependencies

enum HallieBenchDependencies {

    struct ModelRequired: Error, CustomStringConvertible {
        let stage: String
        var description: String { "model required at \(stage)" }
    }

    /// Profiles shaped like Rick's People tab: a couple of dozen, a few
    /// with aliases. Small on purpose — the People tab is not 16k rows.
    static func profiles(ownerName: String) -> [HallieTurnExecutor.ProfileSnapshot] {
        var out: [HallieTurnExecutor.ProfileSnapshot] = [
            .init(stableID: "owner", canonicalName: ownerName, aliases: ["Rick"]),
            .init(stableID: "donna", canonicalName: "Donna Hudson", aliases: ["Donna"]),
        ]
        for (i, given) in ["Tim", "Dan", "Matt", "Chris", "Eileen", "George",
                           "Muriel", "Agnes", "Mary", "David"].enumerated() {
            out.append(.init(stableID: "p\(i)", canonicalName: "\(given) Breen",
                             aliases: [given]))
        }
        return out
    }

    static func make(
        graph: GedcomFamilyGraph,
        profiles: [HallieTurnExecutor.ProfileSnapshot],
        speakers: HallieTurnExecutor.Speakers,
        ledger: HalliePhaseLedger
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in throw ModelRequired(stage: "translateAST") },
            interpretTurn: { _, _, _ in throw ModelRequired(stage: "interpretTurn") },
            composeConversation: { _, _, _, _, _ in
                .init(value: .init(text: "", composedByModel: false, note: "bench"),
                      responderHost: "bench")
            },
            loadProfiles: { ledger.measure("loadProfiles") { profiles } },
            loadGraph: { ledger.measure("loadGraph") { graph } },
            loadNeedsRecompile: { ledger.measure("loadNeedsRecompile") { [] } },
            loadCyberBrain: { ledger.measure("loadCyberBrain") { nil } },
            loadSpeakers: { ledger.measure("loadSpeakers") { speakers } },
            executeRequest: { request, context in
                try await ledger.measureAsync("executeRequest") {
                    try await HallieTurnExecutor.execute(request, context: context)
                }
            },
            continueTurn: { clarification, id, context in
                try await ledger.measureAsync("continueTurn") {
                    try await HallieTurnExecutor.continue(
                        pending: clarification, selecting: id, context: context)
                }
            },
            resolveBiographyPhoto: { _ in ledger.measure("resolveBiographyPhoto") { nil } })
    }
}

// MARK: - The bench

@Suite("HallieQueryBench", .serialized)
struct HallieQueryBench {

    static let performanceOptIn = "VIDEOSCAN_HALLIE_PERF"

    /// Built once: parsing 16,383 people twice is the expensive part and it
    /// is setup, not the thing under test.
    static let fixture: HallieBenchTree.Fixture = HallieBenchTree.make()
    /// A catalog behind the turn. Small next to the 100k scale suites on
    /// purpose: only the catalog-stats shape reads it, and this bench is
    /// about the tree path. Built here rather than borrowed from
    /// CatalogSearchProfileBench because that generator is `@MainActor` and
    /// the turn runner must stay off the main actor to measure queueing.
    static let records: [VideoRecord] = makeRecords(5_000)

    static func makeRecords(_ n: Int) -> [VideoRecord] {
        (0..<n).map { i in
            let r = VideoRecord()
            let year = 1978 + (i % 45)
            r.filename = "clip_\(i).mov"
            r.directory = "/Volumes/FamilyArchive/\(year)"
            r.ext = "mov"
            r.streamTypeRaw = i % 7 == 0 ? StreamType.audioOnly.rawValue
                                         : StreamType.videoAndAudio.rawValue
            r.videoCodec = "h264"
            r.audioCodec = "aac"
            r.sizeBytes = Int64(50_000_000 + i * 977)
            r.durationSeconds = Double(30 + i % 900)
            r.dateCreated = "\(year)-06-01 12:00"
            r.dateCreatedRaw = Date(timeIntervalSince1970: Double(year - 1970) * 31_557_600)
            return r
        }
    }

    struct Question: Sendable {
        let label: String
        let text: String
    }

    static func questions(_ f: HallieBenchTree.Fixture) -> [Question] {
        [
            .init(label: "parents", text: "who were \(f.rootName)'s parents?"),
            .init(label: "biography", text: "tell me about \(f.fatherName)"),
            .init(label: "grandparents", text: "who were \(f.rootName)'s grandparents?"),
            .init(label: "deep-ancestor", text: "who is \(f.rootName)'s great great great grandfather?"),
            .init(label: "paternal-line", text: "trace \(f.rootName)'s paternal line back 6 generations"),
            .init(label: "kinship", text: "how is \(f.rootName) related to \(f.distantName)?"),
            .init(label: "common-ancestor", text: "who is the common ancestor of \(f.rootName) and \(f.distantName)?"),
            .init(label: "person-tree", text: "tell me about \(f.rootName)'s family tree"),
            .init(label: "surname-tree", text: "show the family tree for the Ashgrove family"),
            .init(label: "ambiguous-name", text: "tell me about \(f.ambiguousName)"),
            .init(label: "roster", text: "who do you know about?"),
            .init(label: "catalog-stats", text: "how many videos are archived?"),
        ]
    }

    static func speakers(_ f: HallieBenchTree.Fixture) -> HallieTurnExecutor.Speakers {
        HallieTurnExecutor.Speakers(
            ownerName: f.rootName, archivistName: "Hallie Mae")
    }

    struct TurnOutcome: Sendable {
        let label: String
        let seconds: Double
        let route: String
        let outcome: String
        let modelRequired: Bool
    }

    static func runTurn(
        _ question: Question,
        dependencies: HallieAppTurnCoordinator.Dependencies
    ) async -> TurnOutcome {
        let start = ContinuousClock.now
        do {
            let response = try await HallieAppTurnCoordinator.execute(
                question: question.text,
                records: records,
                referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["bench.invalid"],
                modelName: "bench-model",
                composeWithModel: false,
                dependencies: dependencies)
            return TurnOutcome(
                label: question.label,
                seconds: HallieBenchClock.seconds(since: start),
                route: HallieTurnExecutor.label(response.result.route),
                outcome: HallieTurnExecutor.label(response.result.outcome),
                modelRequired: false)
        } catch {
            let isModel = error is HallieBenchDependencies.ModelRequired
            return TurnOutcome(
                label: question.label,
                seconds: HallieBenchClock.seconds(since: start),
                route: isModel ? "model" : "error",
                outcome: isModel ? "model-required" : "\(error)",
                modelRequired: isModel)
        }
    }

    // MARK: 1. What is deterministic at all

    /// Runs every candidate question once and prints how it routed. This is
    /// the map for everything below: a question that reaches the translator
    /// is not part of the deterministic budget, and saying so out loud
    /// stops a future reader from quoting a model-shaped number as if it
    /// were local work.
    @Test("routing map: which questions are answered without a model")
    func routingMap() async {
        let f = Self.fixture
        let ledger = HalliePhaseLedger()
        let deps = HallieBenchDependencies.make(
            graph: f.graph, profiles: HallieBenchDependencies.profiles(ownerName: f.rootName),
            speakers: Self.speakers(f), ledger: ledger)
        print("[hallie-bench] tree: \(f.graph.people.count) people, \(f.graph.familyCount) families")
        var deterministic = 0
        for question in Self.questions(f) {
            ledger.reset()
            let outcome = await Self.runTurn(question, dependencies: deps)
            if !outcome.modelRequired { deterministic += 1 }
            let calls = ledger.snapshot.calls
            let callSummary = calls.keys.sorted()
                .map { "\($0)×\(calls[$0] ?? 0)" }.joined(separator: " ")
            print(String(format: "[hallie-bench] %-16@ %7@ ms  %-12@ %-18@ %@",
                         outcome.label as NSString,
                         HallieBenchStats.ms(outcome.seconds) as NSString,
                         outcome.route as NSString,
                         outcome.outcome as NSString,
                         callSummary as NSString))
        }
        #expect(deterministic >= 6,
                Comment(rawValue: "only \(deterministic) of \(Self.questions(f).count) questions answered without a model — the bench would be measuring stubs"))
    }

    // MARK: 2. Single user

    @Test("single user: p50 / p95 / max per question, with a phase breakdown")
    func singleUserLatency() async {
        let f = Self.fixture
        let ledger = HalliePhaseLedger()
        let deps = HallieBenchDependencies.make(
            graph: f.graph, profiles: HallieBenchDependencies.profiles(ownerName: f.rootName),
            speakers: Self.speakers(f), ledger: ledger)
        let iterations = 20
        var all: [Double] = []
        var perQuestion: [String: [Double]] = [:]

        // Warm once: first-touch of a lazily built index is setup cost.
        for question in Self.questions(f) { _ = await Self.runTurn(question, dependencies: deps) }

        ledger.reset()
        let wall = ContinuousClock.now
        for _ in 0..<iterations {
            for question in Self.questions(f) {
                let outcome = await Self.runTurn(question, dependencies: deps)
                guard !outcome.modelRequired else { continue }
                perQuestion[outcome.label, default: []].append(outcome.seconds)
                all.append(outcome.seconds)
            }
        }
        let wallSeconds = HallieBenchClock.seconds(since: wall)

        print("[hallie-bench] SINGLE USER — \(iterations) iterations, \(HallieBenchStats.ms(wallSeconds)) ms wall")
        for label in perQuestion.keys.sorted() {
            print("[hallie-bench]   " + HallieBenchStats.line(label, perQuestion[label] ?? []))
        }
        print("[hallie-bench]   " + HallieBenchStats.line("ALL DETERMINISTIC TURNS", all))

        let (seconds, calls) = ledger.snapshot
        let turns = max(all.count, 1)
        print("[hallie-bench]   phase breakdown (per deterministic turn, \(turns) turns):")
        for phase in seconds.keys.sorted(by: { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }) {
            let total = seconds[phase] ?? 0
            print(String(format: "[hallie-bench]     %-22@ %8@ ms/turn  %.2f calls/turn  (%.1f%% of turn time)",
                         phase as NSString,
                         HallieBenchStats.ms(total / Double(turns)) as NSString,
                         Double(calls[phase] ?? 0) / Double(turns),
                         100 * total / max(all.reduce(0, +), 1e-9)))
        }

        #expect(!all.isEmpty)
        // Loose, always-on ceiling. A deterministic tree answer is index
        // lookups and a bounded walk; a full scan of 16,383 people per turn
        // is the regression worth catching, and it is nowhere near this.
        let p95 = HallieBenchStats.percentile(all, 95)
        #expect(p95 < 2.0,
                Comment(rawValue: "deterministic p95 \(HallieBenchStats.ms(p95)) ms — that is scan-shaped"))
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(p95 < 0.100,
                    Comment(rawValue: "Release budget: deterministic p95 \(HallieBenchStats.ms(p95)) ms"))
        } else {
            print("[hallie-bench]   \(PerformanceLane.explanation(optInKey: Self.performanceOptIn))")
        }
    }

    // MARK: 3. Multi user

    struct ConcurrencyPoint: Sendable {
        let k: Int
        let p50: Double
        let p95: Double
        let max: Double
        let throughput: Double
        let hopP50: Double
        let hopP95: Double
        let hopMax: Double
    }

    static func measureConcurrency(
        k: Int,
        turnsPerSession: Int,
        dependencies: HallieAppTurnCoordinator.Dependencies,
        questions: [Question]
    ) async -> ConcurrencyPoint {
        let probe = MainActorHopProbe()
        probe.start()
        let wall = ContinuousClock.now
        let latencies = await withTaskGroup(of: [Double].self) { group in
            for session in 0..<k {
                group.addTask {
                    var out: [Double] = []
                    for turn in 0..<turnsPerSession {
                        let question = questions[(session + turn) % questions.count]
                        let outcome = await runTurn(question, dependencies: dependencies)
                        if !outcome.modelRequired { out.append(outcome.seconds) }
                    }
                    return out
                }
            }
            var all: [Double] = []
            for await batch in group { all.append(contentsOf: batch) }
            return all
        }
        let wallSeconds = HallieBenchClock.seconds(since: wall)
        let hops = probe.stop()
        return ConcurrencyPoint(
            k: k,
            p50: HallieBenchStats.percentile(latencies, 50),
            p95: HallieBenchStats.percentile(latencies, 95),
            max: latencies.max() ?? 0,
            throughput: Double(latencies.count) / max(wallSeconds, 1e-9),
            hopP50: HallieBenchStats.percentile(hops, 50),
            hopP95: HallieBenchStats.percentile(hops, 95),
            hopMax: hops.max() ?? 0)
    }

    @Test("multi user: K = 1, 2, 5, 10 concurrent sessions — latency, throughput, main-actor hop")
    func multiUserScaling() async {
        let f = Self.fixture
        let ledger = HalliePhaseLedger()
        let deps = HallieBenchDependencies.make(
            graph: f.graph, profiles: HallieBenchDependencies.profiles(ownerName: f.rootName),
            speakers: Self.speakers(f), ledger: ledger)
        // Deterministic questions only: a model-required turn returns
        // instantly from the stub and would flatter the curve.
        var deterministic: [Question] = []
        for question in Self.questions(f) {
            let outcome = await Self.runTurn(question, dependencies: deps)
            if !outcome.modelRequired { deterministic.append(question) }
        }
        #expect(deterministic.count >= 6)

        var points: [ConcurrencyPoint] = []
        for k in [1, 2, 5, 10] {
            let point = await Self.measureConcurrency(
                k: k, turnsPerSession: 12, dependencies: deps, questions: deterministic)
            points.append(point)
            print(String(format: "[hallie-bench] MULTI K=%-3d p50 %8@ ms  p95 %8@ ms  max %8@ ms  %7.1f turns/s   main-actor hop p50 %7@ ms p95 %7@ ms max %7@ ms",
                         point.k,
                         HallieBenchStats.ms(point.p50) as NSString,
                         HallieBenchStats.ms(point.p95) as NSString,
                         HallieBenchStats.ms(point.max) as NSString,
                         point.throughput,
                         HallieBenchStats.ms(point.hopP50) as NSString,
                         HallieBenchStats.ms(point.hopP95) as NSString,
                         HallieBenchStats.ms(point.hopMax) as NSString))
        }

        guard let one = points.first, let ten = points.last else {
            Issue.record("no concurrency points measured")
            return
        }
        let scaling = ten.throughput / max(one.throughput, 1e-9)
        print(String(format: "[hallie-bench] scaling K=1 → K=10: throughput ×%.2f (perfect = ×10), p95 ×%.1f",
                     scaling, ten.p95 / max(one.p95, 1e-9)))
        // Structural, not a budget: more sessions must never make the
        // system do LESS total work. If this fires, concurrency is actively
        // harmful and the architecture question is no longer theoretical.
        #expect(ten.throughput >= one.throughput * 0.75,
                Comment(rawValue: String(format: "throughput collapsed from %.1f to %.1f turns/s at K=10",
                                         one.throughput, ten.throughput)))
    }

    // MARK: 4. Multi user through the web bridge

    /// The same curve through the code the iPad actually hits:
    /// `HallieWebBridge.handle` → `ask` → the coordinator. The bridge is
    /// `@MainActor` and keeps a per-device session dictionary, so this is
    /// where main-actor serialisation would show up if it is going to.
    /// Compare the numbers with `multiUserScaling`: the difference between
    /// the two IS the bridge's cost.
    @Test("multi user through HallieWebBridge: same K sweep, one session per device")
    func multiUserThroughWebBridge() async {
        let f = Self.fixture
        let ledger = HalliePhaseLedger()
        let deps = HallieBenchDependencies.make(
            graph: f.graph, profiles: HallieBenchDependencies.profiles(ownerName: f.rootName),
            speakers: Self.speakers(f), ledger: ledger)
        var deterministic: [Question] = []
        for question in Self.questions(f) {
            let outcome = await Self.runTurn(question, dependencies: deps)
            if !outcome.modelRequired { deterministic.append(question) }
        }

        let bridge = await MainActor.run {
            HallieWebBridge(
                records: { Self.records },
                record: { _ in nil },
                configuration: {
                    .init(passphrase: "", archivistName: "Hallie Mae",
                          archivistPersonName: nil, hosts: ["bench.invalid"],
                          modelName: "bench-model", composeWithModel: false)
                },
                dependencies: deps)
        }

        func ask(session: String, text: String) async -> Double {
            let body = try? JSONSerialization.data(
                withJSONObject: ["session": session, "text": text])
            let request = HallieHTTPRequest(
                method: "POST", path: "/api/ask", query: [:],
                headers: ["content-type": "application/json"], body: body ?? Data())
            let start = ContinuousClock.now
            _ = await bridge.handle(request, peer: "bench")
            return HallieBenchClock.seconds(since: start)
        }

        // Warm the bridge's session map and any first-touch index.
        _ = await ask(session: "warm", text: deterministic[0].text)

        var first: Double = 0
        for k in [1, 2, 5, 10] {
            let probe = MainActorHopProbe()
            probe.start()
            let wall = ContinuousClock.now
            let latencies = await withTaskGroup(of: [Double].self) { group in
                for session in 0..<k {
                    group.addTask {
                        var out: [Double] = []
                        for turn in 0..<12 {
                            out.append(await ask(
                                session: "device-\(session)",
                                text: deterministic[(session + turn) % deterministic.count].text))
                        }
                        return out
                    }
                }
                var all: [Double] = []
                for await batch in group { all.append(contentsOf: batch) }
                return all
            }
            let wallSeconds = HallieBenchClock.seconds(since: wall)
            let hops = probe.stop()
            let throughput = Double(latencies.count) / max(wallSeconds, 1e-9)
            if k == 1 { first = throughput }
            print(String(format: "[hallie-bench] BRIDGE K=%-3d p50 %8@ ms  p95 %8@ ms  max %8@ ms  %7.1f turns/s   main-actor hop p50 %7@ ms p95 %7@ ms max %7@ ms",
                         k,
                         HallieBenchStats.ms(HallieBenchStats.percentile(latencies, 50)) as NSString,
                         HallieBenchStats.ms(HallieBenchStats.percentile(latencies, 95)) as NSString,
                         HallieBenchStats.ms(latencies.max() ?? 0) as NSString,
                         throughput,
                         HallieBenchStats.ms(HallieBenchStats.percentile(hops, 50)) as NSString,
                         HallieBenchStats.ms(HallieBenchStats.percentile(hops, 95)) as NSString,
                         HallieBenchStats.ms(hops.max() ?? 0) as NSString))
            if k == 10 {
                print(String(format: "[hallie-bench] bridge scaling K=1 → K=10: throughput x%.2f", throughput / max(first, 1e-9)))
                #expect(throughput >= first * 0.75,
                        Comment(rawValue: String(format: "bridge throughput collapsed from %.1f to %.1f turns/s at K=10", first, throughput)))
            }
        }
    }
}
