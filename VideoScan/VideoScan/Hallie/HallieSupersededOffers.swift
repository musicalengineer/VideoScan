// HallieSupersededOffers.swift
// A navigation offer belongs to the answer that made it. Once a later
// answer settles the conversation on a DIFFERENT person, the earlier
// "Open in Family Tree: X" chips are retired from the transcript — the
// same rule ConversationMemory.tree.lastOffers already applies to "show
// me" (HallieTreeFollowUp): only the last tree answer's offers are live.
//
// Live 2026-09-26 14:15 ET (Rick, app): "find videos of dad" was answered
// for Dafydd ab Einion (b. ~1360) with an "Open in Family Tree: Dafydd …"
// chip. Rick corrected — "dad breen not someone from 5 centuries ago" —
// and the model timed out for 21 s. In the second the corrected answer
// landed (14:15:28 → "Family Tree: selected Dafydd" at 14:15:29) that
// stale chip was tapped and the tree opened on the man Rick had just
// rejected. A chip tapped WHILE Hallie thinks is dropped without a word
// (ArchivistChatWindow.handle(chip:)), which is how a tap lands the
// instant thinking ends; a chip that no longer answers the conversation
// must not stay tappable once the conversation has moved on.
//
// "A different person" is decided by tree person ID when both sides have
// one, by name only when they do not (GH #202, night hardening
// 2026-09-27): two Mary O'Connors, b. 1650 and b. 1904, share a name, so
// comparing names retired nothing when the conversation moved from one to
// the other and the stale chip opened the record just left behind.
//
// Pure: a function over the transcript value. The window applies it from
// HallieResponseCommit's `retireSupersededOffers` sink, before the new
// answer's own bubble is appended, so the current answer's chips are
// never touched.

import Foundation

enum HallieSupersededOffers {

    /// Who the conversation settled on: the name, and the family-tree
    /// person id when an answer supplied one
    /// (ConversationMemory.lastSubjectPersonID).
    struct Subject: Equatable {
        let name: String
        let personID: String?

        init(name: String, personID: String? = nil) {
            self.name = name
            self.personID = personID
        }

        /// Is this a different person from `other`? When both ids are
        /// known, the ids decide — namesakes are different people, and one
        /// record under two spellings is the same person. Otherwise the
        /// normalized names decide (the pre-#202 rule), so the same name
        /// with an id missing on either side is NOT different: a live chip
        /// is never retired on a guess.
        func isDifferentPerson(from other: Subject) -> Bool {
            if let personID, let otherID = other.personID {
                return personID != otherID
            }
            return PersonResolver.normalize(name) != PersonResolver.normalize(other.name)
        }
    }

    /// Does this chip open the tree on someone other than `subject`?
    /// Only the person-navigation chips count; asks, folders, surnames and
    /// app-tab chips are never superseded by a change of person. A chip
    /// with a person id is judged by id when the subject has one; a
    /// name-only chip (or an id-less subject) by name.
    static func isSuperseded(_ chip: ArchivistMessage.Chip, by subject: Subject) -> Bool {
        switch chip.action {
        case .openFamilyTreePerson(let id, let name):
            return subject.isDifferentPerson(from: Subject(name: name, personID: id))
        case .openFamilyTree(let name):
            return subject.isDifferentPerson(from: Subject(name: name))
        default:
            return false
        }
    }

    /// Name-only convenience (no tree id known for the subject).
    static func isSuperseded(_ chip: ArchivistMessage.Chip, by subject: String) -> Bool {
        isSuperseded(chip, by: Subject(name: subject))
    }

    /// The transcript with every assistant bubble's stale tree offers
    /// removed. User bubbles, other chips and bubble identity are untouched.
    static func retire(in messages: [ArchivistMessage], keeping subject: Subject) -> [ArchivistMessage] {
        messages.map { message in
            guard message.role == .assistant,
                  message.chips.contains(where: { isSuperseded($0, by: subject) })
            else { return message }
            var retired = message
            retired.chips = message.chips.filter { !isSuperseded($0, by: subject) }
            return retired
        }
    }

    /// Name-only convenience (no tree id known for the subject).
    static func retire(in messages: [ArchivistMessage], keeping subject: String) -> [ArchivistMessage] {
        retire(in: messages, keeping: Subject(name: subject))
    }
}
