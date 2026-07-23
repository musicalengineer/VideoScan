import Testing
import Foundation
@testable import VideoScan

// MARK: - Workflow tags + userNotes split tests (feature/tags-and-usernotes, 2026-07-23)
//
// Five-dimension checklist coverage:
//   1. Logic       — tag canonicalization / case-insensitive matching /
//                    toggle semantics, tag:/tags: + note: field tokens,
//                    the notes → userNotes migration rule.
//   2. Scale       — 100k Rick-shaped corpus decorated with tags +
//                    userNotes; settled-keystroke budgets (Release-only
//                    assertions, same shape as CatalogSearchBudgetSensor-
//                    Tests) + index/canonical agreement at scale.
//   3. Media matrix — N/A: this feature opens no media files (pure
//                    record-field + search logic).
//   4. Isolation   — the model-level test constructs VideoScanModel in
//                    the test host, where CatalogStore / search-index
//                    persistence are diverted to per-process temp dirs
//                    via TestEnvironment.isTestHost (the GH #123 seam);
//                    no test here can touch the real catalog.
//   5. Sensor      — machine notes (lines starting with "[") must NEVER
//                    surface in plain search, at 100k scale, via both
//                    the index and the canonical matcher. That guarantee
//                    is the reason the notes/userNotes split exists.

// MARK: - 1. Logic — WorkflowTags vocabulary + helpers

@Suite("WorkflowTags logic")
struct WorkflowTagsLogicTests {

    @Test func quickPickVocabularyIsStable() {
        #expect(WorkflowTags.quickPicks ==
                ["Follow Up", "Investigate", "Interesting", "Gold", "Fix Audio"])
    }

    @Test func canonicalizeSnapsQuickPickSpelling() {
        #expect(WorkflowTags.canonicalize("follow up") == "Follow Up")
        #expect(WorkflowTags.canonicalize("FOLLOW UP") == "Follow Up")
        #expect(WorkflowTags.canonicalize("  gold  ") == "Gold")
        #expect(WorkflowTags.canonicalize("fix audio") == "Fix Audio")
    }

    @Test func canonicalizeKeepsCustomSpellingTrimmed() {
        #expect(WorkflowTags.canonicalize("  Fix Color ") == "Fix Color")
        #expect(WorkflowTags.canonicalize("timmy's birthday") == "timmy's birthday")
    }

    @Test func canonicalizeRejectsWhitespaceOnly() {
        #expect(WorkflowTags.canonicalize("").isEmpty)
        #expect(WorkflowTags.canonicalize("   \n ").isEmpty)
    }

    @Test func containsIsCaseInsensitive() {
        let tags = ["Follow Up", "Fix Color"]
        #expect(WorkflowTags.contains(tags, "follow up"))
        #expect(WorkflowTags.contains(tags, "FIX COLOR"))
        #expect(!WorkflowTags.contains(tags, "Gold"))
    }

    @Test func addingDedupsCaseInsensitively() {
        var tags: [String] = []
        tags = WorkflowTags.adding("gold", to: tags)
        #expect(tags == ["Gold"])
        // Same tag in any case is a no-op — never two spellings at once.
        tags = WorkflowTags.adding("GOLD", to: tags)
        #expect(tags == ["Gold"])
        tags = WorkflowTags.adding("Fix Color", to: tags)
        #expect(tags == ["Gold", "Fix Color"])
        // Whitespace-only input never lands.
        tags = WorkflowTags.adding("  ", to: tags)
        #expect(tags == ["Gold", "Fix Color"])
    }

    @Test func removingIsCaseInsensitive() {
        let tags = ["Gold", "Fix Color"]
        #expect(WorkflowTags.removing("gold", from: tags) == ["Fix Color"])
        #expect(WorkflowTags.removing("FIX COLOR", from: tags) == ["Gold"])
        #expect(WorkflowTags.removing("absent", from: tags) == tags)
    }
}

// MARK: - 1. Logic — search tokens (tag: / tags: / note: union)

@Suite("WorkflowTags search tokens")
struct WorkflowTagSearchTokenTests {

    private func record(
        tags: [String] = [],
        userNotes: String = "",
        notes: String = ""
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip.mov"
        r.fullPath = "/Volumes/T/clip.mov"
        r.directory = "/Volumes/T"
        r.tags = tags
        r.userNotes = userNotes
        r.notes = notes
        return r
    }

    @Test func tokenizerRecognizesTagPrefix() {
        #expect(pfTokenizeSearchQuery("tag:gold") ==
                [.field(name: .tag, value: "gold")])
        #expect(pfTokenizeSearchQuery("tags:gold") ==
                [.field(name: .tag, value: "gold")])
    }

    @Test func tagTokenMatchesCaseInsensitiveSubstring() {
        let r = record(tags: ["Fix Audio"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "tag:fix"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "tag:AUDIO"))
        #expect(pfRecordFilenameOrPersonMatch(r, query: "tags:fix"))
        #expect(!pfRecordFilenameOrPersonMatch(r, query: "tag:gold"))
        // Universal matcher honors the same token.
        #expect(pfRecordMatchesQuery(r, query: "tag:fix"))
    }

    @Test func tagTokenOnUntaggedRecordMisses() {
        #expect(!pfRecordFilenameOrPersonMatch(record(), query: "tag:gold"))
    }

    @Test func customTagsMatchViaTokenAndPlainSearch() {
        let r = record(tags: ["Timmy's Birthday"])
        #expect(pfRecordFilenameOrPersonMatch(r, query: "tag:birthday"))
        // Tags are HUMAN signal — plain catalog-bar search finds them too.
        #expect(pfRecordFilenameOrPersonMatch(r, query: "birthday"))
    }

    @Test func noteTokenMatchesUserNotesOrLegacyNotesUnion() {
        // Human text now lives in userNotes…
        let migrated = record(userNotes: "check the wedding audio")
        #expect(pfRecordFilenameOrPersonMatch(migrated, query: "note:wedding"))
        #expect(pfRecordFilenameOrPersonMatch(migrated, query: "notes:wedding"))
        // …but anything still in legacy notes stays findable via the
        // same token — nothing previously findable becomes unfindable.
        let legacy = record(notes: "[mov @ 0x0] moov atom not found")
        #expect(pfRecordFilenameOrPersonMatch(legacy, query: "note:moov"))
        #expect(pfRecordMatchesQuery(legacy, query: "note:moov"))
    }

    @Test func userNotesJoinPlainSearchButMachineNotesDoNot() {
        let human = record(userNotes: "grampa waves at the camera")
        #expect(pfRecordFilenameOrPersonMatch(human, query: "grampa"))
        // Machine notes stay OUT of plain search — the point of the split.
        let machine = record(notes: "[mov @ 0x7f8] moov atom not found")
        #expect(!pfRecordFilenameOrPersonMatch(machine, query: "moov"))
    }

    @Test func userNotesStayFindableInUniversalSearch() {
        // Universal search always substring-matched `notes`; after the
        // migration moves human text to userNotes it must keep matching.
        let r = record(userNotes: "brockton parade footage")
        #expect(pfRecordMatchesQuery(r, query: "parade"))
    }
}

// MARK: - 1. Logic — notes → userNotes migration rule

@Suite("UserNotesMigration")
struct UserNotesMigrationTests {

    @Test func pureHumanNoteMovesWholesale() {
        let result = UserNotesMigration.migrate(
            notes: "check this one — Donna at the cottage", userNotes: "")
        #expect(result?.userNotes == "check this one — Donna at the cottage")
        #expect(result?.notes.isEmpty == true)
    }

    @Test func pureMachineNoteStaysPut() {
        let machine = "[mov,mp4,m4a @ 0x7f8] moov atom not found"
        #expect(UserNotesMigration.migrate(notes: machine, userNotes: "") == nil)
    }

    @Test func multiLineMachineNoteStaysPut() {
        let machine = "[mxf @ 0x1] no video stream\n[mxf @ 0x1] essence parse error"
        #expect(UserNotesMigration.migrate(notes: machine, userNotes: "") == nil)
    }

    @Test func mixedNoteSplitsByLine() {
        let mixed = "[mov @ 0x0] moov atom not found\nask Breen about this tape\n[mov @ 0x0] partial file"
        let result = UserNotesMigration.migrate(notes: mixed, userNotes: "")
        #expect(result?.userNotes == "ask Breen about this tape")
        #expect(result?.notes == "[mov @ 0x0] moov atom not found\n[mov @ 0x0] partial file")
    }

    @Test func multiLineHumanNoteSurvivesIntact() {
        let human = "first thought\n\nsecond paragraph"
        let result = UserNotesMigration.migrate(notes: human, userNotes: "")
        #expect(result?.userNotes == human)
        #expect(result?.notes.isEmpty == true)
    }

    @Test func alreadyMigratedRecordIsUntouched() {
        // userNotes non-empty → gate never fires, whatever notes holds.
        #expect(UserNotesMigration.migrate(
            notes: "human-looking text", userNotes: "existing note") == nil)
    }

    @Test func emptyNotesIsNoOp() {
        #expect(UserNotesMigration.migrate(notes: "", userNotes: "") == nil)
    }

    @Test func migrationIsIdempotent() {
        // Apply, then apply again to the RESULT — second pass must be nil
        // for every shape (the "idempotent by construction" claim).
        let shapes = [
            "just a human note",
            "[machine] only",
            "[machine] line\nhuman line",
        ]
        for notes in shapes {
            guard let first = UserNotesMigration.migrate(notes: notes, userNotes: "") else {
                continue  // nothing moved — trivially idempotent
            }
            #expect(UserNotesMigration.migrate(
                notes: first.notes, userNotes: first.userNotes) == nil,
                "second migration pass must be a no-op for '\(notes)'")
        }
    }
}

// MARK: - 4. Isolation — model-level mutation path (test-host seams)

@MainActor
@Suite("WorkflowTags model path")
struct WorkflowTagsModelTests {

    private func makeRecord(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        return r
    }

    /// setTag applies across the whole selection (mixed → apply to all)
    /// and the search index reflects the mutation immediately — the
    /// dossier-writeback update(_:) contract.
    @Test func setTagAppliesToMixedSelectionAndUpdatesIndex() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        let b = makeRecord("/Volumes/T/b.mov")
        b.tags = ["Gold"]                       // mixed selection
        model.records = [a, b]
        model.searchIndex.rebuild(records: model.records)

        model.setTag("Gold", on: [a, b], present: true)
        #expect(a.tags == ["Gold"])
        #expect(b.tags == ["Gold"])             // no duplicate
        #expect(model.searchIndex.filter(records: model.records, query: "tag:gold").count == 2)
        #expect(model.searchIndex.filter(records: model.records, query: "gold").count == 2)

        model.setTag("Gold", on: [a, b], present: false)
        #expect(a.tags.isEmpty && b.tags.isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "tag:gold").isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "gold").isEmpty)
    }

    @Test func addCustomTagCanonicalizesAndRemoveAllClears() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.addTag("  fix audio ", to: [a])   // quick-pick spelling snap
        #expect(a.tags == ["Fix Audio"])
        model.addTag("Fix Color", to: [a])
        #expect(a.tags == ["Fix Audio", "Fix Color"])

        model.removeAllTags(from: [a])
        #expect(a.tags.isEmpty)
        #expect(model.searchIndex.filter(records: model.records, query: "tag:fix").isEmpty)
    }

    @Test func setUserNotesUpdatesIndexImmediately() {
        let model = VideoScanModel()
        let a = makeRecord("/Volumes/T/a.mov")
        model.records = [a]
        model.searchIndex.rebuild(records: model.records)

        model.setUserNotes("ask Donna about this reel", for: a)
        #expect(a.userNotes == "ask Donna about this reel")
        #expect(model.searchIndex.filter(records: model.records, query: "reel").count == 1)
        #expect(model.searchIndex.filter(records: model.records, query: "note:donna").count == 1)
    }

    @Test func migrateLegacyUserNotesMovesHumanTextOnce() {
        let model = VideoScanModel()
        let human = makeRecord("/Volumes/T/h.mov")
        human.notes = "human comment about the tape"
        let machine = makeRecord("/Volumes/T/m.mov")
        machine.notes = "[mov @ 0x0] moov atom not found"
        let mixed = makeRecord("/Volumes/T/x.mov")
        mixed.notes = "[mxf @ 0x1] parse error\nrescued from MacPro"
        model.records = [human, machine, mixed]

        #expect(model.migrateLegacyUserNotes() == 2)
        #expect(human.userNotes == "human comment about the tape" && human.notes.isEmpty)
        #expect(machine.userNotes.isEmpty && machine.notes == "[mov @ 0x0] moov atom not found")
        #expect(mixed.userNotes == "rescued from MacPro")
        #expect(mixed.notes == "[mxf @ 0x1] parse error")
        // Second pass: nothing left to move.
        #expect(model.migrateLegacyUserNotes() == 0)
    }
}

// MARK: - 2 + 5. Scale + sensor — 100k Rick-shaped corpus

@MainActor
@Suite("WorkflowTags scale + sensor", .serialized)
struct WorkflowTagsScaleSensorTests {

    /// One big test so the 100k corpus + index build happen once (same
    /// shape as CatalogSearchBudgetSensorTests). Decorates the bench
    /// corpus with tags, userNotes, AND machine notes, then pins:
    ///   * budgets for a plain query, a tag-word query, and a tag:
    ///     field query (Release-only, same interim numbers as the
    ///     GH #123 sensor: 165 ms linear-regime ceiling);
    ///   * index ≡ canonical agreement for tag + userNotes queries;
    ///   * SENSOR: machine "[" notes never surface in plain search —
    ///     via the index AND the canonical matcher — at 100k records.
    @Test func taggedCorpusBudgetsAgreementAndMachineNoteSensorAt100k() {
        let clock = ContinuousClock()
        let corpus = CatalogSearchProfileBench.makeRickShapedCorpus(100_000)
        // Decorate: every 100th record gets a tag + a user note; every
        // 50th gets a machine probe note. "zorply" is a nonsense word
        // guaranteed absent from the generator's vocabulary, so the
        // sensor needle can only ever match via the notes field.
        for (i, rec) in corpus.enumerated() {
            if i % 100 == 0 {
                rec.tags = (i % 200 == 0) ? ["Gold"] : ["Fix Audio", "Follow Up"]
                rec.userNotes = "flagged while triaging batch \(i / 100)"
            }
            if i % 50 == 0 {
                rec.notes = "[mov,mp4,m4a @ 0x7f\(i)] zorply atom not found"
            }
        }
        let index = CatalogSearchIndex()
        index.rebuild(records: corpus)

        // ---- budgets (Release-only assertions; Debug prints only) ----
        // "donna" pins "adding tags didn't regress the existing word
        // fast-path"; "gold"/"flagged" hit the new haystack content;
        // "tag:gold" is a field token → linear regime (165 ms interim
        // ceiling, see CatalogSearchBudgetSensorTests header).
        let budgets: [(String, Double)] = [
            ("donna", 50),
            ("gold", 165),
            ("flagged", 165),
            ("tag:gold", 165),
        ]
        for (query, budget) in budgets {
            _ = index.filter(records: corpus, query: query)  // warm-up
            var times: [Double] = []
            for _ in 0..<5 {
                let t = clock.measure { _ = index.filter(records: corpus, query: query) }
                times.append(Double(t.components.seconds) * 1_000
                             + Double(t.components.attoseconds) / 1e15)
            }
            let settled = times.sorted()[2]
            print(String(format: "[tags-sensor] q='%@' settled_ms=%.1f budget_ms=%.0f",
                         query, settled, budget))
            #if !DEBUG
            #expect(settled <= budget,
                    "settled keystroke for '\(query)' took \(settled) ms — budget \(budget) ms at 100k tagged records")
            #endif
        }

        // ---- agreement: index ≡ canonical with tags + userNotes ----
        for q in ["gold", "tag:gold", "tags:fix", "flagged", "note:flagged", "donna gold"] {
            let viaIndex = index.filter(records: corpus, query: q).map(\.fullPath)
            let canonical = corpus.filter { pfRecordFilenameOrPersonMatch($0, query: q) }
                .map(\.fullPath)
            #expect(viaIndex == canonical,
                    "index vs canonical disagree for '\(q)': \(viaIndex.count) vs \(canonical.count) rows")
        }
        // Sanity: the decoration actually landed (agreement on two empty
        // sets would be vacuous).
        #expect(index.filter(records: corpus, query: "tag:gold").count == 500)
        #expect(!index.filter(records: corpus, query: "flagged").isEmpty)

        // ---- SENSOR: machine notes never in plain search ----
        // 2,000 records carry "zorply" in machine notes; a plain query
        // must find ZERO of them — via the index and the canonical
        // matcher. The note: field token (explicit opt-in) still finds
        // them, proving the data is intact, just not plain-searchable.
        #expect(index.filter(records: corpus, query: "zorply").isEmpty,
                "SENSOR: machine '[' notes leaked into indexed plain search")
        #expect(corpus.filter { pfRecordFilenameOrPersonMatch($0, query: "zorply") }.isEmpty,
                "SENSOR: machine '[' notes leaked into canonical plain search")
        #expect(index.filter(records: corpus, query: "note:zorply").count == 2_000,
                "note: opt-in must still reach machine notes")
    }
}
