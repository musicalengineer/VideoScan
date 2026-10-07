import Foundation

/// Immutable People-gallery identity used only to bridge a typed nickname to
/// a GEDCOM person. Profile notes, photos, and recognition settings never enter
/// graph execution, so they cannot leak into factual answers or an LLM prompt.
struct ArchivistGraphProfileSnapshot: Sendable, Equatable {
    let stableID: String
    let canonicalName: String
    let aliases: [String]
    /// Typed local relationships (2026-08-27) — feed FamilyKinshipOverlay.
    /// Additive: every existing caller's default is "none".
    let kinships: [Kinship]
    /// Sex / birthdate only so the overlay can pick "brother" vs "sister"
    /// and "older" vs "younger"; no notes or photos cross this boundary.
    let sex: PersonSex?
    let birthdate: Date?
    /// The profile's recorded death, if any (LifeStatus, 2026-09-01): the
    /// only thing that makes a People-tab person "passed on" in Hallie's
    /// tense. Additive; nil = none recorded.
    let deathdate: Date?
    /// Durable profile identity that `.profile(id:)` kinship anchors use.
    let uuid: UUID?
    /// The profile's durable tree pin (design amendment 1). nil = unpinned.
    let treeIdentity: TreeIdentity?
    /// True when the stored pin could not be decoded (newer build wrote it):
    /// the overlay fails closed — unbridged with a pin problem, never a name.
    let treeIdentityUnreadable: Bool
    // Family-name fields (2026-09-06). They stopped at this boundary until
    // now, which is why `FamilyKinshipOverlay` could only build a resolver
    // over canonical names and aliases: "Richard Harding Breen Sr" resolved
    // to nobody, so the ONLY spelling the kinship rebind had to work with
    // was the ambiguous given name "Richard" — which, since Rick adopted
    // surnames on 2026-09-04, is his father's canonical name AND Rick's own
    // alias. At equal priority the son won and "my dad" stopped finding Dad.
    // Additive and all-optional: nil everywhere ⇒ the old behaviour exactly.
    let surname: String?
    let maidenName: String?
    let middleName: String?
    let suffix: String?

    /// The exact-match spellings these fields imply, built by the SAME pure
    /// builder `POIProfile` and `ProfileSnapshot` use — so the People tab,
    /// the stored profile and the kinship overlay can never disagree about
    /// what "Tim Breen" means. Empty until Rick fills in a surname.
    var fullNameForms: [String] {
        guard surname != nil || maidenName != nil else { return [] }
        return POINameForms(name: canonicalName, aliases: aliases,
                            middleName: middleName, surname: surname,
                            maidenName: maidenName, suffix: suffix).matchingForms
    }

    /// How this person is named on first mention once a surname is known —
    /// the unambiguous spelling the kinship rebind binds in place of a bare
    /// given name.
    var displayFullName: String {
        POINameForms(name: canonicalName, aliases: aliases,
                     middleName: middleName, surname: surname,
                     maidenName: maidenName, suffix: suffix).displayFullName
    }

    init(stableID: String, canonicalName: String, aliases: [String] = [],
         kinships: [Kinship] = [], sex: PersonSex? = nil, birthdate: Date? = nil,
         deathdate: Date? = nil,
         uuid: UUID? = nil, treeIdentity: TreeIdentity? = nil, treeIdentityUnreadable: Bool = false,
         surname: String? = nil, maidenName: String? = nil,
         middleName: String? = nil, suffix: String? = nil) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.aliases = aliases
        self.kinships = kinships
        self.sex = sex
        self.birthdate = birthdate
        self.deathdate = deathdate
        self.uuid = uuid
        self.treeIdentity = treeIdentity
        self.treeIdentityUnreadable = treeIdentityUnreadable
        self.surname = POINameText.cleaned(surname)
        self.maidenName = POINameText.cleaned(maidenName)
        self.middleName = POINameText.cleaned(middleName)
        self.suffix = POINameText.cleanedSuffix(suffix)
    }

    // `@MainActor` ≈ "copy UI-owned state while on the UI thread"; the
    // resulting value has no actor affinity and contains no private POI media.
    @MainActor
    init(profile: POIProfile) {
        self.init(
            stableID: profile.id,
            canonicalName: profile.name,
            aliases: profile.aliases,
            kinships: profile.kinships,
            sex: profile.sex,
            birthdate: profile.birthdate,
            deathdate: profile.deathdate,
            uuid: profile.uuid,
            treeIdentity: profile.treeIdentity,
            treeIdentityUnreadable: profile.treeIdentityQuarantined != nil,
            surname: profile.surname, maidenName: profile.maidenName,
            middleName: profile.middleName, suffix: profile.suffix)
    }
}

/// Complete immutable input to deterministic graph execution. Callers create
/// this value before detached work; the executor performs no I/O or mutation.
struct ArchivistGraphInputs: Sendable {
    let graph: GedcomFamilyGraph
    let profiles: [ArchivistGraphProfileSnapshot]
    /// The signed-in owner's configured name, so the overlay can bind the
    /// owner's fuller spellings ("Rick Breen" from "me") to the owner's
    /// one-word profile. nil ⇒ exact profile spellings only.
    let ownerName: String?
    /// Typed People-tab relationships laid over the same identity space
    /// (2026-08-27). Built once per turn here so detached execution gets a
    /// ready value; ≤ 50 ms for 500 profiles × 5 rows.
    let kinshipOverlay: FamilyKinshipOverlay

    init(
        graph: GedcomFamilyGraph,
        profiles: [ArchivistGraphProfileSnapshot] = [],
        ownerName: String? = nil
    ) {
        self.graph = graph
        self.profiles = profiles
        self.ownerName = ownerName
        self.kinshipOverlay = FamilyKinshipOverlay(snapshots: profiles, graph: graph)
    }

    @MainActor
    init(graph: GedcomFamilyGraph, profiles: [POIProfile], ownerName: String? = nil) {
        self.init(
            graph: graph,
            profiles: profiles.map {
                ArchivistGraphProfileSnapshot(profile: $0)
            },
            ownerName: ownerName)
    }
}
