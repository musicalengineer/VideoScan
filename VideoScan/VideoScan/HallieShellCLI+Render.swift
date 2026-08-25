// HallieShellCLI+Render.swift
// Output rendering, transcript events, and follow-up media actions for the
// headless shell. Split from HallieShellCLI.swift for file length; the
// behaviour is unchanged.

import Foundation
import VideoScanCore

extension HallieShellCLI {

    static func transcriptEvent(
        result: HallieTurnExecutor.Result,
        responder: String,
        state: inout Session
    ) -> HallieTranscriptEvent {
        transcriptEvent(
            kind: .assistant,
            // The log keeps the claim tags a model-phrased answer carried,
            // so every logged sentence traces to its plan claim.
            text: result.transcriptText ?? result.prose,
            queryDescription: result.queryDescription,
            basisLine: result.basisLine,
            responder: responder,
            route: transcriptLabel(result.route),
            outcome: transcriptLabel(result.outcome),
            offeredActions: (result.clarification?.candidates.map(\.label) ?? [])
                + result.offeredActions.map(HallieTurnExecutor.offerLabel),
            citations: result.citations,
            knowledgeCitations: result.knowledgeCitations,
            attachments: result.attachments,
            composedBy: result.composedBy.rawValue,
            state: &state)
    }

    static func transcriptEvent(
        kind: HallieTranscriptEvent.Kind,
        text: String,
        queryDescription: String? = nil,
        basisLine: String? = nil,
        responder: String? = nil,
        route: String? = nil,
        outcome: String? = nil,
        offeredActions: [String] = [],
        citations: [HallieTurnExecutor.Citation] = [],
        knowledgeCitations: [HallieTurnExecutor.KnowledgeCitation] = [],
        attachments: [HallieAttachment] = [],
        composedBy: String? = nil,
        state: inout Session
    ) -> HallieTranscriptEvent {
        state.transcriptSequence += 1
        return HallieTranscriptEvent(
            sessionID: state.transcriptSessionID,
            runID: state.runID,
            sequence: state.transcriptSequence,
            client: .shell,
            kind: kind,
            text: text,
            queryDescription: queryDescription,
            basisLine: basisLine,
            responder: responder,
            model: state.model,
            route: route,
            outcome: outcome,
            offeredActions: offeredActions,
            mediaEvidence: citations.map {
                .init(recordID: $0.recordID,
                      filename: $0.filename,
                      fullPath: $0.fullPath,
                      playbackSeconds: $0.playbackSeconds,
                      bases: $0.bases.map(evidenceDescription))
            },
            knowledgeEvidence: knowledgeCitations.map {
                .init(id: $0.id, title: $0.title,
                      attribution: $0.attribution, locator: $0.locator)
            },
            attachmentOutline: attachments.isEmpty
                ? nil : HallieAttachmentText.lines(attachments),
            composedBy: composedBy)
    }

    static func transcriptLabel(_ route: HallieTurnExecutor.Route) -> String {
        HallieTurnExecutor.label(route)
    }

    static func transcriptLabel(_ outcome: HallieTurnExecutor.Outcome) -> String {
        HallieTurnExecutor.label(outcome)
    }

    /// Perform a follow-up media action ("play the first one") on already
    /// cited items through the same seam as `:play N` / `:reveal N`. `show`
    /// prints the item; the shell has no catalog window to point at.
    static func performMediaAction(
        _ action: HallieTurnExecutor.MediaActionRequest?,
        output: (String) -> Void,
        dependencies: Dependencies,
        allowActions: Bool = true
    ) -> CommandOutcome {
        guard let action else { return .continueSession }
        guard allowActions else {
            let names = action.citations.map(\.filename).joined(separator: ", ")
            output("\(actionsDisabledNotice); requested \(action.kind.rawValue)"
                   + (names.isEmpty ? "" : " \(names)"))
            return .continueSession
        }
        switch action.kind {
        case .show:
            for citation in action.citations {
                output("showing \(citation.filename) — \(citation.fullPath)")
            }
            return .continueSession
        case .play, .reveal:
            // First available item wins for play (one player); reveal walks
            // every requested item.
            let isPlay = action.kind == .play
            var performed = 0
            for citation in action.citations {
                let url = URL(fileURLWithPath: citation.fullPath)
                guard dependencies.mediaURLIsAvailable(url) else {
                    output("\(citation.filename) is unavailable or unreadable; skipping.")
                    continue
                }
                let media: MediaAction = isPlay ? .play(url) : .reveal(url)
                guard dependencies.tryPerformMediaAction(media) else {
                    output("The system refused to \(isPlay ? "open" : "reveal") \(citation.filename).")
                    continue
                }
                output(isPlay ? "opening \(citation.filename)" : "revealing \(citation.filename)")
                performed += 1
                if isPlay { break }
            }
            if performed == 0 {
                output("No media action was completed.")
                return .mediaFailure
            }
            return .continueSession
        }
    }

    static func render(
        _ result: HallieTurnExecutor.Result,
        ast: ArchivistQueryAST?,
        context: HallieTurnExecutor.Context,
        state: inout Session,
        diagnostics: Bool = false,
        output: (String) -> Void
    ) {
        // A follow-up media action keeps the previous citation list numbered
        // as it was; anything else replaces it.
        if result.route != .followUp || result.mediaAction == nil {
            state.citations = result.citations
        }
        state.knowledgeCitations = result.knowledgeCitations
        state.pendingClarification = result.clarification.map {
            Session.PendingClarification(value: $0, context: context)
        }
        state.biographyPhoto = nil
        if result.clarification == nil,
           case .graph(let payload)? = ast,
           payload.operation == .biography,
           let canonical = result.catalogPersonName {
            state.biographyPhoto = ArchivistBiographyPhoto.resolve(
                personName: canonical, profiles: state.profiles ?? [])
        }
        output(result.prose)
        var attachments = result.attachments
        if state.biographyPhoto == nil, result.clarification == nil,
           result.outcome == .answered,
           case .graph(let payload)? = ast, payload.operation == .biography,
           let canonical = result.catalogPersonName {
            let assets = FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
            let person = FamilyAssetPerson(name: canonical)
            if let url = assets.photoURLs(for: person).first {
                attachments.append(.photo(HalliePhotoAttachment(
                    personName: canonical, fileURL: url)))
            }
        }
        for line in HallieAttachmentText.lines(attachments) { output(line) }
        if diagnostics {
            if result.composedBy == .model {
                output("phrased by: model (facts verified against the plan)")
            }
            output(result.basisLine)
            if result.route == .graph, let photo = state.biographyPhoto {
                output("photo: \(photo.fileURL.path)")
            }
            if let queryDescription = result.queryDescription {
                output("query: \(queryDescription)")
            }
            if result.route != .followUp || result.mediaAction == nil {
                printCitations(state.citations, output: output)
            }
            printKnowledgeCitations(state.knowledgeCitations, output: output)
            for action in result.offeredActions {
                switch action {
                case .openFamilyTree(let name):
                    output("offer: open the Family Tree tab focused on \(name) (app only)")
                case .openFamilyTreePerson(_, let name):
                    output("offer: open the Family Tree tab focused on \(name) (app only)")
                case .openFamilyTreeSurname(let surname):
                    output("offer: open the Family Tree tab filtered to \(surname) (app only)")
                case .getFamilyTree:
                    output("offer: open Get Family Tree in the Family Tree tab (app only)")
                case .ask(let question, _):
                    output("offer: ask “\(question)”")
                }
            }
        }
        if let clarification = result.clarification {
            printClarification(clarification, output: output)
        }
    }

    static func printClarification(
        _ clarification: HallieTurnExecutor.Clarification,
        output: (String) -> Void
    ) {
        output("choices:")
        for (index, candidate) in clarification.candidates.enumerated() {
            output("  \(index + 1). \(candidate.label)")
        }
        output("Reply with a number or exact name; :cancel abandons this question.")
    }

    static func printCitations(
        _ citations: [HallieTurnExecutor.Citation],
        output: (String) -> Void
    ) {
        guard !citations.isEmpty else { output("citations: none"); return }
        output("citations:")
        for (index, citation) in citations.enumerated() {
            let at = citation.playbackSeconds.map { String(format: " @ %.1fs", $0) } ?? ""
            output("  \(index + 1). \(citation.filename)\(at) — \(citation.fullPath)")
            output("     \(citation.bases.map(evidenceDescription).joined(separator: "; "))")
        }
    }

    static func printKnowledgeCitations(
        _ citations: [HallieTurnExecutor.KnowledgeCitation],
        output: (String) -> Void
    ) {
        guard !citations.isEmpty else { return }
        output("knowledge sources:")
        for (index, citation) in citations.enumerated() {
            let attribution = citation.attribution.map { " — \($0)" } ?? ""
            let locator = citation.locator.map { " [\($0)]" } ?? ""
            output("  \(index + 1). \(citation.title)\(attribution)\(locator)")
        }
    }

    static func evidenceDescription(_ basis: ArchivistEvidenceBasis) -> String {
        basis.summary
    }
}
