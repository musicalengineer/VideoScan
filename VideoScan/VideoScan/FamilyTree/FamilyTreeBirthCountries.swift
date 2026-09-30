// FamilyTreeBirthCountries.swift
// GH #229: the birth country behind the tiny flag on a Family Tree person
// card — Rick 2026-09-30, for the ancestors four and more generations back
// who have no photo and nothing else on the card to say where they came
// from. The family map (#227) already decides where each person was born;
// this file asks the SAME question the same way and keeps the answer as
// one dictionary, so a card is one lookup and the card and the map can
// never disagree (his grandmother in Cork gets 🇮🇪 from the family's notes
// here exactly as she is placed in Ireland there).
//
// WHERE THE COUNTRY COMES FROM — `FamilyMapModel.place(tree:family:)`, the
// map's one resolver call site: the tree's recorded birthplace first, then
// the family's own notes (an ACTIVE CyberBrain birth event with a place,
// visible at the map's family privacy ceiling), the first that resolves
// wins; a country-only resolution ("Ireland") still has a country. The
// unit key's country prefix is the flag. Nothing unresolved or off the map
// ("Berlin, Germany") gets a flag — an honest blank beats a guess.
//
// WHEN IT IS BUILT — once per (tree, family notes) pair, OFF the main
// actor, by FamilyTreeLiveModel (`scheduleBirthCountriesBuild`): after a
// tree is installed and again when the family's notes arrive or change.
// NEVER in a view body: FamilyTreePersonCard receives its flag as a value
// the view layer looked up with `model.birthFlag(for:)` (a sensor in
// FamilyTreeBirthFlagTests pins that no view file names the resolver or
// the builder).
//
// MEMORY: one `FamilyTreeBirthFlag` per FLAGGED person — an enum, the
// recorded place string (shared storage with the graph's own string) and a
// Bool — about 60 bytes plus the dictionary slot. Worst case at 100k
// people ≈ 10 MB; the real 39k tree ≈ 4 MB. Nothing grows after the build.
//
// (For Rick: `struct … Sendable` ≈ a plain value type the compiler has
// checked is safe to hand to another thread; `nonisolated static func` ≈ a
// free function that is not tied to the UI thread.)

import Foundation
import VideoScanCore

/// One person's birth country as the card shows it: the flag, what was
/// recorded, and whether the tree or the family's notes said so.
struct FamilyTreeBirthFlag: Equatable, Sendable {
    let country: FamilyMap.Country
    /// The place text that resolved — the tree's, or the family note's.
    let recordedPlace: String
    /// True when the tree had no usable birthplace and the family's notes
    /// supplied it (the same "from the family's notes" the map's panel says).
    let fromFamilyNotes: Bool

    /// The glyph the card draws (today's flag — see FamilyMapFlag).
    var emoji: String { country.flag }

    /// VoiceOver reads the country, never the emoji's own description.
    var accessibilityLabel: String { country.label }

    /// Historical honesty in one line: a 1650 Massachusetts Bay birth
    /// under 🇺🇸, a 1904 Cork birth under 🇮🇪.
    var tooltip: String {
        Self.tooltip(recordedPlace: recordedPlace, fromFamilyNotes: fromFamilyNotes)
    }

    static func tooltip(recordedPlace: String, fromFamilyNotes: Bool) -> String {
        fromFamilyNotes
            ? "Born in \(recordedPlace) (from the family's notes) · shown under today's flag"
            : "Born in \(recordedPlace) · shown under today's flag"
    }

    /// How the card draws the flag: no photo → the flag IS the portrait
    /// (large, centred in the photo slot, every generation); a photo → a
    /// small badge in the portrait's corner.
    enum Presentation: Equatable, Sendable {
        case placeholder
        case badge
    }

    static func presentation(hasPhoto: Bool) -> Presentation {
        hasPhoto ? .badge : .placeholder
    }
}

/// Every flagged person of one installed tree, keyed by GEDCOM id, plus
/// the counts the log line reports.
struct FamilyTreeBirthCountries: Equatable, Sendable {
    let flags: [String: FamilyTreeBirthFlag]
    /// How many people the tree holds (flagged or not).
    let peopleCount: Int
    /// Flagged from the tree's own birthplace.
    let treeCount: Int
    /// Flagged from the family's notes.
    let notesCount: Int

    static let empty = FamilyTreeBirthCountries(flags: [:], peopleCount: 0, treeCount: 0, notesCount: 0)

    var flaggedCount: Int { flags.count }

    /// One person's flag — a dictionary hit; nil when they have none.
    subscript(personID: String) -> FamilyTreeBirthFlag? { flags[personID] }

    /// The one line the app log gets per build:
    /// "flags: 12,694 of 39,250 people have a birth country (tree 12,693, notes 1)".
    var summaryLine: String {
        "flags: \(flags.count.formatted()) of \(peopleCount.formatted()) people have a birth country "
            + "(tree \(treeCount.formatted()), notes \(notesCount.formatted()))"
    }

    // MARK: Building

    /// The installed tree and — when a brain is loaded — its notes
    /// resolver. O(people): one dictionary walk, one `place` per person;
    /// the family's notes are consulted only for a person the tree could
    /// not place (a dictionary miss for almost everyone — the map computes
    /// the same column eagerly, and both come to the same answer because
    /// `place` tries the tree first either way).
    nonisolated static func build(graph: GedcomFamilyGraph, knowledge: FamilyTreeNotesResolver?) -> FamilyTreeBirthCountries {
        var flags: [String: FamilyTreeBirthFlag] = [:]
        flags.reserveCapacity(graph.people.count / 2)
        var tree = 0, notes = 0
        for (id, person) in graph.people {
            let placed = place(id: id, treePlace: person.birthPlace, knowledge: knowledge)
            guard let placed else { continue }
            flags[id] = placed
            if placed.fromFamilyNotes { notes += 1 } else { tree += 1 }
        }
        return FamilyTreeBirthCountries(flags: flags, peopleCount: graph.people.count, treeCount: tree, notesCount: notes)
    }

    /// The pure form for a scale test: parallel columns, no graph and no
    /// brain. `familyPlaces` nil = no family knowledge.
    nonisolated static func build(ids: [String], treePlaces: [String?], familyPlaces: [String?]? = nil) -> FamilyTreeBirthCountries {
        var flags: [String: FamilyTreeBirthFlag] = [:]
        flags.reserveCapacity(ids.count / 2)
        var tree = 0, notes = 0
        for (i, id) in ids.enumerated() {
            let treePlace = i < treePlaces.count ? treePlaces[i] : nil
            let family: String? = familyPlaces.flatMap { i < $0.count ? $0[i] : nil }
            guard let flag = flag(from: FamilyMapModel.place(tree: treePlace, family: family)) else { continue }
            flags[id] = flag
            if flag.fromFamilyNotes { notes += 1 } else { tree += 1 }
        }
        return FamilyTreeBirthCountries(flags: flags, peopleCount: ids.count, treeCount: tree, notesCount: notes)
    }

    /// One person: the tree's place through the map's decision; the
    /// family's note only when the tree did not place them.
    nonisolated static func place(id: String, treePlace: String?, knowledge: FamilyTreeNotesResolver?) -> FamilyTreeBirthFlag? {
        let first = FamilyMapModel.place(tree: treePlace, family: nil)
        if let flag = flag(from: first) { return flag }
        guard let knowledge, let familyPlace = FamilyMapModel.familyBirthPlace(gedcomID: id, in: knowledge) else { return nil }
        return flag(from: FamilyMapModel.place(tree: treePlace, family: familyPlace))
    }

    /// The map's placement → a flag; nil when the map would not place them
    /// either (no hit, or a hit whose key names no country — impossible
    /// today, guarded so a future unit table cannot fly a blank flag).
    nonisolated static func flag(from placement: FamilyMapModel.Placement) -> FamilyTreeBirthFlag? {
        guard let hit = placement.hit, let recorded = placement.recorded,
              let country = FamilyMapFlag.country(forUnitKey: hit.unitKey) else { return nil }
        return FamilyTreeBirthFlag(country: country, recordedPlace: recorded,
                                   fromFamilyNotes: placement.source == .family)
    }
}
