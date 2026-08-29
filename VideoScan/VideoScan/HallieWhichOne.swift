// HallieWhichOne.swift
// The capped, ranked "which one?" for a name several family-tree people
// share (live 2026-08-28: "rick" on a 16k tree drew ten chips — Catherine
// Auker b. 1374, Robert de Cralle b. 1334 … — for a question about the
// owner). Every graph route that asks which GEDCOM person is meant goes
// through here, so the rule is one:
//
//   1. anchors first — the tree's home people (roots) and the owner's
//      pinned FamilySearch record — then everyone else in name order;
//   2. at most `cap` chips, with the overflow counted ("and 583 more");
//   3. more than `cap` namesakes and NO anchor among them → no chips at
//      all: ask for a surname or a birth year rather than list medieval
//      strangers;
//   4. the typed name is echoed with the typed casing ("Which Rick…", not
//      "Which rick…").
//
// C++ readers: a namespace of pure static functions over value types —
// nothing here touches the UI or the tree on disk.

import Foundation
import VideoScanCore

enum HallieWhichOne {

    static let cap = 6

    struct Arrangement: Equatable {
        /// The people to offer, anchors first, at most `cap`.
        let shown: [GedcomFamilyGraph.Person]
        /// How many matched in all.
        let total: Int
        /// True when a root or the pinned owner is among `shown`.
        let anchored: Bool

        var overflow: Int { total - shown.count }
        /// False when the honest move is to ask for a surname/year instead
        /// of offering chips (rule 3).
        var offersChips: Bool { anchored || total <= HallieWhichOne.cap }
    }

    static func arrange(
        _ people: [GedcomFamilyGraph.Person],
        graph: GedcomFamilyGraph?,
        ownerFamilySearchID: String? = nil
    ) -> Arrangement {
        var anchorIDs = Set(graph?.rootPersonIDs ?? [])
        if let pinned = graph?.person(familySearchID: ownerFamilySearchID) { anchorIDs.insert(pinned.id) }
        let ordered = ArchivistBiographyPolicy.orderedPeople(people)
        let anchors = ordered.filter { anchorIDs.contains($0.id) }
        let others = ordered.filter { !anchorIDs.contains($0.id) }
        let shown = Array((anchors + others).prefix(cap))
        return Arrangement(shown: shown, total: people.count, anchored: !anchors.isEmpty)
    }

    /// The echo of what was typed: typed casing, capitalized per word.
    static func display(_ typed: String) -> String {
        HallieLineageQuestion.capitalizedName(typed)
    }

    /// The which-one sentence. With chips: "Which Rick do you mean — A, B,
    /// or C?" plus the overflow. Without: the ask for a surname or year.
    static func prose(typed: String, arrangement: Arrangement, labels: [String]) -> String {
        let name = display(typed)
        guard arrangement.offersChips else {
            let forms = GedcomFamilyGraph.givenNameForms(of: FamilyIdentityText.tokens(typed).first ?? "")
            let asFormal = forms.count > 1 && forms[0] != forms[1] ? " (as \(forms[1].capitalized))" : ""
            return "The family tree has \(arrangement.total) people named \(name)\(asFormal) — which one? Add a surname or a birth year, for example “\(name) Breen” or “\(name) born 1959”."
        }
        var text = "Which \(name) do you mean — " + HallieNameQualifier.joined(labels, conjunction: "or") + "?"
        if arrangement.overflow > 0 {
            text += " There are \(arrangement.overflow) more; add a surname or a birth year to narrow it."
        }
        return text
    }

    static func basis(typed: String, arrangement: Arrangement) -> String {
        let shown = arrangement.offersChips
            ? "\(arrangement.shown.count) offered" + (arrangement.anchored ? ", home people first" : "")
            : "none offered"
        return "Basis: the family tree has \(arrangement.total) people by the name “\(display(typed))”; \(shown); nothing was looked up."
    }
}
