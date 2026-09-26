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
// Pure: a function over the transcript value. The window applies it from
// HallieResponseCommit's `retireSupersededOffers` sink, before the new
// answer's own bubble is appended, so the current answer's chips are
// never touched.

import Foundation

enum HallieSupersededOffers {

    /// Does this chip open the tree on someone other than `subject`?
    /// Only the person-navigation chips count; asks, folders, surnames and
    /// app-tab chips are never superseded by a change of person.
    static func isSuperseded(_ chip: ArchivistMessage.Chip, by subject: String) -> Bool {
        switch chip.action {
        case .openFamilyTree(let name), .openFamilyTreePerson(_, let name):
            return PersonResolver.normalize(name) != PersonResolver.normalize(subject)
        default:
            return false
        }
    }

    /// The transcript with every assistant bubble's stale tree offers
    /// removed. User bubbles, other chips and bubble identity are untouched.
    static func retire(in messages: [ArchivistMessage], keeping subject: String) -> [ArchivistMessage] {
        messages.map { message in
            guard message.role == .assistant,
                  message.chips.contains(where: { isSuperseded($0, by: subject) })
            else { return message }
            var retired = message
            retired.chips = message.chips.filter { !isSuperseded($0, by: subject) }
            return retired
        }
    }
}
