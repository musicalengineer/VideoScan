// StewardSensorTests.swift
// Source-level sensors for the content steward's trial UI (2026-10-03;
// design §5.6 of docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md).
//
// What they pin:
//   * NO O(records) work in the pane's or the card's view bodies — they
//     read the model's cached StewardSnapshot (the 2026-07-02 storm rule).
//   * The Steward folder can reach deletion ONLY through the existing
//     front door (the shared deleteDuplicatesFlow → picker → forecast →
//     job): no DeleteDuplicatesJob, no unlink / removeItem / trashItem, no
//     FileManager, no direct start of the job anywhere in the folder.
//   * The "Probably not worth keeping" card has NO delete action (ruling
//     2026-09-26: short clips are low signal, not delete candidates).
//   * An EVENT card (2026-10-03) has no delete action either — it says
//     what belongs together and offers only ways to look.
//   * The occasion is the Angel's labeller's and the trusted day is the
//     Angel's: no second labeller, no second date rule, and the first
//     trial's StewardEventGuess is gone.
//   * The filter and the "By year" order are pure view state, applied in
//     event handlers.
//   * Rule 2's predicates are the canonical ones, and rule 1's proof calls
//     the Delete planner's own functions.
//   * The Triage tab still has its table and its Analyze menu, with the
//     pane above them; the queue rides the existing debounced pass.
//   * Every identifier is `steward.…`; no engine-room word reaches a
//     string a person reads.
//   * The junk line is still Triage's (5), and the Catalog still persists
//     its Show filters under the key the steward writes.
//
// Deliberately NON-INTERACTIVE (no windows, no events).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Steward — source sensors")
struct StewardSensorTests {

    private func source(_ file: String) throws -> String {
        try SourceTree.appSource(named: file)
    }

    /// Code only — comment lines stripped so headers that EXPLAIN a rule
    /// don't trip the check.
    private func code(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// Every Swift file in VideoScan/VideoScan/Steward, comment-stripped.
    private func stewardFolder() throws -> [(name: String, code: String)] {
        let files = SourceTree.appSources.filter { $0.relative.hasPrefix("Steward/") }
        return try files.map { ($0.relative, code(try String(contentsOf: $0.url, encoding: .utf8))) }
    }

    private func matches(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }

    private let recordsWalks = ["model.records", "records.filter", "records.map", "for r in records",
                                "for rec in records", "records.reduce", "records.first", "records.count"]

    @Test func theFolderIsFoundAndHasItsFiles() throws {
        let names = Set(try stewardFolder().map(\.name))
        #expect(names == ["Steward/StewardCardView.swift", "Steward/StewardCase.swift", "Steward/StewardCaseBuilder.swift",
                          "Steward/StewardEvents.swift", "Steward/StewardEvidence.swift", "Steward/StewardPaneView.swift",
                          "Steward/StewardSkipStore.swift", "Steward/StewardWords.swift", "Steward/VideoScanModel+Steward.swift"],
                "a file was added to or removed from Steward/ — review it against these sensors, then update this list")
    }

    @Test func theViewsDoNoRecordsWork() throws {
        for file in ["StewardPaneView.swift", "StewardCardView.swift"] {
            let src = code(try source(file))
            for walk in recordsWalks {
                #expect(!src.contains(walk), "\(file) walks records: `\(walk)`")
            }
            #expect(!src.contains("StewardCaseBuilder.project("), "\(file) projects the catalog itself")
            #expect(!src.contains("StewardCaseBuilder.build("), "\(file) builds the queue itself")
        }
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains("@ObservedObject var snapshot: StewardSnapshot"), "the pane reads the model's cached queue")
        #expect(pane.contains("@ObservedObject var coverage: AnalyzeCoverageSnapshot"), "freshness comes from the coverage snapshot")
        #expect(pane.contains(".task(id: evidenceKey)"), "the focused set's proof is worked out in a task, not in body")
        // The proof's main-actor step is called from that task only.
        let bodyStart = try #require(pane.range(of: "var body: some View {"))
        let bodyEnd = try #require(pane.range(of: "private var headerBar: some View {"))
        let body = String(pane[bodyStart.upperBound..<bodyEnd.lowerBound])
        #expect(!body.contains("StewardEvidenceBuilder.prepare("))
        #expect(!body.contains("skipStore.partition("), "the skip memory is read in event handlers, not per render")
        #expect(!body.contains("StewardCaseBuilder.arrange("), "the list is narrowed and ordered in event handlers, not per render")
        // Events F9: the "next up" rows and the focused card are worked out
        // with the list, in event handlers — not by a filter over the
        // (up to ~425) listed cases on every render.
        // From the top of the view (its computed properties too) to the actions.
        let viewStart = try #require(pane.range(of: "struct StewardPaneView: View {"))
        let actions = try #require(pane.range(of: "private func actions(for c: StewardCase)"))
        let viewBuilding = String(pane[viewStart.upperBound..<actions.lowerBound])
        for scan in ["visible.filter", "visible.first", "visible.contains", "skipped.filter", "active.filter"] {
            #expect(!viewBuilding.contains(scan), "a view-building property scans the list: `\(scan)`")
        }
    }

    /// The filter and "By year" are pure view state: two stored settings,
    /// one pure function, applied when something changes.
    @Test func theFilterAndTheYearOrderArePureViewState() throws {
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains("@AppStorage(\"steward.pane.filter\") private var filterRaw"))
        #expect(pane.contains("@AppStorage(\"steward.pane.eventsByYear\") private var eventsByYear"))
        #expect(pane.contains("visible = StewardCaseBuilder.arrange(showSkipped ? skipped : active, filter: filter, eventsByYear: eventsByYear)"))
        #expect(pane.contains("@State private var visible: [StewardCase] = []"), "the list on screen is state, not recomputed per render")
        #expect(pane.contains(".onChange(of: filterRaw) { _, _ in viewChanged() }"))
        #expect(pane.contains(".onChange(of: eventsByYear) { _, _ in viewChanged() }"))
        #expect(pane.contains("StewardLog.viewLine(filter: filter, eventsByYear: eventsByYear, listed: visible.count)"),
                "one log line when the person changes the view")
        #expect(pane.contains("Here is what is in the catalog, by occasion — and what would tidy it"), "the header leads with content")
        #expect(pane.contains("StewardFreshness.events(placed: snapshot.queue.placedClips, of: snapshot.queue.placeableClips)"),
                "the Events lane's coverage line reads the cached numbers")
        // The builder's order is lane after lane; nothing takes turns any more.
        let builder = code(try source("StewardCaseBuilder.swift"))
        #expect(builder.contains("queue.cases = occasions.events + occasions.days + footage + reclaim.sorted(by: reclaimOrder) + junkCases"))
        #expect(!builder.contains("interleave"))
        #expect(StewardCaseKind.allCases.sorted { $0.lane < $1.lane }.map(\.lane) == [0, 1, 2, 3, 3, 4])
        #expect(StewardCaseKind.event.lane < StewardCaseKind.unlabelledDay.lane
                && StewardCaseKind.unlabelledDay.lane < StewardCaseKind.sameFootage.lane
                && StewardCaseKind.sameFootage.lane < StewardCaseKind.reclaimGroup.lane
                && StewardCaseKind.reclaimGroup.lane < StewardCaseKind.junk.lane)
    }

    /// An event card says what belongs together. It never offers to let
    /// anything go — no Delete, no Trash, no "review below" for marking.
    @Test func anEventCardHasNoDeleteAction() throws {
        let card = code(try source("StewardCardView.swift"))
        let buttons = try #require(card.range(of: "private var actionButtons: some View {"))
        let start = try #require(card.range(of: "case .event, .unlabelledDay:", range: buttons.upperBound..<card.endIndex))
        let end = try #require(card.range(of: "case .reclaimDrive, .reclaimGroup:", range: start.upperBound..<card.endIndex))
        let arm = String(card[start.upperBound..<end.lowerBound])
        #expect(arm.contains("showInCatalogButton"))
        #expect(arm.contains("steward.event.openFootageGroup") && arm.contains("steward.event.reviewCopies"))
        #expect(arm.contains("if item.footageGroupID != nil {"), "Open the footage group only when there is exactly one")
        for word in ["deleteDuplicates", "Delete", "delete", "trash", "Trash", "reviewBelow", "deleteGate"] {
            #expect(!arm.contains(word), "the event card offers `\(word)`")
        }
        // The lines under its buttons are the naming gap, never a Delete reason.
        let notes = try #require(card.range(of: "private var notes: [String] {"))
        let notesEvent = try #require(card.range(of: "case .event:", range: notes.upperBound..<card.endIndex))
        let notesEnd = try #require(card.range(of: "case .reclaimDrive:", range: notesEvent.upperBound..<card.endIndex))
        let notesArm = String(card[notesEvent.upperBound..<notesEnd.lowerBound])
        #expect(notesArm.contains("StewardActionGate.eventNamingGap") && notesArm.contains("StewardActionGate.dayNamingGap"))
        #expect(!notesArm.contains("deleteGate"))
        #expect(StewardActionGate.dayNamingGap == "You could name this — naming arrives later.")
        // Its actions in the pane only ever focus the Catalog.
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains("model.showInCatalog(focus: Set(c.copyReviewIDs), label:"))
        // …and the builder gives an event nothing a cleanup could act on.
        let events = code(try source("StewardEvents.swift"))
        for field in ["driveRoot =", "estimate =", "keeperID =", "runRows", "actionableBytes", "duplicateGroupID ="] {
            #expect(!events.contains(field), "an event card carries `\(field)`")
        }
        #expect(StewardCaseKind.event.chip == "Event")
    }

    /// Do NOT write a second labeller: the occasion and the trusted day
    /// are the Angel's, called — not copied.
    @Test func theOccasionIsTheAngelsLabellerAndTheFirstTrialsGuessIsGone() throws {
        #expect(SourceTree.appSources.allSatisfy { !$0.relative.hasSuffix("StewardEventGuess.swift") }, "StewardEventGuess.swift is back")
        let folder = try stewardFolder()
        let all = folder.map(\.code).joined(separator: "\n")
        #expect(!all.contains("StewardEventGuess"), "the first trial's own guesser is referenced again")
        for own in ["RecordDateResolver.resolve(", "thanksgivingDay", "easterSunday", "nthWeekday(", "calendarLabels(", "birthdayLabels(",
                    "nameLabels(", "\"xmas\"", "\"christmas\"", "\"thanksgiving\"", "\"halloween\"", "\"easter\"", "(12, 25)", "(7, 4)"] {
            #expect(!all.contains(own), "Steward/ has `\(own)` — a second labeller or a second date rule")
        }
        // The steward asks through the Angel's front door (2026-10-03, the
        // boundary fix) and names nothing of the Angel's inside…
        let events = code(try source("StewardEvents.swift"))
        #expect(events.contains("reader.occasions(for: facts(r), now: now, folders: &folders)"),
                "the trusted day and the labels come from the Angel's reader")
        #expect(events.contains("StewardPlacement(day: occasions.day, year: occasions.year, labels: occasions.labels)"),
                "the day is the reader's typed day — not parsed out of a key")
        #expect(events.contains("guard !occasions.isLivePhotoMotion else"), "Live Photo halves are left out by the Angel's own test")
        for inside in ["ArchiveAngelEvent", "ArchiveAngelCandidate", "AngelCoverageRules", "trustedDay(inKey", "\"d:\""] {
            #expect(!all.contains(inside), "Steward/ names `\(inside)` — the Angel's inside, or its key format")
        }
        // …and the front door is the Angel's ONE derivation, called.
        let door = code(try source("ArchiveAngel+Occasions.swift"))
        #expect(door.contains("ArchiveAngelEvent.derive(candidate, now: now, context: context, keysOnly: false, folders: &folders)"),
                "the trusted day and the labels come from the Angel's one derivation")
        #expect(door.contains("Occasions(labels: derived.labels, day: derived.day)"), "the day is the derivation's own")
        #expect(door.contains("ArchiveAngelEvent.dayKeyMinimumConfidence"), "the copy-era stamp rule is the Angel's constant")
        #expect(door.contains("guard !candidate.isLivePhotoMotion else"), "Live Photo halves are told apart by the Angel's own test")
        #expect(door.contains("rules.eventLabels = true"))
        #expect(door.contains("OccasionReader(coverage: policy.coverage, birthdays: familyBirthdays)"))
        let builder = code(try source("StewardCaseBuilder.swift"))
        #expect(builder.contains("StewardEvents.place(r, now: now, reader: events, folders: &folders)"), "once per record, in the build pass")
        #expect(builder.contains("var folders = EventLabeler.FolderWordCache()"), "one folder-word memo per build")
        #expect(builder.contains("StewardEvents.footageGuess(members: members, placements: placements)"),
                "the Same-footage title guess is the labeller's too")
        #expect(!builder.contains("dayPrecise"), "the builder has a day rule of its own again")
        let model = code(try source("VideoScanModel+Steward.swift"))
        #expect(model.contains("let events = archiveAngel.occasionReader"), "the Angel's rules and birthdays, captured on the main actor")
        // Nothing is stored: the folder never writes a record or the catalog.
        for write in ["catalogStore", "saveCatalog", "scheduleSave", "markDirty", "userNotes", ".tags"] {
            #expect(!all.contains(write), "Steward/ touches `\(write)` — events are derived, never stored")
        }
    }

    @Test func theFolderReachesDeletionOnlyThroughTheExistingFrontDoor() throws {
        let forbidden = ["DeleteDuplicatesJob", "unlink", "removeItem", "trashItem", "FileManager", "startDeleteDuplicates(",
                         "deleteDuplicates(onVolume", "prepareDuplicateDeletion(", "moveToTrash", "recycle("]
        let folder = try stewardFolder()
        #expect(folder.count >= 9)
        for file in folder {
            for word in forbidden {
                #expect(!file.code.contains(word), "\(file.name) contains `\(word)` — the steward may only open the existing Delete front door")
            }
        }
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains(".deleteDuplicatesFlow(picker: $picker, preselectedPath: pickerPreselect, source: \"Triage tab\""),
                "Delete goes through the shared picker → forecast → job flow, the drive preselected")
        #expect(pane.contains("picker = DeleteDuplicatesVolumePickerRequest()"))
        // …and that front door is the one the Storage card uses.
        #expect(code(try source("StorageReclaimableCard.swift")).contains(".deleteDuplicatesFlow(picker: $picker"))
    }

    @Test func theJunkCardHasNoDeleteAction() throws {
        let card = code(try source("StewardCardView.swift"))
        let buttons = try #require(card.range(of: "private var actionButtons: some View {"))
        let junkStart = try #require(card.range(of: "case .junk:", range: buttons.upperBound..<card.endIndex))
        let junkEnd = try #require(card.range(of: "if isSkipped {", range: junkStart.upperBound..<card.endIndex))
        let junkArm = String(card[junkStart.upperBound..<junkEnd.lowerBound])
        #expect(junkArm.contains("steward.action.reviewBelow"))
        for word in ["deleteDuplicates", "Delete", "trash", "steward.action.deleteDuplicates"] {
            #expect(!junkArm.contains(word), "the junk card offers `\(word)`")
        }
        // The pane hands junk cases to the Triage table and nowhere else.
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains("onReviewBelow(Set(c.recordIDs), c.title, c.id)"))
    }

    @Test func ruleTwoUsesTheCanonicalPredicates() throws {
        let src = code(try source("VideoScanModel+Steward.swift"))
        // GH #258: the Delete planner's OWN two rules, nothing of the
        // steward's own — a card and the run behind it cannot disagree.
        for predicate in ["archiveVolumeProtection()", "self.bulkDeleteRefusal(r, volume: archiveDrive)",
                          "let hold = duplicateDeletionHoldRule()", "switch hold(r) {"] {
            #expect(src.contains(predicate), "rule 2 no longer asks `\(predicate)`")
        }
        for own in ["candidateIDs", "preparedIDs", "promotedIDs", "lifecycleStage", "isArchiveElement", "isArchiveCopy"] {
            #expect(!src.contains(own), "the steward reads `\(own)` itself — it must ask the planner's rule")
        }
        // …and that rule still reads what rule 2 promises.
        let planner = code(try source("VideoScanModel+Duplicates.swift"))
        // (The Angel's half is asked BY ID since codex #258 r4-2 —
        // `duplicateAngelUseRule`, which the hold rule calls with `r.id`.)
        for predicate in ["self.isArchiveCopy(r)", "archiveAngel.recommendations", "angel.preparedIDs.contains(id)",
                          "angel.promotedIDs.contains(id)", "onDisk.contains(id)", "preparing.contains(id)",
                          "return inUseByAngel(r.id) ? .inUseByAngel : nil"] {
            #expect(planner.contains(predicate), "the planner's hold rule no longer asks `\(predicate)`")
        }
        // The Angel's front door carries them (ArchiveAngel+Occasions:
        // `OccasionReader(coverage: policy.coverage, birthdays: familyBirthdays)`,
        // pinned in theOccasionIsTheAngelsLabeller…).
        #expect(src.contains("archiveAngel.occasionReader"), "the People tab's birthdays come through the Angel's reading of them")
        #expect(src.contains("guard stewardWanted else { return }"), "no work until the pane has been shown")
        let builder = code(try source("StewardCaseBuilder.swift"))
        #expect(builder.contains("} else if r.protection.isProtected {"),
                "every protected copy is one the Delete planner leaves alone — “never offered”")
        let folder = try stewardFolder().map(\.code).joined(separator: "\n")
        #expect(!folder.contains("stillChecked") && !folder.contains("would still check"),
                "since GH #258 no class of protected copy is still checked by the drive's cleanup")
        #expect(builder.contains("isExtraCopy: r.isExtraCopy && !r.protection.isProtected"),
                "a protected row is never counted as reclaimable on a drive card")
        #expect(builder.contains("ReclaimableCalculator.compute("), "per-drive numbers are the Storage tab's arithmetic")
        #expect(builder.contains("guard reclaimableCopies > 0 else { continue }"))
    }

    @Test func ruleOneCallsThePlannersOwnFunctions() throws {
        let src = code(try source("StewardEvidence.swift"))
        for call in ["model.deletionTierCandidates(",
                     "record: record, keeper: keeper, run: DuplicateRunScope(volumePath: row.driveRoot, pending: sameRun))",
                     "DeletionTierFacts.gather(candidates, digest: digest, driveOf: seam)",
                     "seam?(path, stamp) ?? resolver.drive(path: path, stamp: stamp)",
                     "SiblingProver.readableSiblings(",
                     "candidates.duplicateIdentity = FileIdentityStamp.capture(path: q.copyPath)",
                     "c.runRows.filter { $0.driveRoot == row.driveRoot && $0.id != row.id }",
                     "DeletionTierDecision.decide(facts: facts, preferTrash: preferTrash)"] {
            #expect(src.contains(call), "the proof no longer calls `\(call)`")
        }
        let card = code(try source("StewardCardView.swift"))
        #expect(card.contains("ReclaimableEstimate.survivalRule"), "the survival rule is quoted from the constants")
        #expect(card.contains("StewardActionGate.perGroupDeleteGap"), "the per-set delete gap is said on the card")
        #expect(StewardActionGate.perGroupDeleteGap == "Deleting just this set arrives later; for now this cleans the whole drive's duplicates.")
    }

    @Test func theTriageTabKeepsItsTableAndAnalyzeMenuUnderThePane() throws {
        let src = code(try source("TriageView.swift"))
        #expect(src.contains("StewardPaneView(snapshot: model.stewardSnapshot,"))
        let pane = try #require(src.range(of: "StewardPaneView("))
        let toolbar = try #require(src.range(of: "            toolbar\n", range: pane.upperBound..<src.endIndex))
        let table = try #require(src.range(of: "fileTable(rows: rows)", range: toolbar.upperBound..<src.endIndex))
        #expect(pane.lowerBound < toolbar.lowerBound && toolbar.lowerBound < table.lowerBound, "pane, then toolbar, then the table")
        #expect(src.contains("Label(isAnalyzing ? \"Analyzing...\" : \"Analyze\", systemImage: \"wand.and.stars\")"),
                "Triage's own Analyze menu is still there")
        // 2026-10-03 (perf/triage-view-snapshot): the count and the rows come
        // from the model's off-main TriageSnapshot, not a records walk in body.
        #expect(src.contains("Button(\"Analyze All (\\(snapshot.value.triageTotal))\")"))
        #expect(src.contains("Table(rows, selection: $selectedIDs, sortOrder: $sortOrder)"))
        #expect(src.contains("reviewIDs: stewardReviewIDs"), "Review these below is part of the table's query")
        #expect(code(try source("TriageSnapshot.swift")).contains("rows = rows.filter { query.reviewIDs.contains($0.id) }"),
                "Review these below narrows the table")
        // The model's refresh rides the existing debounced pass.
        let model = code(try source("VideoScanModel.swift"))
        let refresh = try #require(model.range(of: "func refreshDossierCountsNow() {"))
        #expect(String(model[refresh.upperBound...].prefix(2_500)).contains("scheduleStewardRefresh()"))
    }

    /// QA F3: "Review these below" narrows the table and selects NOTHING —
    /// one click on Junk must never mark a whole cluster by accident.
    @Test func reviewTheseBelowNarrowsTheTableButSelectsNothing() throws {
        let src = code(try source("TriageView.swift"))
        let start = try #require(src.range(of: "private func reviewFromSteward("))
        let end = try #require(src.range(of: "private var stewardReviewBanner", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        #expect(body.contains("stewardReviewIDs = ids"), "it narrows the table")
        #expect(!body.contains("selectedIDs = ids"), "it must not select the records")
        #expect(body.contains("selectedIDs = []"), "…and it clears whatever was selected before")
        // QA F8: every decision pressed in the tab — buttons and context
        // menu share applyDisposition — is noted against the reviewed card.
        #expect(body.contains("stewardReview = StewardReview(caseID: caseID, ids: ids)"))
        let apply = try #require(src.range(of: "private func applyDisposition("))
        let applyEnd = try #require(src.range(of: "private func noteStewardReviewDecision(", range: apply.upperBound..<src.endIndex))
        #expect(String(src[apply.upperBound..<applyEnd.lowerBound]).contains("noteStewardReviewDecision(disposition, on: ids)"))
        #expect(src.contains("StewardSkipStore(defaults: model.stewardDefaults).markReviewed(caseID: stewardReview.caseID, facts: facts)"))
        #expect(code(try source("VideoScanModel+Steward.swift")).contains("reviewed: reviewed"), "the builder hears what was finished")
        let card = code(try source("StewardCardView.swift"))
        #expect(!card.contains("in the table below, selected"), "the button's help no longer promises a selection")
    }

    @Test func everyIdentifierStartsWithSteward() throws {
        var seen = 0
        for file in try stewardFolder() {
            for id in matches(#"accessibilityIdentifier\("[^"]*"\)"#, in: file.code) {
                seen += 1
                #expect(id.hasPrefix("accessibilityIdentifier(\"steward."), "\(file.name): \(id)")
            }
            for id in matches(#"id: "[a-z][A-Za-z.]*""#, in: file.code) {
                seen += 1
                #expect(id.hasPrefix("id: \"steward."), "\(file.name): \(id)")
            }
        }
        #expect(seen >= 20, "found only \(seen) identifiers — the scan is reading nothing")
        // The Events lane's own identifiers are `steward.event.…`.
        let eventIDs = try stewardFolder().flatMap { matches(#""steward\.event\.[A-Za-z.]+""#, in: $0.code) }
        #expect(Set(eventIDs).isSuperset(of: ["\"steward.event.why\"", "\"steward.event.inside\"", "\"steward.event.alsoIn\"",
                                              "\"steward.event.reasons\"", "\"steward.event.reviewCopies\"",
                                              "\"steward.event.openFootageGroup\"", "\"steward.event.byYear\"",
                                              "\"steward.event.coverage\""]), "found: \(Set(eventIDs).sorted())")
        let triage = code(try source("TriageView.swift"))
        #expect(triage.contains("accessibilityIdentifier(\"steward.review.banner\")"))
    }

    /// Friendly language: none of the engine-room words in a string a
    /// person reads (string literals only — comments and code may use them).
    @Test func noEngineRoomWordsInWhatAPersonReads() throws {
        let banned = ["stamp", "cycler", "orchestrator", "heuristic", "phase", "fixity", "digest", "ledger", "predicate"]
        // QA F10: whole words a person should never meet either. (Identifier
        // and settings-key literals — "steward.…" — are not read by anyone.)
        let bannedWords = ["steward", "case", "payoff", "score", "queue"]
        var literals = 0
        var files = try stewardFolder()
        files.append((name: "TriageView.swift (steward banner)", code: try stewardBannerCode()))
        for file in files {
            for literal in matches(#""(?:[^"\\\n]|\\.)*""#, in: file.code) {
                literals += 1
                let lower = literal.lowercased()
                for word in banned {
                    #expect(!lower.contains(word), "\(file.name): \(literal) says “\(word)”")
                }
                if lower.hasPrefix("\"steward.") || lower.hasPrefix("\"dup:") || lower.hasPrefix("\"footage:")
                    || lower.hasPrefix("\"junk:") || lower.hasPrefix("\"drive:") || lower.hasPrefix("\"event:")
                    || lower.hasPrefix("\"day:") { continue }
                for word in bannedWords where !matches("\\b\(word)\\b", in: lower).isEmpty {
                    Issue.record("\(file.name): \(literal) says “\(word)”")
                }
            }
        }
        #expect(literals > 100, "found only \(literals) string literals — the scan is reading nothing")
    }

    private func stewardBannerCode() throws -> String {
        let src = code(try source("TriageView.swift"))
        let start = try #require(src.range(of: "private var stewardReviewBanner: some View {"))
        let end = try #require(src.range(of: "private func runAnalysis", range: start.upperBound..<src.endIndex))
        return String(src[start.upperBound..<end.lowerBound])
    }

    @Test func theJunkLineIsStillTriagesAndTheCatalogStillUsesTheFilterKey() throws {
        #expect(StewardCaseBuilder.junkThreshold == 5)
        #expect(try source("MediaAnalyzer.swift").contains("junkScore >= 5 && familyScore < 2"),
                "MediaAnalyzer's Suspected Junk line moved — move StewardCaseBuilder.junkThreshold with it")
        #expect(try source("TriageView.swift").contains("rec.junkScore >= 5 ? .orange"),
                "the Triage table's orange line moved — move StewardCaseBuilder.junkThreshold with it")
        #expect(StewardCatalogDoor.viewFiltersKey == "catalog.viewFilters")
        #expect(try source("ContentView.swift").contains("@AppStorage(\"catalog.viewFilters\") private var persistedViewFilters"),
                "the Catalog's Show-filter key moved — the steward's One Per Footage door writes the old one")
        #expect(try source("ContentView.swift").contains("catalogViewFilters = CatalogShowingSummary.decode(persistedViewFilters)"))
        #expect(StewardCaseBuilder.minFootageStrength == FootageConfidence.likely.strength, "Likely or stronger")
    }

    @Test func logLinesGoThroughTheExistingSinksOnePerAction() throws {
        let pane = code(try source("StewardPaneView.swift"))
        #expect(pane.contains("model.log(line)") && pane.contains("appLog.write(line)"))
        let folder = try stewardFolder().map(\.code).joined(separator: "\n")
        #expect(!folder.contains("FileHandle") && !folder.contains("LogSink("), "no log file or sink of its own")
        // `note(` is only ever called from an action closure or a state
        // handler — never from a view-building property.
        let bodyStart = try #require(pane.range(of: "var body: some View {"))
        let actionsStart = try #require(pane.range(of: "private func actions(for c: StewardCase)"))
        let viewBuilding = String(pane[bodyStart.upperBound..<actionsStart.lowerBound])
        let calls = viewBuilding.components(separatedBy: "note(.").count - 1
        #expect(calls == 1, "the one allowed call above the actions is the Delete flow's onStarted callback (found \(calls))")
        #expect(viewBuilding.contains("note(.acted, c, action: \"Delete duplicates started on"))
    }
}
