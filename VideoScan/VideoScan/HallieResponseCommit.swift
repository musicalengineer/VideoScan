import Foundation

/// Applies one local Hallie response synchronously on the window's actor.
/// The window retains request ownership; this helper has no session or
/// duplicate-completion cache (one request may commit several clauses).
@MainActor
enum HallieResponseCommit {
    /// A temporary value snapshot, not a second conversation/session owner.
    struct State {
        var lastResponder: String? = nil
        var pendingClarification: HallieAppTurnCoordinator.PendingClarification? = nil
        var telling: HallieTellingMode.Session? = nil
        var drill: HalliePronunciationDrillMode.Session? = nil
        var picker: HalliePronunciationPicker.Offer? = nil
        var memory = HallieTurnExecutor.ConversationMemory()
        var lastMatches: [VideoRecord] = []
    }

    /// Injected callbacks are analogous to C++ function objects; production
    /// supplies the existing window effects and tests supply recording sinks.
    struct Sinks {
        let isSpeechEnabled: () -> Bool
        let speakPrepared: (String, String) -> Void
        let speak: (String, String?) -> Void
        let recordForID: (UUID) -> VideoRecord?
        let publishState: (State) -> Void
        let appendMessage: (ArchivistMessage) -> Void
        let performMediaAction: (HallieTurnExecutor.MediaActionRequest) -> Void
        let play: ([VideoRecord]) -> Void
        let openFamilyTreePerson: (_ personID: String, _ personName: String) -> Void
        let recompileFamilyTree: (String?) -> Void
        let acceptImmediateOffer: (HallieTurnExecutor.Result) -> Void
    }

    @discardableResult
    static func apply(
        _ response: HallieAppTurnCoordinator.Response,
        question: String? = nil,
        modelName: String,
        requestID: UUID,
        activeRequestID: UUID?,
        isCancelled: Bool,
        state: State,
        sinks: Sinks
    ) -> Bool {
        // Preserve the caller's existing cancellation/identity authority.
        // No suspension occurs between acceptance and the final action.
        guard !isCancelled, activeRequestID == requestID else { return false }
        var state = state
        // Rick 2026-08-22: "in-app, there's no audio." On by default; the
        // settings sheet has the switch and the voice picker.
        if sinks.isSpeechEnabled() {
            if let kokoro = response.pickerSpeech {
                // The picker's candidates carry their own phoneme overrides
                // ("One: [Latta](/lˈætə/). Two: …"); no lexicon pass.
                sinks.speakPrepared(kokoro, response.pickerSpeechFallback ?? kokoro)
            } else {
                sinks.speak(response.result.prose, response.result.catalogPersonName)
            }
        }
        state.lastResponder = response.responderHost
        // A repair reply re-asks the pending which-one; keep it so the next
        // typed or tapped name still selects from it.
        if response.result.outcome == .repaired, response.pendingClarification == nil {
            // keep state.pendingClarification as is
        } else {
            state.pendingClarification = response.pendingClarification
        }
        state.telling = response.telling
        state.drill = response.drill
        state.picker = response.picker
        state.memory.record(intent: response.executedIntent,
                            result: response.result,
                            question: question)
        let citations = response.citations
        let isFollowUpAction = response.result.route == .followUp
            && response.result.mediaAction != nil
        // Bare "play first" may refer only to evidence actually shown in
        // this answer, never an unseen broad result set. A follow-up media
        // action keeps the previous referent list intact.
        if !isFollowUpAction {
            state.lastMatches = citations.compactMap {
                sinks.recordForID($0.recordID)
            }
        }
        sinks.publishState(state)
        let clarificationChips = response.result.clarification?.candidates.map {
            ArchivistMessage.Chip(
                label: $0.label,
                action: .hallieIdentityChoice($0.id))
        } ?? []
        let offerChips = response.result.offeredActions.map { offer -> ArchivistMessage.Chip in
            let label = HallieTurnExecutor.offerLabel(offer)
            switch offer {
            case .openFamilyTree(let name):
                return ArchivistMessage.Chip(
                    label: label, action: .openFamilyTree(personName: name))
            case .openFamilyTreePerson(let id, let name):
                return ArchivistMessage.Chip(
                    label: label,
                    action: .openFamilyTreePerson(
                        personID: id, personName: name))
            case .openFamilyTreeSurname(let surname):
                return ArchivistMessage.Chip(
                    label: label, action: .openFamilyTreeSurname(surname))
            case .getFamilyTree:
                return ArchivistMessage.Chip(label: label, action: .getFamilyTree)
            case .ask(let question, _):
                return ArchivistMessage.Chip(
                    label: label, action: .askText(question, playAfterAnswer: false))
            case .recompileFamilyTree:
                return ArchivistMessage.Chip(
                    label: label, action: .recompileFamilyTree(thenAsk: question))
            case .openPeopleTab:
                return ArchivistMessage.Chip(label: label, action: .openPeopleTab)
            case .openAppDestination(let destination):
                return ArchivistMessage.Chip(
                    label: label, action: .openAppDestination(destination))
            case .showPossibleDuplicate(let id, let name):
                // Same navigation as a person focus: the record with both
                // parents is what Rick needs to see.
                return ArchivistMessage.Chip(
                    label: label,
                    action: .openFamilyTreePerson(personID: id, personName: name))
            case .revealFolder(let url, _):
                return ArchivistMessage.Chip(label: label, action: .revealFolder(url))
            }
        }
        // The variations picker: one chip per way to say the name (click =
        // hear it), then "That's it" for the one heard, and "None of these".
        let pickerChips = response.picker.map { ArchivistMessage.pickerChips(for: $0) } ?? []
        sinks.appendMessage(ArchivistMessage(
            role: .assistant,
            text: response.result.prose,
            queryLine: response.result.queryDescription,
            basisLine: response.result.basisLine,
            biographyPhoto: response.biographyPhoto,
            attachments: response.result.attachments,
            citations: isFollowUpAction ? [] : citations,
            knowledgeCitations: response.result.knowledgeCitations,
            responder: response.responderHost,
            model: modelName,
            route: HallieTurnExecutor.label(response.result.route),
            outcome: HallieTurnExecutor.label(response.result.outcome),
            composedBy: response.result.composedBy.rawValue,
            transcriptText: response.result.transcriptText,
            chips: clarificationChips + offerChips + pickerChips))
        if let action = response.result.mediaAction {
            sinks.performMediaAction(action)
        } else if response.playAfterAnswer, !state.lastMatches.isEmpty {
            sinks.play(state.lastMatches)
        }
        // "center the family tree on Martha Lamson" (2026-08-29): the user
        // asked for the navigation, so the chip's own path runs without a
        // tap. The prose already says what is happening; no second line.
        if case .openFamilyTreePerson(let personID, let personName)? =
            response.result.immediateOfferedAction {
            sinks.openFamilyTreePerson(personID, personName)
        }
        // "I can do that now" (live miss #8): the recompile runs without a
        // tap and the question that hit the refused tree is asked again.
        if case .recompileFamilyTree? = response.result.immediateOfferedAction {
            sinks.recompileFamilyTree(question)
        }
        // Explicit "show/open the … tab/window" asks carry the same action
        // as their chip. Accept only this response's first offer; no old
        // transcript state participates in the decision.
        sinks.acceptImmediateOffer(response.result)
        return true
    }
}
