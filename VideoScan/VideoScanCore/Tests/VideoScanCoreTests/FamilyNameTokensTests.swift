import Testing
@testable import VideoScanCore

/// GH #184 item 6 (live 2026-09-11 22:11Z): "see" resolved to Adam
/// FitzHerbert of Llanllowell through his notes-style tree alias
/// "Llanlowell Llan Hywel and see note". One rule decides which single
/// word may stand for a person; these pin it.
struct FamilyNameTokensTests {

    /// The REAL alias shape from Rick's tree (GEDCOM @IB23862@).
    private let adam = (name: "Adam FitzHerbert of Llanllowell",
                        aliases: ["Llanlowell Llan Hywel and see note"])

    @Test func noCommonWordInsideTheGarbageAliasResolves() {
        for word in ["see", "and", "note", "See", "AND", "of"] {
            #expect(!FamilyNameTokens.matches(word, primaryName: adam.name, aliases: adam.aliases),
                    Comment(rawValue: word))
            #expect(FamilyNameTokens.spelling(of: word, primaryName: adam.name, aliases: adam.aliases) == nil,
                    Comment(rawValue: word))
        }
        // The notes-style alias yields NO single-word names at all — not
        // even its capitalised ones; only the whole alias matches.
        #expect(FamilyNameTokens.isNotesStyle(adam.aliases[0]))
        #expect(FamilyNameTokens.nameWords(ofAlias: adam.aliases[0], primaryName: adam.name).isEmpty)
        #expect(!FamilyNameTokens.matches("Hywel", primaryName: adam.name, aliases: adam.aliases))
        #expect(FamilyNameTokens.matches("Llanlowell Llan Hywel and see note", primaryName: adam.name, aliases: adam.aliases))
    }

    @Test func nameWordsOfThePrimaryNameStillResolve() {
        #expect(FamilyNameTokens.spelling(of: "adam", primaryName: adam.name, aliases: adam.aliases) == "Adam")
        #expect(FamilyNameTokens.spelling(of: "FITZHERBERT", primaryName: adam.name, aliases: adam.aliases) == "FitzHerbert")
        #expect(FamilyNameTokens.spelling(of: "Llanllowell", primaryName: adam.name, aliases: adam.aliases) == "Llanllowell")
        #expect(FamilyNameTokens.nameWords(ofPrimaryName: adam.name) == ["Adam", "FitzHerbert", "Llanllowell"])
    }

    /// A sensor over a wider garbage-alias shape: every common English word
    /// that could sit inside a note-like alias, none of them a name.
    @Test func sensorCommonWordsInsideGarbageAliasesNeverResolve() {
        let garbage = [
            "Llanlowell Llan Hywel and see note",
            "the same as the one above",
            "possibly the son of John (see notes)",
            "High Sheriff of Essex, Assistant to King Henry VIII",
            "unknown wife of Thomas",
            "Mary née Smith or Smyth",
        ]
        let primary = "Thomas Fixture"
        for alias in garbage {
            for word in FamilyNameTokens.words(alias)
            where FamilyNameTokens.commonWords.contains(FamilyIdentityText.normalized(word)) {
                #expect(!FamilyNameTokens.matches(word, primaryName: primary, aliases: [alias]),
                        Comment(rawValue: "\(word) in \(alias)"))
            }
        }
        // The list is not empty by accident.
        #expect(FamilyNameTokens.commonWords.isSuperset(of: ["see", "and", "note", "the", "of", "or", "in"]))
    }

    @Test func wholeAliasAndCapitalisedAliasWordsAreNames() {
        // People-tab style: a canonical name plus nicknames.
        #expect(FamilyNameTokens.spelling(of: "nate", primaryName: "Nathaniel McGill", aliases: ["Nate"]) == "Nate")
        #expect(FamilyNameTokens.spelling(of: "Ma", primaryName: "Eileen Latta", aliases: ["Ma", "Mom"]) == "Ma")
        // A capitalised word of a clean multi-word alias.
        #expect(FamilyNameTokens.spelling(of: "latta", primaryName: "Ma", aliases: ["Eileen Latta"]) == "Latta")
        // A lowercase word of a multi-word alias is not a name unless the
        // primary name also carries it.
        #expect(FamilyNameTokens.spelling(of: "breen", primaryName: "Tim", aliases: ["tim breen"]) == nil)
        #expect(FamilyNameTokens.spelling(of: "breen", primaryName: "Tim Breen", aliases: ["tim breen"]) == "Breen")
        // The whole lowercase alias still matches whole.
        #expect(FamilyNameTokens.spelling(of: "tim breen", primaryName: "Tim", aliases: ["tim breen"]) == "tim breen")
    }

    @Test func lowercaseTreeNamesNeedNoCapital() {
        // The tree carries "peter ronan" as a primary name.
        #expect(FamilyNameTokens.spelling(of: "Ronan", primaryName: "peter ronan", aliases: []) == "ronan")
        #expect(FamilyNameTokens.spelling(of: "peter", primaryName: "peter ronan", aliases: []) == "peter")
    }

    @Test func commonWordsAndSuffixesInsideAPrimaryNameAreNotNames() {
        for word in ["of", "Sr", "jr", "the", "Sir"] {
            #expect(!FamilyNameTokens.matches(word, primaryName: "Sir Richard of the Manor Breen Sr", aliases: []),
                    Comment(rawValue: word))
        }
        #expect(FamilyNameTokens.matches("Manor", primaryName: "Sir Richard of the Manor Breen Sr", aliases: []))
        #expect(!FamilyNameTokens.matches("", primaryName: "Rick Breen", aliases: []))
        #expect(!FamilyNameTokens.matches("   ", primaryName: "Rick Breen", aliases: []))
    }

    @Test func notesStyleIsParentheticalOrCommonLowercaseWordOrLong() {
        #expect(FamilyNameTokens.isNotesStyle("Richard (Dick) Breen"))
        #expect(FamilyNameTokens.isNotesStyle("Mary [Polly] Jones"))
        #expect(FamilyNameTokens.isNotesStyle("John and see note"))
        #expect(FamilyNameTokens.isNotesStyle("One Two Three Four Five Six"))
        #expect(!FamilyNameTokens.isNotesStyle("Richard Harding Breen Jr"))
        #expect(!FamilyNameTokens.isNotesStyle("Dicky"))
        #expect(!FamilyNameTokens.isNotesStyle("Mary O'Connor"))
    }
}
