// FamilyPersonFolderNameTests.swift
// The naming rule for People/ folders (Rick, 2026-09-17).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Person folder names")
struct FamilyPersonFolderNameTests {
    typealias N = FamilyPersonFolderName

    @Test func aTreePersonIsNamedThenKeyedOnTheirFamilySearchID() {
        #expect(N.component(name: .init(first: "Donna", last: "Hudson"),
                            identity: .familySearch("G2CL-86B")) == "Donna_Hudson_G2CL-86B")
    }

    /// Rick's People-tab scheme: nickname first, because that is what he
    /// scans for in Finder.
    @Test func alivingRelativeIsNicknameFirstThenAStableLocalKey() {
        let folder = N.component(
            name: .init(nickname: "Beth", first: "Elizabeth", last: "Breen"),
            identity: .local("L7K2QX"))
        #expect(folder == "Beth_Elizabeth_Breen_L7K2QX")
    }

    /// A suffix is often the only thing separating a father from a son.
    @Test func aSuffixSurvivesBecauseItIsSometimesTheOnlyDifference() {
        #expect(N.component(name: .init(first: "Richard", last: "Breen", suffix: "Jr"),
                            identity: .familySearch("GVQV-NW3")) == "Richard_Breen_Jr_GVQV-NW3")
    }

    /// Nobody gets Tim_Tim_Breen.
    @Test func aNicknameThatIsAlreadyTheFirstNameIsNotRepeated() {
        #expect(N.component(name: .init(nickname: "Tim", first: "Tim", last: "Breen"),
                            identity: .local("AAA111")) == "Tim_Breen_AAA111")
    }

    /// THE INVARIANT. Whatever the name — empty, punctuation only, absurd —
    /// the key is on the end, because that is what keeps one person to one
    /// folder.
    @Test func theKeyIsAlwaysOnTheEndWhateverTheName() {
        for name in [N.Name(), N.Name(first: "   "), N.Name(first: "///"),
                     N.Name(nickname: "O'Connor", last: "D’Arcy")] {
            let folder = N.component(name: name, identity: .familySearch("G89Q-34N"))
            #expect(folder.hasSuffix("G89Q-34N"), "lost the key: \(folder)")
            #expect(!folder.hasSuffix("_G89Q-34N") || folder.split(separator: "_").count > 1)
        }
    }

    @Test func theIdentityCanBeReadBackOutOfTheFolderName() {
        #expect(N.identity(inComponent: "Donna_Hudson_G2CL-86B") == .familySearch("G2CL-86B"))
        #expect(N.identity(inComponent: "G2CL-86B") == .familySearch("G2CL-86B"))
        #expect(N.identity(inComponent: "Beth_Elizabeth_Breen_L7K2QX",
                           isLocalKey: { $0 == "L7K2QX" }) == .local("L7K2QX"))
        // A folder from before this rule, and a group folder, carry none —
        // which is how they are recognised and left alone.
        #expect(N.identity(inComponent: "Donna_Elaine_Hudson") == nil)
        #expect(N.identity(inComponent: "RickDonnaBreenFamily") == nil)
    }

    /// Rick reads and retypes these out of Finder, so no lookalikes.
    @Test func aLocalKeyHasNoCharactersThatCanBeMisread() {
        for _ in 0..<200 {
            let key = N.newLocalKey()
            #expect(key.count == 6)
            #expect(!key.contains("O") && !key.contains("0"))
            #expect(!key.contains("I") && !key.contains("1"))
        }
    }

    @Test func awholeNameSplitsIntoThePiecesTheRuleWants() {
        let a = N.Name(wholeName: "Mary Christina /O'Connor/")
        #expect(a.first == "Mary Christina")
        #expect(a.last == "O'Connor")
        let b = N.Name(wholeName: "Richard Harding Breen Jr.")
        #expect(b.last == "Breen")
        #expect(b.suffix == "Jr")
    }
}
