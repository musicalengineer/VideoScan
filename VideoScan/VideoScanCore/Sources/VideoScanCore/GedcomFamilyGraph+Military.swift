// GedcomFamilyGraph+Military.swift (VideoScanCore)
// Military facts a family tree records about a person (Rick 2026-09-23:
// Hallie should answer "was anyone in the family in the Revolution?" from
// the tree as well as from the family's own stories).
//
// What FamilySearch / Ancestry exports actually carry (Rick's pulls,
// measured 2026-09-23: 235 people in one 20-generation pull):
//
//   1 _MILT Private in Revolutionary War      ← the text is the fact
//   1 _MILT                                    ← or only a date and place
//   2 DATE 6 July 1780
//   2 PLAC Shrewsbury, Worcester, Massachusetts, United States
//   1 EVEN                                     ← a typed event
//   2 TYPE Military Draft Registration
//   2 DATE 1917-1918
//
// Kept: the level-1 tag and its text, and TYPE / DATE / PLAC / an inline
// NOTE (with its CONT/CONC). Dropped and COUNTED as dropped, like every
// other line the graph has no model for: map coordinates, source
// citations, and NOTE pointers (`2 NOTE @N80@` — top-level NOTE records
// are not read). A typed EVEN/FACT is military only when its TYPE says so;
// any other typed event is dropped whole, exactly as before.
//
// Raw strings, verbatim, like the vital dates: Hallie shows what the tree
// says and never reinterprets it. Nothing here decides that a person
// "served" or "fought" — a draft registration is a registration.
//
// C++ analogy: a plain aggregate struct (all-public, value semantics); the
// static sets are `static const std::unordered_set` built once.

import Foundation

extension GedcomFamilyGraph {

    public struct MilitaryFact: Sendable, Equatable {
        /// The level-1 tag as read ("_MILT", "MILI", "EVEN", …); the writer
        /// emits it back unchanged.
        public var tag: String
        /// The text on the level-1 line ("Private in Revolutionary War").
        public var value: String?
        /// `2 TYPE` — required (and military) for EVEN / FACT.
        public var type: String?
        /// `2 DATE`, raw.
        public var date: String?
        /// `2 PLAC`, raw.
        public var place: String?
        /// An inline `2 NOTE` with its CONT (newline) / CONC continuations.
        public var note: String?

        public init(tag: String, value: String? = nil, type: String? = nil,
                    date: String? = nil, place: String? = nil, note: String? = nil) {
            self.tag = tag
            self.value = value
            self.type = type
            self.date = date
            self.place = place
            self.note = note
        }

        /// "Military Draft Registration" — a registration for the draft,
        /// which is not service. Hallie words it as a registration.
        public var isDraftRegistration: Bool {
            [value, type].compactMap { $0?.lowercased() }.contains { $0.contains("draft") }
        }

        /// The fact's own words: the line text, else the TYPE, else nil.
        /// A FamilySearch TYPE arrives URL-ish ("Military+Rank+-+Lieutenant");
        /// the plus signs are read as spaces.
        public var summary: String? {
            let text = value ?? type
            return text.map { $0.replacingOccurrences(of: "+", with: " ") }
                .map { $0.replacingOccurrences(of: "  ", with: " ") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
        }

        /// Year of the raw date ("6 July 1780", "from 1707 to 1716" → first).
        public var year: Int? { GedcomFamilyGraph.year(in: date) }
    }

    /// Level-1 tags that ARE a military fact whatever follows.
    static let militaryTags: Set<String> = ["_MILT", "_MIL", "_MILI", "MILI"]
    /// Level-1 tags that are a military fact only when their TYPE says so.
    static let typedEventTags: Set<String> = ["EVEN", "FACT"]

    static func isMilitaryType(_ type: String?) -> Bool {
        guard let type else { return false }
        return type.lowercased().contains("milit")
    }

    /// A military block being read. `heldLines` counts the lines kept so
    /// far; when a typed event turns out not to be military they are all
    /// counted as dropped at once, so the loss accounting stays exact.
    struct PendingMilitaryFact {
        var fact: MilitaryFact
        var typed: Bool
        var heldLines: Int
        /// The level-2 tag currently open (NOTE → CONT/CONC follow).
        var openSubTag: String = ""

        var isMilitary: Bool { !typed || GedcomFamilyGraph.isMilitaryType(fact.type) }
    }

    /// Opens a block for a level-1 line, or nil when the tag is not one of
    /// ours.
    static func openMilitaryFact(tag: String, value: String) -> PendingMilitaryFact? {
        let text = value.trimmingCharacters(in: .whitespaces)
        if militaryTags.contains(tag) {
            return PendingMilitaryFact(
                fact: MilitaryFact(tag: tag, value: text.isEmpty ? nil : text),
                typed: false, heldLines: 1)
        }
        if typedEventTags.contains(tag) {
            return PendingMilitaryFact(
                fact: MilitaryFact(tag: tag, value: text.isEmpty ? nil : text),
                typed: true, heldLines: 1)
        }
        return nil
    }

    /// Reads one sub-line (level ≥ 2) of an open block. Returns false when
    /// the line is not kept (the caller counts it as dropped).
    static func applyMilitaryLine(level: Int, tag: String, value: String,
                                  to pending: inout PendingMilitaryFact) -> Bool {
        let text = value.trimmingCharacters(in: .whitespaces)
        if level == 2 {
            pending.openSubTag = tag
            switch tag {
            case "TYPE" where pending.fact.type == nil && !text.isEmpty:
                pending.fact.type = text
            case "DATE" where pending.fact.date == nil && !text.isEmpty:
                pending.fact.date = text
            case "PLAC" where pending.fact.place == nil && !text.isEmpty:
                pending.fact.place = text
            case "NOTE" where pending.fact.note == nil && !text.isEmpty && !text.hasPrefix("@"):
                pending.fact.note = text
            default:
                pending.openSubTag = ""
                return false
            }
            pending.heldLines += 1
            return true
        }
        if level == 3, pending.openSubTag == "NOTE", pending.fact.note != nil {
            switch tag {
            case "CONT": pending.fact.note = (pending.fact.note ?? "") + "\n" + value
            case "CONC": pending.fact.note = (pending.fact.note ?? "") + value
            default: return false
            }
            pending.heldLines += 1
            return true
        }
        return false
    }
}
