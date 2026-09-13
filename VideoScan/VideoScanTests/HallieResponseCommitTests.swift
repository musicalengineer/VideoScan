import Foundation
import Testing
@testable import VideoScan

/// Executes the production commit helper through inert sinks: no window,
/// player, speech engine, model, defaults, filesystem evidence, or profile.
@Suite("Hallie response commit")
@MainActor
struct HallieResponseCommitTests {
    private typealias Commit = HallieResponseCommit
    private typealias Exec = HallieTurnExecutor

    @MainActor
    private final class Capture {
        var events: [String] = []
        var state = Commit.State()
        var messages: [ArchivistMessage] = []
        var records: [UUID: VideoRecord] = [:]
        var speechEnabled = true
        var spoken: [(String, String?)] = []
        var prepared: [(String, String)] = []
        var media: [Exec.MediaActionRequest] = []
        var played: [[UUID]] = []
        var focused: [(String, String)] = []
        var recompiled: [String?] = []
        var accepted: [Exec.Result] = []
        var memoryAtMessage: [Exec.ConversationMemory] = []
        var memoryAtMedia: [Exec.ConversationMemory] = []

        var sinks: Commit.Sinks {
            .init(
                isSpeechEnabled: { self.events.append("speechEnabled"); return self.speechEnabled },
                speakPrepared: { self.events.append("prepared"); self.prepared.append(($0, $1)) },
                speak: { self.events.append("speak"); self.spoken.append(($0, $1)) },
                recordForID: { self.events.append("lookup"); return self.records[$0] },
                publishState: { self.events.append("state"); self.state = $0 },
                appendMessage: { self.events.append("message"); self.messages.append($0); self.memoryAtMessage.append(self.state.memory) },
                performMediaAction: { self.events.append("media"); self.media.append($0); self.memoryAtMedia.append(self.state.memory) },
                play: { self.events.append("play"); self.played.append($0.map(\.id)) },
                openFamilyTreePerson: { self.events.append("focus"); self.focused.append(($0, $1)) },
                recompileFamilyTree: { self.events.append("recompile"); self.recompiled.append($0) },
                acceptImmediateOffer: { self.events.append("navigation"); self.accepted.append($0) })
        }

        @discardableResult
        func apply(_ response: HallieAppTurnCoordinator.Response,
                   question: String? = "fixture question",
                   requestID: UUID = UUID(), active: UUID? = nil,
                   cancelled: Bool = false) -> Bool {
            Commit.apply(response, question: question, modelName: "fixture-model",
                         requestID: requestID, activeRequestID: active ?? requestID,
                         isCancelled: cancelled, state: state, sinks: sinks)
        }
    }

    private func citation(_ id: UUID = UUID()) -> Exec.Citation {
        .init(recordID: id, fullPath: "/synthetic/never-open.mov", filename: "never-open.mov",
              playbackSeconds: 12.5, bases: [])
    }

    private func result(route: Exec.Route = .graph, outcome: Exec.Outcome = .answered,
                        citations: [Exec.Citation] = [],
                        clarification: Exec.Clarification? = nil,
                        media: Exec.MediaActionRequest? = nil,
                        offers: [Exec.OfferedAction] = [],
                        immediate: Exec.OfferedAction? = nil) -> Exec.Result {
        .init(route: route, outcome: outcome, prose: "Fixture answer.", basisLine: "Fixture basis.",
              queryDescription: "fixture query", citations: citations,
              knowledgeCitations: [.init(id: "source-1", title: "Synthetic source", attribution: "Fixture", locator: "relative/source")],
              catalogPersonName: "Fixture Person", clarification: clarification,
              mediaAction: media, offeredActions: offers, transcriptText: "Fixture answer. [claim-1]",
              attachments: [.photoRequest(personName: "Fixture Person", folderURL: URL(fileURLWithPath: "/synthetic/never-open"))],
              immediateOfferedAction: immediate)
    }

    private func response(_ result: Exec.Result,
                          citations: [Exec.Citation]? = nil,
                          pending: HallieAppTurnCoordinator.PendingClarification? = nil,
                          autoPlay: Bool = false,
                          intent: Exec.Intent? = nil) -> HallieAppTurnCoordinator.Response {
        .init(result: result, responderHost: "fixture.invalid",
              biographyPhoto: .init(profileStableID: "fixture", profileCanonicalName: "Fixture Person",
                                    fileURL: URL(fileURLWithPath: "/synthetic/never-open.png"),
                                    cropOffsetX: 0.1, cropOffsetY: 0.2, cropScale: 1.5),
              capturedReferentID: UUID(), citations: citations ?? result.citations,
              pendingClarification: pending, playAfterAnswer: autoPlay, executedIntent: intent)
    }

    private func pending(_ name: String) -> HallieAppTurnCoordinator.PendingClarification {
        let context = Exec.Context()
        let intent = Exec.Intent(originalQuestion: "Who is \(name)?",
                                 ast: .graph(.init(people: [name], operation: .relationship)))
        let clarification = Exec.makeClarification(
            intent: intent, stage: .suggestedIdentity,
            candidates: [.init(id: .gedcomPersonID("@\(name)@"), canonicalName: name, label: "\(name) (fixture)")],
            context: context)
        return .init(clarification: clarification, context: context, responderHost: "fixture.invalid",
                     capturedReferentID: UUID(), composition: .off)
    }

    @Test func cancelledSupersededAndFinishedRequestsHaveZeroEffects() {
        let request = UUID()
        for (active, cancelled) in [(Optional(request), true), (Optional(UUID()), false), (nil, false)] {
            let capture = Capture()
            capture.state.lastResponder = "previous responder"
            let old = pending("Previous")
            capture.state.pendingClarification = old
            let action = Exec.MediaActionRequest(kind: .play, citations: [citation()])
            let value = response(result(citations: action.citations, media: action,
                                        immediate: .recompileFamilyTree), autoPlay: true)
            // #expect is Swift Testing's EXPECT-style assertion; it does not
            // abort the case, so a failure retains the sink evidence below.
            #expect(!Commit.apply(value, modelName: "fixture", requestID: request,
                                  activeRequestID: active, isCancelled: cancelled,
                                  state: capture.state, sinks: capture.sinks))
            #expect(capture.events.isEmpty)
            #expect(capture.messages.isEmpty)
            #expect(capture.state.lastResponder == "previous responder")
            #expect(capture.state.pendingClarification?.clarification == old.clarification)
        }
    }

    @Test func evidenceAndTranscriptFieldsSurviveInOrder() throws {
        let capture = Capture()
        let first = VideoRecord(), second = VideoRecord()
        capture.records = [first.id: first, second.id: second]
        let shown = [citation(second.id), citation(), citation(first.id)]
        let value = response(result(citations: [citation()]), citations: shown)
        #expect(capture.apply(value))
        #expect(capture.events == ["speechEnabled", "speak", "lookup", "lookup", "lookup", "state", "message", "navigation"])
        #expect(capture.state.lastMatches.map(\.id) == [second.id, first.id])
        #expect(capture.state.lastResponder == value.responderHost)
        let message = try #require(capture.messages.first)
        #expect(message.role == .assistant)
        #expect(message.text == value.result.prose)
        #expect(message.queryLine == value.result.queryDescription)
        #expect(message.basisLine == value.result.basisLine)
        #expect(message.citations == shown)
        #expect(message.knowledgeCitations == value.result.knowledgeCitations)
        #expect(message.biographyPhoto == value.biographyPhoto)
        #expect(message.attachments == value.result.attachments)
        #expect(message.responder == "fixture.invalid")
        #expect(message.model == "fixture-model")
        #expect(message.route == Exec.label(value.result.route))
        #expect(message.outcome == Exec.label(value.result.outcome))
        #expect(message.composedBy == value.result.composedBy.rawValue)
        #expect(message.transcriptText == value.result.transcriptText)
        #expect(capture.spoken.first?.0 == value.result.prose)
        #expect(capture.spoken.first?.1 == "Fixture Person")
        #expect(capture.accepted == [value.result])
    }

    @Test func repairKeepsPendingUnlessReplacementArrivesAndOrdinaryAnswerClearsIt() {
        let capture = Capture()
        let old = pending("Old"), replacement = pending("New")
        capture.state.pendingClarification = old
        capture.apply(response(result(outcome: .repaired)))
        #expect(capture.state.pendingClarification?.clarification == old.clarification)
        #expect(capture.state.pendingClarification?.capturedReferentID == old.capturedReferentID)
        capture.apply(response(result(outcome: .repaired), pending: replacement))
        #expect(capture.state.pendingClarification?.clarification == replacement.clarification)
        #expect(capture.state.pendingClarification?.capturedReferentID == replacement.capturedReferentID)
        capture.apply(response(result()))
        #expect(capture.state.pendingClarification == nil)
    }

    @Test func sessionsAreReplacedAndThenCleared() {
        let capture = Capture()
        var value = response(result())
        value.telling = .init(opening: .init(subject: "Fixture Person", relation: nil, pronoun: .they, firstStatement: nil))
        value.drill = .init(list: .init(items: []), index: nil)
        value.picker = .init(word: "Fixture", candidates: [])
        capture.apply(value)
        #expect(capture.state.telling == value.telling)
        #expect(capture.state.drill == value.drill)
        #expect(capture.state.picker == value.picker)
        capture.apply(response(result()))
        #expect(capture.state.telling == nil)
        #expect(capture.state.drill == nil)
        #expect(capture.state.picker == nil)
    }

    @Test func followUpMediaKeepsShownReferentsAndDoesNotRepeatCitations() throws {
        for kind in [Exec.MediaActionRequest.Kind.play, .reveal, .show] {
            let capture = Capture()
            let old = VideoRecord()
            capture.state.lastMatches = [old]
            let requested = Exec.MediaActionRequest(kind: kind, citations: [citation(old.id)])
            let value = response(result(route: .followUp, citations: [citation()], media: requested), autoPlay: true)
            capture.apply(value)
            #expect(capture.state.lastMatches.map(\.id) == [old.id])
            #expect(try #require(capture.messages.first).citations.isEmpty)
            #expect(capture.media == [requested])
            #expect(capture.played.isEmpty)
            #expect(capture.events == ["speechEnabled", "speak", "state", "message", "media", "navigation"])
        }
    }

    @Test func followUpWithoutMediaReplacesPreviousReferents() {
        let capture = Capture()
        capture.state.lastMatches = [VideoRecord()]
        capture.apply(response(result(route: .followUp)))
        #expect(capture.state.lastMatches.isEmpty)
    }

    @Test func autoPlayUsesOnlyResolvedShownEvidenceAfterMessage() {
        let capture = Capture()
        let shown = VideoRecord()
        capture.records[shown.id] = shown
        capture.state.lastMatches = [VideoRecord()]
        capture.apply(response(result(citations: [citation(shown.id), citation()]), autoPlay: true))
        #expect(capture.played == [[shown.id]])
        #expect(capture.events == ["speechEnabled", "speak", "lookup", "lookup", "state", "message", "play", "navigation"])
        capture.apply(response(result(citations: [citation()]), autoPlay: true))
        #expect(capture.played.count == 1)
        #expect(capture.state.lastMatches.isEmpty)
    }

    @Test func preparedSpeechHonorsAppleFallbackAndDisabledVoice() {
        for fallback in [Optional("Apple version"), nil] {
            let capture = Capture()
            var value = response(result())
            value.pickerSpeech = "[Fixture](/phonemes/)"
            value.pickerSpeechFallback = fallback
            capture.apply(value)
            #expect(capture.prepared.first?.0 == value.pickerSpeech)
            #expect(capture.prepared.first?.1 == (fallback ?? value.pickerSpeech))
            #expect(capture.spoken.isEmpty)
            #expect(capture.events.prefix(2) == ["speechEnabled", "prepared"])
            capture.speechEnabled = false
            capture.apply(value)
            #expect(capture.prepared.count == 1)
            #expect(capture.messages.count == 2)
        }
    }

    @Test func clarificationAndEveryOfferKeepTypedActionsAndTheirOrder() throws {
        let capture = Capture()
        let pending = pending("Fixture")
        let folder = URL(fileURLWithPath: "/synthetic/never-open")
        let offers: [Exec.OfferedAction] = [
            .openFamilyTree(personName: "Fixture"), .openFamilyTreePerson(personID: "@I1@", personName: "Fixture"),
            .openFamilyTreeSurname("Fixture"), .getFamilyTree, .ask(question: "Next?", label: "Next"),
            .recompileFamilyTree, .openPeopleTab, .openAppDestination(.archive),
            .showPossibleDuplicate(personID: "@I2@", personName: "Other"), .revealFolder(url: folder, label: "Folder")]
        var value = response(result(clarification: pending.clarification, offers: offers), pending: pending)
        value.picker = .init(word: "Fixture", candidates: [])
        capture.apply(value, question: "Original question")
        let actions: [ArchivistMessage.Chip.Action] = [
            .hallieIdentityChoice(pending.clarification.candidates[0].id),
            .openFamilyTree(personName: "Fixture"), .openFamilyTreePerson(personID: "@I1@", personName: "Fixture"),
            .openFamilyTreeSurname("Fixture"), .getFamilyTree, .askText("Next?", playAfterAnswer: false),
            .recompileFamilyTree(thenAsk: "Original question"), .openPeopleTab, .openAppDestination(.archive),
            .openFamilyTreePerson(personID: "@I2@", personName: "Other"), .revealFolder(folder)]
        let message = try #require(capture.messages.first)
        #expect(Array(message.chips.prefix(actions.count)).map(\.action) == actions)
        #expect(Array(message.chips.dropFirst()).prefix(offers.count).map(\.label) == offers.map(Exec.offerLabel))
        let picker = try #require(value.picker)
        #expect(Array(message.chips.dropFirst(actions.count)).map(\.action) == ArchivistMessage.pickerChips(for: picker).map(\.action))
        #expect(capture.focused.isEmpty)
        #expect(capture.recompiled.isEmpty)
    }

    @Test func immediateActionUsesItsIdentityAndRunsAfterMessageAndMedia() {
        let capture = Capture()
        let media = Exec.MediaActionRequest(kind: .reveal, citations: [citation()])
        let focus = Exec.OfferedAction.openFamilyTreePerson(personID: "@TARGET@", personName: "Target")
        capture.apply(response(result(media: media, offers: [.openPeopleTab, focus], immediate: focus)))
        #expect(capture.events == ["speechEnabled", "speak", "state", "message", "media", "focus", "navigation"])
        #expect(capture.focused.first?.0 == "@TARGET@")
        #expect(capture.focused.first?.1 == "Target")
        #expect(capture.media == [media])
        capture.apply(response(result(offers: [.openPeopleTab, .recompileFamilyTree], immediate: .recompileFamilyTree)), question: "Retry this")
        #expect(capture.recompiled.count == 1)
        #expect(capture.recompiled[0] == "Retry this")
        #expect(capture.events.suffix(3) == ["message", "recompile", "navigation"])
    }

    @Test func sameActiveRequestAllowsSeveralClausesAndDoesNotInventDeduplication() {
        let capture = Capture()
        let request = UUID()
        let first = response(result()), second = response(result(route: .followUp))
        #expect(capture.apply(first, requestID: request))
        #expect(capture.apply(second, requestID: request))
        #expect(capture.apply(first, requestID: request))
        #expect(capture.messages.map(\.route) == ["graph", "follow-up", "graph"])
        #expect(capture.spoken.count == 3)
        #expect(capture.accepted.count == 3)
    }

    /// Requires real ConversationMemory, including its evidence retention.
    /// A standalone harness with inert memory must not claim to run this case.
    @Test func committedMemoryIsVisibleBeforeMessageActionAndTheNextClause() throws {
        let capture = Capture()
        let request = UUID()
        let record = VideoRecord()
        capture.records[record.id] = record
        let evidence = [citation(record.id)]
        let ast = ArchivistQueryAST.presence(.init(people: ["Fixture Person"]))
        let intent = Exec.Intent(originalQuestion: "Find Fixture Person", ast: ast)
        let first = response(result(route: .presence, citations: evidence), intent: intent)
        #expect(capture.apply(first, question: "Entire compound question", requestID: request))
        let atMessage = try #require(capture.memoryAtMessage.first)
        #expect(atMessage.lastAST == ast)
        #expect(atMessage.lastSubject == "Fixture Person")
        #expect(atMessage.lastExchange?.question == intent.originalQuestion)
        #expect(atMessage.lastShownList?.citations == evidence)

        // Clause two takes its evidence from clause one's published memory,
        // just as the chat loop rebuilds each next request from window state.
        let carried = try #require(capture.state.memory.lastShownList)
        let action = Exec.MediaActionRequest(kind: .play, citations: carried.citations)
        let second = response(result(route: .followUp, media: action))
        #expect(capture.apply(second, question: "Play the first", requestID: request))
        let atAction = try #require(capture.memoryAtMedia.first)
        #expect(atAction.lastAST == ast)
        #expect(atAction.lastShownList?.citations == evidence)
        #expect(atAction.lastExchange?.question == intent.originalQuestion)
        #expect(capture.media == [action])
        #expect(capture.memoryAtMessage.count == 2)
        #expect(capture.memoryAtMessage[1].lastShownList?.citations == evidence)
    }
}
