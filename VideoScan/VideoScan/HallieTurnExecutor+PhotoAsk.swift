// HallieTurnExecutor+PhotoAsk.swift
// "photos of X" as a presence intent with mediaKind photo (the model lane,
// and the deterministic shape when the name is a which-one). Nothing in the
// catalog is a photograph, so a photo ask about a FAMILY-TREE person is
// answered from the tree: the stored gallery (every photo and document in
// the person's folders, 2026-09-10), the photography-floor line
// (WorldKnowledge: died before 1838), or the folder card — and when the
// name fits several people, the same which-one chips as a biography, with
// the photo ask carried through the clarification so the chip finishes it
// (live 2026-08-27: "are there are photos of Nathaniel Parker").
//
// A PEOPLE-TAB person the tree does not know (2026-09-10) is answered from
// the profile's reference folder (cover first) plus any name-keyed folder
// in the archive — on the presence route, where People answers live.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// A one-person presence ask for photos.
    static func isPhotoAsk(_ ast: ArchivistQueryAST) -> Bool {
        guard case .presence(let payload) = ast else { return false }
        return payload.mediaKind == .photo && payload.people?.count == 1
    }

    /// The tree's or the People tab's answer to a photo ask, or nil to let
    /// the ordinary presence search run (not a photo ask, or a name neither
    /// source knows at all).
    static func photoAsk(
        _ payload: ArchivistQueryAST.Presence,
        request: Request,
        context: Context,
        dependencies: Dependencies = .production
    ) -> Result? {
        guard payload.mediaKind == .photo,
              let people = payload.people, people.count == 1 else { return nil }
        let typed = people[0].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        // Built once per ask: the store is a value with a fresh snapshot of
        // the archive authority (C++: a small struct copied by value, no
        // shared mutable state).
        let store = dependencies.assetConfiguration().makeStore()

        // A chip tapped on this very ask (or the gallery offer's "yes"):
        // the pointer is the answer.
        switch request.selectedIdentity {
        case .gedcomPersonID(let id)?:
            guard let graph = context.graph, let person = graph.people[id] else {
                return invalidContinuationResult(for: request.intent.ast)
            }
            return HallieLineageAnswer.personPhoto(person: person, store: store)
        case .profileStableID(let id)?:
            guard let profile = context.profiles?.first(where: { $0.stableID == id }) else {
                return invalidContinuationResult(for: request.intent.ast)
            }
            return profileGallery(profile, store: store, dependencies: dependencies)
        case .some:
            return invalidContinuationResult(for: request.intent.ast)
        case nil:
            break
        }
        if HalliePronounContinuity.isThirdPersonPronoun(typed) {
            return HallieLineageAnswer.pronounAsk(typed)
        }
        let name = typed
        guard let graph = context.graph else {
            // No tree loaded: the People tab is the only place a photo
            // can be; an unknown name goes on to the presence search.
            guard let profile = uniqueProfile(named: name, in: context.profiles) else { return nil }
            return profileGallery(profile, store: store, dependencies: dependencies)
        }
        switch HallieLineageAnswer.resolveDetailed(name, context: context, graph: graph) {
        case .success(let person, _):
            return HallieLineageAnswer.personPhoto(person: person, store: store)
        case .ambiguous(let people):
            return namesakeClarification(name, among: people, request: request, context: context)
        case .failure(let result):
            // Not in the tree, but in the People tab: the profile's folder.
            if let profile = uniqueProfile(named: name, in: context.profiles) {
                return profileGallery(profile, store: store, dependencies: dependencies)
            }
            // A qualified name that matched nobody gets its honest years
            // line; a plain unknown name is not the tree's to answer — the
            // presence search says what the catalog has (nothing, for photos).
            if HallieNameQualifier.parse(name) != nil, let result { return result }
            return nil
        }
    }

    /// Exactly one People-tab profile whose canonical name or alias IS the
    /// typed name (PersonResolver.normalize equality — the same rule the
    /// biography cover uses). Nil for none or several.
    static func uniqueProfile(named typed: String,
                              in profiles: [ProfileSnapshot]?) -> ProfileSnapshot? {
        let key = PersonResolver.normalize(typed)
        guard !key.isEmpty, let profiles else { return nil }
        let matches = profiles.filter { profile in
            ([profile.canonicalName] + profile.aliases).contains { PersonResolver.normalize($0) == key }
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// The People-tab gallery: the profile's reference folder (cover first,
    /// then every other verified image directly inside it) plus whatever
    /// the archive's name-keyed People/ folder holds for that name. An
    /// honest decline when both are empty.
    static func profileGallery(_ profile: ProfileSnapshot,
                               store: FamilyAssetStore,
                               dependencies: Dependencies) -> Result {
        let name = profile.canonicalName
        let gallery = dependencies.resolveProfileGallery(name)
        let asset = FamilyAssetPerson(name: name)
        var photos: [URL] = []
        var seen: Set<URL> = []
        for url in (gallery?.photoURLs ?? []) + store.photoURLs(for: asset)
        where seen.insert(url).inserted { photos.append(url) }
        let documents = store.documentURLs(for: asset)
        var folders: [URL] = []
        if let folder = gallery?.folderURL { folders.append(folder) }
        folders += store.personFolders(for: asset).filter { !folders.contains($0) }
        guard !photos.isEmpty || !documents.isEmpty else {
            return Result(
                route: .presence, outcome: .declined,
                prose: "I don\u{2019}t have a photo of \(name) yet.",
                basisLine: "Basis: no image in the People-tab reference folder or the archive\u{2019}s People folder for this person.",
                queryDescription: "photo: \(name)",
                citations: [], catalogPersonName: name)
        }
        var sources: [String] = []
        if gallery != nil { sources.append("the People-tab reference folder") }
        if folders.count > (gallery == nil ? 0 : 1) {
            sources.append(HallieGalleryAnswer.archiveSource(folderCount: folders.count - (gallery == nil ? 0 : 1)))
        }
        return HallieGalleryAnswer.result(
            personName: name, gedcomID: nil,
            photos: photos, documents: documents, folders: folders,
            route: .presence,
            source: sources.isEmpty ? "the People tab" : sources.joined(separator: " and "))
    }

    /// "Which Nathaniel Parker do you mean — Sr (b. …) or Caleb (b. …)?" with
    /// one chip per namesake; the intent rides through so the chip resumes
    /// THIS ask (photo, biography, …) for the chosen person.
    static func namesakeClarification(
        _ typed: String,
        among people: [GedcomFamilyGraph.Person],
        request: Request,
        context: Context
    ) -> Result {
        let shown = HallieNameQualifier.parse(typed)?.name ?? typed
        let candidates = people.map { person -> Candidate in
            guard let graph = context.graph else {
                let label = ArchivistBiographyPolicy.disambiguationCandidate(for: person).label
                return Candidate(id: .gedcomPersonID(person.id), canonicalName: person.name, label: label)
            }
            return gedcomCandidate(person, graph: graph)
        }
        let asked = HallieLineageAnswer.whichOne(shown, among: people)
        return Result(
            route: route(request.intent.ast),
            outcome: .needsClarification,
            prose: asked.prose,
            basisLine: asked.basisLine,
            queryDescription: description(of: request.intent.ast),
            citations: [],
            catalogPersonName: nil,
            clarification: makeClarification(
                intent: request.intent, stage: .gedcomPerson,
                candidates: candidates, context: context))
    }
}
