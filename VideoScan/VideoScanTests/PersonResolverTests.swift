import Testing
@testable import VideoScan

// Family Archivist Phase 1 — PersonResolver contract (design doc §2):
// exact normalized matching, ambiguity surfaced never guessed, unknown
// names honestly unknown. Tim and Timmy are DISTINCT POIs in this
// family (memory: separate people) — the tests encode that reality.
struct PersonResolverTests {

    private var resolver: PersonResolver {
        PersonResolver(people: [
            ResolvablePerson(canonicalName: "Donna",
                             aliases: ["Mom", "Goldilocks"]),
            ResolvablePerson(canonicalName: "Tim", aliases: []),
            ResolvablePerson(canonicalName: "Timmy", aliases: []),
            ResolvablePerson(canonicalName: "Ellen",
                             aliases: ["Aunt Ellen"]),
            // Shared alias on purpose: both boys get called "the birthday boy"
            ResolvablePerson(canonicalName: "Dan", aliases: ["birthday boy"]),
            ResolvablePerson(canonicalName: "Matt", aliases: ["birthday boy"]),
        ])
    }

    @Test func canonicalAndAliasResolve() {
        #expect(resolver.resolve("Donna") == .resolved(canonicalName: "Donna"))
        #expect(resolver.resolve("mom") == .resolved(canonicalName: "Donna"))
        #expect(resolver.resolve("  GOLDILOCKS ") == .resolved(canonicalName: "Donna"))
        #expect(resolver.resolve("aunt ellen") == .resolved(canonicalName: "Ellen"))
    }

    @Test func timAndTimmyStayDistinct() {
        #expect(resolver.resolve("Tim") == .resolved(canonicalName: "Tim"))
        #expect(resolver.resolve("Timmy") == .resolved(canonicalName: "Timmy"))
    }

    @Test func sharedAliasIsAmbiguousNotGuessed() {
        #expect(resolver.resolve("birthday boy")
                == .ambiguous(candidates: ["Dan", "Matt"]))
    }

    @Test func unknownIsUnknownNotInvented() {
        #expect(resolver.resolve("Bartholomew") == .unknown)
        #expect(resolver.resolve("") == .unknown)
        #expect(resolver.resolve("   ") == .unknown)
    }

    @Test func diacriticsFold() {
        let r = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Renée", aliases: [])])
        #expect(r.resolve("renee") == .resolved(canonicalName: "Renée"))
    }
}
