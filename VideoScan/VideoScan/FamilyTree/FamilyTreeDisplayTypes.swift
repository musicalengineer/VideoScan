// FamilyTreeDisplayTypes.swift
// The value types the Family Tree tab draws (sex, person summary, card,
// scene, relatives, anchors, line options/chains). Moved out of
// FamilyTreeLiveModel.swift unchanged (2026-11-01) — the model file had
// reached its length limit; nothing here depends on the model.

import AppKit
import Foundation

// MARK: - Display types

/// Sex as the card draws it. GEDCOM records "M" / "F" / "" (or "U").
enum FamilyTreeSex: Equatable {
    case male, female, unknown

    init(gedcom value: String) {
        switch value.uppercased() {
        case "M": self = .male
        case "F": self = .female
        default: self = .unknown
        }
    }

    var glyph: String {
        switch self {
        case .male: return "♂"
        case .female: return "♀"
        case .unknown: return ""
        }
    }
}

/// One row in the sidebar / one person in the inspector. Only facts the
/// GEDCOM actually records; nothing is invented.
struct FamilyTreePersonSummary: Identifiable, Equatable {
    let id: String
    let name: String
    let surname: String?
    let years: String?
    let sex: FamilyTreeSex
    /// The FamilySearch id, when the record has one. Shown on the card in
    /// place of the surname (Rick, 2026-09-17: "where the last name is
    /// currently in the person in FT view such as 'Doherty' we should have
    /// FS ID since Doherty is already in view, why list it again in small
    /// print under, put FSID?"). It is also the thing he searches by, the
    /// key his People folders are named on, and the key his identity
    /// rulings are recorded against.
    var familySearchID: String? = nil
    /// "I123" style GEDCOM pointer for live people, a short label for demo
    /// people. Shown in monospace on the card's last line.
    let reference: String
}

/// One card on the canvas, resolved from a layout node.
struct FamilyTreeCard: Identifiable {
    let id: String
    let person: FamilyTreePersonSummary
    let position: CGPoint
    let isRoot: Bool
    let photo: NSImage?
    let assetPerson: FamilyAssetPerson?

    init(id: String, person: FamilyTreePersonSummary, position: CGPoint,
         isRoot: Bool, photo: NSImage?, assetPerson: FamilyAssetPerson? = nil) {
        self.id = id
        self.person = person
        self.position = position
        self.isRoot = isRoot
        self.photo = photo
        self.assetPerson = assetPerson
    }
}

struct FamilyTreeScene {
    var cards: [FamilyTreeCard] = []
    var edges: [FamilyTreeLayout.Edge] = []
    var size: CGSize = .zero

    static let empty = FamilyTreeScene()
}

/// The people the inspector lists around the selected person.
struct FamilyTreeRelatives: Equatable {
    var parents: [FamilyTreePersonSummary] = []
    var spouses: [FamilyTreePersonSummary] = []
    var children: [FamilyTreePersonSummary] = []
    var siblings: [FamilyTreePersonSummary] = []

    var isEmpty: Bool {
        parents.isEmpty && spouses.isEmpty && children.isEmpty && siblings.isEmpty
    }
}

/// Someone a "Line to…" can end at: the tree root ("me") and the root's
/// spouse(s). Built once at install; labels are the person's first given
/// name, never a hard-coded "Rick"/"Donna".
struct FamilyTreeAnchor: Identifiable, Equatable {
    let id: String
    let label: String
    /// True for a home person of the tree (every root of a merged tree).
    let isRoot: Bool
    /// True only for the anchor that IS the reader: the pinned owner, or
    /// the root of a single-root tree (the first-INDI assumption). Its
    /// relation reads "your …"; every other anchor is named ("Donna's …").
    ///
    /// Separate from `isRoot` since 2026-09-27 (Tree Walk STEP 0, Rick:
    /// "the joined trees can sometimes think someone is my ancestor even
    /// though we're walking Donna's tree"). A merged tree has TWO roots;
    /// with no owner pin both read "your", so Donna's grandmother appeared
    /// as "your grandmother" in Donna's row. Two home people and no pin
    /// means nobody is "you".
    let readsAsYou: Bool

    init(id: String, label: String, isRoot: Bool, readsAsYou: Bool? = nil) {
        self.id = id
        self.label = label
        self.isRoot = isRoot
        self.readsAsYou = readsAsYou ?? isRoot
    }
}

/// One "Line to X" button for the selected person: the path when they are
/// an ancestor of the anchor, nil (disabled) when not.
struct FamilyTreeLineOption: Identifiable, Equatable {
    var id: String { anchor.id }
    let anchor: FamilyTreeAnchor
    /// Generations from the selected person down to the anchor (1 =
    /// parent); nil when they are not an ancestor. The path itself is
    /// built only when the chain is shown — it can be thousands long.
    let generations: Int?
    /// "your great-great-grandmother" — nil when `generations` is nil.
    let relation: String?
    var isAvailable: Bool { generations != nil }
}

/// The vertical chain the canvas draws in place of the tree.
struct FamilyTreeLineChain: Equatable {
    struct Card: Identifiable, Equatable {
        var id: String { person.id }
        let person: FamilyTreePersonSummary
        /// Recorded spouse names, as a caption ("⚭ Eileen Latta").
        let spouseNames: [String]
        /// 0 = the ancestor at the top.
        let generation: Int
        /// "Born 1615 (Plymouth…)" / "Died 1690, age 75 (…)" — the same
        /// lines the inspector shows; carried so the exported line strip
        /// can print places (2026-08-29). Empty when the GEDCOM has none.
        var lifeLines: [String] = []
    }
    let anchor: FamilyTreeAnchor
    let title: String
    let cards: [Card]
    var personIDs: Set<String> { Set(cards.map { $0.person.id }) }
}
