// KinshipWarning.swift
// The little yellow triangle on a People-tab card, as a value instead of a
// tooltip (Rick, 2026-09-13). The triangle used to carry one free-form
// string in `.help(...)`, which is no help at all when the cause is one of
// ten different things and the remedy for each lives somewhere else.
//
// A warning is now classified AT THE SITE THAT PRODUCES IT
// (FamilyKinshipOverlay.note), so the card can say what the nudge is, what
// the app gets wrong while it stands, how to fix it, and offer a button
// that goes where the fix happens.
//
// The `text` is the EXISTING line, byte for byte. Hallie's basis lines,
// the strict replays and the kinship suites all pin those exact strings;
// this type wraps them, it never rewrites them. `why` and `fix` are new
// prose attached to the CODE, so they are identical for every instance of
// a cause and a new code cannot ship without guidance (there is an
// exhaustiveness sensor over `Code.allCases`).
//
// Pure and tiny: ten codes, a handful of Strings each, no state, no I/O.
// (C++ readers: this is a plain value type — think `struct` with const
// members and a switch-backed lookup table; `CaseIterable` ≈ a generated
// array of every enumerator, which is what lets the sensor walk them all.)

import Foundation

/// One data-hygiene nudge about a People-tab person: the line Rick already
/// sees, plus what it costs to leave it and what to do about it.
struct KinshipWarning: Hashable, Sendable, Identifiable {

    /// Every condition `FamilyKinshipOverlay` can warn about. Split so that
    /// two causes share a code only when they share a remedy.
    enum Code: String, CaseIterable, Hashable, Sendable {
        /// An alias that is a relational WORD — "Dad" on a profile, rather
        /// than a Relationship row saying whose dad.
        case relationalAlias
        /// Duplicate definitions of one profile disagree about the tree pin.
        case pinDefinitionsDisagree
        /// The stored pin was written by a newer build and can't be decoded.
        case pinUnreadable
        /// The pin names a person the installed tree does not carry.
        case pinNotInTree
        /// There is a pin but no tree is installed to check it against.
        case pinNoTreeInstalled
        /// Two profiles are pinned to the same tree person.
        case pinCollision
        /// A relationship row points at a profile that no longer exists.
        case danglingRelationshipRow
        /// A relationship row points into an older tree export.
        case staleTreePointer
        /// A half-sibling row names a shared parent nobody can find.
        case halfSiblingParentMissing
        /// Sibling / parent rows contradict each other, so the shared-parent
        /// derivation failed closed for that whole set.
        case derivationConflict

        /// What goes wrong while this stands — stated as what the app and
        /// Hallie will get wrong, not as an abstraction.
        var why: String {
            switch self {
            case .relationalAlias:
                return "A word like \u{201C}Dad\u{201D} or \u{201C}Mom\u{201D} means a different person depending on who says it. Held as an alias it belongs to this one person, so every \u{201C}Dad\u{201D} in a search — and every answer Hallie gives — lands on them, no matter who was asking."
            case .pinDefinitionsDisagree:
                return "Two copies of this person's profile name different records in the family tree, so the app can't tell which one is theirs. Until that settles they read as not being in the tree: no tree dates, no tree relatives."
            case .pinUnreadable:
                return "The saved family-tree link is in a shape this version of the app doesn't recognise \u{2014} most likely a newer build wrote it. It is kept exactly as it is, but it isn't used, so this person reads as not being in the tree."
            case .pinNotInTree:
                return "This person is linked to a tree record the installed tree doesn't have, usually after a fresh export or a different tree. Nothing from the tree reaches their card while that link dangles."
            case .pinNoTreeInstalled:
                return "This person has a saved family-tree link, but there's no tree loaded to check it against, so the app can neither confirm it nor use it."
            case .pinCollision:
                return "Two people here claim the same record in the family tree, so both claims are set aside \u{2014} one record can only be one person. Neither card gets tree dates or tree relatives meanwhile."
            case .danglingRelationshipRow:
                return "A relationship row on this card points at a profile that has since been deleted. The row still counts as a link, so it reads as \u{201C}a removed profile\u{201D} instead of a name, and anything built on it \u{2014} parents, siblings, Hallie's answers \u{2014} stops there."
            case .staleTreePointer:
                return "This relationship points into an older export of the family tree. That export's internal numbering doesn't survive a fresh pull, so the app can't say who was meant and shows the raw pointer instead of a name."
            case .halfSiblingParentMissing:
                return "A half-sibling row names the parent the two share, but that person isn't in the People tab any more. Without them nothing is carried across the row, so that side of the family stays unconnected."
            case .derivationConflict:
                return "Two rows say different things about this family, so the app stops rather than guess. Nothing is carried across the sibling set: parents you'd expect on the other cards won't appear, and Hallie leaves the gap rather than fill it."
            }
        }

        /// The concrete steps, in the order Rick would take them.
        var fix: String {
            switch self {
            case .relationalAlias:
                return "Open this person's card, take the word out of Aliases, and record the real link as a Relationship row \u{2014} \u{201C}child of\u{201D} or \u{201C}parent of\u{201D}. The row says who is whose, so the answers follow whoever is asking."
            case .pinDefinitionsDisagree:
                return "Open the family tree from this person's card and pick their record again. The fresh choice replaces both of the old ones."
            case .pinUnreadable:
                return "Open the newer build that wrote it, or pick this person's tree record again here \u{2014} that writes a link this version understands."
            case .pinNotInTree:
                return "Open the family tree from this person's card and pick their record in the tree that's installed now."
            case .pinNoTreeInstalled:
                return "Load or pull a family tree in the Family Tree tab. The link is checked again the moment one is installed \u{2014} nothing here needs re-entering."
            case .pinCollision:
                return "Decide which of the two is that tree record, then open the family tree from the other person's card and pick the right record for them (or clear it)."
            case .danglingRelationshipRow:
                return "Open this person's card, go to Relationships, and either delete that row or pick the person it should point at."
            case .staleTreePointer:
                return "Open this person's card, go to Relationships, and pick that relative again from the tree that's installed now."
            case .halfSiblingParentMissing:
                return "Open this person's card, go to Relationships, and pick the shared parent again \u{2014} or make it a plain sibling row if they're full siblings after all."
            case .derivationConflict:
                return "The line above names the rows that disagree. Open the cards it names, go to Relationships, and correct the one that's wrong \u{2014} everything derived comes back on its own."
            }
        }

        /// Where the fix happens, when the app can take Rick there.
        var action: Action? {
            switch self {
            case .relationalAlias, .danglingRelationshipRow, .staleTreePointer,
                 .halfSiblingParentMissing, .derivationConflict:
                return .editRelationships
            case .pinDefinitionsDisagree, .pinUnreadable, .pinNotInTree,
                 .pinNoTreeInstalled, .pinCollision:
                return .openFamilyTree
            }
        }
    }

    /// Where a warning's remedy lives. The People gallery turns this into
    /// navigation (`PersonWarningRoute`); nothing here knows about views.
    enum Action: String, Hashable, Sendable, CaseIterable {
        /// This person's editor, the way the card's "Edit…" menu item opens it.
        case editPerson
        /// The same editor, for work that happens in its Relationships rows.
        case editRelationships
        /// The Family Tree — which, for a person whose pin is broken, is
        /// the pick-the-record sheet (`showInFamilyTree`).
        case openFamilyTree

        /// The button's words, for one named person.
        func buttonTitle(personName: String) -> String {
            switch self {
            case .editPerson:        return "Open \(personName)'s Card"
            case .editRelationships: return "Open \(personName)'s Relationships"
            case .openFamilyTree:    return "Show \(personName) in the Family Tree"
            }
        }
    }

    let code: Code
    /// The existing warning line, unchanged. This is what the tooltip, the
    /// basis lines and the regression suites have always carried.
    let text: String

    /// Stable within one overlay: `warnings` is deduplicated by line, and a
    /// line is produced by exactly one site, so code + text is unique.
    var id: String { code.rawValue + "\u{1F}" + text }

    var why: String { code.why }
    var fix: String { code.fix }
    var action: Action? { code.action }

    init(code: Code, text: String) {
        self.code = code
        self.text = text
    }

    /// The hover tooltip: the same newline-joined summary the card has
    /// shown since 2026-08-28, so nothing about the badge's glance value
    /// changes when the popover is added.
    static func tooltip(for warnings: [KinshipWarning]) -> String? {
        warnings.isEmpty ? nil : warnings.map(\.text).joined(separator: "\n")
    }
}
