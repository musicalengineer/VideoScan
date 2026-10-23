// FamilyTreeCardInvalidationSensorTests.swift
// GH #307 (Rick, 2026-10-10, Bonnie demo): right-click on a Family Tree
// card → the menu, especially "Research <name> elsewhere", flickered and
// could not be selected.
//
// Cause, measured with the counter below before the fix: FamilyTreeView
// declared `@EnvironmentObject VideoScanModel`, so EVERY catalog publish
// (promote progress, CatalogSync, an Archive Angel pass, the cache count —
// ~90 @Published properties plus explicit objectWillChange sends) re-ran
// the tree's body. The person cards are not diffable (they carry closures),
// so each pass rebuilt all of them, and SwiftUI builds `.contextMenu` with
// the card body — an open menu was torn down and rebuilt under the cursor.
// Probe numbers on a 15-card scene (Debug): 20 catalog publishes → +360
// card-menu builds; 20 dashboard console lines → 0; idle 2 s → 0.
// The Research run itself is innocent: ResearchPersonModel is owned by its
// own sheet and publishes only to it (pinned here too).
//
// The counter: `FamilyTreeLiveModel.researchLinksEvaluations` — one tick
// per card menu build, i.e. per card-body evaluation. Every test carries a
// positive control (the tree model's own publish DOES rebuild the cards)
// so a zero can never come from a dead sensor.
//
// Isolation: synthetic 400-person tree in a temp Sandbox; @AppStorage is
// routed to a throwaway suite; the window is ordered out (nothing on
// Rick's screen); the research run uses a fixed in-memory source.

import AppKit
import Combine
import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

/// What ContentView does: observe the catalog, rebuild the tree view's
/// inputs on every catalog change, `.equatable()` at the call site. Equal
/// inputs must not re-run the tree.
private struct CatalogObservingHost: View {
    @ObservedObject var catalog: VideoScanModel
    let model: FamilyTreeLiveModel
    let preferences: UserDefaults
    var body: some View {
        FamilyTreeView(model: model, catalog: catalog, preferences: preferences)
            .equatable()
    }
}

private struct FixedResearchSource: ResearchSource {
    let kind: ResearchSourceKind = .chroniclingAmerica
    let findings: [ResearchFinding]
    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] { findings }
}

@Suite("FamilyTreeCardInvalidationSensor", .serialized)
@MainActor
struct FamilyTreeCardInvalidationSensorTests {

    private typealias Sandbox = FamilyGraphCompiledStoreTests.Sandbox

    /// Everything a test needs alive for its duration.
    @MainActor
    private struct Mounted {
        let box: Sandbox
        let model: FamilyTreeLiveModel
        let catalog: VideoScanModel
        let window: NSWindow
        var builds: Int { model.researchLinksEvaluations }
        func tearDown() { window.contentView = nil; box.tearDown() }
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    /// Mount the real FamilyTreeView, as production does: the catalog is
    /// ALSO in the environment, so any child that still subscribes to it
    /// would show up here.
    private static func mount(throughObservingParent: Bool = false) async throws -> Mounted {
        let box = try Sandbox()
        _ = try box.write(FamilyGraphCompiledStoreTests.tree)
        let model = FamilyTreeLiveModel(originalsDirectory: box.originals, compiledStore: box.store())
        await model.loadFromDisk()
        let suite = try #require(UserDefaults(suiteName: "FamilyTreeCardInvalidationSensor.\(UUID().uuidString)"))
        let catalog = VideoScanModel()
        let root: AnyView = throughObservingParent
            ? AnyView(CatalogObservingHost(catalog: catalog, model: model, preferences: suite))
            : AnyView(FamilyTreeView(model: model, catalog: catalog, preferences: suite))
        let host = NSHostingView(rootView: root.environmentObject(catalog).defaultAppStorage(suite))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        host.layoutSubtreeIfNeeded()
        try await settle(model)
        return Mounted(box: box, model: model, catalog: catalog, window: window)
    }

    /// Quiet intervals in a row before the mount counts as settled, and the
    /// most a mount may take. Measured 2026-10-22: idle, the mount builds
    /// 30 → 90 card menus in 3–4 passes of 15 (one extra pass — 105 — on the
    /// first mount in a process) and is quiet within ~1 s.
    static let quietIntervalsRequired = 8
    static let settleCap: Duration = .seconds(30)

    /// Wait until the tree's mount-time work has stopped building cards.
    ///
    /// The background fills (load-on-appear, CyberBrain, birth-country
    /// flags at .utility priority, document counts) hop back to the main
    /// actor, and those hops run ONLY while this test is suspended: `pump`
    /// is a nested run loop inside a main-actor job, which does not drain
    /// the main queue. The old settle ("unchanged across one 150 ms sleep")
    /// was fooled under load (GH #307 sensor flake, 2026-10-22): in the
    /// parallel sensor lane other @MainActor tests hold the main queue and
    /// the pool is busy, a fill lands after one quiet window, and its pass
    /// of 15 card builds was counted against the catalog publishes
    /// ("105 vs 90"). Reproduced exactly by a main-actor hog.
    ///
    /// Now: the load is done, the flags build has finished, AND the counter
    /// has not moved for `quietIntervalsRequired` intervals in a row, each
    /// of which suspends (so pending hops can land) and pumps (so SwiftUI
    /// can render). Hitting the cap is a failure, never a pass.
    private static func settle(_ model: FamilyTreeLiveModel) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + settleCap
        var last = model.researchLinksEvaluations
        var quiet = 0
        while quiet < quietIntervalsRequired {
            guard clock.now < deadline else {
                // `Issue.record` + throw ≈ ADD_FAILURE() then return: the
                // test stops here, red, with the reason.
                let reason = "mount never settled: card builds still moving (\(model.researchLinksEvaluations)) "
                    + "after \(settleCap); loadState=\(model.loadState), "
                    + "flags build pending=\(model.birthCountriesTask != nil)"
                Issue.record("\(reason)")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(100))
            pump(0.05)
            let now = model.researchLinksEvaluations
            var loaded = false
            if case .loaded = model.loadState { loaded = true }
            let pipelineIdle = loaded && model.birthCountriesTask == nil
            quiet = (now == last && pipelineIdle) ? quiet + 1 : 0
            last = now
        }
    }

    /// Fire `count` publishes, each in its own run-loop turn (SwiftUI
    /// coalesces same-turn writes, which would hide the symptom).
    private static func publish(_ count: Int, _ send: () -> Void) async {
        for _ in 0..<count {
            send()
            await Task.yield()
            pump(0.02)
        }
        pump(0.3)
    }

    /// Positive control: the tree model's own publish re-runs the cards.
    private static func expectSensorIsLive(_ m: Mounted, sourceLocation: SourceLocation = #_sourceLocation) async {
        let before = m.builds
        await publish(3) { m.model.objectWillChange.send() }
        #expect(m.builds > before, "dead sensor: the tree model's own publish built no card menus",
                sourceLocation: sourceLocation)
    }

    @Test func catalogPublishesDoNotRebuildTheTreeCards() async throws {
        let m = try await Self.mount(); defer { m.tearDown() }
        #expect(!m.model.scene.cards.isEmpty)
        #expect(m.builds > 0, "mounting the tree builds each card's menu once")
        let before = m.builds
        await Self.publish(20) { m.catalog.objectWillChange.send() }
        #expect(m.builds == before,
                "20 catalog publishes rebuilt card menus \(m.builds - before) times — an open right-click menu flickers (GH #307)")
        await Self.expectSensorIsLive(m)
    }

    /// Production wiring: ContentView observes the catalog and constructs
    /// FamilyTreeView on every catalog change. The inputs are references
    /// and values that do not change, so the tree must not re-run.
    @Test func aParentObservingTheCatalogDoesNotRebuildTheTreeCards() async throws {
        let m = try await Self.mount(throughObservingParent: true); defer { m.tearDown() }
        #expect(m.builds > 0)
        let before = m.builds
        await Self.publish(20) { m.catalog.objectWillChange.send() }
        #expect(m.builds == before,
                "catalog publishes through an observing parent rebuilt card menus \(m.builds - before) times (GH #307)")
        await Self.expectSensorIsLive(m)
    }

    /// The run Rick saw in the log: a Research run's progress publishes on
    /// ResearchPersonModel only, never on anything the tree observes.
    @Test func aResearchRunDoesNotRebuildTheTreeCards() async throws {
        let m = try await Self.mount(); defer { m.tearDown() }
        let graph = GedcomFamilyGraph(gedcomText:
            "0 HEAD\n0 @I1@ INDI\n1 NAME Bessie /Macgregor/\n1 BIRT\n2 DATE 1892\n1 DEAT\n2 DATE 1960\n0 TRLR\n")
        let person = try #require(graph.people["@I1@"])
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let finding = ResearchFinding(source: .chroniclingAmerica, title: "Synthetic hit", date: nil,
                                      excerpt: "Synthetic excerpt", url: "https://example.invalid/307/1",
                                      retrievedAt: at)
        let research = ResearchPersonModel(
            subject: ResearchSubject(person: person),
            store: ResearchStore(peopleRoot: m.box.root.appendingPathComponent("People", isDirectory: true)),
            fetcher: FixtureResearchFetcher(fixtures: [], retrievedAt: at),
            speakerName: "Tester", record: { _ in throw CancellationError() },
            sources: { _ in [FixedResearchSource(findings: [finding])] },
            log: { _ in }, now: { at })
        research.load()
        let before = m.builds
        research.run()
        // Suspend (not a nested run loop): the run's merge hops back onto
        // the main actor, which a synchronous pump would keep busy.
        for _ in 0..<300 where research.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try #require(!research.isRunning, "the synthetic research run did not finish")
        Self.pump(0.3)
        #expect(research.findings.count == 1)
        #expect(m.builds == before,
                "a research run rebuilt card menus \(m.builds - before) times (GH #307)")
        await Self.expectSensorIsLive(m)
    }

    /// The production wiring the two mounted tests stand in for: ContentView
    /// builds the tab with `.equatable()`, and the tree view does not
    /// subscribe to the catalog. Code only (comments stripped).
    @Test func productionWiringKeepsTheCatalogOffTheTree() throws {
        let content = try SourceTree.code(of: SourceTree.appSource(named: "ContentView.swift"),
                                          named: "ContentView.swift")
        let call = try #require(content.range(of: "FamilyTreeView(sharedModel:"),
                                "ContentView no longer builds the Family Tree tab here")
        let tail = content[call.upperBound...].prefix(300)
        #expect(tail.contains(".equatable()"),
                "ContentView must build FamilyTreeView with .equatable() — without it every catalog publish rebuilds the tree's cards (GH #307)")
        let tree = try SourceTree.code(of: SourceTree.appSource(named: "FamilyTreeView.swift"),
                                       named: "FamilyTreeView.swift")
        let subscribes = tree.range(of: #"@(EnvironmentObject|ObservedObject|StateObject)[^\n]*:\s*VideoScanModel"#,
                                    options: .regularExpression)
        #expect(subscribes == nil, "FamilyTreeView.swift must not subscribe to VideoScanModel (GH #307)")
    }

    /// The four facts the tree reloads on still reach it: the parent's
    /// revision string moves when any one of them does.
    @Test func sourceRevisionFollowsTheCatalogFactsItEncodes() {
        let catalog = VideoScanModel()
        let base = FamilyTreeView.sourceRevision(of: catalog)
        catalog.masterArchiveIdentityMismatch = "synthetic mismatch"
        let mismatched = FamilyTreeView.sourceRevision(of: catalog)
        catalog.masterArchiveIdentityMismatch = nil
        catalog.isReadOnly = true
        let readOnly = FamilyTreeView.sourceRevision(of: catalog)
        #expect(Set([base, mismatched, readOnly]).count == 3)
        #expect(readOnly.hasSuffix("|readonly"))
    }
}
