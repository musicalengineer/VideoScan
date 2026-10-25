import Foundation

/// GH #375: the family's nickname is both the menu name and the new tag.
/// Labels can carry birth years; those decorations never become tag keys.
/// UUIDs identify menu rows even when profiles share a formal name.
enum PersonPickerNames {
    struct Option: Identifiable {
        let id: UUID
        let label: String
        let tagName: String?
        /// Only spellings that identify this person alone. In particular,
        /// an old shared "Timothy" tag must not check both Tim and Timmy.
        let uniqueKeys: Set<String>

        func isTagged(in record: VideoRecord) -> Bool {
            record.taggedPeople.contains { uniqueKeys.contains($0.lowercased()) }
        }

        /// The spellings `records` actually carry for this person — what an
        /// uncheck hands the engine, so a rejection keeps the record's own
        /// case (#375 review 2026-10-25: a lowercased key written to
        /// `rejectedPeople` could never be un-rejected by an exact match).
        func spellings(in records: [VideoRecord]) -> Set<String> {
            Set(records.flatMap { record in
                record.taggedPeople.filter { uniqueKeys.contains($0.lowercased()) }
            })
        }

        var help: String {
            tagName.map { "Tag as \($0)" }
                ?? "Give this person a distinct nickname in the People tab before tagging."
        }
    }

    /// One pass over the small family roster, never over catalog records.
    /// Pure and injectable: does not read profiles or the family tree.
    static func options(_ profiles: [POIProfile]) -> [Option] {
        let labels = labels(profiles)
        let keys = profiles.map { PersonVideos.tagKeys(for: $0) }
        var owners: [String: Set<UUID>] = [:]
        for (profile, spellings) in zip(profiles, keys) {
            for key in spellings { owners[key, default: []].insert(profile.uuid) }
        }
        return zip(profiles, keys).map { profile, spellings in
            // "Family" is the existing everyone wildcard, never one person.
            let unique = Set(spellings.filter { owners[$0]?.count == 1 && $0 != "family" })
            let nickname = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return Option(id: profile.uuid, label: labels[profile.uuid] ?? nickname,
                          tagName: unique.contains(nickname.lowercased()) ? nickname : nil,
                          uniqueKeys: unique)
        }
    }

    static func labels(_ profiles: [POIProfile]) -> [UUID: String] {
        var labels = Dictionary(uniqueKeysWithValues: profiles.map { profile in
            let name = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            return (profile.uuid, name.isEmpty ? "Unnamed person" : name)
        })
        for group in collisions(profiles, labels: labels) {
            for profile in group {
                if let birthdate = profile.birthdate {
                    let year = TreeIdentityDeriver.utcCalendar.component(.year, from: birthdate)
                    labels[profile.uuid, default: ""] += " (b. \(year))"
                }
            }
        }
        // Missing or identical birth years still need distinct labels. A
        // stable UUID ordering keeps the numbers unchanged on gallery drag.
        for group in collisions(profiles, labels: labels) {
            for (index, profile) in group.sorted(by: { $0.uuid.uuidString < $1.uuid.uuidString }).enumerated() {
                labels[profile.uuid, default: ""] += " (person \(index + 1))"
            }
        }
        return labels
    }

    private static func collisions(_ profiles: [POIProfile], labels: [UUID: String]) -> [[POIProfile]] {
        Dictionary(grouping: profiles, by: { labels[$0.uuid, default: ""].lowercased() })
            .values.filter { $0.count > 1 }
    }
}
