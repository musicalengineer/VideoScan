// HallieVitalDates.swift
// The ONE place that decides which store a person's birth and death dates
// come from, so the "how old is X" route and the "tell me about X" route
// can never again answer the same question two different ways.
//
// Live 2026-09-03/04, demo eve, in front of Rick's brother:
//
//   "tell me about Ma"  → born 31 August 1930, died 3 March 2023   [tree]
//   "how old is Ma"     → "Ma died on 1 June 2023, at 89."         [profile]
//
// Same evening, same shape, on Dad. The biography route
// (HallieBiographyCard.vitalsClause/eventClause) always read
// `GedcomFamilyGraph.Person.birthDate`/`.deathDate` — the family tree. The
// temporal route (ArchivistTemporalExecutor, via
// HallieTurnExecutor+Identity.temporalResolution) always read the People
// profile's `birthdate`/`deathdate` and never looked at the tree at all.
// Two stores, two answers, same woman, same conversation.
//
// ─────────────────────────────────────────────────────────────────────
// RICK'S RULING, 2026-09-04 (Director; this is a factual ruling, not an
// engineering preference, and it is not this code's to revisit):
//
//   "The People tab should be the source for the immediate contemporary
//    people in the People tab."
//
// Asked directly which store holds the truth, he answered: the People
// profiles are right and the family tree is wrong. The tree is a
// FamilySearch import; the People tab is his own curation of people he
// actually knew. The usual genealogical instinct — prefer the curated
// tree — is backwards here.
//
//   Ma  (Eileen Latta)        TRUE  born 31 Aug 1933, died 1 June 2023 (89)
//                             tree  born 31 Aug 1930, died 3 March 2023 (92)
//   Dad (Richard H Breen Sr)  TRUE  died 25 June 2008
//                             tree  died 22 June 2008
//
// THE RULE (per field, birth and death independently):
//   1. The People profile holds a date for the field → that date wins,
//      whether or not a tree bridge exists.
//   2. The profile holds nothing for the field → the tree's value stands.
//      Precedence is PER FIELD: a profile may hold a death date while the
//      tree holds the birth date, and each is spoken from its own store.
//   3. A person with no People profile — the other ~39,237 in the tree —
//      is untouched. The rule is self-limiting by construction, which is
//      exactly why Rick scoped it this way; there is deliberately NO other
//      scoping test in here.
//   4. Only birth and death DATES are in scope. Places, parents, spouses,
//      counts and every other biography sentence continue to come from the
//      tree, unchanged.
//   5. A disagreement between the two stores is logged ONCE per person per
//      field at `.notice`, with both values and both sources, so Rick can
//      find the rows to reconcile. It is NEVER spoken in the answer —
//      Hallie states a fact, she does not audit her own stores out loud.
//   6. The basis line names which store the spoken date came from.
//
// UNIQUE PIN OWNERSHIP (review finding, 2026-09-04). A profile reaches its
// tree record through a `TreeIdentity` pin. If two profiles pin to ONE
// GEDCOM person, neither owns it: without this, both would override that
// person's biography, and both would inherit its dates. `PinOwnership`
// below resolves pins and drops every colliding or duplicated claim,
// enforcing the same rule `FamilyKinshipOverlay.resolvePins` enforces for
// kinship — deliberately re-stated here as a small standalone pass so the
// age route does not have to build a whole kinship overlay to ask what a
// person's birthday is.
//
// C++ readers:
//   • `enum HallieVitalDates` with only static members ≈ a namespace with
//     free functions; Swift has no bare namespace, so a case-less enum is
//     the idiom for "this type is never instantiated".
//   • `resolve` is a pure function of value-type inputs. Nothing here
//     touches the network, the filesystem, the UI, or UserDefaults.
//   • The "log once" behaviour is the one piece of process-lifetime state,
//     held in a lock-guarded set — the analogue is a function-static
//     std::unordered_set<std::string> behind a std::mutex.
//
// Memory: everything here is bounded by the PROFILE count (tens), never by
// the tree's person count. `PinOwnership` allocates at most two dictionary
// entries per profile. The one tree-sized cost is the content fingerprint
// a `.pointer` pin needs (one SHA-256 pass, streamed by
// FamilyKinshipOverlay.fingerprint); it is computed at most once per
// `PinOwnership`, and only when some profile actually carries a pointer pin
// — Rick's tree pins by FamilySearch ID and never pays it.

import Foundation
import os

private let vitalDateLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "vitalDates"
)

/// The profile fields this seam reads — nothing else from a People profile
/// crosses into it. Both `HallieTurnExecutor.ProfileSnapshot` (age route)
/// and `ArchivistGraphProfileSnapshot` (biography route) project into this
/// one value type so the two routes cannot diverge in what they consider a
/// profile to say.
struct HallieVitalProfile: Sendable, Equatable {
    let stableID: String
    let canonicalName: String
    let treeIdentity: TreeIdentity?
    /// The stored pin could not be decoded (written by a newer build). Fails
    /// closed: unbridged, exactly as the kinship overlay treats it.
    let treeIdentityUnreadable: Bool
    let birthdate: Date?
    let deathdate: Date?

    init(
        stableID: String,
        canonicalName: String,
        treeIdentity: TreeIdentity? = nil,
        treeIdentityUnreadable: Bool = false,
        birthdate: Date? = nil,
        deathdate: Date? = nil
    ) {
        self.stableID = stableID
        self.canonicalName = canonicalName
        self.treeIdentity = treeIdentity
        self.treeIdentityUnreadable = treeIdentityUnreadable
        self.birthdate = birthdate
        self.deathdate = deathdate
    }

    init(_ snapshot: ArchivistGraphProfileSnapshot) {
        self.init(
            stableID: snapshot.stableID,
            canonicalName: snapshot.canonicalName,
            treeIdentity: snapshot.treeIdentity,
            treeIdentityUnreadable: snapshot.treeIdentityUnreadable,
            birthdate: snapshot.birthdate,
            deathdate: snapshot.deathdate)
    }

    init(_ snapshot: HallieTurnExecutor.ProfileSnapshot) {
        self.init(
            stableID: snapshot.stableID,
            canonicalName: snapshot.canonicalName,
            treeIdentity: snapshot.treeIdentity,
            treeIdentityUnreadable: false,
            birthdate: snapshot.birthdate,
            deathdate: snapshot.deathdate)
    }

    /// The fields that decide a vital-date answer. Two snapshots of the same
    /// stableID that differ in ANY of these mean two different people as far
    /// as this seam is concerned, and the seam refuses rather than picking
    /// one (see `consistentProfile`).
    var vitalMeaning: [String] {
        [
            treeIdentity.map(String.init(describing:)) ?? "-",
            treeIdentityUnreadable ? "unreadable" : "-",
            birthdate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-",
            deathdate.map { String($0.timeIntervalSinceReferenceDate) } ?? "-",
        ]
    }
}

enum HallieVitalDates {

    /// One resolved field and the store it came from.
    struct Field: Sendable, Equatable {
        let date: Date
        let provenance: ArchivistTemporalBirthdateProvenance
    }

    struct Resolved: Sendable, Equatable {
        let birthdate: Field?
        let deathdate: Field?
        /// The canonical name of the People profile that supplied a field,
        /// for the basis line. Nil when no profile was involved at all.
        let profileName: String?

        static let none = Resolved(birthdate: nil, deathdate: nil, profileName: nil)

        /// The date the BIOGRAPHY route speaks in place of the tree's own
        /// recorded string. Nil means only "the profile holds nothing for
        /// this field", and then the tree's own string stands exactly as
        /// written — including an imprecise one ("about 1900").
        var profileBirthdate: Date? { Self.profileOnly(birthdate) }
        var profileDeathdate: Date? { Self.profileOnly(deathdate) }

        private static func profileOnly(_ field: Field?) -> Date? {
            guard let field, case .poiProfile = field.provenance else { return nil }
            return field.date
        }
    }

    // MARK: - Pin ownership

    /// Which profile owns which tree person, with duplicated and colliding
    /// claims dropped. Build ONCE per turn and pass it to both routes.
    struct PinOwnership: Sendable, Equatable {
        private let treePersonIDByProfile: [String: String]
        private let profileByTreePersonID: [String: String]
        /// Tree people that more than one profile pinned — kept for the log
        /// line and for tests; never resolvable.
        let collidedTreePersonIDs: Set<String>

        static let none = PinOwnership(
            treePersonIDByProfile: [:], profileByTreePersonID: [:],
            collidedTreePersonIDs: [])

        fileprivate init(
            treePersonIDByProfile: [String: String],
            profileByTreePersonID: [String: String],
            collidedTreePersonIDs: Set<String>
        ) {
            self.treePersonIDByProfile = treePersonIDByProfile
            self.profileByTreePersonID = profileByTreePersonID
            self.collidedTreePersonIDs = collidedTreePersonIDs
        }

        /// The tree person this profile uniquely owns, or nil.
        func treePersonID(ownedBy stableID: String) -> String? {
            treePersonIDByProfile[stableID]
        }

        /// The profile that uniquely owns this tree person, or nil.
        func profileStableID(owning treePersonID: String) -> String? {
            profileByTreePersonID[treePersonID]
        }
    }

    /// Resolve every profile's tree pin and keep only the unambiguous ones.
    ///
    /// Rejected, each fails CLOSED (the profile is treated as unbridged and
    /// the tree person as unowned):
    ///   • duplicate snapshots of one stableID that disagree about the pin;
    ///   • a pin marked unreadable (written by a newer build);
    ///   • a pin the installed tree cannot resolve (stale FSID, or a
    ///     pointer whose source fingerprint no longer matches);
    ///   • a tree person claimed by two or more profiles.
    static func pinOwnership(
        profiles: [HallieVitalProfile],
        graph: GedcomFamilyGraph?
    ) -> PinOwnership {
        guard let graph, !profiles.isEmpty else { return .none }

        // One SHA-256 pass over the tree, and only if some profile actually
        // pins by pointer. A FamilySearch-ID pin — every pin in Rick's tree
        // — never needs it. (Swift's lazy local: computed on first use.)
        var fingerprint: String?
        var fingerprintComputed = false
        func treeFingerprint() -> String {
            if !fingerprintComputed {
                fingerprint = FamilyKinshipOverlay.fingerprint(of: graph)
                fingerprintComputed = true
            }
            return fingerprint ?? ""
        }

        var resolved: [String: String] = [:]          // stableID -> tree person id
        var claimants: [String: Set<String>] = [:]    // tree person id -> stableIDs
        let byStableID = Dictionary(grouping: profiles, by: \.stableID)
        for stableID in byStableID.keys.sorted() {
            guard let definitions = byStableID[stableID],
                  let first = definitions.first else { continue }
            // Duplicate snapshots that disagree about the pin: refuse.
            guard definitions.allSatisfy({ $0.vitalMeaning == first.vitalMeaning }) else { continue }
            guard !first.treeIdentityUnreadable, let pin = first.treeIdentity else { continue }
            let person: GedcomFamilyGraph.Person?
            switch pin {
            case .familySearchID(let fsid):
                person = graph.person(familySearchID: fsid)
            case .pointer(let pointer, let sourceFingerprint):
                person = sourceFingerprint == treeFingerprint() ? graph.people[pointer] : nil
            }
            guard let person else { continue }
            resolved[stableID] = person.id
            claimants[person.id, default: []].insert(stableID)
        }

        var collided: Set<String> = []
        for (personID, ids) in claimants where ids.count > 1 {
            collided.insert(personID)
            for id in ids { resolved[id] = nil }
        }
        var owners: [String: String] = [:]
        for (stableID, personID) in resolved { owners[personID] = stableID }
        return PinOwnership(
            treePersonIDByProfile: resolved,
            profileByTreePersonID: owners,
            collidedTreePersonIDs: collided)
    }

    // MARK: - The age route

    /// What dates does THIS profile speak? Rule 1 first (the profile's own
    /// date), then rule 2 (the tree record it uniquely owns, for a field the
    /// profile leaves empty).
    static func resolve(
        profile: HallieVitalProfile,
        graph: GedcomFamilyGraph?,
        ownership: PinOwnership
    ) -> Resolved {
        let treePerson = ownership.treePersonID(ownedBy: profile.stableID)
            .flatMap { graph?.people[$0] }
        return merge(profile: profile, treePerson: treePerson)
    }

    /// Convenience for callers that hold only the one profile and the graph
    /// (single-subject age questions): builds the ownership pass over
    /// `profiles` — which must be the WHOLE profile set, or a collision
    /// could go unseen.
    static func resolve(
        profile: HallieVitalProfile,
        among profiles: [HallieVitalProfile],
        graph: GedcomFamilyGraph?
    ) -> Resolved {
        resolve(profile: profile, graph: graph,
                ownership: pinOwnership(profiles: profiles, graph: graph))
    }

    // MARK: - The biography route

    /// What dates does THIS TREE PERSON speak? `.none` when no People
    /// profile unambiguously owns them — the ~39,237 people who are only in
    /// the tree, and every case where ownership is contested, are left
    /// exactly as the tree records them.
    ///
    /// `throughProfileStableID` is the profile the QUESTION came through
    /// ("tell me about Ma" resolved via Ma's card). A tree pin can name an
    /// owner too. When both exist and name different profiles, ownership is
    /// contested and the tree stands.
    static func resolve(
        treePerson: GedcomFamilyGraph.Person,
        profiles: [HallieVitalProfile],
        graph: GedcomFamilyGraph?,
        throughProfileStableID: String?,
        ownership: PinOwnership? = nil
    ) -> Resolved {
        let ownership = ownership ?? pinOwnership(profiles: profiles, graph: graph)
        let pinned = ownership.profileStableID(owning: treePerson.id)
        let owner: String?
        switch (throughProfileStableID, pinned) {
        case (nil, nil): owner = nil
        case (let asked?, nil): owner = asked
        case (nil, let byPin?): owner = byPin
        case (let asked?, let byPin?): owner = asked == byPin ? asked : nil
        }
        guard let owner, let profile = consistentProfile(owner, in: profiles) else {
            return .none
        }
        return merge(profile: profile, treePerson: treePerson)
    }

    // MARK: - The merge itself

    /// The single per-field precedence both routes run. Keeping it private
    /// and single is the whole point of the file: there is no second opinion
    /// about a birthday anywhere in the app.
    private static func merge(
        profile: HallieVitalProfile,
        treePerson: GedcomFamilyGraph.Person?
    ) -> Resolved {
        Resolved(
            birthdate: field(
                profileDate: profile.birthdate, treeDate: exactDay(fromGedcom: treePerson?.birthDate),
                fieldName: "birthdate", owner: profile, treePersonID: treePerson?.id),
            deathdate: field(
                profileDate: profile.deathdate, treeDate: exactDay(fromGedcom: treePerson?.deathDate),
                fieldName: "deathdate", owner: profile, treePersonID: treePerson?.id),
            profileName: profile.canonicalName)
    }

    private static func field(
        profileDate profile: Date?,
        treeDate tree: Date?,
        fieldName: String,
        owner: HallieVitalProfile,
        treePersonID: String?
    ) -> Field? {
        if let profile {
            // Rule 5: both stores speak and name different calendar days.
            // The comparison is on the CANONICAL day (noon UTC, exactly the
            // definition ArchivistTemporalExecutor already uses), so a
            // sub-day difference — a stored time of day, a time-zone
            // artifact — is not a disagreement, only a genuinely different
            // date is.
            if let tree, let day = ArchivistTemporalExecutor.canonicalDay(profile), tree != day {
                disagreementLog.logOnce(key: owner.stableID + "." + fieldName) {
                    "\(owner.canonicalName)'s \(fieldName) disagrees between stores — "
                        + "People profile (\(owner.stableID)) says \(HallieDateStyle.spoken(day, calendar: utcCalendar)), "
                        + "family tree (\(treePersonID ?? "?")) says \(HallieDateStyle.spoken(tree, calendar: utcCalendar)); "
                        + "the People profile is spoken (Rick's ruling 2026-09-04). "
                        + "Check the family-tree record."
                }
            }
            return Field(date: profile, provenance: .poiProfile(profileID: owner.stableID))
        }
        guard let tree, let treePersonID else { return nil }
        return Field(date: tree, provenance: .gedcomTree(personID: treePersonID))
    }

    /// The ONE snapshot for a stableID, or nil when duplicate snapshots of
    /// that stableID disagree about anything this seam reads. Refusing is
    /// order-independent; picking one would not be.
    private static func consistentProfile(
        _ stableID: String, in profiles: [HallieVitalProfile]
    ) -> HallieVitalProfile? {
        let definitions = profiles.filter { $0.stableID == stableID }
        guard let first = definitions.first,
              definitions.allSatisfy({ $0.vitalMeaning == first.vitalMeaning })
        else { return nil }
        return first
    }

    // MARK: - Dates

    /// The tree's raw GEDCOM date string as the SAME canonical noon-UTC day
    /// a profile date is canonicalised to, or nil for anything that is not
    /// exactly one unambiguous day: missing, qualified ("ABT 1900"), ranged
    /// ("BET … AND …"), or precise only to the month or year. An age is a
    /// day-precision subtraction, and a fair `==` needs one definition of
    /// "same day" — this is it.
    static func exactDay(fromGedcom raw: String?) -> Date? {
        guard let raw, let normalized = HallieDateStyle.normalizingSingleDate(raw) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = HallieDateStyle.houseFormat
        guard let parsed = formatter.date(from: normalized) else { return nil }
        return ArchivistTemporalExecutor.canonicalDay(parsed)
    }

    /// The fixed UTC calendar every date on both routes is read in, so the
    /// calendar day a sentence names cannot shift with the reader's zone.
    static var utcCalendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    // MARK: - Rule 5: log once, never speak

    private static let disagreementLog = DisagreementLog()

    /// Test-only window onto the "once per person+field" log. Scraping
    /// ~/Library/Logs would make the test depend on the real log file's
    /// path and format, which this feature is explicitly forbidden to touch.
    static var loggedDisagreementKeysForTesting: Set<String> {
        disagreementLog.loggedKeysForTesting
    }
}

/// "Log once per person+field, for the life of the process" (rule 5).
/// C++ analogue: a function-static std::unordered_set<std::string> guarded
/// by a std::mutex. A class rather than an `actor` because every caller
/// (both executors) is synchronous, and an actor would force them async.
///
/// Memory: one short key per person+field that ever disagreed — bounded by
/// 2 × the profile count, tens of bytes each.
private final class DisagreementLog: @unchecked Sendable {
    private let lock = NSLock()
    private var logged: Set<String> = []

    func logOnce(key: String, _ message: () -> String) {
        lock.lock()
        let isNew = logged.insert(key).inserted
        lock.unlock()
        guard isNew else { return }
        let text = message()
        vitalDateLog.notice("\(text, privacy: .public)")
    }

    var loggedKeysForTesting: Set<String> {
        lock.lock()
        defer { lock.unlock() }
        return logged
    }
}
