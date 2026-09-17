// FamilyPersonFolderName.swift
// What a person's folder under People/ is called (Rick, 2026-09-17).
//
// TWO KINDS OF PERSON, ONE SHAPE. Rick's rule: "IFF a person has an ID from
// Gedcom such as an ID used by family search, we can use that ID and
// centralize the folder such as Donna_Hudson_Breen_ID … if there is no ID …
// you can make up a UUID if you like." And for the People tab: "the rest of
// the living siblings and children do not have FSIDs, so we'll have to use
// nickname_first_last_suffix."
//
// Both end in a KEY, and that is the point. A folder named only for a person
// drifts: Donna had one folder under her maiden name and another under her
// married name, Hallie had one as "Mae" and one as "May", and Peter had three
// spellings including a misspelt surname. A key on the end makes the folder
// survive every one of those, and makes the name in front of it free to
// change — which it will, because Rick reads these in Finder and will want
// them to read well.
//
// A NICKNAME IS NOT A KEY, which is the one place the scheme as first stated
// needs care. "Beth" can become "Liz"; a sister can be "Beth" in one decade
// and "Elizabeth" on a legal document in the next. So the nickname goes in
// the NAME, where it helps Rick recognise the folder, and a short stable
// local key goes on the END, where identity lives. Renaming the folder then
// costs nothing, exactly as renaming a FamilySearch-keyed folder costs
// nothing.

import Foundation

public enum FamilyPersonFolderName {

    /// How this person is identified durably.
    public enum Identity: Equatable, Sendable {
        /// In the shared tree.
        case familySearch(String)
        /// Not in the shared tree — a living relative, usually by choice.
        /// The key is stable and opaque; it is never a display name.
        case local(String)

        public var key: String {
            switch self {
            case .familySearch(let id): return id
            case .local(let key): return key
            }
        }
    }

    /// The pieces of a name, in the order Rick asked for them.
    public struct Name: Equatable, Sendable {
        /// What the family actually calls them ("Beth", "Timmy"). Optional,
        /// and first when present, because that is what Rick scans for.
        public var nickname: String?
        public var first: String?
        public var last: String?
        /// "Jr", "Sr", "III" — kept, because it is often the only thing
        /// separating a father from a son who share everything else.
        public var suffix: String?

        public init(nickname: String? = nil, first: String? = nil,
                    last: String? = nil, suffix: String? = nil) {
            self.nickname = nickname
            self.first = first
            self.last = last
            self.suffix = suffix
        }

        /// Split a whole name into the pieces, for callers that only have
        /// one string. Slashes are GEDCOM surname markers when present.
        public init(wholeName raw: String) {
            let marked = raw.range(of: #"/[^/]*/"#, options: .regularExpression)
            var surname: String?
            var rest = raw
            if let marked {
                surname = String(raw[marked]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                rest = raw.replacingCharacters(in: marked, with: " ")
            }
            var parts = rest.split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
            var suffix: String?
            if let last = parts.last, Self.suffixes.contains(last.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                suffix = last.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                parts.removeLast()
            }
            if surname == nil, parts.count > 1 { surname = parts.removeLast() }
            self.init(nickname: nil, first: parts.joined(separator: " "),
                      last: surname, suffix: suffix)
        }

        static let suffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "v"]
    }

    /// `Beth_Elizabeth_Breen_L7K2QX` or `Donna_Hudson_G2CL-86B`.
    ///
    /// The key is ALWAYS last and always present. A caller cannot produce a
    /// folder without one, which is what keeps one person to one folder.
    public static func component(name: Name, identity: Identity) -> String {
        let words = [name.nickname, name.first, name.last, name.suffix]
            .compactMap { $0 }
            .map(sanitise)
            .filter { !$0.isEmpty }
        // De-duplicate a nickname that IS the first name ("Tim"/"Tim"), so
        // nobody gets Tim_Tim_Breen.
        var seen = Set<String>()
        let unique = words.filter { seen.insert($0.lowercased()).inserted }
        let stem = unique.joined(separator: "_")
        return stem.isEmpty ? identity.key : "\(stem)_\(identity.key)"
    }

    /// The identity a folder name carries, or nil when it has none — which
    /// is how a folder written before this rule, or a group folder like
    /// RickDonnaBreenFamily, is recognised and left alone.
    public static func identity(inComponent component: String,
                                isLocalKey: (String) -> Bool = { _ in false }) -> Identity? {
        if GedcomFamilyGraph.isFamilySearchID(component) { return .familySearch(component) }
        guard let last = component.split(separator: "_").last.map(String.init) else { return nil }
        if GedcomFamilyGraph.isFamilySearchID(last) { return .familySearch(last) }
        if isLocalKey(last) { return .local(last) }
        return nil
    }

    /// A short, stable, opaque key for someone with no FamilySearch record.
    /// Six characters from a no-lookalike alphabet: no O/0 or I/1, because
    /// Rick reads and retypes these out of Finder.
    public static func newLocalKey(randomness: () -> UInt8 = { UInt8.random(in: 0...255) }) -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        return String((0..<6).map { _ in alphabet[Int(randomness()) % alphabet.count] })
    }

    /// Folder-safe: letters, digits and single underscores.
    static func sanitise(_ raw: String) -> String {
        let cleaned = raw.replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        return cleaned.unicodeScalars
            .map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { out, c in
                if c == "_" && (out.isEmpty || out.hasSuffix("_")) { return }
                out.append(c)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }
}
