import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Grounded composition: plan → phrase → verify
//
// No network anywhere in this file. The model is a closure; the verifier and
// plan extraction are pure. Composed wording is never pinned verbatim — the
// contract pinned here is that whatever is displayed is a subset of verified
// sentences and every displayed sentence maps to plan claims.

@Suite("Hallie grounded composition")
struct HallieGroundedCompositionTests {

    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private func tag(_ name: String) -> ConfirmedTag {
        ConfirmedTag(name: name, confirmedAt: confirmedAt)
    }

    /// A three-claim biography plan, the shape Rick asked to smoke.
    private func biographyPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .graph,
            shape: .biography,
            subject: "Ellen Breen",
            claims: [
                .init(id: "c1", text: "The imported family tree records 12 MAR 1920 as Ellen Breen's birth date.", evidenceIDs: ["gedcom:@I7@"]),
                .init(id: "c2", text: "The imported family tree records Ellen Breen's spouse as John Breen.", evidenceIDs: ["gedcom:@I7@"]),
                .init(id: "c3", text: "The imported family tree records Ellen Breen's children as Rick Breen, Mary Breen.", evidenceIDs: ["gedcom:@I7@"]),
            ],
            counts: [.init(label: "supporting sources", value: 1)],
            fallbackText: "Here is what the family archive currently supports about Ellen Breen. …")
    }

    private func fixedResult(_ route: HallieTurnExecutor.Route,
                             outcome: HallieTurnExecutor.Outcome = .answered) -> HallieTurnExecutor.Result {
        HallieTurnExecutor.Result(
            route: route, outcome: outcome,
            prose: "Fixed wording. Second sentence with 1994.",
            basisLine: "Basis: fixture.",
            queryDescription: nil, citations: [], catalogPersonName: nil)
    }

    // MARK: Plan extraction per route

    @Test func presenceRoutePlanCarriesCountSentenceAndCitedItems() async throws {
        let records = (1...12).map { index in
            ArchivistPresenceRecordSnapshot(
                fullPath: "/isolated/1994/donna_\(index).mov",
                confirmedPeople: [tag("Donna")])
        }
        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Donna"])),
            context: .init(presenceRecords: records))
        #expect(result.outcome == .answered)
        let plan = try #require(result.answerPlan)
        #expect(plan.route == .presence)
        #expect(plan.shape == .list)
        #expect(plan.isComposable)
        // c1 is the templated count sentence verbatim; the fallback is the same.
        #expect(plan.claims.first?.id == "c1")
        #expect(plan.claims.first?.text == result.prose)
        #expect(plan.fallbackText == result.prose)
        // Item claims are bounded, name the file, and carry the record ID.
        // Since 2026-08-21 the plan also carries derived span/people claims
        // between the count and the items, so locate the items by prefix
        // rather than by a fixed index.
        let itemClaims = plan.claims.filter { $0.text.hasPrefix("Item ") }
        #expect(itemClaims.count == min(result.citations.count, HallieAnswerPlan.maxItemClaims))
        #expect(itemClaims[0].text.contains("donna_1.mov"))
        #expect(itemClaims[0].evidenceIDs == [result.citations[0].recordID.uuidString])
        // Claim IDs stay dense and ordered whatever the mix.
        #expect(plan.claimIDs == (1...plan.claims.count).map { "c\($0)" })
        #expect(plan.counts.contains(.init(label: "matching catalog items", value: 12)))
        // derive() prefers the executor's own plan.
        #expect(HallieAnswerPlan.derive(from: result) == plan)
    }

    @Test func presenceNoEvidenceIsFixedNotComposable() async throws {
        let result = try await HallieTurnExecutor.execute(
            .presence(.init(people: ["Nobody"])),
            context: .init(presenceRecords: [
                ArchivistPresenceRecordSnapshot(
                    fullPath: "/isolated/x.mov", confirmedPeople: [tag("Donna")]),
            ]))
        #expect(result.outcome == .declined)
        #expect(result.answerPlan == nil)
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.shape == .fixed)
        #expect(!plan.isComposable)
        #expect(plan.fallbackText == result.prose)
    }

    @Test func cyberBrainBiographyPlanKeepsClaimsAndEvidenceIDs() {
        let source = CyberBrainAnswerPlan(
            subject: "Ellen Breen",
            answerState: .answered,
            claims: [
                .init(id: "bio:1", text: "Ellen taught school in Westford.",
                      evidenceIDs: ["ev-1", "ev-2"], confidence: .confirmed),
                .init(id: "bio:2", text: "She married John in 1941.",
                      evidenceIDs: ["ev-3"], confidence: .probable),
            ],
            uncertaintyStatements: ["The archive contains a disputed account about this person."],
            sourceCitations: [.init(id: "ev-1", title: "Oral history", attribution: nil, locator: nil)])
        let plan = HallieAnswerPlan.biography(source, fallbackText: "template text")
        #expect(plan.shape == .biography)
        #expect(plan.subject == "Ellen Breen")
        #expect(plan.claimIDs == ["c1", "c2", "c3"])
        #expect(plan.claims[0].text == "Ellen taught school in Westford.")
        #expect(plan.claims[0].evidenceIDs == ["ev-1", "ev-2"])
        #expect(plan.claims[2].text.contains("disputed"))
        #expect(plan.maxSentences == 6)
        #expect(plan.fallbackText == "template text")
    }

    @Test func graphAnsweredRouteDerivesOneClaimPerTemplatedSentence() {
        let result = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "Donna's mother is Elaine Smith. Elaine Smith was born 12 MAR 1950.",
            basisLine: "Checked: imported family tree.",
            queryDescription: "shape=graph", citations: [],
            catalogPersonName: "Donna")
        let plan = HallieAnswerPlan.derive(from: result)
        #expect(plan.shape == .fact)
        #expect(plan.claims.map(\.text) == [
            "Donna's mother is Elaine Smith.",
            "Elaine Smith was born 12 MAR 1950.",
        ])
        #expect(plan.claimIDs == ["c1", "c2"])
        #expect(plan.subject == "Donna")
        #expect(plan.fallbackText == result.prose)
    }

    @Test func fixedRoutesDeclinesAndClarificationsAreNeverComposable() async throws {
        for route in [HallieTurnExecutor.Route.capability, .help, .smalltalk,
                      .reset, .followUp, .unsupportedEvent] {
            let plan = HallieAnswerPlan.derive(from: fixedResult(route))
            #expect(plan.shape == .fixed, "\(route)")
            #expect(!plan.isComposable, "\(route)")
        }
        for outcome in [HallieTurnExecutor.Outcome.declined, .unsupported, .needsClarification] {
            let plan = HallieAnswerPlan.derive(from: fixedResult(.graph, outcome: outcome))
            #expect(!plan.isComposable, "\(outcome)")
        }
        // A real clarification result (needsClarification) from the executor.
        let profiles = [
            HallieTurnExecutor.ProfileSnapshot(stableID: "a", canonicalName: "Tim"),
            HallieTurnExecutor.ProfileSnapshot(stableID: "b", canonicalName: "Timmy", aliases: ["tim"]),
        ]
        let result = try await HallieTurnExecutor.execute(
            .temporal(.init(subject: "tim", operation: .age, reference: .currentSelection)),
            context: .init(profiles: profiles))
        #expect(result.clarification != nil)
        #expect(!HallieAnswerPlan.derive(from: result).isComposable)
    }

    // MARK: Verifier matrix

    @Test func verifierKeepsTaggedSentencesAndDropsUntagged() {
        let plan = biographyPlan()
        let text = "Ellen Breen was born on 12 MAR 1920 [c1]. She married John Breen. Her children were Rick Breen and Mary Breen [c3]."
        let v = HallieCompositionVerifier.verify(text, plan: plan, personaName: "Hallie Mae")
        #expect(v.kept.map(\.display) == [
            "Ellen Breen was born on 12 MAR 1920.",
            "Her children were Rick Breen and Mary Breen.",
        ])
        #expect(v.kept.map(\.claimIDs) == [["c1"], ["c3"]])
        #expect(v.dropped == [.init(text: "She married John Breen.", reason: .untagged)])
        #expect(v.transcriptText.contains("[c1]"))
        #expect(!v.displayText.contains("["))
    }

    @Test func verifierDropsUnknownClaimIDs() {
        let plan = biographyPlan()
        let v = HallieCompositionVerifier.verify(
            "Ellen Breen was born on 12 MAR 1920 [c9].", plan: plan, personaName: "Hallie Mae")
        #expect(v.kept.isEmpty)
        #expect(v.dropped.first?.reason == .unknownClaimID)
    }

    @Test func verifierDropsSentenceFragmentsAndComposerUsesTemplate() async {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(
                id: "c1",
                text: "Rick Breen's father is Richard Harding Breen Sr.")],
            fallbackText: "Rick Breen's father is Richard Harding Breen Sr.")
        let verification = HallieCompositionVerifier.verify(
            "s father is Richard Harding Breen Sr. [c1]",
            plan: plan, personaName: "Hallie Mae")
        #expect(verification.kept.isEmpty)
        #expect(verification.dropped.first?.reason == .sentenceFragment)

        let outcome = await composer { _, _ in
            "s father is Richard Harding Breen Sr. [c1]"
        }.compose(plan: plan, history: [])
        #expect(outcome.composedBy == .template)
        #expect(outcome.displayText == plan.fallbackText)
    }

    @Test func verifierDropsLeakedYearNumberAndName() {
        let plan = biographyPlan()
        let year = HallieCompositionVerifier.verify(
            "Ellen Breen died in 1999 [c1].", plan: plan, personaName: "Hallie Mae")
        #expect(year.dropped.first?.reason == .leakedYear)
        let number = HallieCompositionVerifier.verify(
            "Ellen Breen had 7 children [c3].", plan: plan, personaName: "Hallie Mae")
        #expect(number.dropped.first?.reason == .leakedNumber)
        let name = HallieCompositionVerifier.verify(
            "Ellen Breen married John Breen in Boston [c2].", plan: plan, personaName: "Hallie Mae")
        #expect(name.dropped.first?.reason == .leakedName)
        // A name from a DIFFERENT claim than the one cited is still a leak.
        let crossClaim = HallieCompositionVerifier.verify(
            "Ellen Breen's spouse was Rick Breen [c2].", plan: plan, personaName: "Hallie Mae")
        #expect(crossClaim.dropped.first?.reason == .leakedName)
        // Persona name and sentence-initial words are not leaks; case and
        // possessives fold.
        let fine = HallieCompositionVerifier.verify(
            "Ellen's spouse was John Breen, says Hallie Mae [c2].", plan: plan, personaName: "Hallie Mae")
        #expect(fine.kept.count == 1)
    }

    @Test func verifierExpandsMonthsAndChecksSpelledOutNumbers() {
        let plan = biographyPlan()
        // "12 MAR 1920" vouches for "March 12, 1920" (live smoke 2026-08-17).
        let month = HallieCompositionVerifier.verify(
            "Ellen Breen was born on March 12, 1920 [c1].", plan: plan, personaName: "Hallie Mae")
        #expect(month.kept.count == 1)
        // A spelled-out count with no digit or word in the cited claim leaks.
        let word = HallieCompositionVerifier.verify(
            "Ellen Breen had seven children [c3].", plan: plan, personaName: "Hallie Mae")
        #expect(word.dropped.first?.reason == .leakedNumber)
        // "one" is exempt (pronoun), and a digit in the claim vouches for its word.
        let list = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [.init(id: "c1", text: "I found 2 catalog items matching that.")],
            fallbackText: "I found 2 catalog items matching that.")
        let two = HallieCompositionVerifier.verify(
            "There are two, and one of them is below [c1].", plan: list, personaName: "Hallie")
        #expect(two.kept.count == 1)
    }

    @Test func verifierEnforcesSentenceBudgetAndHandlesTagVariants() {
        let plan = HallieAnswerPlan(
            route: .presence, shape: .list,
            claims: [.init(id: "c1", text: "I found 4 catalog items matching that."),
                     .init(id: "c2", text: "Item 1: a.mov"),
                     .init(id: "c3", text: "Item 2: b.mov")],
            fallbackText: "I found 4 catalog items matching that.")
        let text = "I found 4 items [c1]. One is a.mov. [c2] Another is b.mov [c2, c3]. Extra sentence [c1]. Fifth [c1]"
        let v = HallieCompositionVerifier.verify(text, plan: plan, personaName: "Hallie")
        #expect(v.kept.count == 3)
        #expect(v.kept[1].claimIDs == ["c2"])
        #expect(v.kept[2].claimIDs == ["c2", "c3"])
        #expect(v.dropped.map(\.reason) == [.overSentenceBudget, .overSentenceBudget])
        #expect(v.displayText == "I found 4 items. One is a.mov. Another is b.mov.")
    }

    @Test func sentenceSplitterKeepsDecimalsAndTrailingTags() {
        let sentences = HallieCompositionVerifier.splitSentences(
            "It is at 12.5s in the clip [c2]. Really? Yes. [c1]\nNew line [c3]")
        #expect(sentences == [
            "It is at 12.5s in the clip [c2].", "Really?", "Yes. [c1]", "New line [c3]",
        ])
        #expect(HallieCompositionVerifier.stripTags("Hello [c1] , world [c2].") == "Hello, world.")
    }

    // MARK: Composer with a fake model

    private func composer(
        timeout: Double = 6,
        _ reply: @escaping @Sendable (String, String) async throws -> String
    ) -> HallieGroundedComposer {
        HallieGroundedComposer(personaName: "Hallie Mae", timeoutSeconds: timeout, modelCall: reply)
    }

    @Test func perfectlyTaggedReplyIsShownWithTagsStrippedAndLogged() async {
        let plan = biographyPlan()
        let outcome = await composer { _, _ in
            "Ellen Breen was born on 12 MAR 1920 [c1]. She married John Breen [c2]."
        }.compose(plan: plan, history: [])
        #expect(outcome.composedBy == .model)
        #expect(outcome.displayText == "Ellen Breen was born on 12 MAR 1920. She married John Breen.")
        #expect(outcome.transcriptText == "Ellen Breen was born on 12 MAR 1920 [c1]. She married John Breen [c2].")
        #expect(outcome.dropped.isEmpty)
        // Golden contract: every displayed sentence maps to plan claims.
        let verification = HallieCompositionVerifier.verify(
            outcome.transcriptText, plan: plan, personaName: "Hallie Mae")
        #expect(verification.displayText == outcome.displayText)
        #expect(verification.kept.allSatisfy { !$0.claimIDs.isEmpty })
    }

    @Test func hallucinatedSentenceIsDroppedOnlyTaggedSurvive() async {
        let plan = biographyPlan()
        let outcome = await composer { _, _ in
            "Ellen Breen was born on 12 MAR 1920 [c1]. She loved gardening and lived in Lowell until 1988. Her children were Rick Breen and Mary Breen [c3]."
        }.compose(plan: plan, history: [])
        #expect(outcome.composedBy == .model)
        #expect(outcome.displayText == "Ellen Breen was born on 12 MAR 1920. Her children were Rick Breen and Mary Breen.")
        #expect(outcome.dropped.count == 1)
        #expect(outcome.dropped.first?.reason == .untagged)
    }

    @Test func emptyGarbageOrAllDroppedFallsBackToTemplate() async {
        let plan = biographyPlan()
        for reply in ["", "   \n", "lorem ipsum without tags. more nonsense!",
                      "Ellen died in 2001 [c1]. Ellen had 9 cats [c3]."] {
            let outcome = await composer { _, _ in reply }.compose(plan: plan, history: [])
            #expect(outcome.composedBy == .template, Comment(rawValue: reply))
            #expect(outcome.displayText == plan.fallbackText, Comment(rawValue: reply))
            #expect(outcome.transcriptText == plan.fallbackText, Comment(rawValue: reply))
        }
    }

    @Test func modelErrorAndTimeoutFallBackToTemplateWithinBudget() async {
        struct Down: Error {}
        let plan = biographyPlan()
        let failed = await composer { _, _ in throw Down() }.compose(plan: plan, history: [])
        #expect(failed.composedBy == .template)
        #expect(failed.note.contains("error"))

        let started = ContinuousClock.now
        let slow = await composer(timeout: 0.2) { _, _ in
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return "Ellen Breen was born on 12 MAR 1920 [c1]."
        }.compose(plan: plan, history: [])
        let elapsed = ContinuousClock.now - started
        #expect(slow.composedBy == .template)
        #expect(slow.note.contains("timeout"))
        #expect(slow.displayText == plan.fallbackText)
        #expect(elapsed < .seconds(2))
    }

    @Test func fixedPlanNeverCallsTheModel() async {
        let calls = LockedCounter()
        let plan = HallieAnswerPlan(route: .help, shape: .fixed, fallbackText: "help card")
        let outcome = await composer { _, _ in calls.increment(); return "x [c1]." }
            .compose(plan: plan, history: [])
        #expect(calls.value == 0)
        #expect(outcome.composedBy == .template)
        #expect(outcome.displayText == "help card")
    }

    @Test func promptCarriesPersonaClaimsCountsAndBoundedHistoryOnly() async throws {
        let plan = biographyPlan()
        let captured = LockedBox<(String, String)>()
        let history = (1...5).map {
            HallieGroundedComposer.HistoryTurn(user: "q\($0)", assistant: "a\($0)")
        }
        _ = await HallieGroundedComposer(personaName: "Aunt Bea", modelCall: { system, user in
            captured.set((system, user))
            return "Ellen Breen was born on 12 MAR 1920 [c1]."
        }).compose(plan: plan, history: history)
        let (system, user) = try #require(captured.value)
        #expect(system.contains("You are Aunt Bea"))
        #expect(!system.contains("Hallie"))
        #expect(system.contains("ONLY the given claims"))
        #expect(user.contains("[c1] The imported family tree records 12 MAR 1920"))
        #expect(user.contains("supporting sources = 1"))
        #expect(user.contains("Subject: Ellen Breen"))
        // Only the last three turns.
        #expect(!user.contains("q1"))
        #expect(!user.contains("q2"))
        #expect(user.contains("q3") && user.contains("a5"))
    }

    // MARK: Result application + settings

    @Test func applyingCompositionChangesOnlyProseAndProvenanceFields() {
        let original = HallieTurnExecutor.Result(
            route: .graph, outcome: .answered,
            prose: "template", basisLine: "Basis: x.",
            queryDescription: "q", citations: [], catalogPersonName: "Ellen",
            offeredActions: [.openFamilyTree(personName: "Ellen")])
        let composed = original.applying(.init(
            displayText: "Ellen it is.", transcriptText: "Ellen it is [c1].",
            composedBy: .model, dropped: [], note: "model"))
        #expect(composed.prose == "Ellen it is.")
        #expect(composed.transcriptText == "Ellen it is [c1].")
        #expect(composed.composedBy == .model)
        #expect(composed.basisLine == original.basisLine)
        #expect(composed.offeredActions == original.offeredActions)
        #expect(composed.catalogPersonName == original.catalogPersonName)

        let templated = original.applying(.template(
            HallieAnswerPlan(route: .graph, shape: .fact, fallbackText: "template"),
            note: "template: timeout"))
        #expect(templated == original)
    }

    @Test func settingDefaultsOnAndPersonaNameFallsBack() {
        let defaults = UserDefaults(suiteName: "HallieGroundedCompositionTests.\(UUID().uuidString)")!
        defer { defaults.removePersistentDomain(forName: defaults.description) }
        #expect(HallieCompositionSettings.isEnabled(defaults))
        HallieCompositionSettings.setEnabled(false, defaults)
        #expect(!HallieCompositionSettings.isEnabled(defaults))
        #expect(HallieCompositionSettings.personaName(defaults) == "Hallie Mae")
        defaults.set("Aunt Bea", forKey: HallieCompositionSettings.personaNameKey)
        #expect(HallieCompositionSettings.personaName(defaults) == "Aunt Bea")
        defaults.set("   ", forKey: HallieCompositionSettings.personaNameKey)
        #expect(HallieCompositionSettings.personaName(defaults) == "Hallie Mae")
    }

    // MARK: Test doubles

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = 0
        func increment() { lock.withLock { storage += 1 } }
        var value: Int { lock.withLock { storage } }
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: T?
        func set(_ value: T) { lock.withLock { storage = value } }
        var value: T? { lock.withLock { storage } }
    }
}

// MARK: - Coordinator and shell seams

@MainActor
@Suite("Hallie grounded composition — coordinator and shell", .serialized)
struct HallieGroundedCompositionClientTests {

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Value] = []
        func append(_ value: Value) { lock.withLock { storage.append(value) } }
        func append(contentsOf values: [Value]) { lock.withLock { storage.append(contentsOf: values) } }
        var values: [Value] { lock.withLock { storage } }
    }

    private func listResult() -> HallieTurnExecutor.Result {
        let citation = HallieTurnExecutor.Citation(
            recordID: UUID(), fullPath: "/isolated/1994/donna_cape.mov",
            filename: "donna_cape.mov", playbackSeconds: nil, bases: [])
        let prose = "I found 1 catalog item matching that."
        return HallieTurnExecutor.Result(
            route: .presence, outcome: .answered, prose: prose,
            basisLine: "Basis: 1 cited of 1 matching catalog items.",
            queryDescription: "shape=presence", citations: [citation],
            catalogPersonName: nil, matchCount: 1,
            answerPlan: .presenceList(
                route: .presence, prose: prose, totalMatchCount: 1,
                shownCount: 1, citations: [citation]))
    }

    private func dependencies(
        ast: ArchivistQueryAST,
        result: HallieTurnExecutor.Result,
        composeCalls: Recorder<HallieAnswerPlan>,
        reply: String = "Just one, Donna at the cape in donna_cape.mov [c1][c2]."
    ) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in .init(ast: ast, responderHost: "fixture-host") },
            loadProfiles: { [] },
            loadGraph: { nil },
            executeRequest: { _, _ in result },
            continueTurn: { _, _, _ in result },
            resolveBiographyPhoto: { _ in nil },
            composeAnswer: { plan, history, hosts, model in
                composeCalls.append(plan)
                #expect(hosts == ["fixture.invalid"])
                #expect(model == "fixture-model")
                #expect(history.map(\.user) == ["earlier question"])
                let composer = HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in reply }
                return await composer.compose(plan: plan, history: history)
            })
    }

    @Test func coordinatorPhrasesComposableAnswerAndKeepsBasisAndCitations() async throws {
        let calls = Recorder<HallieAnswerPlan>()
        let result = listResult()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "show me donna at the cape",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            composeWithModel: true,
            history: [.init(user: "earlier question", assistant: "earlier answer")],
            dependencies: dependencies(
                ast: .presence(.init(people: ["donna"])), result: result, composeCalls: calls))
        #expect(calls.values.count == 1)
        #expect(response.result.composedBy == .model)
        #expect(response.result.prose == "Just one, Donna at the cape in donna_cape.mov.")
        #expect(response.result.transcriptText == "Just one, Donna at the cape in donna_cape.mov [c1][c2].")
        #expect(response.result.basisLine == result.basisLine)
        #expect(response.result.citations == result.citations)
        #expect(response.citations == result.citations)
    }

    @Test func coordinatorSettingOffShowsTemplateAndNeverCallsComposer() async throws {
        let calls = Recorder<HallieAnswerPlan>()
        let result = listResult()
        let response = try await HallieAppTurnCoordinator.execute(
            question: "show me donna at the cape",
            records: [], referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            composeWithModel: false,
            dependencies: dependencies(
                ast: .presence(.init(people: ["donna"])), result: result, composeCalls: calls))
        #expect(calls.values.isEmpty)
        #expect(response.result.composedBy == .template)
        #expect(response.result.prose == result.prose)
        #expect(response.result.transcriptText == nil)
    }

    /// Sensor: capability, help, small talk, reset, follow-up declines, and
    /// executor declines never reach the composer, even with the setting ON.
    @Test func fixedRoutesNeverCallTheComposerEvenWhenEnabled() async throws {
        let calls = Recorder<HallieAnswerPlan>()
        let declined = HallieTurnExecutor.Result(
            route: .presence, outcome: .declined,
            prose: ArchivistPresenceAnswerComposer.noEvidenceProse,
            basisLine: "Basis: no matching catalog evidence.",
            queryDescription: "shape=presence", citations: [], catalogPersonName: nil,
            matchCount: 0)
        let deps = dependencies(
            ast: .presence(.init(people: ["nobody"])), result: declined, composeCalls: calls)
        for question in ["help", "thanks", "start over", "can we change donna's biography?",
                         "play the first one", "show me nobody"] {
            let response = try await HallieAppTurnCoordinator.execute(
                question: question,
                records: [], referent: .init(recordID: nil, temporalDate: nil),
                hosts: ["fixture.invalid"], modelName: "fixture-model",
                composeWithModel: true,
                history: [.init(user: "earlier question", assistant: "earlier answer")],
                dependencies: deps)
            #expect(response.result.composedBy == .template, Comment(rawValue: question))
        }
        #expect(calls.values.isEmpty)
    }

    @Test func coordinatorSlowComposerFallsBackWithoutBlocking() async throws {
        let result = listResult()
        let deps = HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { hosts in hosts },
            translateAST: { _, _, _ in .init(ast: .presence(.init(people: ["donna"])), responderHost: "h") },
            loadProfiles: { [] },
            loadGraph: { nil },
            executeRequest: { _, _ in result },
            continueTurn: { _, _, _ in result },
            resolveBiographyPhoto: { _ in nil },
            composeAnswer: { plan, history, _, _ in
                let composer = HallieGroundedComposer(personaName: "Hallie Mae", timeoutSeconds: 0.2) { _, _ in
                    try await Task.sleep(nanoseconds: 5_000_000_000)
                    return "never [c1]."
                }
                return await composer.compose(plan: plan, history: history)
            })
        let started = ContinuousClock.now
        let response = try await HallieAppTurnCoordinator.execute(
            question: "show me donna", records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            composeWithModel: true, dependencies: deps)
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(response.result.composedBy == .template)
        #expect(response.result.prose == result.prose)
    }

    // MARK: Shell

    @Test func shellComposeFlagParsesAndDefaultsOff() throws {
        #expect(try HallieShellCLI.parse(arguments: ["--hallie"]).compose == false)
        let options = try HallieShellCLI.parse(arguments: [
            "--hallie", "--compose", "--once", "who is ellen?"])
        #expect(options.compose)
        #expect(options.once == "who is ellen?")
    }

    private func shellDependencies(
        result: HallieTurnExecutor.Result,
        composeCalls: Recorder<HallieAnswerPlan>,
        transcript: Recorder<HallieTranscriptEvent>
    ) -> HallieShellCLI.Dependencies {
        HallieShellCLI.Dependencies(
            loadCatalog: { _ in [] },
            loadProfiles: { .loaded([]) },
            loadGraph: { _ in nil },
            translateAST: { _, _ in .init(ast: .presence(.init(people: ["donna"])), responderHost: "fixture") },
            executeTurn: { _, _ in result },
            performMediaAction: { _ in },
            recordTranscript: { transcript.append(contentsOf: $0) },
            composeAnswer: { plan, history, options in
                composeCalls.append(plan)
                #expect(options.compose)
                let composer = HallieGroundedComposer(personaName: "Hallie Mae") { _, _ in
                    "Just one, donna_cape.mov [c2]."
                }
                return await composer.compose(plan: plan, history: history)
            })
    }

    @Test func shellWithoutComposeFlagPrintsTemplateAndSkipsComposer() async {
        let calls = Recorder<HallieAnswerPlan>()
        let transcript = Recorder<HallieTranscriptEvent>()
        let output = Recorder<String>()
        var options = HallieShellCLI.Options()
        options.once = "show me donna"
        _ = await HallieShellCLI.run(
            options: options, input: { nil }, output: { output.append($0) },
            dependencies: shellDependencies(result: listResult(), composeCalls: calls, transcript: transcript))
        #expect(calls.values.isEmpty)
        #expect(output.values.contains("I found 1 catalog item matching that."))
        #expect(!output.values.contains { $0.hasPrefix("phrased by:") })
        let assistant = transcript.values.first { $0.kind == .assistant }
        #expect(assistant?.composedBy == "template")
    }

    @Test func shellWithComposeFlagShowsVerifiedProseAndLogsTaggedText() async {
        let calls = Recorder<HallieAnswerPlan>()
        let transcript = Recorder<HallieTranscriptEvent>()
        let output = Recorder<String>()
        var options = HallieShellCLI.Options()
        options.once = "show me donna"
        options.compose = true
        _ = await HallieShellCLI.run(
            options: options, input: { nil }, output: { output.append($0) },
            dependencies: shellDependencies(result: listResult(), composeCalls: calls, transcript: transcript))
        #expect(calls.values.count == 1)
        #expect(output.values.contains("Just one, donna_cape.mov."))
        #expect(output.values.contains { $0.hasPrefix("phrased by: model") })
        let assistant = transcript.values.first { $0.kind == .assistant }
        #expect(assistant?.composedBy == "model")
        #expect(assistant?.text == "Just one, donna_cape.mov [c2].")
        #expect(assistant?.basisLine == "Basis: 1 cited of 1 matching catalog items.")
    }
}

// MARK: - Eval-driven hardening (Rick's 2026-08-21 conversational-quality pass)

@Suite("Hallie composition — noise rejection and richer list claims")
struct HallieCompositionNoiseTests {

    private func listPlan() -> HallieAnswerPlan {
        HallieAnswerPlan(
            route: .cross, shape: .list,
            claims: [
                .init(id: "c1", text: "I found 21 catalog items matching that."),
                .init(id: "c2", text: "Item 1: Clip 01.dv — confirmed person tag Donna proves donna"),
            ],
            counts: [.init(label: "matching catalog items", value: 21)],
            fallbackText: "I found 21 catalog items matching that.")
    }

    /// The live bug: a good answer with a bogus "no evidence" sentence welded
    /// on. Composition only runs on ANSWERED turns, so that sentence is noise.
    @Test func falseNoEvidenceSentenceIsDropped() {
        let v = HallieCompositionVerifier.verify(
            "There are 21 clips of Donna here [c1][c2]. I don't have evidence for that [c2].",
            plan: listPlan(), personaName: "Hallie")
        #expect(v.kept.count == 1)
        #expect(v.displayText == "There are 21 clips of Donna here.")
        #expect(v.dropped.contains { $0.reason == .falseNoEvidence })
    }

    /// History narration bleeding into an answer (the "who did Rick marry?"
    /// turn that recited two earlier questions).
    @Test func conversationNarrationIsDropped() {
        let v = HallieCompositionVerifier.verify(
            "You asked about that [c1]. There are 21 clips [c1].",
            plan: listPlan(), personaName: "Hallie")
        #expect(v.kept.count == 1)
        #expect(v.displayText == "There are 21 clips.")
        #expect(v.dropped.contains { $0.reason == .metaConversation })
    }

    /// A plan that legitimately voices an absence may still be phrased that
    /// way — the rule keys on the PLAN, not on the words alone.
    @Test func genuineNoEvidencePlanMayStillSayIt() {
        let plan = HallieAnswerPlan(
            route: .graph, shape: .fact,
            claims: [.init(id: "c1", text: "The family tree has no evidence of a second marriage.")],
            fallbackText: "no evidence")
        let v = HallieCompositionVerifier.verify(
            "The family tree has no evidence of a second marriage [c1].",
            plan: plan, personaName: "Hallie")
        #expect(v.kept.count == 1)
        #expect(v.dropped.isEmpty)
    }

    @Test func ordinaryAnswersSurviveBothRules() {
        // Both sentences cite the claims that vouch for their facts — the
        // pre-existing leak rules still apply on top of the new ones.
        let v = HallieCompositionVerifier.verify(
            "There are 21 clips of Donna here [c1][c2]. The earliest is Clip 01.dv [c2].",
            plan: listPlan(), personaName: "Hallie")
        #expect(v.kept.count == 2)
        #expect(v.dropped.isEmpty)
    }

    // MARK: richer list claims

    private func citation(_ name: String, year: Int?, person: String?) -> HallieTurnExecutor.Citation {
        var bases: [ArchivistEvidenceBasis] = []
        if let year { bases.append(.pathYear(year: year, fullPath: "/x/\(year)/\(name)")) }
        if let person {
            bases.append(.humanPersonTag(queryIdentity: person.lowercased(),
                                         taggedName: person,
                                         confirmedAt: Date(timeIntervalSince1970: 1_700_000_000)))
        }
        return .init(recordID: UUID(), fullPath: "/x/\(name)", filename: name,
                     playbackSeconds: nil, bases: bases)
    }

    /// Without these the composer can only re-say "I found N catalog items".
    @Test func listPlanCarriesSpanAndPeopleClaims() {
        let cites = [
            citation("a.mov", year: 1993, person: "Donna"),
            citation("b.mov", year: 2011, person: "Donna"),
            citation("c.mov", year: 1998, person: "Rick"),
        ]
        let plan = HallieAnswerPlan.presenceList(
            route: .cross, prose: "I found 3 catalog items matching that.",
            totalMatchCount: 3, shownCount: 3, citations: cites)
        let texts = plan.claims.map(\.text)
        #expect(texts.contains { $0.contains("1993") && $0.contains("2011") })
        #expect(texts.contains { $0.contains("Donna") && $0.contains("2 of them") })
        #expect(plan.claims.first?.text == "I found 3 catalog items matching that.")
        // Item claims still present and last.
        #expect(texts.contains { $0.hasPrefix("Item 1:") })
    }

    @Test func spanClaimReadsSinglyWhenOneYear() {
        let plan = HallieAnswerPlan.presenceList(
            route: .presence, prose: "p", totalMatchCount: 1, shownCount: 1,
            citations: [citation("a.mov", year: 1984, person: nil)])
        #expect(plan.claims.map(\.text).contains { $0 == "These are from 1984." })
    }

    @Test func undatedCitationsProduceNoSpanClaim() {
        let plan = HallieAnswerPlan.presenceList(
            route: .presence, prose: "p", totalMatchCount: 1, shownCount: 1,
            citations: [citation("a.mov", year: nil, person: nil)])
        #expect(!plan.claims.map(\.text).contains { $0.hasPrefix("These are from") })
        #expect(!plan.claims.map(\.text).contains { $0.hasPrefix("These run from") })
    }
}
