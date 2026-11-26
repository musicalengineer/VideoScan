// PersonLogNameSensorTests.swift
// GH #466 / DECISIONS 2026-11-25: every log line that names a person goes
// through PersonLogName (deceased in full; living by nickname or first name,
// never a surname). This sensor reads the app source:
//   1. every converted site still calls the helper (a revert goes red);
//   2. no `appLog.write(` statement interpolates a raw person-name member
//      (`\(x.name)`, `.displayName`, `.canonicalName`, `.speakerName`,
//      `.displayFullName`, `.personName`) except the named non-person
//      exceptions below, each with its reason.
// And the taught-word rule (`taughtForLog`): a pronunciation word appears in
// the log only when the person's log rendering already shows it.
// Every name here is invented.

import Foundation
import Testing
@testable import VideoScan

@Suite("PersonLogName sensor — log sites name people through the one helper (#466)")
struct PersonLogNameSensorTests {

    /// File → a call that must survive in its code (comments stripped).
    static let sites: [(file: String, mustContain: String)] = [
        ("FamilyTree/FamilyAssetStore+Documents.swift", "person.logName"),
        ("FamilyTree/FamilyAssetStore.swift", "PersonLogName.of(person)"),
        ("FamilyTree/FamilyTreeLiveModel.swift", "PersonLogName.of("),
        ("FamilyTree/FamilyTreeView.swift", "assetPerson.logName"),
        ("FamilyTree/TreeIdentityCenter.swift", "PersonLogName.of(profile:"),
        ("FamilyTree/TreeIdentityShowInTree.swift", "PersonLogName.of(profile:"),
        ("Hallie/HallieAppTurnCoordinator.swift", "PersonLogName.named("),
        ("Hallie/HallieAppTurnCoordinator+Drill.swift", "PersonLogName.mayShow("),
        ("Hallie/HallieAppTurnCoordinator+Pronunciation.swift", "taughtForLog("),
        ("Hallie/HallieLineageAnswer+GedcomAwareness.swift", "PersonLogName.of(person)"),
        ("Hallie/Shell/HallieShellCLI+Picker.swift", "target: target"),
        ("Hallie/Shell/HallieShellCLI+Pronunciation.swift", "target: target"),
        ("Hallie/Shell/HallieShellCLI+Drill.swift", "target: target"),
        ("People/PersonFinderModel.swift", "PersonLogName.of(profile:"),
        ("People/PersonFinderModel+JobLifecycle.swift", "PersonLogName.of(profile:"),
        ("People/FindPersonJob.swift", "PersonLogName.named(person)"),
        ("People/VideoScanModel+FamilyTagging.swift", "PersonLogName.named("),
        ("People/PersonVideosSection.swift", "PersonLogName.of(profile:"),
        ("People/PersonPageHides.swift", "PersonLogName.of(profile:"),
        ("People/FeaturedVideos.swift", "PersonLogName.of(profile:"),
        ("People/PersonCatalogLink.swift", "PersonLogName.of(profile:"),
        ("People/POIProfileAudit.swift", "PersonLogName.of(profile:"),
        ("App/ContentView.swift", "PersonLogName.named("),
    ]

    /// `\(a.b.name)`-shaped interpolations that are NOT a person.
    static let notAPerson: [(file: String, expression: String, why: String)] = [
        ("Archive/ArchiveIndexRename.swift", "failed.name", "an archive index file"),
        ("People/PersonVideosSection.swift", "family?.name", "a People-tab family group, not a person"),
        ("People/PersonFinderView.swift", "family.name", "a People-tab family group, not a person"),
        ("People/PersonFinderView+People.swift", "family.name", "a People-tab family group, not a person"),
        ("People/FeaturedVideos.swift", "family.name", "a People-tab family group, not a person"),
        ("People/FamilyEditSheet.swift", "updated.name", "a People-tab family group (FamilyGroupStore), not a person"),
    ]

    private static func code(_ name: String) throws -> String {
        let url = try #require(SourceTree.appSourceURL(named: name))
        let scanned = SourceTree.scan(try String(contentsOf: url, encoding: .utf8))
        #expect(scanned.unsupported.isEmpty, "\(name): \(scanned.unsupported)")
        return scanned.code
    }

    @Test func everyConvertedSiteCallsTheHelper() throws {
        for site in Self.sites {
            let text = try Self.code(site.file)
            #expect(text.contains(site.mustContain), "\(site.file) no longer calls \(site.mustContain) (GH #466)")
        }
    }

    @Test func noLogLineInterpolatesARawPersonName() throws {
        let member = try Regex(
            #"\\\(\s*((?:[A-Za-z_]\w*[?!]?\.)+(?:name|displayName|canonicalName|speakerName|displayFullName|personName|fullName))\s*(?:\?\?[^)]*)?\)"#)
        var offenders: [String] = []
        var scanned = 0
        for source in SourceTree.appSources {
            let scan = SourceTree.scan(try String(contentsOf: source.url, encoding: .utf8))
            let lines = scan.code.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() where line.contains("appLog.write(") {
                scanned += 1
                // The call and its two continuation lines (multi-line `+` strings).
                let window = lines[index..<min(lines.count, index + 3)].joined(separator: "\n")
                for match in window.matches(of: member) {
                    let expression = String(window[match.output[1].range!])
                    let excused = Self.notAPerson.contains {
                        source.relative.hasSuffix($0.file) && expression == $0.expression
                    }
                    if !excused { offenders.append("\(source.relative):\(index + 1) \(expression)") }
                }
            }
        }
        #expect(scanned > 500, "the scan read the app's log calls (\(scanned))")
        #expect(offenders.isEmpty, "log a person through PersonLogName (DECISIONS 2026-11-25): \(offenders)")
    }

    // MARK: Taught words (pure)

    @Test func aLivingPersonsSurnameIsNeverLoggedAsATaughtWord() {
        let target = HallieAppTurnCoordinator.PronunciationTarget.treePerson(
            name: "Tamsin Quistgaard", gedcomID: "@I2@", aliases: [])
        let line = HallieAppTurnCoordinator.taughtForLog(word: "Quistgaard", saidAs: "KWIST-gard", target: target)
        #expect(line == "a name of Tamsin (word withheld: it is not a name the log may show)")
        #expect(!line.contains("Quistgaard") && !line.contains("KWIST"))
    }

    @Test func aFirstNameTheLogMayShowIsLoggedWithItsRespelling() {
        let target = HallieAppTurnCoordinator.PronunciationTarget.cyberBrainPerson(id: "p-1", name: "Tamsin Quistgaard")
        #expect(HallieAppTurnCoordinator.taughtForLog(word: "Tamsin", saidAs: "TAM-zin", target: target)
                == "Tamsin ← TAM-zin (Tamsin)")
    }

    @Test func aWordKeptForNoOnePersonIsWithheld() {
        let line = HallieAppTurnCoordinator.taughtForLog(word: "Quistgaard", saidAs: "KWIST-gard", target: .file)
        #expect(!line.contains("Quistgaard") && !line.contains("KWIST"))
    }
}
