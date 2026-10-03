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
                          "Steward/StewardEventGuess.swift", "Steward/StewardEvidence.swift", "Steward/StewardPaneView.swift",
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
        #expect(pane.contains("onReviewBelow(Set(c.recordIDs), c.title)"))
    }

    @Test func ruleTwoUsesTheCanonicalPredicates() throws {
        let src = code(try source("VideoScanModel+Steward.swift"))
        for predicate in ["archiveVolumeProtection()", "self.bulkDeleteRefusal(r, volume: archiveDrive)", "isArchiveElement(r)",
                          "r.lifecycleStage == .archived", "archiveAngel.recommendations", "angel.preparedIDs.contains(r.id)",
                          "angel.candidateIDs.contains(r.id)", "angel.promotedIDs.contains(r.id)"] {
            #expect(src.contains(predicate), "rule 2 no longer asks `\(predicate)`")
        }
        #expect(src.contains("archiveAngel.familyBirthdays"), "the People tab's birthdays come through the Angel's reading of them")
        #expect(src.contains("guard stewardWanted else { return }"), "no work until the pane has been shown")
        let builder = code(try source("StewardCaseBuilder.swift"))
        #expect(builder.contains("} else if r.protection.plannerRefuses {"),
                "“never offered” is said only of what the Delete planner itself refuses")
        #expect(code(try source("StewardCardView.swift")).contains("StewardActionGate.stillCheckedCaution(item.stillCheckedOnDrive)"),
                "the caution about still-checked copies is on the card, above the buttons")
        #expect(builder.contains("isExtraCopy: r.isExtraCopy && !r.protection.isProtected"),
                "a protected row is never counted as reclaimable on a drive card")
        #expect(builder.contains("ReclaimableCalculator.compute("), "per-drive numbers are the Storage tab's arithmetic")
        #expect(builder.contains("guard reclaimableCopies > 0 else { continue }"))
    }

    @Test func ruleOneCallsThePlannersOwnFunctions() throws {
        let src = code(try source("StewardEvidence.swift"))
        for call in ["model.deletionTierCandidates(record: record, keeper: keeper, excluding: sameRun)",
                     "DeletionTierFacts.gather(candidates, digest: digest)",
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
        #expect(src.contains("Button(\"Analyze All (\\(triageRecords.count))\")"))
        #expect(src.contains("Table(rows, selection: $selectedIDs, sortOrder: $sortOrder)"))
        #expect(src.contains("stewardReviewIDs.contains($0.id)"), "Review these below narrows the table")
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
                    || lower.hasPrefix("\"junk:") || lower.hasPrefix("\"drive:") { continue }
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
