// POIFamilyNameFieldsTests.swift
// Last names, maiden names, middle names, suffixes and titles on a People
// profile (Rick, 2026-09-04: "should be easy to add last names, maiden names
// etc, this will help the bios").
//
// THE TWO NEGATIVES ARE THE POINT OF THIS FILE.
//
//   • A BARE SURNAME MUST RESOLVE TO NOBODY. "Breen" belongs to hundreds of
//     people in a 39,250-person tree. If a last name became a spelling of its
//     own, one of them would be picked and stated confidently — the worst
//     failure this system can produce, and strictly worse than declining.
//
//   • TITLES ARE DISPLAY ONLY. "Grampa" / "Dad" / "Ma" are RELATIONAL: they
//     name a different person depending on who is speaking. Making them
//     matchable would recreate the Mom/Ma collision that produced a
//     wrong-person answer on 2026-09-03 and forced an archive folder rename.
//
// And the quiet requirement that covers all thirteen live profiles today:
// BLANK IS ABSENT. Rick will fill a surname in for some rows and leave the
// rest empty, possibly for a long time. A blank field, a whitespace-only
// field and a field that was never written must be indistinguishable — no
// stray form, no "Tim  Breen", no behaviour change of any kind.
//
// ISOLATION: nothing here reads or writes ~/Library/Application Support.
// The codable tests use a per-test temp dir; everything else is pure values.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

struct POIFamilyNameFieldsTests {

    typealias Tab = HallieTurnExecutor.PeopleTab
    typealias Snapshot = HallieTurnExecutor.ProfileSnapshot

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: y, month: m, day: d))!
    }

    /// Fresh scratch dir under the system temp root — never App Support.
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_poi_family_names_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func roundTrip(_ profile: POIProfile) throws -> POIProfile {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("profile.json")
        try JSONEncoder().encode(profile).write(to: url)
        return try JSONDecoder().decode(POIProfile.self, from: Data(contentsOf: url))
    }

    private func json(_ profile: POIProfile) throws -> [String: Any] {
        let data = try JSONEncoder().encode(profile)
        return try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static let familyNameKeys = ["surname", "maidenName", "middleName", "suffix"]

    // MARK: - The family, as Rick's People tab will look once he fills it in

    /// Brother Tim: short name plus a last name, nothing else. This is the
    /// shape Rick said he will use for most rows.
    private let tim = POIProfile(name: "Tim", referencePath: "/p/tim",
                                 aliases: ["Mimmy", "Brother"], surname: "Breen")

    /// Rick himself — a last name and a generational suffix, because the
    /// family has a live Richard Sr / Richard Jr confusion.
    private let rick = POIProfile(name: "Rick", referencePath: "/p/rick",
                                  aliases: ["Richard"], surname: "Breen",
                                  middleName: "Harding", suffix: "Jr")

    /// Rick's mother: the case that cost a wrong-person answer. The tree
    /// knows her as Eileen Latta, the family called her Ma, and her married
    /// name is Breen. "Ma" is a TITLE and must never be a matching key — it
    /// stays where it always was, in `name`, because it is her display name.
    private let ma = POIProfile(name: "Ma", referencePath: "/p/ma",
                                aliases: ["Eileen"], surname: "Breen", maidenName: "Latta",
                                titles: ["Grampa's wife", "Nana"])

    /// Donna — no family-name fields at all, the state of every live profile
    /// today. Every "unchanged" assertion below is anchored on her.
    private let donna = POIProfile(name: "Donna", referencePath: "/p/donna",
                                   aliases: ["Mom", "Goldilocks"])

    private var family: [POIProfile] { [tim, rick, ma, donna] }

    // MARK: - Codable: round trips

    @Test func aProfileWithNoFamilyNameFieldsRoundTripsUnchanged() throws {
        let decoded = try roundTrip(donna)
        #expect(decoded == donna)
        #expect(decoded.surname == nil)
        #expect(decoded.maidenName == nil)
        #expect(decoded.middleName == nil)
        #expect(decoded.suffix == nil)
        #expect(decoded.titles.isEmpty)
        // Old readers must see byte-compatible json: an unset optional field
        // emits no key at all (the rule POIProfileIdentityCodableTests
        // established for sex/hairColor/eyeColor).
        let obj = try json(donna)
        for key in Self.familyNameKeys {
            #expect(obj[key] == nil,
                    "unset field '\(key)' leaked into json — old readers would see an unexpected key")
        }
    }

    @Test func aProfileCarryingEveryFamilyNameFieldRoundTrips() throws {
        let full = POIProfile(
            name: "Dad", referencePath: "/p/dad",
            aliases: ["Dick", "Grampa Dicky"],
            surname: "Breen", maidenName: "n/a", middleName: "Harding",
            suffix: "Sr", titles: ["Grampa", "Pops"])
        let decoded = try roundTrip(full)
        #expect(decoded == full)
        #expect(decoded.surname == "Breen")
        #expect(decoded.maidenName == "n/a")
        #expect(decoded.middleName == "Harding")
        #expect(decoded.suffix == "Sr")
        #expect(decoded.titles == ["Grampa", "Pops"])
        // Raw strings are the persistence format.
        let obj = try json(full)
        #expect(obj["surname"] as? String == "Breen")
        #expect(obj["middleName"] as? String == "Harding")
        #expect(obj["suffix"] as? String == "Sr")
        #expect(obj["titles"] as? [String] == ["Grampa", "Pops"])
    }

    @Test func aSurnameOnlyProfileRoundTripsAndLeavesTheRestAbsent() throws {
        let decoded = try roundTrip(tim)
        #expect(decoded == tim)
        #expect(decoded.surname == "Breen")
        #expect(decoded.maidenName == nil)
        #expect(decoded.middleName == nil)
        #expect(decoded.suffix == nil)
        let obj = try json(tim)
        #expect(obj["surname"] as? String == "Breen")
        for key in ["maidenName", "middleName", "suffix"] {
            #expect(obj[key] == nil, "'\(key)' was left blank and must not be written")
        }
    }

    /// A profile.json written before the fields existed. No migration step,
    /// no invented values.
    @Test func legacyJSONWithoutTheNewKeysDecodesWithNothingInvented() throws {
        let legacy = """
        {"name": "Grampa", "referencePath": "/old/path"}
        """
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(legacy.utf8))
        #expect(p.name == "Grampa")
        #expect(p.surname == nil)
        #expect(p.maidenName == nil)
        #expect(p.middleName == nil)
        #expect(p.suffix == nil)
        #expect(p.titles.isEmpty)
        #expect(p.fullNameForms.isEmpty)
        #expect(p.displayFullName == "Grampa")
        // Re-encoding a legacy profile must not conjure the keys either.
        let obj = try json(p)
        for key in Self.familyNameKeys { #expect(obj[key] == nil) }
    }

    // MARK: - Blank is absent

    @Test func blanksAndWhitespaceAreStoredAsAbsentNotAsEmptyStrings() throws {
        // Exactly what PersonEditSheet produces when Rick tabs through the
        // fields without typing: "" everywhere, and a stray space or two.
        let blank = POIProfile(
            name: "Tim", referencePath: "/p",
            surname: "", maidenName: "   ", middleName: "\t",
            suffix: "  \n ", titles: ["", "  "])
        #expect(blank.surname == nil)
        #expect(blank.maidenName == nil)
        #expect(blank.middleName == nil)
        #expect(blank.suffix == nil)
        #expect(blank.titles.isEmpty)

        let decoded = try roundTrip(blank)
        #expect(decoded == blank)
        let obj = try json(blank)
        for key in Self.familyNameKeys {
            #expect(obj[key] == nil, "blank '\(key)' must not be written as an empty string")
        }
    }

    /// A blank that arrives from OUTSIDE the initializer — a hand-edited
    /// json, or a build that wrote "" before this rule existed — is absent
    /// on the way in too.
    @Test func blankValuesInStoredJSONDecodeAsAbsent() throws {
        let raw = """
        {"name": "Tim", "referencePath": "/p",
         "surname": "", "maidenName": "  ", "middleName": " ",
         "suffix": "  ", "titles": ["", " "]}
        """
        let p = try JSONDecoder().decode(POIProfile.self, from: Data(raw.utf8))
        #expect(p.surname == nil)
        #expect(p.maidenName == nil)
        #expect(p.middleName == nil)
        #expect(p.suffix == nil)
        #expect(p.titles.isEmpty)
        #expect(p.fullNameForms.isEmpty)
        #expect(p.displayFullName == "Tim")
    }

    @Test func aBlankFieldGeneratesNoForm() {
        // With a blank surname the "given + surname" shape would degrade to
        // the bare given name — and with a blank given name, to a bare
        // surname. Neither may be emitted.
        let blankSurname = POINameForms(name: "Tim", aliases: ["Mimmy"], surname: "  ")
        #expect(blankSurname.matchingForms.isEmpty)
        #expect(blankSurname.displayFullName == "Tim")

        let onlyMiddle = POINameForms(name: "Tim", middleName: "Harding")
        #expect(onlyMiddle.matchingForms.isEmpty,
                "a middle name alone is not a full name and must not make one")
        #expect(onlyMiddle.displayFullName == "Tim")

        let onlySuffix = POINameForms(name: "Rick", suffix: "Jr")
        #expect(onlySuffix.matchingForms.isEmpty)
        #expect(onlySuffix.displayFullName == "Rick Jr")
    }

    /// No double spaces, no leading/trailing space, no dangling punctuation —
    /// the whole "Tim  Breen" / "Richard Harding Breen " class.
    @Test func namesAreJoinedFromNonBlankPartsOnly() {
        let cases: [(POINameForms, String)] = [
            (POINameForms(name: "Tim", surname: "Breen"), "Tim Breen"),
            (POINameForms(name: "Tim", surname: "  Breen  "), "Tim Breen"),
            (POINameForms(name: "  Tim ", surname: "Breen", suffix: ""), "Tim Breen"),
            (POINameForms(name: "Rick", surname: "Breen", suffix: "Jr."), "Rick Breen Jr"),
            (POINameForms(name: "Donna"), "Donna"),
            (POINameForms(name: "Ma", middleName: "Marie", surname: "Breen"), "Ma Breen"),
        ]
        for (forms, expected) in cases {
            #expect(forms.displayFullName == expected, Comment(rawValue: forms.displayFullName))
            #expect(!forms.displayFullName.contains("  "),
                    Comment(rawValue: forms.displayFullName))
            #expect(forms.displayFullName
                    == forms.displayFullName.trimmingCharacters(in: .whitespaces),
                    Comment(rawValue: forms.displayFullName))
        }
        for form in POINameForms(name: "Rick", aliases: ["Richard"], middleName: "Harding",
                                 surname: "Breen", suffix: "Jr").matchingForms {
            #expect(!form.contains("  "), Comment(rawValue: form))
            #expect(form == form.trimmingCharacters(in: .whitespaces), Comment(rawValue: form))
        }
    }

    // MARK: - Which forms are generated (pinned exactly)

    /// The generated set is deliberately small. If a shape is added or
    /// removed this test names it, rather than a resolver test failing
    /// somewhere far away.
    @Test func formsAreBuiltOnlyFromGivenNamesTheProfileAlreadyAnswersTo() {
        #expect(tim.fullNameForms == ["Tim Breen", "Mimmy Breen", "Brother Breen"])
        #expect(rick.fullNameForms == [
            "Rick Breen", "Rick Harding Breen", "Rick Breen Jr", "Rick Harding Breen Jr",
            "Richard Breen", "Richard Harding Breen", "Richard Breen Jr",
            "Richard Harding Breen Jr",
        ])
        #expect(ma.fullNameForms == [
            "Ma Breen", "Ma Latta", "Eileen Breen", "Eileen Latta",
        ])
        #expect(donna.fullNameForms.isEmpty)
        // Not one of them is a bare surname, maiden name or suffix.
        let bare = Set(["breen", "latta", "harding", "jr"])
        for profile in family {
            for form in profile.fullNameForms {
                #expect(!bare.contains(PersonResolver.normalize(form)),
                        Comment(rawValue: "\(profile.name) generated a bare name part: \(form)"))
            }
        }
    }

    /// An alias that already carries the family name is a complete spelling
    /// on its own; combining it again would produce "Eileen Latta Breen".
    @Test func anAliasThatAlreadyCarriesTheFamilyNameIsNotCombinedAgain() {
        let forms = POINameForms(name: "Ma", aliases: ["Eileen", "Eileen Latta", "Ma Breen", "Jr"],
                                 surname: "Breen", maidenName: "Latta")
        #expect(forms.givenNames == ["Ma", "Eileen"])
        #expect(forms.matchingForms == ["Ma Breen", "Ma Latta", "Eileen Breen", "Eileen Latta"])
        for form in forms.matchingForms {
            #expect(POINameText.tokens(form).count <= 2, Comment(rawValue: form))
        }
    }

    /// Bounded by construction: aliases are hand-typed, but the index must
    /// not be growable without limit by a damaged or synthetic profile.
    @Test func theGeneratedSetIsBounded() {
        let many = (1...40).map { "Alias\($0)" }
        let forms = POINameForms(name: "Big", aliases: many, middleName: "M",
                                 surname: "S", maidenName: "D", suffix: "Jr")
        #expect(forms.givenNames.count == POINameForms.maxGivenNames)
        #expect(forms.matchingForms.count <= POINameForms.maxForms)
    }

    // MARK: - Resolution: the full names find their person

    private var resolver: PersonResolver { PersonResolver(profiles: family) }

    @Test func aFullNameResolvesToTheProfileItBelongsTo() {
        #expect(resolver.resolve("Tim Breen") == .resolved(canonicalName: "Tim"))
        #expect(resolver.resolve("  TIM breen ") == .resolved(canonicalName: "Tim"))
        #expect(resolver.resolve("Rick Breen") == .resolved(canonicalName: "Rick"))
        #expect(resolver.resolve("Richard Harding Breen Jr") == .resolved(canonicalName: "Rick"))
        // The short name still wins for itself — this is additive.
        #expect(resolver.resolve("Tim") == .resolved(canonicalName: "Tim"))
        #expect(resolver.resolve("Donna") == .resolved(canonicalName: "Donna"))
    }

    /// The case that cost a wrong-person answer: married and maiden forms
    /// both reach the same woman, and neither reaches anyone else.
    @Test func maidenAndMarriedFormsBothResolveToMa() {
        #expect(resolver.resolve("Eileen Latta") == .resolved(canonicalName: "Ma"))
        #expect(resolver.resolve("Eileen Breen") == .resolved(canonicalName: "Ma"))
        #expect(resolver.resolve("Ma Latta") == .resolved(canonicalName: "Ma"))
        #expect(resolver.resolve("Eileen") == .resolved(canonicalName: "Ma"))
        #expect(resolver.resolve("Ma") == .resolved(canonicalName: "Ma"))
    }

    // MARK: - NEGATIVE: a bare surname belongs to nobody

    /// THE IMPORTANT ONE. In a 39,250-person tree "Breen" names hundreds of
    /// people. A last name must never become a spelling of its own: no
    /// silent single match, ever. Same for a maiden name, a middle name and
    /// a generational suffix.
    @Test func aBareSurnameResolvesToNobodyInParticular() {
        for bare in ["Breen", "breen", "  BREEN  ", "Latta", "Harding", "Jr", "Sr"] {
            let verdict = resolver.resolve(bare)
            if case .resolved(let who) = verdict {
                Issue.record("bare name part “\(bare)” silently resolved to \(who)")
            }
            // Not merely "not this person" — nobody in particular.
            #expect(verdict == .unknown, Comment(rawValue: "\(bare) → \(verdict)"))
        }
    }

    @Test func aFullNameThatMatchesNobodyStillDeclines() {
        #expect(resolver.resolve("Bartholomew Breen") == .unknown)
        #expect(resolver.resolve("Tim O'Connor") == .unknown)
        #expect(resolver.resolve("Eileen Kowalski") == .unknown)
        #expect(resolver.resolve("Bartholomew") == .unknown)
    }

    // MARK: - NEGATIVE: titles are display only

    /// A title is RELATIONAL — Rick's sons' "Dad" is Rick; Tim's "Dad" is
    /// their father. Titles are stored so the People tab can show them and
    /// are never offered to matching. A distinctive form Rick DOES want
    /// resolved belongs in `aliases`, which already works.
    @Test func titlesAreDisplayOnlyAndNeverResolve() {
        let grampa = POIProfile(
            name: "Dad", referencePath: "/p",
            aliases: ["Grampa Dicky"],           // the alias route still works
            surname: "Breen", titles: ["Grampa", "Pops", "Grampa Dicky"])
        let people = PersonResolver(profiles: [grampa, donna])

        #expect(grampa.titles == ["Grampa", "Pops", "Grampa Dicky"])
        #expect(people.resolve("Grampa") == .unknown)
        #expect(people.resolve("Pops") == .unknown)
        // Nor does a title ever reach the derived spellings.
        #expect(!grampa.fullNameForms.contains { $0.localizedCaseInsensitiveContains("Pops") })
        #expect(!grampa.fullNameForms.contains { PersonResolver.normalize($0) == "grampa breen" })
        // The alias Rick typed himself still resolves — that is the
        // supported way to make a title-shaped spelling findable.
        #expect(people.resolve("Grampa Dicky") == .resolved(canonicalName: "Dad"))
    }

    // MARK: - SENSOR: a profile with nothing filled in behaves as it does today

    /// All thirteen live profiles are in this state, and will be until Rick
    /// edits them. Every verdict must be identical to the pre-feature
    /// resolver, which is reconstructed here from name + aliases alone.
    @Test func profilesWithNoFamilyNameFieldsResolveExactlyAsBefore() {
        let bare = [
            POIProfile(name: "Donna", referencePath: "/p", aliases: ["Mom", "Goldilocks"]),
            POIProfile(name: "Tim", referencePath: "/p", aliases: ["Timmy", "Mimmy"]),
            POIProfile(name: "Timmy", referencePath: "/p", aliases: ["Tim", "Tim Jr"]),
            POIProfile(name: "Dad", referencePath: "/p", aliases: ["Dick", "Dad Breen"]),
        ]
        let now = PersonResolver(profiles: bare)
        let before = PersonResolver(people: bare.map {
            ResolvablePerson(canonicalName: $0.name, aliases: $0.aliases)
        })
        for spelling in ["Donna", "Mom", "Tim", "Timmy", "Tim Jr", "Mimmy", "Dad",
                         "Dick", "Dad Breen", "Breen", "Goldilocks", "Nobody",
                         "Tim Breen", "", "   ", "Donna Breen"] {
            #expect(now.resolve(spelling) == before.resolve(spelling),
                    Comment(rawValue: spelling))
        }
        for profile in bare {
            #expect(profile.fullNameForms.isEmpty)
            #expect(profile.displayFullName == profile.name)
        }
    }

    // MARK: - Bios: full name on FIRST mention, short name afterwards

    private func biography(_ typed: String,
                           profiles: [Snapshot]) async throws -> HallieTurnExecutor.Result {
        try await HallieTurnExecutor.execute(
            .init(intent: HallieTurnExecutor.Intent(
                originalQuestion: "who is \(typed)?",
                ast: .graph(.init(people: [typed], operation: .biography)))),
            context: HallieTurnExecutor.Context(profiles: profiles))
    }

    private func snapshot(_ profile: POIProfile) -> Snapshot {
        Snapshot(stableID: profile.id, canonicalName: profile.name,
                 aliases: profile.aliases, birthdate: profile.birthdate,
                 note: profile.notes, kinships: profile.kinships,
                 sex: profile.sex, uuid: profile.uuid,
                 treeIdentity: profile.treeIdentity, deathdate: profile.deathdate,
                 surname: profile.surname, maidenName: profile.maidenName,
                 middleName: profile.middleName, suffix: profile.suffix)
    }

    @Test func aProfileWithASurnameIsNamedInFullOnFirstMentionOnly() async throws {
        let profiles = [snapshot(tim), snapshot(donna)]
        let result = try await biography("Tim", profiles: profiles)
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix("Tim Breen is one of the people in the People tab"),
                Comment(rawValue: result.prose))
        // …and the SHORT name everywhere after it. `name` is not renamed.
        #expect(result.prose.contains("I don't have an imported family tree to place Tim in."),
                Comment(rawValue: result.prose))
        #expect(result.prose.hasSuffix(
            "If you tell me more about Tim — \u{201C}let me tell you about Tim\u{201D} — I'll remember it."),
                Comment(rawValue: result.prose))
        #expect(result.prose.components(separatedBy: "Tim Breen").count == 2,
                "the full name belongs to the first mention only")
        // The profile title in the basis line stays the profile's own name.
        #expect(result.basisLine.contains("People profile \u{201C}Tim\u{201D}"),
                Comment(rawValue: result.basisLine))
        #expect(!result.prose.contains("  "), Comment(rawValue: result.prose))

        // And the full name is a way in: asking by it reaches the same person.
        let byFullName = try await biography("Tim Breen", profiles: profiles)
        #expect(byFullName.outcome == .answered)
        #expect(byFullName.prose.hasPrefix("Tim Breen is one of the people in the People tab"),
                Comment(rawValue: byFullName.prose))
    }

    /// SENSOR — the thirteen live profiles. Byte-identical prose to today.
    @Test func aProfileWithNoSurnameReadsExactlyAsItDoesToday() async throws {
        let result = try await biography("Donna", profiles: [snapshot(tim), snapshot(donna)])
        #expect(result.outcome == .answered)
        #expect(result.prose.hasPrefix(
            "Donna is one of the people in the People tab — also known as Mom, Goldilocks."),
                Comment(rawValue: result.prose))
        #expect(!result.prose.contains("Donna Breen"))
        #expect(!result.prose.contains("  "), Comment(rawValue: result.prose))
    }

    /// The short name is the display name EVERYWHERE else. Rick was explicit:
    /// "Tim is 66 today" must stay exactly that.
    @Test func theAgeAnswerStillUsesTheShortName() {
        let born = Self.date(1960, 3, 4)
        let subject = ArchivistTemporalSubjectSnapshot(
            stableID: "tim", canonicalName: tim.name, birthdate: born)
        let result = ArchivistTemporalExecutor.executePresentAge(
            .init(subject: "Tim", operation: .age, reference: .currentSelection),
            subject: .resolved(requested: "Tim", subject: subject),
            now: Self.date(2026, 9, 4))
        #expect(result.value == .exactAge(66))
        #expect(result.prose == "Tim is 66 today — born 4 March 1960.",
                Comment(rawValue: result.prose))
        #expect(!result.prose.contains("Breen"))
        // The bridge that builds this subject carries the SHORT name, which
        // is what keeps the sentence above short.
        #expect(snapshot(tim).canonicalName == "Tim")
        #expect(snapshot(tim).displayFullName == "Tim Breen")
    }

    // MARK: - End to end from a profile.json on disk

    /// The whole chain the app runs, from a real file: profile.json → the
    /// decoder `POIProfile.load` uses → the ProfileSnapshot mapping
    /// `HallieAppTurnCoordinator` performs → the turn executor.
    ///
    /// This is the temporary fixture that proves the feature. Rick's own
    /// profiles carry no surnames yet, and nothing here reads or writes
    /// ~/Library/Application Support — the fixture is written to a per-test
    /// temp dir and deleted.
    @Test func aSurnameWrittenToProfileJSONReachesTheAnswer() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Written the way Rick's file will look after he types a last name
        // into the People tab — and beside it, a profile left exactly as the
        // thirteen live ones are today.
        let files = [
            "tim": """
            {"name": "Tim", "referencePath": "\(dir.path)",
             "aliases": ["Mimmy", "Brother"], "notes": "Brother Tim",
             "surname": "Breen"}
            """,
            "donna": """
            {"name": "Donna", "referencePath": "\(dir.path)",
             "aliases": ["Mom", "Goldilocks"], "notes": ""}
            """,
        ]
        var loaded: [POIProfile] = []
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = dir.appendingPathComponent("\(name).json")
            try Data(text.utf8).write(to: url, options: .atomic)
            loaded.append(try JSONDecoder().decode(
                POIProfile.self, from: Data(contentsOf: url)))
        }
        #expect(loaded.map(\.name) == ["Donna", "Tim"])
        #expect(loaded[1].surname == "Breen")
        #expect(loaded[0].surname == nil)

        let snapshots = loaded.map(snapshot)
        let full = try await biography("Tim Breen", profiles: snapshots)
        #expect(full.outcome == .answered)
        #expect(full.prose.hasPrefix("Tim Breen is one of the people in the People tab"),
                Comment(rawValue: full.prose))
        #expect(full.prose.contains("\u{201C}Brother Tim\u{201D}"), Comment(rawValue: full.prose))

        // The short name still works, and still gets the full first mention.
        let short = try await biography("Tim", profiles: snapshots)
        #expect(short.prose == full.prose)

        // The profile Rick has not touched is untouched in every sense.
        let unchanged = try await biography("Donna", profiles: snapshots)
        #expect(unchanged.prose.hasPrefix(
            "Donna is one of the people in the People tab — also known as Mom, Goldilocks."),
                Comment(rawValue: unchanged.prose))

        // And a bare surname, loaded from a real file, still names nobody.
        #expect(PersonResolver(profiles: loaded).resolve("Breen") == .unknown)
    }

    // MARK: - The People tab and the resolver still give ONE verdict

    /// Mirror of HalliePeopleTabTests.peopleTabAndPersonResolverGiveOneVerdict
    /// with family-name fields in play: the route and the resolver must not
    /// disagree about who a full name belongs to.
    @Test func thePeopleTabAndTheResolverAgreeOnEveryFullName() {
        let profiles = family.map(snapshot)
        let resolver = PersonResolver(people: profiles.map {
            ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases,
                             fullNameForms: $0.fullNameForms)
        })
        for spelling in ["Tim", "Tim Breen", "Rick Breen", "Richard Harding Breen Jr",
                         "Eileen Latta", "Eileen Breen", "Donna", "Donna Breen",
                         "Breen", "Latta", "Jr", "Nobody At All"] {
            let label = Comment(rawValue: spelling)
            switch resolver.resolve(spelling) {
            case .resolved(let canonicalName):
                guard case .one(let profile) = Tab.claim(spelling, in: profiles) else {
                    Issue.record("People tab did not claim \(spelling)"); continue
                }
                #expect(profile.canonicalName == canonicalName, label)
            case .ambiguous:
                if case .ambiguous = Tab.claim(spelling, in: profiles) {} else {
                    Issue.record("People tab disagreed (expected ambiguous) for \(spelling)")
                }
            case .unknown:
                #expect(Tab.claim(spelling, in: profiles) == .none, label)
            }
        }
    }
}
