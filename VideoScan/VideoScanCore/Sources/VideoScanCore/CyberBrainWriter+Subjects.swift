// CyberBrainWriter+Subjects.swift
import Foundation

extension CyberBrainWriter {
    /// Subject → CyberBrain person id, minting one when nobody matches. The
    /// resolution ladder shared by testimony and captions: a known GEDCOM
    /// pointer wins; a name match that carries a DIFFERENT pointer is
    /// somebody else (Jr/Sr); an unlinked name match acquires the pointer.
    /// Internal (not private) so note corrections resolve a MOVE target by
    /// exactly this ladder instead of a copy of it.
    static func resolveSubject(
        _ subject: String,
        gedcomPersonID: String?,
        aliases: [String],
        index: CyberBrainIndex,
        people: inout [CyberBrainPerson]
    ) throws -> (id: String, created: Bool) {
        func createPerson() -> String {
            let id = uniqueID(
                base: "person." + slug(subject)
                    + (gedcomPersonID.map { "." + slug($0) } ?? ""),
                taken: Set(people.map(\.id)))
            people.append(CyberBrainPerson(
                id: id,
                gedcomPersonID: gedcomPersonID,
                canonicalName: subject,
                aliases: normalizedAliases(aliases, excluding: subject)))
            return id
        }
        if let pointer = gedcomPersonID,
           let linked = index.people(gedcomPersonID: pointer).first {
            return (linked.id, false)
        }
        switch index.resolve(subject) {
        case .resolved(let person):
            if let pointer = gedcomPersonID,
               let existing = person.gedcomPersonID, existing != pointer {
                return (createPerson(), true)
            }
            if person.gedcomPersonID == nil, let pointer = gedcomPersonID,
               let at = people.firstIndex(where: { $0.id == person.id }) {
                let p = people[at]
                people[at] = CyberBrainPerson(
                    id: p.id, gedcomPersonID: pointer, profileStableID: p.profileStableID,
                    canonicalName: p.canonicalName, aliases: p.aliases, terminology: p.terminology,
                    biographyPassages: p.biographyPassages, anecdotes: p.anecdotes,
                    lifeEvents: p.lifeEvents, notes: p.notes,
                    pronunciations: p.pronunciations)
            }
            return (person.id, false)
        case .ambiguous(let candidates):
            guard gedcomPersonID != nil else {
                throw WriteError.ambiguousSubject(candidates.map(\.canonicalName))
            }
            return (createPerson(), true)
        case .notFound:
            return (createPerson(), true)
        }
    }

    public static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
        var out = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "unnamed" : out
    }

    static func uniqueID(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base).\(n)") { n += 1 }
        return "\(base).\(n)"
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func normalizedAliases(_ aliases: [String],
                                          excluding canonical: String) -> [String] {
        var seen: Set<String> = [FamilyIdentityText.normalized(canonical)]
        var out: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = FamilyIdentityText.normalized(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }
}
