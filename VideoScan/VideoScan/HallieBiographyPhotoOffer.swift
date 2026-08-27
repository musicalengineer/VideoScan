// HallieBiographyPhotoOffer.swift
// The picture beside a biography answer, decided in one testable place:
// the family's own file when the People folder has one (a painting or an
// engraving counts — it is THEIR file, whatever the dates), otherwise the
// "put a photo in this folder" card — unless the person's KNOWN death
// year predates photography (WorldKnowledge, photograph medium; Rick
// 2026-08-26 after a 1651–1737 biography came back with a photo-request
// card). An unknown death year never withholds the card. Presentation
// only, never evidence.

import Foundation
import VideoScanCore

enum HallieBiographyPhotoOffer {
    struct Decision: Equatable {
        var attachments: [HallieAttachment] = []
        /// "d. 1737 < photograph 1838" when the folder card was withheld
        /// by the photography floor; nil otherwise. The caller logs it.
        var suppressedNote: String? = nil
        /// A folder-card write that failed (read-only archive, etc.).
        var folderError: String? = nil
    }

    /// `graphMatches` are the tree people whose display name IS the
    /// canonical name; only a unique match carries dates into the rule.
    static func decide(canonicalName: String,
                       graphMatches: [GedcomFamilyGraph.Person],
                       assets: FamilyAssetStore) -> Decision {
        let person = graphMatches.count == 1
            ? FamilyAssetPerson(graphMatches[0])
            : FamilyAssetPerson(name: canonicalName)
        var decision = Decision()
        if let url = assets.photoURLs(for: person).first {
            decision.attachments = [.photo(HalliePhotoAttachment(
                personName: canonicalName, fileURL: url, personGedcomID: person.gedcomID))]
            return decision
        }
        if graphMatches.count == 1,
           let note = WorldKnowledge.photography.impossibilityNote(person: graphMatches[0], medium: .photograph) {
            decision.suppressedNote = note
            return decision
        }
        do {
            // The folder is created here only after the current
            // archive/viewer authority permits it. Renderers never create
            // directories from attachment path strings.
            let folder = try assets.folderForPhotoRequest(person: person)
            decision.attachments = [.photoRequest(personName: canonicalName, folderURL: folder)]
        } catch {
            decision.folderError = error.localizedDescription
        }
        return decision
    }
}
