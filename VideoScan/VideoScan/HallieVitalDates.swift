// HallieVitalDates.swift
// The one place that decides — for a People-tab profile bridged to a
// family-tree record — which STORE's birth/death date is authoritative.
//
// Live 2026-09-04, demo eve, in front of Rick's brother:
//
//   "tell me about Ma"  → born 31 August 1930, died 3 March 2023   [tree]
//   "how old is Ma"     → "Ma died on 1 June 2023, at 89."         [People profile]
//
// Same evening, same shape, on Dad. The biography route (HallieBiographyCard)
// always read `GedcomFamilyGraph.Person.birthDate`/`.deathDate` — the tree.
// The temporal route (ArchivistTemporalExecutor, via
// HallieTurnExecutor+Identity.temporalResolution) always read the POI
// profile's hand-entered `birthdate`/`deathdate` — and never looked at the
// tree at all, bridged or not. Two stores, two answers, same person.
//
// RULE (Rick, 2026-09-04 — do not revisit which store is factually right;
// that is his to fix on the two cards, not this code's to decide):
//   1. Bridged profile (a `treeIdentity` pin that resolves on the
//      INSTALLED tree) → the tree's date wins for a field it records.
//      The tree is the curated genealogical record; profile fields are
//      hand-entered.
//   2. Unbridged profile (no pin, or a pin the installed tree can't
//      resolve) → the profile's date is the only evidence and is used
//      exactly as before.
//   3. Bridged, but the tree has NO reading for that field to day
//      precision (missing entirely, or only a qualified / ranged /
//      year-only date — none of which an age calculation can use) →
//      falls back to the profile's value for that field. A tree bridge
//      makes the tree authoritative for what it HAS, not for what it
//      lacks. (`HallieBiographyCard`'s own fallback is a courser test —
//      the tree's raw string is simply absent — because biography can
//      still speak an imprecise tree date verbatim; only the age route
//      needs a `Date` it can subtract.)
//   4. A disagreement of more than a day between the two stores is
//      logged ONCE per person per field at `.notice`, never spoken —
//      Hallie should sound certain, not audit her own stores out loud.
//
// Both routes now go through `resolve(...)` below: HallieTurnExecutor
// +Identity.vitalSubject (age route) uses the resolved `Date` directly;
// ArchivistGraphExecutor's biography/family-tree case uses it only as a
// fallback `Date` for a field the tree's own raw string lacks.
//
// C++ readers: `resolve` is a pure function of five value-type inputs
// (nothing here touches the network or the UI). The "log it once"
// behaviour is the one piece of process-lifetime state, held in a tiny
// lock-guarded set — the C++ analogue is a static
// std::unordered_set<std::string> behind a std::mutex.

import Foundation
import os

private let vitalDateLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "vitalDates"
)

enum HallieVitalDates {

    /// One resolved field and which store it came from.
    struct Field: Sendable, Equatable {
        let date: Date
        let provenance: ArchivistTemporalBirthdateProvenance
    }

    struct Resolved: Sendable, Equatable {
        let birthdate: Field?
        let deathdate: Field?
    }

    /// Resolve one person's birth/death precedence. `graph` nil (no tree
    /// installed) behaves exactly like an unbridged profile (rule 2).
    static func resolve(
        stableID: String,
        canonicalName: String,
        treeIdentity: TreeIdentity?,
        profileBirthdate: Date?,
        profileDeathdate: Date?,
        graph: GedcomFamilyGraph?
    ) -> Resolved {
        guard let treeIdentity, let graph,
              let person = bridgedPerson(treeIdentity, graph: graph) else {
            return Resolved(
                birthdate: profileBirthdate.map {
                    Field(date: $0, provenance: .poiProfile(profileID: stableID))
                },
                deathdate: profileDeathdate.map {
                    Field(date: $0, provenance: .poiProfile(profileID: stableID))
                })
        }
        return Resolved(
            birthdate: field(
                tree: exactDay(fromGedcom: person.birthDate), profile: profileBirthdate,
                fieldName: "birthdate", personID: person.id, stableID: stableID,
                canonicalName: canonicalName),
            deathdate: field(
                tree: exactDay(fromGedcom: person.deathDate), profile: profileDeathdate,
                fieldName: "deathdate", personID: person.id, stableID: stableID,
                canonicalName: canonicalName))
    }

    /// The GEDCOM person a profile's tree pin resolves to on the
    /// installed tree — nil when unbridged, or the pin is stale. The
    /// `.pointer` fingerprint (an SHA-256 pass over the whole tree,
    /// `FamilyKinshipOverlay.fingerprint(of:)`) is only computed for that
    /// case: `.familySearchID` — the pin every FamilySearch export carries
    /// and the one Ma's and Dad's cards use — never needs it.
    private static func bridgedPerson(
        _ pin: TreeIdentity, graph: GedcomFamilyGraph
    ) -> GedcomFamilyGraph.Person? {
        switch pin {
        case .familySearchID:
            return TreeIdentityDeriver.pinnedPerson(pin, graph: graph, fingerprint: nil)
        case .pointer:
            return TreeIdentityDeriver.pinnedPerson(
                pin, graph: graph, fingerprint: FamilyKinshipOverlay.fingerprint(of: graph))
        }
    }

    /// One field's precedence: the tree's exact-day date when it has one,
    /// else the profile's — logging a disagreement the first time this
    /// person+field combination is seen with both stores populated and in
    /// conflict.
    private static func field(
        tree: Date?, profile: Date?, fieldName: String,
        personID: String, stableID: String, canonicalName: String
    ) -> Field? {
        if let tree {
            if let profile, tree != profile {
                disagreementLog.logOnce(key: stableID + "." + fieldName) {
                    "\(canonicalName)'s \(fieldName) disagrees between stores — "
                        + "family tree (\(personID)) says \(HallieDateStyle.spoken(tree)), "
                        + "People profile (\(stableID)) says \(HallieDateStyle.spoken(profile)); "
                        + "the tree wins the spoken answer. Check the People profile."
                }
            }
            return Field(date: tree, provenance: .gedcomTree(personID: personID))
        }
        guard let profile else { return nil }
        return Field(date: profile, provenance: .poiProfile(profileID: stableID))
    }

    /// The tree's raw GEDCOM date string, converted to the SAME canonical
    /// noon-UTC-day `Date` `ArchivistTemporalExecutor` already
    /// canonicalises POI profile dates to (so `==`/`!=` is a fair
    /// comparison) — or nil for anything that isn't exactly one
    /// unambiguous day: missing, qualified ("ABT 1900"), ranged
    /// ("BET … AND …"), or precise only to the month or year. An age is a
    /// day-precision subtraction; a tree date that cannot supply a day is,
    /// for this purpose only, treated like a field the tree lacks (rule
    /// 3) — `HallieBiographyCard`'s own, coarser fallback test is separate
    /// and unaffected, since it can still speak an imprecise date verbatim.
    private static func exactDay(fromGedcom raw: String?) -> Date? {
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

    private static let disagreementLog = DisagreementLog()

    /// Test-only window onto the "once per person+field" log (rule 4) —
    /// scraping ~/Library/Logs would make the sensor test depend on the
    /// real log file's location and format, which this feature is
    /// explicitly forbidden from touching.
    static var loggedDisagreementKeysForTesting: Set<String> {
        disagreementLog.loggedKeysForTesting
    }
}

/// "Log once per person+field, ever" (rule 4). C++ analogue: a static
/// std::unordered_set<std::string> guarded by a std::mutex; Swift has no
/// bare equivalent, so this is the smallest stand-in — a class instead of
/// an actor because the caller (`ArchivistTemporalExecutor`,
/// `HallieBiographyCard`'s composer) is synchronous, not async.
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
