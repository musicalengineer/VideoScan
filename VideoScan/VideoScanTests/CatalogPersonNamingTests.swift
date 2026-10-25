import Foundation
import Testing
@testable import VideoScan

// GH #375: synthetic profiles only; no gallery, catalog or media on disk.
@MainActor
@Suite("Catalog person names — nicknames and namesakes")
struct CatalogPersonNamingTests {
    private func person(_ name: String, alias: String? = nil, year: Int? = nil) -> POIProfile {
        var p = POIProfile(name: name, referencePath: "")
        p.aliases = alias.map { [$0] } ?? []
        if let year {
            p.birthdate = Calendar(identifier: .gregorian).date(from: DateComponents(year: year, month: 6, day: 15))
        }
        return p
    }

    @Test func nicknameWinsAndSelectionKeepsItsIdentity() {
        let elder = person("Timothy", alias: "Tim")
        let son = person("Timothy", alias: "Timmy")
        let store = CatalogPersonFilterStore()
        store.reload([elder, son])
        #expect(store.people.map(\.name) == ["Tim", "Timmy"])
        store.select(id: son.uuid)
        #expect(store.selected?.id == son.uuid)
        #expect(store.selected?.name == "Timmy")
    }

    /// #375 review (2026-10-25): unchecking handed the engine a lowercased
    /// lookup key, and the engine stored THAT in `rejectedPeople` ("richard"
    /// beside a confirmed "Richard"), which the Inspector's exact-case
    /// compare could never un-reject. RED on e6d617288; GREEN once the
    /// engine rejects under the record's own spelling.
    @Test func uncheckKeepsTheRecordsSpelling() {
        let option = PersonPickerNames.options([person("Richard", alias: "Rick")])[0]
        let model = VideoScanModel()
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/test_T/r.mov"
        rec.filename = "r.mov"
        rec.detectedPeople = ["Richard"]
        model.records = [rec]
        model.searchIndex.rebuild(records: model.records)
        for key in option.uniqueKeys { model.setPerson(key, on: [rec], present: false) }
        #expect(rec.rejectedPeople == ["Richard"])
        #expect(option.spellings(in: [rec]).isEmpty, "nothing left to uncheck")
    }

    @Test func uncheckHandsTheEngineTheRowsOwnSpellings() {
        let option = PersonPickerNames.options([person("Richard", alias: "Rick")])[0]
        let rec = VideoRecord()
        rec.detectedPeople = ["Richard"]
        #expect(option.spellings(in: [rec]) == ["Richard"])
        #expect(option.isTagged(in: rec))
    }

    @Test func duplicateNamesShowBirthYears() {
        let store = CatalogPersonFilterStore()
        store.reload([person("Richard", year: 1930), person("Richard", year: 1960)])
        #expect(store.people.map(\.name) == ["Richard (b. 1930)", "Richard (b. 1960)"])
    }

    @Test func duplicateNicknamesAndMissingDatesRemainDistinctAndStable() {
        let first = person("Richard", alias: "Rick", year: 1960)
        let second = person("Richard", alias: "Rick", year: 1960)
        let third = person("Rick")
        let store = CatalogPersonFilterStore()
        store.reload([first, second, third])
        let original = Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) })
        #expect(Set(original.values).count == 3)
        store.reload([third, second, first])
        #expect(Dictionary(uniqueKeysWithValues: store.people.map { ($0.id, $0.name) }) == original)
    }

    @Test func nicknameIsTheWrittenTagAndDoesNotTagTheNamesake() throws {
        let elder = person("Timothy", alias: "Tim")
        let son = person("Timothy", alias: "Timmy")
        let options = PersonPickerNames.options([elder, son])
        let choice = try #require(options.first { $0.id == son.uuid })
        let name = try #require(choice.tagName)
        #expect(name == "Timmy")
        let model = VideoScanModel()
        let record = VideoRecord()
        record.fullPath = "/Volumes/test_T/nicknames.mov"
        record.filename = "nicknames.mov"
        model.records = [record]
        model.searchIndex.rebuild(records: model.records)
        model.setPerson(name, on: [record], present: true)
        #expect(record.confirmedByUserPeople.map(\.name) == ["Timmy"])
        #expect(choice.isTagged(in: record))
        #expect(!options[0].isTagged(in: record))
        #expect(CatalogPersonFilter.apply([record], person: CatalogPerson(son)).count == 1)
        #expect(CatalogPersonFilter.apply([record], person: CatalogPerson(elder)).isEmpty)
        #expect(model.searchIndex.filter(records: [record], query: "people:timmy").count == 1)
        for key in choice.uniqueKeys { model.setPerson(key, on: [record], present: false) }
        #expect(record.confirmedByUserPeople.isEmpty)
    }

    @Test func sharedFormalTagDoesNotCheckBothNicknames() {
        let options = PersonPickerNames.options([
            person("Timothy", alias: "Tim"), person("Timothy", alias: "Timmy")])
        let record = VideoRecord()
        record.detectedPeople = ["Timothy"]
        #expect(options.allSatisfy { !$0.isTagged(in: record) })
        #expect(options.allSatisfy { !$0.uniqueKeys.contains("timothy") })
    }

    @Test func uniqueLegacyFormalTagCanStillBeUnchecked() {
        let option = PersonPickerNames.options([person("Richard", alias: "Rick")])[0]
        let record = VideoRecord()
        record.detectedPeople = ["RICHARD"]
        #expect(option.isTagged(in: record))
        #expect(option.tagName == "Rick")
        #expect(option.uniqueKeys == ["richard", "rick"])
    }

    @Test func blankAliasesFallBackAndWhitespaceIsTrimmed() {
        var p = person(" Timothy ")
        p.aliases = [" \n", " Timmy \n", "Tim"]
        #expect(PersonPickerNames.options([p])[0].tagName == "Timmy")
        p.aliases = [" \n"]
        #expect(PersonPickerNames.options([p])[0].tagName == "Timothy")
    }

    @Test func duplicateNicknamesCannotWriteAnAmbiguousTag() {
        let profiles = [person("Richard", alias: "Rick", year: 1930),
                        person("Richard", alias: "rICK", year: 1960)]
        let options = PersonPickerNames.options(profiles)
        #expect(options.map(\.label) == ["Rick (b. 1930)", "rICK (b. 1960)"])
        #expect(options.allSatisfy { $0.tagName == nil })
        #expect(options.allSatisfy { $0.help.contains("distinct nickname") })
    }

    @Test func emptyNameAndFamilyWildcardAreNotPersonTags() {
        let options = PersonPickerNames.options([person("  "), person("Someone", alias: "Family")])
        #expect(options[0].label == "Unnamed person")
        #expect(options.allSatisfy { $0.tagName == nil })
    }

    @Test func labelDecorationsNeverBecomeTagsOrChangeProfiles() {
        let profiles = [person("Richard", alias: "Rick", year: 1930),
                        person("Richard", alias: "Rick", year: 1960)]
        let snapshot = profiles
        let options = PersonPickerNames.options(profiles)
        #expect(profiles == snapshot)
        #expect(options.allSatisfy { option in
            !option.uniqueKeys.contains(option.label.lowercased())
        })
    }
}

@Suite("Catalog person naming — menu wiring")
struct CatalogPersonNamingSensorTests {
    @Test func tagMenusDoNotDiscardProfileIdentityOrNicknames() throws {
        for file in ["CatalogRowContextMenu+Organize.swift", "InspectorFamilyTagsView.swift"] {
            let source = try SourceTree.strippingComments(SourceTree.appSource(named: file))
            #expect(!source.contains("POIProfile.listAll().map(\\.name)"), "\(file) discards nicknames and UUIDs")
            #expect(source.contains("PersonPickerNames.options("), "\(file) must use the shared naming rule")
        }
    }

    @Test func galleryAndCatalogShareDisambiguation() throws {
        for file in ["CatalogPersonFilter.swift", "PersonFinderView+People.swift", "FeaturedVideos.swift"] {
            let source = try SourceTree.strippingComments(SourceTree.appSource(named: file))
            #expect(source.contains("PersonPickerNames.labels("), "\(file) must distinguish namesakes")
        }
    }

    @Test func narrowCardsExposeTheFullDisambiguatedName() throws {
        let source = try SourceTree.strippingComments(SourceTree.appSource(named: "PersonFinderSubviews.swift"))
        #expect(source.contains(".help(saveProblem ?? displayLabel ?? profile.displayName)"))
    }
}
