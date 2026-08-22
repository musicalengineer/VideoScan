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

    @Test func conservativeMisspellingsRecoverButTiesAndShortNamesDoNotGuess() {
        let names = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Rick Breen", aliases: []),
            ResolvablePerson(canonicalName: "Mary", aliases: []),
            ResolvablePerson(canonicalName: "Mark", aliases: []),
            ResolvablePerson(canonicalName: "Tim", aliases: []),
        ])

        #expect(names.resolve("Rick Brren")
                == .resolved(canonicalName: "Rick Breen"))
        #expect(names.resolve("Mara")
                == .ambiguous(candidates: ["Mark", "Mary"]))
        #expect(names.resolve("Tin") == .unknown)
    }

    @Test func requestOpenerRecoveryIsNarrowAndDeterministic() {
        #expect(HallieSpellingRecovery.repairRequestOpener(
            "shxw me videos of Donna").text == "show me videos of Donna")
        #expect(HallieSpellingRecovery.repairRequestOpener(
            "shwo me videos of Donna").text == "show me videos of Donna")
        #expect(HallieSpellingRecovery.repairRequestOpener(
            "yell me about yourself").text == "tell me about yourself")
        #expect(HallieSpellingRecovery.repairRequestOpener(
            "hello Hallie").text == "hello Hallie")
        #expect(HallieSpellingRecovery.repairRequestOpener(
            "hell Hallie").text == "hell Hallie")
    }

    @Test func diacriticsFold() {
        let r = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Renée", aliases: [])])
        #expect(r.resolve("renee") == .resolved(canonicalName: "Renée"))
    }

    /// Production-path sensor: ArchivistChatWindow constructs its resolver
    /// from POIProfile values through this initializer. If that bridge ever
    /// drops aliases again, this test fails even though the pure resolver's
    /// hand-built fixtures would continue to pass.
    @Test func profileBridgePreservesAliases() {
        let profile = POIProfile(
            name: "Hallie Mae McGill",
            referencePath: "/synthetic/reference",
            aliases: ["Grandma Hallie", "Hallie Mae"])
        let resolver = PersonResolver(profiles: [profile])

        #expect(resolver.resolve("grandma hallie")
                == .resolved(canonicalName: "Hallie Mae McGill"))
        #expect(resolver.resolve("hallie mae")
                == .resolved(canonicalName: "Hallie Mae McGill"))
    }

    @Test func aliasesCanonicalizeBeforeCatalogComposition() {
        let resolver = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Donna Breen", aliases: ["Mom"]),
            ResolvablePerson(canonicalName: "Timmy Breen", aliases: ["Timster"]),
        ])

        guard case .resolved(let canonical) =
                resolver.resolveAll(["mom", "timster"]) else {
            Issue.record("aliases should resolve atomically"); return
        }
        let composed = NLQueryComposer.infixString(
            for: NLQueryNormalizer.normalize(NLQuerySpec(people: canonical)))

        #expect(composed == "people:donna people:breen people:timmy people:breen")
    }

    @Test func resolveAllStopsForHumanClarification() {
        #expect(resolver.resolveAll(["birthday boy", "Donna"])
                == .ambiguous(typedName: "birthday boy",
                              candidates: ["Dan", "Matt"]))
        #expect(resolver.resolveAll(["Bartholomew", "Donna"])
                == .unknown(typedName: "Bartholomew"))
    }

    @Test func splitMultiwordIdentityIsRepairedBeforeDeclining() {
        let resolver = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Donna", aliases: []),
            ResolvablePerson(canonicalName: "Dad Breen", aliases: []),
            ResolvablePerson(canonicalName: "Timmy", aliases: []),
        ])

        #expect(resolver.resolveAll(["dad", "breen"])
                == .resolved(canonicalNames: ["Dad Breen"]))
        #expect(resolver.resolveAll(["Donna", "Dad", "Breen", "Timmy"])
                == .resolved(canonicalNames: ["Donna", "Dad Breen", "Timmy"]))
    }

    @Test func competingPersonSegmentationsAreSurfacedNotGuessed() {
        let resolver = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Mary", aliases: []),
            ResolvablePerson(canonicalName: "Ann", aliases: []),
            ResolvablePerson(canonicalName: "Mary Ann", aliases: []),
        ])

        #expect(resolver.resolveAll(["Mary", "Ann"])
                == .segmentationAmbiguous(
                    options: [["Mary", "Ann"], ["Mary Ann"]]))
    }

    @Test("100k untrusted person items fail closed in constant time",
          .timeLimit(.minutes(1)))
    func oversizedTranslatorOutputIsBounded() {
        let resolver = PersonResolver(people: [
            ResolvablePerson(canonicalName: "Donna", aliases: []),
        ])
        let untrusted = Array(repeating: "Donna", count: 100_000)

        let started = ContinuousClock.now
        let result = resolver.resolveAll(untrusted)
        let elapsed = started.duration(to: .now)

        #expect(result == .tooMany(limit: 6))
        #expect(elapsed < .milliseconds(100),
                "person-list rejection exceeded 100 ms: \(elapsed)")
    }

    @Test func poiAliasResolvesFormalGedcomIdentity() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Richard /Breen/
        0 @I2@ INDI
        1 NAME Hallie Mae /McGill/
        0 @I3@ INDI
        1 NAME Richard /Jones/
        0 TRLR
        """)
        let resolver = FamilyTreeIdentityResolver(
            graph: graph,
            profiles: [
                POIProfile(name: "Richard Breen", referencePath: "/synthetic",
                           aliases: ["Rick"]),
            ])

        guard case .people(let people) = resolver.resolve("Rick") else {
            Issue.record("Rick should resolve through the POI alias"); return
        }
        #expect(people.map(\.name) == ["Richard Breen"])

        // Ancestors without POI profiles still resolve directly from GEDCOM.
        guard case .people(let ancestors) = resolver.resolve("Hallie Mae") else {
            Issue.record("GEDCOM-only ancestor should still resolve"); return
        }
        #expect(ancestors.map(\.name) == ["Hallie Mae McGill"])
    }

    @Test func sharedPoiAliasRemainsAmbiguousForFamilyFacts() {
        let graph = GedcomFamilyGraph(gedcomText: """
        0 @I1@ INDI
        1 NAME Daniel /Breen/
        0 @I2@ INDI
        1 NAME Matthew /Breen/
        0 TRLR
        """)
        let resolver = FamilyTreeIdentityResolver(
            graph: graph,
            profiles: [
                POIProfile(name: "Daniel Breen", referencePath: "/synthetic",
                           aliases: ["birthday boy"]),
                POIProfile(name: "Matthew Breen", referencePath: "/synthetic",
                           aliases: ["birthday boy"]),
            ])

        #expect(resolver.resolve("birthday boy")
                == .profileAmbiguous(
                    candidates: ["Daniel Breen", "Matthew Breen"]))
    }
}
