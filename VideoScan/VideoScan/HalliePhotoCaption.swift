// HalliePhotoCaption.swift
// "This photo is a photo of me and my family with Donna and the boys."
// (Rick, 2026-08-26 23:36Z — typed right after Hallie showed the wrong
// photo for Richard Sr; it was routed as a catalog search and answered
// "I found 2 catalog items".)
//
// When the previous answer showed a photo, a turn that opens with
// this/that photo/picture … is/shows/of is a TELLING about that photo:
// a caption to keep, and — if the photo was shown for someone the caption
// does not name — a correction ("never show it for him again").
//
// Pure text work only; the coordinator resolves names against the tree and
// performs the writes. C++ analogy: a small recursive-descent tokenizer
// returning a POD; no state, no I/O.

import Foundation
import VideoScanCore

enum HalliePhotoCaption {

    struct Statement: Equatable, Sendable {
        /// The caption as spoken, lead removed ("me and my family with
        /// Donna and the boys").
        let caption: String
        /// "me" / "I" / "myself" — the person typing is in the photo.
        let mentionsSpeaker: Bool
        /// "my wife" / "my husband" without a name.
        let mentionsSpouse: Bool
        /// "the boys" / "the kids" / "our sons" … as spoken, lowercased.
        let childrenPhrase: String?
        /// "dad" / "my father" — the speaker's father; likewise mother.
        let mentionsFather: Bool
        let mentionsMother: Bool
        /// Names as typed, first letters capitalised ("Donna").
        let names: [String]
        /// A four-digit year in the caption, if any.
        let year: Int?
        /// "in Montana" → "Montana".
        let place: String?
    }

    // MARK: Detection

    /// Leads that make the turn a caption. Anchored; case-insensitive.
    private static let leadPatterns: [String] = [
        #"^(this|that|the) (one|photo|picture|pic|photograph|image|shot)( here)? (is|was|shows|show|has|is of|is from|is a (photo|picture|pic|photograph|image|shot) of|is a (photo|picture|pic|photograph|image|shot) from|is (of|from))\b"#,
        #"^(this is|that is|that's|thats|it's|its|it is) (a|the) (photo|picture|pic|photograph|image|shot) (of|from|showing)\b"#,
        #"^(this is|that is|that's|thats) (a|the) (photo|picture|pic|photograph|image|shot)\b"#,
    ]

    static func detect(_ text: String) -> Statement? {
        let cleaned = normalize(text)
        guard !cleaned.isEmpty else { return nil }
        var tail: String?
        for pattern in leadPatterns {
            if let range = cleaned.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                tail = String(cleaned[range.upperBound...])
                break
            }
        }
        guard var rest = tail?.trimmingCharacters(in: .whitespaces) else { return nil }
        // "…is a photo of X", "…is of X", "…shows X" all leave X.
        for prefix in ["a photo of ", "a picture of ", "a pic of ", "a photograph of ", "an image of ",
                       "a shot of ", "of ", "from ", "showing "] where rest.hasPrefix(prefix) {
            rest = String(rest.dropFirst(prefix.count))
            break
        }
        rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " .,:;!?\"'"))
        guard !rest.isEmpty, rest.count <= 300 else { return nil }
        // A question about the photo is not a caption ("this photo is of whom?").
        guard !rest.contains("?"),
              !["who", "whom", "what", "when", "where", "which"].contains(rest.split(separator: " ").first.map(String.init) ?? "")
        else { return nil }
        return parse(rest)
    }

    // MARK: Parsing

    private static let childrenPhrases: [String] = [
        "the boys", "the kids", "the children", "the girls", "our boys", "our kids",
        "our children", "our sons", "our daughters", "our girls", "my boys", "my kids",
        "my children", "my sons", "my daughters", "my girls", "all the kids", "all the boys",
    ]
    private static let speakerWords: Set<String> = ["me", "i", "myself"]
    private static let familyWords: Set<String> = ["my family", "our family", "the family", "the whole family", "family"]
    private static let spouseWords: Set<String> = ["my wife", "my husband", "my spouse"]
    private static let fatherWords: Set<String> = ["dad", "my dad", "father", "my father", "pop", "my pop", "pa", "my pa", "daddy", "my daddy"]
    private static let motherWords: Set<String> = ["mom", "my mom", "mother", "my mother", "ma", "my ma", "mum", "my mum", "mommy", "my mommy"]
    private static let stopChunks: Set<String> = ["", "us", "everyone", "everybody", "all of us", "the rest of us"]

    private static func parse(_ rest: String) -> Statement {
        var body = rest
        var year: Int?
        if let match = body.range(of: #"\b(18|19|20)\d{2}\b"#, options: .regularExpression) {
            year = Int(body[match])
        }
        // Trailing where/when: " in Montana in 1995", " at the lake", " back in '95".
        var place: String?
        if let cut = body.range(of: #"\s+(in|at|on|near|during|back in|circa|around|about|from)\s+"#, options: .regularExpression) {
            let tailText = String(body[cut.upperBound...])
            body = String(body[..<cut.lowerBound])
            let stripped = tailText
                .replacingOccurrences(of: #"\b(in|at|on|near|during|back in|circa|around|about)\b"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\b(18|19|20)\d{2}\b"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " .,;!"))
            if !stripped.isEmpty, stripped.count <= 60 { place = capitalised(stripped) }
        }
        let chunks = body
            .replacingOccurrences(of: " & ", with: " and ")
            .replacingOccurrences(of: " plus ", with: " and ")
            .replacingOccurrences(of: " with ", with: " and ")
            .replacingOccurrences(of: ",", with: " and ")
            .components(separatedBy: " and ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .;!")) }
        var mentionsSpeaker = false
        var mentionsSpouse = false
        var mentionsFather = false
        var mentionsMother = false
        var childrenPhrase: String?
        var names: [String] = []
        for raw in chunks {
            var chunk = raw
            if chunk.hasPrefix("also ") { chunk = String(chunk.dropFirst(5)) }
            if chunk.hasPrefix("of ") { chunk = String(chunk.dropFirst(3)) }
            if stopChunks.contains(chunk) { continue }
            if speakerWords.contains(chunk) { mentionsSpeaker = true; continue }
            if familyWords.contains(chunk) { mentionsSpeaker = true; continue }
            if spouseWords.contains(chunk) { mentionsSpouse = true; continue }
            if childrenPhrases.contains(chunk) { childrenPhrase = childrenPhrase ?? chunk; continue }
            if fatherWords.contains(chunk) { mentionsFather = true; continue }
            if motherWords.contains(chunk) { mentionsMother = true; continue }
            // "my wife Donna" / "my brother Tom" → the name after the kinship
            // word; "our wedding" / "my house" is not a person at all.
            var words = chunk.split(separator: " ").map(String.init)
            if ["my", "our", "his", "her", "their", "your"].contains(words.first ?? "") {
                guard words.count >= 3 else { continue }
                words.removeFirst(2)
            }
            let name = words.joined(separator: " ")
            guard !name.isEmpty, name.count <= 40, words.count <= 4,
                  words.allSatisfy({ $0.first?.isLetter ?? false }) else { continue }
            let pretty = capitalised(name)
            if !names.contains(pretty) { names.append(pretty) }
        }
        return Statement(
            caption: rest,
            mentionsSpeaker: mentionsSpeaker,
            mentionsSpouse: mentionsSpouse,
            childrenPhrase: childrenPhrase,
            mentionsFather: mentionsFather,
            mentionsMother: mentionsMother,
            names: names,
            year: year,
            place: place)
    }

    // MARK: Reply

    /// "Got it — I've noted this photo shows you, Donna and the boys
    /// (Montana, 1995), and I won't show it for Richard Harding Breen Sr
    /// again."
    static func reply(shows: [String], place: String?, year: Int?,
                      excludedName: String?, problems: [String]) -> String {
        var text = "Got it — I've noted this photo shows " + joined(shows)
        let hint = [place, year.map(String.init)].compactMap { $0 }
        if !hint.isEmpty { text += " (" + hint.joined(separator: ", ") + ")" }
        if let excludedName {
            text += ", and I won't show it for \(excludedName) again."
        } else {
            text += "."
        }
        for problem in problems { text += " " + problem }
        return text
    }

    /// Place and year read off a file name like `SouthEastMontana1995.jpg`
    /// when the caption gave none. Presentation only.
    static func filenameHint(_ url: URL) -> (place: String?, year: Int?) {
        let stem = url.deletingPathExtension().lastPathComponent
        var year: Int?
        if let match = stem.range(of: #"(18|19|20)\d{2}"#, options: .regularExpression) {
            year = Int(stem[match])
        }
        let words = stem
            .replacingOccurrences(of: #"(18|19|20)\d{2}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"([a-z])([A-Z])"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #"[_\-]+"#, with: " ", options: .regularExpression)
            .split(separator: " ").map(String.init)
            .filter { $0.count > 1 && $0.first!.isLetter }
        let place = words.isEmpty ? nil : words.joined(separator: " ")
        return (place, year)
    }

    static func joined(_ items: [String]) -> String {
        switch items.count {
        case 0: return "the family"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }

    // MARK: Helpers

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalised(_ text: String) -> String {
        text.split(separator: " ").map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }.joined(separator: " ")
    }
}
