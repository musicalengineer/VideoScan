// HallieGalleryOffer.swift
// "I have 3 photos and 1 document of her in the archive — want to see
// them all?" after a biography (Rick 2026-09-10: "if I ask about Mary
// O'Connor I want Hallie to tell me her vitals and maybe even ask 'do you
// want to see all photos of her that we have in the archive?'").
//
// One pure decision: count what the family's folders hold for the person
// the biography was about; with two or more files (one photo is already
// beside the biography) append the question and carry a ONE-candidate
// clarification whose "yes" resumes a "show all photos of <name>" intent
// through the executor's ordinary continuation. Nothing here is a fact
// about the family; the sentence is a question Hallie asks.

import Foundation
import VideoScanCore

enum HallieGalleryOffer {
    /// The person a biography resolved to: a unique tree record, or a
    /// unique People-tab profile when the tree has nobody by that name.
    enum Subject: Equatable {
        case tree(GedcomFamilyGraph.Person)
        case profile(HallieTurnExecutor.ProfileSnapshot)

        var name: String {
            switch self {
            case .tree(let p): return p.name
            case .profile(let p): return p.canonicalName
            }
        }

        var candidate: HallieTurnExecutor.Candidate {
            switch self {
            case .tree(let p):
                return .init(id: .gedcomPersonID(p.id), canonicalName: p.name, label: p.name)
            case .profile(let p):
                return .init(id: .profileStableID(p.stableID), canonicalName: p.canonicalName, label: p.canonicalName)
            }
        }

        /// "her" / "him" / "them" — from the tree's SEX or the profile's.
        var objectPronoun: String {
            switch self {
            case .tree(let p):
                return p.sex == "F" ? "her" : p.sex == "M" ? "him" : "them"
            case .profile(let p):
                switch p.sex {
                case .female?: return "her"
                case .male?: return "him"
                case nil: return "them"
                }
            }
        }
    }

    struct Count: Equatable {
        var photos: Int
        var documents: Int
        var total: Int { photos + documents }
    }

    /// Minimum files before the offer is worth a question.
    static let minimumFiles = 2

    /// What the archive holds for the subject: the asset store's folders
    /// (tree record or a name-keyed folder for a profile) plus, for a
    /// profile, its reference folder.
    static func count(for subject: Subject,
                      store: FamilyAssetStore,
                      profileGallery: ArchivistProfileGallery?) -> Count {
        switch subject {
        case .tree(let person):
            let asset = FamilyAssetPerson(person)
            return Count(photos: store.photoURLs(for: asset).count,
                         documents: store.documentURLs(for: asset).count)
        case .profile(let profile):
            let asset = FamilyAssetPerson(name: profile.canonicalName)
            var photos = Set(profileGallery?.photoURLs ?? [])
            photos.formUnion(store.photoURLs(for: asset))
            return Count(photos: photos.count,
                         documents: store.documentURLs(for: asset).count)
        }
    }

    /// The offer sentence, or nil when there is nothing worth offering.
    static func sentence(_ count: Count, pronoun: String) -> String? {
        guard count.total >= minimumFiles else { return nil }
        var parts: [String] = []
        if count.photos > 0 { parts.append(HallieGalleryAnswer.countPhrase(count.photos, "photo")) }
        if count.documents > 0 { parts.append(HallieGalleryAnswer.countPhrase(count.documents, "document")) }
        return "I have \(parts.joined(separator: " and ")) of \(pronoun) in the archive — want to see them all?"
    }

    /// The intent a "yes" resumes: the gallery ask, by name, with the
    /// chosen identity carried by the continuation.
    static func intent(for subject: Subject) -> HallieTurnExecutor.Intent {
        .init(originalQuestion: "show all photos of \(subject.name)",
              ast: .presence(.init(people: [subject.name], mediaKind: .photo)))
    }

    /// The biography answer with the offer appended, or the same answer
    /// when there is nothing to offer. Only an ANSWERED biography with no
    /// pending clarification of its own is extended.
    static func apply(to result: HallieTurnExecutor.Result,
                      subject: Subject,
                      store: FamilyAssetStore,
                      profileGallery: ArchivistProfileGallery?,
                      context: HallieTurnExecutor.Context) -> HallieTurnExecutor.Result {
        guard result.outcome == .answered, result.clarification == nil else { return result }
        let count = count(for: subject, store: store, profileGallery: profileGallery)
        guard let sentence = sentence(count, pronoun: subject.objectPronoun) else { return result }
        let clarification = HallieTurnExecutor.makeClarification(
            intent: intent(for: subject), stage: .galleryOffer,
            candidates: [subject.candidate], context: context)
        return result.offering(sentence, clarification: clarification)
    }

    /// The biography's subject from what the coordinator already knows:
    /// the unique tree match by canonical name, else the unique People
    /// profile by canonical name / alias.
    static func subject(canonicalName: String,
                        graphMatches: [GedcomFamilyGraph.Person],
                        profiles: [HallieTurnExecutor.ProfileSnapshot]?) -> Subject? {
        if graphMatches.count == 1 { return .tree(graphMatches[0]) }
        guard graphMatches.isEmpty else { return nil }
        let key = PersonResolver.normalize(canonicalName)
        let matches = (profiles ?? []).filter { profile in
            ([profile.canonicalName] + profile.aliases).contains { PersonResolver.normalize($0) == key }
        }
        return matches.count == 1 ? .profile(matches[0]) : nil
    }
}
