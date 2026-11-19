//
//  CorpusUITests.swift
//  VideoScanUITests — the corpus UI lane (scripts/corpus_ui_lane.py)
//
//  The REAL app, driven through XCUITest on the M4, against the real-data
//  corpus's sealed catalog (GauntletCorpusCatalog.swift: read-only, sealed to
//  the M4, ~/corpus/state, a HOME inside the run's folder under ~/corpus/work).
//
//  PRIVACY (the corpus is real family media). Every fact is read through
//  accessibility VALUES and IDENTIFIERS and reported as counts and words:
//    * no screenshot on failure (`screenshotOnFailure` is false), and the
//      VideoScan-CorpusUI plan keeps no attachments of any kind;
//    * no assertion message, print or log line carries a row's text — only
//      counts, step names, timings and the seed;
//    * never the Archivist (Hallie) button: nothing of the corpus goes near
//      a model.
//  Lines the lane reads back start with `[corpus-ui] ` and hold words and
//  numbers only (`report`).
//
//  Gated twice: VS_GAUNTLET=1 (GauntletTestCase) and VS_UI_CORPUS=1 with the
//  catalog/home/tmp paths, all set ONLY by the lane's patched .xctestrun. A
//  plain `xcodebuild test` skips every case.
//
//  The monkey (`test3_seededMonkey`): a seeded random walk over safe UI actions
//  (Show filters, search words that are not from the data, row clicks,
//  Select All, arrows, tab switches). After every step: the app is alive, the
//  Showing box still parses, its TOTAL never moves (the total is every row with
//  every user narrowing off — no filter or search may change it), and the step
//  ran inside its time budget. A finding prints its seed and step, so
//  `VS_UI_CORPUS_SEED=<seed> VS_UI_CORPUS_STEPS=<step+1>` replays it.
//

import XCTest

final class CorpusUITests: GauntletTestCase {

    override var screenshotOnFailure: Bool { false }

    /// Per-step budget: a step that takes longer is a hang finding.
    private static let stepBudget: TimeInterval = 20
    /// The first catalog load (234 records today) and the table's first pass.
    private static let loadBudget: TimeInterval = 120
    /// Never a word from the data: the search must find nothing.
    private static let nonsense = "zqxj7731nosuchthing"
    /// The Show filters by their menu words (CatalogViewFilter.title).
    private static let filters = ["Audio Only", "Videos with Sound", "Videos Missing Sound",
                                  "Not Yet Archived", "Needs a Date", "Hide Other Versions"]
    /// Search words the monkey types: generic, never taken from the corpus.
    private static let searchWords = ["a", "e", "mov", "mp4", "dv", "19", "200", "x", "zz", nonsense]

    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(env["VS_UI_CORPUS"] == "1",
                          "Corpus UI cases run only from the corpus UI lane (VS_UI_CORPUS=1).")
        for key in ["VS_UI_CORPUS_CATALOG", "VS_UI_CORPUS_HOME", "VS_UI_CORPUS_TMP"] where (env[key] ?? "").isEmpty {
            throw XCTSkip("the corpus UI lane did not set \(key)")
        }
    }

    // MARK: - 1. Show filter, search, Select All against the Showing box count

    @MainActor
    func test1_showingCountFollowsFiltersSearchAndSelection() throws {
        let app = launchCorpusApp()
        let base = try waitForLoadedCount(app)
        report("loaded", ["total": base.total, "shown": base.shown, "bare": base.bare ? 1 : 0])
        XCTAssertTrue(base.bare, "At launch nothing narrows the list, so the box must read the bare total; it reads \(base.shown) of \(base.total).")
        let rowsAtLaunch = fileRowCount(app)
        report("rows_at_launch", ["rows": rowsAtLaunch, "shown": base.shown])
        XCTAssertEqual(rowsAtLaunch, base.shown, "The files table lists \(rowsAtLaunch) rows; the box says \(base.shown).")

        // Tick Show ▸ Videos with Sound: "N of M", and N is the table's rows.
        try step("tick_videos_with_sound") { try toggleShowItem(app, "Videos with Sound") }
        let ticked = try waitForCount(app, "after ticking Videos with Sound") { !$0.bare || $0.shown != base.shown }
        let rowsTicked = fileRowCount(app)
        report("ticked", ["shown": ticked.shown, "total": ticked.total, "rows": rowsTicked, "bare": ticked.bare ? 1 : 0])
        XCTAssertFalse(ticked.bare, "With Videos with Sound ticked the box must read N of M.")
        XCTAssertEqual(ticked.total, base.total, "A Show filter must not change the total.")
        XCTAssertEqual(rowsTicked, ticked.shown, "With Videos with Sound ticked the table lists \(rowsTicked) rows; the box says \(ticked.shown).")

        // Untick: the bare total again.
        try step("untick_videos_with_sound") { try toggleShowItem(app, "Videos with Sound") }
        let unticked = try waitForCount(app, "after unticking Videos with Sound") { $0.bare }
        report("unticked", ["shown": unticked.shown, "total": unticked.total, "bare": unticked.bare ? 1 : 0])
        XCTAssertTrue(unticked.bare, "Unticked, the box must read the bare total.")
        XCTAssertEqual(unticked.total, base.total)

        // A nonsense search: "0 of M", and an empty table.
        try step("search_nonsense") { try typeSearch(app, Self.nonsense) }
        let searched = try waitForCount(app, "after a nonsense search") { $0.shown == 0 }
        let rowsSearched = fileRowCount(app)
        report("searched", ["shown": searched.shown, "total": searched.total, "rows": rowsSearched])
        XCTAssertEqual(searched.shown, 0)
        XCTAssertFalse(searched.bare, "A search that narrows to nothing must read 0 of M.")
        XCTAssertEqual(searched.total, base.total, "A search must not change the total.")
        XCTAssertEqual(rowsSearched, 0)
        try step("search_clear") { try clearSearch(app) }
        let cleared = try waitForCount(app, "after clearing the search") { $0.bare }
        XCTAssertEqual(cleared.shown, base.shown)

        // Select All: the lower-left "N selected" is every listed row.
        try step("select_all") {
            try clickRow(app, 0)
            app.typeKey("a", modifierFlags: .command)
        }
        let selected = try waitForSelectionCount(app, equalTo: cleared.shown)
        report("selected", ["selected": selected ?? -1, "shown": cleared.shown])
        XCTAssertEqual(selected, cleared.shown, "Select All selected \(selected.map(String.init) ?? "none"); the box lists \(cleared.shown).")
    }

    // MARK: - 2. Every main tab opens and the Catalog comes back, inside the budget

    @MainActor
    func test2_mainTabsOpenAndReturnWithoutAHang() throws {
        let app = launchCorpusApp()
        let base = try waitForLoadedCount(app)
        let tabs = mainTabs(app)
        report("tabs", ["count": tabs.count])
        XCTAssertGreaterThanOrEqual(tabs.count, 3, "Fewer than three main tabs were found.")
        for (index, tab) in tabs.enumerated() where tab != "tab.Catalog" {
            try step("tab_\(index)_open") { app.buttons[tab].click() }
            XCTAssertEqual(app.state, .runningForeground, "The app is not running after opening tab \(index).")
            try step("tab_\(index)_back") {
                app.buttons["tab.Catalog"].click()
                guard showingBox(app).waitForExistence(timeout: Self.stepBudget) else {
                    throw StepFailure("the Catalog did not come back")
                }
            }
        }
        let after = try waitForLoadedCount(app)
        XCTAssertEqual(after.total, base.total, "Switching tabs changed the catalog total.")
    }

    // MARK: - 3. The seeded monkey

    @MainActor
    func test3_seededMonkey() throws {
        let seed = UInt64(env["VS_UI_CORPUS_SEED"] ?? "") ?? 20261118
        let steps = Int(env["VS_UI_CORPUS_STEPS"] ?? "") ?? 120
        var rng = SplitMix64(seed: seed)
        let app = launchCorpusApp()
        let base = try waitForLoadedCount(app)
        let tabs = mainTabs(app).filter { $0 != "tab.Catalog" }
        report("monkey_start", ["seed": Int(truncatingIfNeeded: seed), "steps": steps, "total": base.total])
        var actions: [String: Int] = [:]
        for index in 0..<steps {
            let action = MonkeyAction.allCases[Int(rng.next() % UInt64(MonkeyAction.allCases.count))]
            actions[action.rawValue.lowercased(), default: 0] += 1
            let started = Date()
            do {
                try perform(action, app: app, rng: &rng, tabs: tabs)
            } catch {
                report("monkey_finding", ["seed": Int(truncatingIfNeeded: seed), "step": index], word: "action_failed_\(action.rawValue)")
                XCTFail("Monkey seed \(seed) step \(index) (\(action.rawValue)): \(error)")
                return
            }
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            guard app.state == .runningForeground else {
                report("monkey_finding", ["seed": Int(truncatingIfNeeded: seed), "step": index], word: "app_not_running_after_\(action.rawValue)")
                XCTFail("Monkey seed \(seed) step \(index) (\(action.rawValue)): the app is no longer running.")
                return
            }
            if Double(ms) > Self.stepBudget * 1000 {
                report("monkey_finding", ["seed": Int(truncatingIfNeeded: seed), "step": index, "ms": ms], word: "over_budget_\(action.rawValue)")
                XCTFail("Monkey seed \(seed) step \(index) (\(action.rawValue)) took \(ms) ms, budget \(Int(Self.stepBudget * 1000)).")
                return
            }
            // Back on the Catalog, the total never moves.
            if !showingBox(app).exists { app.buttons["tab.Catalog"].click() }
            guard let now = readCount(app) else {
                report("monkey_finding", ["seed": Int(truncatingIfNeeded: seed), "step": index], word: "showing_box_unreadable")
                XCTFail("Monkey seed \(seed) step \(index): the Showing box count did not parse.")
                return
            }
            if now.total != base.total || now.shown > now.total {
                report("monkey_finding", ["seed": Int(truncatingIfNeeded: seed), "step": index, "shown": now.shown,
                                          "total": now.total, "base_total": base.total], word: "count_invariant")
                XCTFail("Monkey seed \(seed) step \(index) (\(action.rawValue)): the box reads \(now.shown) of \(now.total); the total was \(base.total).")
                return
            }
            report("monkey_step", ["step": index, "ms": ms, "shown": now.shown], word: action.rawValue)
        }
        report("monkey_done", actions.merging(["steps": steps]) { $1 })
    }

    // MARK: - Monkey actions (safe ones only: nothing that writes, moves or asks a model)

    private enum MonkeyAction: String, CaseIterable {
        case toggleFilter, search, clearSearch, clickRow, selectAll, arrows, switchTab, clearFilters
    }

    @MainActor
    private func perform(_ action: MonkeyAction, app: XCUIApplication, rng: inout SplitMix64, tabs: [String]) throws {
        switch action {
        case .toggleFilter:
            try toggleShowItem(app, Self.filters[Int(rng.next() % UInt64(Self.filters.count))])
        case .search:
            try typeSearch(app, Self.searchWords[Int(rng.next() % UInt64(Self.searchWords.count))])
        case .clearSearch:
            try clearSearch(app)
        case .clickRow:
            let rows = fileRowCount(app)
            if rows > 0 { try clickRow(app, Int(rng.next() % UInt64(min(rows, 25)))) }
        case .selectAll:
            if fileRowCount(app) > 0 {
                try clickRow(app, 0)
                app.typeKey("a", modifierFlags: .command)
            }
        case .arrows:
            if fileRowCount(app) > 0 {
                try clickRow(app, 0)
                for _ in 0..<(1 + Int(rng.next() % 4)) {
                    app.typeKey(rng.next() % 2 == 0 ? .downArrow : .upArrow, modifierFlags: [])
                }
            }
        case .switchTab:
            guard !tabs.isEmpty else { return }
            app.buttons[tabs[Int(rng.next() % UInt64(tabs.count))]].click()
            app.buttons["tab.Catalog"].click()
            guard showingBox(app).waitForExistence(timeout: Self.stepBudget) else {
                throw StepFailure("the Catalog did not come back")
            }
        case .clearFilters:
            showMenu(app).click()
            let item = app.menuItems.matching(NSPredicate(format: "title == %@", "Clear All Filters")).firstMatch
            if item.waitForExistence(timeout: 2) { item.click() } else { app.typeKey(.escape, modifierFlags: []) }
        }
    }

    // MARK: - Launch

    @MainActor
    private func launchCorpusApp() -> XCUIApplication {
        let app = launchGauntletApp(
            seams: ["gauntletCorpusCatalog": env["VS_UI_CORPUS_CATALOG"] ?? ""],
            environment: ["HOME": env["VS_UI_CORPUS_HOME"] ?? "", "CFFIXED_USER_HOME": env["VS_UI_CORPUS_HOME"] ?? "",
                          "TMPDIR": env["VS_UI_CORPUS_TMP"] ?? ""])
        openTab(app, "Catalog", timeout: 90)
        return app
    }

    // MARK: - Reading the Showing box (its accessibility value: "1,247 of 18,903" or "18,903")

    struct Count: Equatable {
        var shown: Int
        var total: Int
        var bare: Bool
    }

    /// Pure parse of the box's value; nil for "" (before the first pass) or anything else.
    nonisolated static func parseCount(_ text: String) -> Count? {
        let digits = { (s: Substring) -> Int? in Int(s.replacingOccurrences(of: ",", with: "").trimmingCharacters(in: .whitespaces)) }
        let parts = text.components(separatedBy: " of ")
        if parts.count == 2, let shown = digits(Substring(parts[0])), let total = digits(Substring(parts[1])) {
            return Count(shown: shown, total: total, bare: false)
        }
        if parts.count == 1, let total = digits(Substring(text)) { return Count(shown: total, total: total, bare: true) }
        return nil
    }

    @MainActor
    private func showingBox(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["catalog.showingBox"].firstMatch
    }

    @MainActor
    private func readCount(_ app: XCUIApplication) -> Count? {
        let box = showingBox(app)
        guard box.exists, let value = box.value as? String else { return nil }
        return Self.parseCount(value)
    }

    @MainActor
    private func waitForCount(_ app: XCUIApplication, _ what: String, timeout: TimeInterval = CorpusUITests.stepBudget,
                              _ accept: (Count) -> Bool) throws -> Count {
        let deadline = Date().addingTimeInterval(timeout)
        var last: Count?
        while Date() < deadline {
            if let now = readCount(app) {
                last = now
                if accept(now) { return now }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        report("count_timeout", ["shown": last?.shown ?? -1, "total": last?.total ?? -1], word: StepFailure.word(what))
        throw StepFailure("the Showing box never settled \(what) (last: \(last.map { "\($0.shown) of \($0.total)" } ?? "unreadable"))")
    }

    /// The first count with a total above zero: the corpus catalog arrived
    /// and the table ran its first pass. A seal refusal leaves the box empty.
    @MainActor
    private func waitForLoadedCount(_ app: XCUIApplication) throws -> Count {
        try waitForCount(app, "with the corpus catalog loaded (a seal refusal leaves it empty)",
                         timeout: Self.loadBudget) { $0.total > 0 }
    }

    // MARK: - The files table

    @MainActor
    private func filesTable(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["catalog.filesTable"].firstMatch
    }

    @MainActor
    private func rowsQuery(_ table: XCUIElement) -> XCUIElementQuery {
        table.outlineRows.firstMatch.exists ? table.outlineRows : table.tableRows
    }

    @MainActor
    private func fileRowCount(_ app: XCUIApplication) -> Int {
        let table = filesTable(app)
        guard table.waitForExistence(timeout: 10) else { return -1 }
        return rowsQuery(table).count
    }

    /// A click at the centre of the row's first text (the Filename cell —
    /// never a status button), by coordinate so no row text is named.
    @MainActor
    private func clickRow(_ app: XCUIApplication, _ index: Int) throws {
        let row = rowsQuery(filesTable(app)).element(boundBy: index)
        guard row.waitForExistence(timeout: 10) else { throw StepFailure("row \(index) missing") }
        let text = row.staticTexts.firstMatch
        let target = text.exists ? text : row
        target.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    @MainActor
    private func waitForSelectionCount(_ app: XCUIApplication, equalTo want: Int) throws -> Int? {
        let label = app.staticTexts["catalog.preview.selectionCount"].firstMatch
        let deadline = Date().addingTimeInterval(Self.stepBudget)
        var got: Int?
        while Date() < deadline {
            if label.exists {
                let text = (label.value as? String).flatMap { $0.isEmpty ? nil : $0 } ?? label.label
                got = Int(text.replacingOccurrences(of: " selected", with: "").replacingOccurrences(of: ",", with: ""))
                if got == want { return got }
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        return got
    }

    // MARK: - Menus, search, tabs

    @MainActor
    private func showMenu(_ app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["catalog.showMenu"].firstMatch
    }

    /// Open Show and click one item by its title (menu items carry no
    /// identifier; the titles are the menu's own words).
    @MainActor
    private func toggleShowItem(_ app: XCUIApplication, _ title: String) throws {
        let menu = showMenu(app)
        guard menu.waitForExistence(timeout: 10) else { throw StepFailure("the Show menu is missing") }
        menu.click()
        let item = app.menuItems.matching(NSPredicate(format: "title == %@", title)).firstMatch
        guard item.waitForExistence(timeout: 5) else {
            app.typeKey(.escape, modifierFlags: [])
            throw StepFailure("Show ▸ \(title) is missing")
        }
        item.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    @MainActor
    private func searchField(_ app: XCUIApplication) -> XCUIElement {
        let s = app.searchFields["catalog.searchField"].firstMatch
        return s.exists ? s : app.textFields["catalog.searchField"].firstMatch
    }

    @MainActor
    private func typeSearch(_ app: XCUIApplication, _ text: String) throws {
        let field = searchField(app)
        guard field.waitForExistence(timeout: 10) else { throw StepFailure("the search field is missing") }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text)
        Thread.sleep(forTimeInterval: 0.6)        // the 250 ms debounce, and the pass after it
    }

    @MainActor
    private func clearSearch(_ app: XCUIApplication) throws {
        let field = searchField(app)
        guard field.waitForExistence(timeout: 10) else { throw StepFailure("the search field is missing") }
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeKey(.delete, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// The main tab strip's identifiers, in screen order, never the
    /// Archivist (Hallie) — nothing of the corpus goes near a model.
    @MainActor
    private func mainTabs(_ app: XCUIApplication) -> [String] {
        let buttons = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'tab.'")).allElementsBoundByIndex
        var seen = Set<String>()
        return buttons.map(\.identifier).filter { $0 != "tab.Archivist" && seen.insert($0).inserted }
    }

    // MARK: - Steps and the lane's lines

    struct StepFailure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
        /// A step's words as one lane word (letters, digits, underscores).
        static func word(_ text: String) -> String {
            String(text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.prefix(60))
        }
    }

    /// Run one UI step under the per-step budget and say how long it took.
    @MainActor
    private func step(_ name: String, _ body: () throws -> Void) throws {
        let started = Date()
        try body()
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let over = Double(ms) > Self.stepBudget * 1000
        report("step", ["ms": ms, "budget_ms": Int(Self.stepBudget * 1000)], word: name + (over ? "_OVER" : ""))
        XCTAssertFalse(over, "Step \(name) took \(ms) ms; budget \(Int(Self.stepBudget * 1000)) ms.")
        XCTAssertEqual(app?.state, .runningForeground, "The app is not running after step \(name).")
    }

    /// One `[corpus-ui]` line: an event word, an optional word, numbers. The
    /// lane keeps only these lines, and only if they hold nothing else.
    private func report(_ event: String, _ numbers: [String: Int], word: String = "") {
        // Keys are lowercase words (the lane's UI_LINE); the case name is its method name.
        let fields = numbers.sorted { $0.key < $1.key }.map { "\(StepFailure.word($0.key))=\($0.value)" }
        let testCase = name.split(separator: " ").last.map(String.init)?
            .filter { $0.isLetter || $0.isNumber || $0 == "_" } ?? "case"
        let parts = [testCase, event] + (word.isEmpty ? [] : [StepFailure.word(word)]) + fields
        print("[corpus-ui] " + parts.joined(separator: " "))
    }
}

/// SplitMix64 — a tiny seeded PRNG so a monkey run replays from its seed
/// (≈ a C++ functor holding a uint64 state; `mutating` = it changes it).
struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
