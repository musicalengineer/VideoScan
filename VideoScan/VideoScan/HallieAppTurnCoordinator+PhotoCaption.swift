// HallieAppTurnCoordinator+PhotoCaption.swift
// The chat window's side of "this photo is me and my family with Donna and
// the boys" (HalliePhotoCaption, 2026-08-26). Resolves who was named
// against the tree, keeps the caption in the CyberBrain, and — when the
// photo had been shown for someone the caption does not name — marks the
// photo as not-of that person so it never comes up for them again.

import Foundation
import VideoScanCore

extension HallieAppTurnCoordinator {

    /// Handle the turn if it captions the photo the previous answer showed.
    /// Nil when no photo is in memory or the turn is not a caption.
    static func photoCaptionResponse(
        question: String,
        memory: HallieTurnExecutor.ConversationMemory,
        referent: CapturedReferent,
        dependencies: Dependencies
    ) -> Response? {
        guard let photo = memory.lastPhotoAttachment,
              let statement = HalliePhotoCaption.detect(question) else { return nil }
        let speakers = dependencies.loadSpeakers()
        let graph = dependencies.loadGraph()
        let cyberBrain = dependencies.loadCyberBrain()
        let owner = graph.flatMap {
            FamilyAssetIdentityDirectory.owner(in: $0, speakers: speakers, cyberBrain: cyberBrain)
        }
        let spouse = owner.flatMap { o in graph?.familyUnits(of: o).compactMap(\.spouse).first }
        let children = owner.map { o in graph?.familyUnits(of: o).flatMap(\.children) ?? [] } ?? []

        typealias Subject = CyberBrainWriter.PhotoCaption.Subject
        var subjects: [Subject] = []
        var shows: [String] = []
        func add(_ subject: Subject) {
            guard !subjects.contains(where: {
                ($0.gedcomPersonID != nil && $0.gedcomPersonID == subject.gedcomPersonID)
                    || FamilyIdentityText.normalized($0.name) == FamilyIdentityText.normalized(subject.name)
            }) else { return }
            subjects.append(subject)
        }
        if statement.mentionsSpeaker {
            if let owner {
                add(Subject(name: owner.name, gedcomPersonID: owner.id))
            } else if let name = speakers.ownerName {
                add(Subject(name: name))
            }
            shows.append("you")
        }
        if statement.mentionsSpouse, let spouse {
            add(Subject(name: spouse.name, gedcomPersonID: spouse.id))
            shows.append(HalliePhotoCaption.capitalised(FamilyIdentityText.tokens(spouse.name).first ?? spouse.name))
        }
        if statement.mentionsFather, let owner, let father = graph?.relatives(.father, of: owner).first {
            add(Subject(name: father.name, gedcomPersonID: father.id))
            shows.append("your dad")
        }
        if statement.mentionsMother, let owner, let mother = graph?.relatives(.mother, of: owner).first {
            add(Subject(name: mother.name, gedcomPersonID: mother.id))
            shows.append("your mom")
        }
        for name in statement.names {
            let resolved = resolve(name, graph: graph, cyberBrain: cyberBrain, spouse: spouse)
            add(resolved.map { Subject(name: $0.name, gedcomPersonID: $0.id) } ?? Subject(name: name))
            shows.append(name)
        }
        if let phrase = statement.childrenPhrase {
            for child in children { add(Subject(name: child.name, gedcomPersonID: child.id)) }
            shows.append(phrase)
        }
        // Nobody named ("this photo is from 1995"): it is about whoever it
        // was shown for.
        if subjects.isEmpty {
            add(Subject(name: photo.personName, gedcomPersonID: photo.personGedcomID))
            shows.append(photo.personName)
        }

        let ownerName = speakers.ownerName ?? ""
        var problems: [String] = []
        let now = Date()
        do {
            try dependencies.recordPhotoCaption(.init(
                subjects: Array(subjects.prefix(CyberBrainWriter.maxCaptionSubjects)),
                speakerName: ownerName,
                text: statement.caption,
                photoPath: photo.fileURL.path,
                date: now))
        } catch {
            problems.append("I couldn't save the caption to the family record (\(error.localizedDescription)); I'll keep it for this conversation.")
        }

        // Correction: shown for someone the caption does not name.
        var excludedName: String?
        let shownID = photo.personGedcomID ?? graph.flatMap { g in
            let matches = g.people.values.filter {
                $0.name.compare(photo.personName, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }
            return matches.count == 1 ? matches[0].id : nil
        }
        if let shownID, !subjects.contains(where: { $0.gedcomPersonID == shownID }) {
            do {
                try dependencies.excludePhoto(photo.fileURL, shownID, speakers.ownerName, statement.caption)
                excludedName = photo.personName
            } catch {
                problems.append("I couldn't mark it as not a photo of \(photo.personName) (\(error.localizedDescription)), so it may come up for them again.")
            }
        }

        // Where/when: what was said, else what the file name says — never a
        // mix of the two.
        let said = statement.place != nil || statement.year != nil
        let hint = said ? (place: statement.place, year: statement.year)
                        : HalliePhotoCaption.filenameHint(photo.fileURL)
        let prose = HalliePhotoCaption.reply(
            shows: shows,
            place: hint.place,
            year: hint.year,
            excludedName: excludedName,
            problems: problems)
        let result = HallieTurnExecutor.Result(
            route: .telling,
            outcome: .answered,
            prose: prose,
            basisLine: "Basis: listening — caption kept as told by \(ownerName.isEmpty ? "you" : ownerName), unverified; photo \(photo.fileURL.lastPathComponent); no model call, no catalog query.",
            queryDescription: "photo caption",
            citations: [],
            catalogPersonName: nil)
        return Response(
            result: result,
            responderHost: localResponder,
            biographyPhoto: nil,
            capturedReferentID: referent.recordID,
            citations: [],
            pendingClarification: nil,
            playAfterAnswer: false,
            executedIntent: nil,
            telling: nil)
    }

    /// A typed name → one tree person: the owner's spouse by first name,
    /// then a unique tree match, then a CyberBrain alias carrying a pointer.
    private static func resolve(
        _ name: String,
        graph: GedcomFamilyGraph?,
        cyberBrain: CyberBrainIndex?,
        spouse: GedcomFamilyGraph.Person?
    ) -> GedcomFamilyGraph.Person? {
        let typed = FamilyIdentityText.tokens(name)
        guard let first = typed.first else { return nil }
        if let spouse, typed.count == 1,
           FamilyIdentityText.tokens(spouse.name).first == first {
            return spouse
        }
        guard let graph else { return nil }
        let matches = graph.people(matching: name)
        if matches.count == 1 { return matches[0] }
        if let cyberBrain, case .resolved(let person) = cyberBrain.resolve(name),
           let pointer = person.gedcomPersonID, let tree = graph.people[pointer] {
            return tree
        }
        let like = graph.people(namedLike: name)
        return like.count == 1 ? like[0] : nil
    }
}
