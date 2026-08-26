// FamilyAssetIdentityDirectoryTests.swift
// Live miss 2026-08-26: "tell me about richard harding breen sr" showed
// People/RickDonnaBreenFamily/… (Rick, Donna, the boys) because "rick →
// richard" + "breen" fits Rick's father too. Group-photo attribution must
// resolve each folder token to ONE tree person by the strongest evidence.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Group-photo identity directory")
struct FamilyAssetIdentityDirectoryTests {

    /// Jr (owner, root, FS ID) and Sr share "Richard … Breen"; Donna Hudson
    /// married Jr; Muriel Lamb married George Breen (Sr's parents).
    static let tree = """
    0 HEAD
    0 @I1@ INDI
    1 NAME Richard Harding /Breen/ Jr
    1 SEX M
    1 _FSFTID GVQV-NW3
    1 FAMC @F2@
    1 FAMS @F1@
    0 @I2@ INDI
    1 NAME Richard Harding /Breen/ Sr
    1 SEX M
    1 FAMC @F3@
    1 FAMS @F2@
    0 @I3@ INDI
    1 NAME Donna Elaine /Hudson/
    1 SEX F
    1 FAMS @F1@
    0 @I4@ INDI
    1 NAME Eileen /Latta/
    1 SEX F
    1 FAMS @F2@
    0 @I5@ INDI
    1 NAME Muriel /Lamb/
    1 SEX F
    1 FAMS @F3@
    0 @I6@ INDI
    1 NAME George /Breen/
    1 SEX M
    1 FAMS @F3@
    0 @I7@ INDI
    1 NAME Timothy /Breen/
    1 SEX M
    1 FAMC @F1@
    0 @I8@ INDI
    1 NAME Matthew /Breen/
    1 SEX M
    1 FAMC @F1@
    0 @F1@ FAM
    1 HUSB @I1@
    1 WIFE @I3@
    1 CHIL @I7@
    1 CHIL @I8@
    0 @F2@ FAM
    1 HUSB @I2@
    1 WIFE @I4@
    1 CHIL @I1@
    0 @F3@ FAM
    1 HUSB @I6@
    1 WIFE @I5@
    1 CHIL @I2@
    0 TRLR
    """

    static let graph = GedcomFamilyGraph(gedcomText: tree)

    /// Owner pinned by FamilySearch ID; CyberBrain-style aliases: Rick =
    /// Jr ("Rick", "Dicky"), Dad = Dick = Sr.
    static func directory(aliases: FamilyAssetIdentityDirectory.AliasTable = [
        "@I1@": ["Rick Breen", "Dicky"],
        "@I2@": ["Dad Breen", "Dick"],
    ], ownerName: String? = "Rick Breen") -> FamilyAssetIdentityDirectory {
        FamilyAssetIdentityDirectory(
            graph: graph, aliases: aliases, ownerGedcomID: "@I1@", ownerName: ownerName)
    }

    static func tokens(_ folder: String) -> [String] {
        FamilyAssetStore.groupFolderTokens(folder) ?? []
    }

    @Test func rickDonnaBreenFamilyIsJrAndDonnaOnly() {
        let d = Self.directory()
        let who = d.attributedMembers(folderTokens: Self.tokens("RickDonnaBreenFamily"))
        #expect(who == ["@I1@", "@I3@"], "Rick = the owner; Donna = Jr's wife by married surname; never Sr")
        #expect(!d.folderNames("@I2@", folderTokens: Self.tokens("RickDonnaBreenFamily")))
    }

    @Test func theOwnersNicknameWinsEvenWithoutAliases() {
        let d = Self.directory(aliases: [:])
        #expect(d.attributedMembers(folderTokens: Self.tokens("RickDonnaBreenFamily")) == ["@I1@", "@I3@"])
    }

    @Test func dickAndMurielBreenIsSrOnlyThroughTheAlias() {
        let d = Self.directory()
        let who = d.attributedMembers(folderTokens: Self.tokens("DickAndMurielBreen"))
        #expect(who == ["@I2@", "@I5@"], "Dick = Sr by alias; Muriel Lamb married a Breen")
        #expect(!who.contains("@I1@"))
    }

    @Test func aSharedDiminutiveWithNoAliasAttachesToNobody() {
        let d = Self.directory(aliases: [:])
        // "dick" → richard fits Jr and Sr; the owner is "Rick", not "Dick".
        #expect(d.attributedMembers(folderTokens: Self.tokens("DickAndMurielBreen")) == ["@I5@"])
    }

    @Test func richardBreenFamilyIsAmbiguousSoNeitherRichardGetsIt() {
        let d = Self.directory()
        #expect(d.attributedMembers(folderTokens: Self.tokens("RichardBreenFamily")).isEmpty)
    }

    @Test func aSuffixTokenInTheFolderSettlesTheAmbiguity() {
        let d = Self.directory()
        #expect(d.attributedMembers(folderTokens: Self.tokens("RichardBreenSrFamily")) == ["@I2@"])
        #expect(d.attributedMembers(folderTokens: Self.tokens("Richard_Breen_Jr_Family")) == ["@I1@"])
    }

    @Test func aliasesNeverOverrideWhatTheTreeAlreadySays() {
        // Sr's alias spells his full formal name; "richard" stays a tree
        // token shared with Jr, so it must remain ambiguous.
        let d = Self.directory(aliases: ["@I2@": ["Richard Harding Breen Sr", "Dick"]])
        #expect(d.attributedMembers(folderTokens: Self.tokens("RichardBreenFamily")).isEmpty)
        #expect(d.attributedMembers(folderTokens: Self.tokens("DickBreenFamily")) == ["@I2@"])
    }

    @Test func surnameOnlyFolderStillReachesEveryCarrierOfTheName() {
        let d = Self.directory()
        let who = d.attributedMembers(folderTokens: Self.tokens("Breen_Family"))
        #expect(who.isSuperset(of: ["@I1@", "@I2@", "@I6@", "@I7@", "@I8@"]))
        #expect(who.contains("@I3@"), "Donna is a Breen by marriage")
        #expect(who.contains("@I4@"), "Eileen Latta married Sr — a Breen by marriage too")
    }

    @Test func anUnrelatedSurnameNamesNobody() {
        let d = Self.directory()
        #expect(d.attributedMembers(folderTokens: Self.tokens("Rick_and_Donna_Solo")).isEmpty)
    }

    @Test func liveBuilderPinsTheOwnerByFamilySearchID() {
        let speakers = HallieTurnExecutor.Speakers(
            ownerName: "Rick Breen", archivistName: "Hallie Mae",
            ownerFamilySearchID: "gvqv-nw3")
        let d = FamilyAssetIdentityDirectory(graph: Self.graph, speakers: speakers)
        #expect(d.ownerGedcomID == "@I1@")
        #expect(d.ownerTokens == ["rick"])
        #expect(d.attributedMembers(folderTokens: Self.tokens("RickDonnaBreenFamily")) == ["@I1@", "@I3@"])
    }

    @Test func peopleTabAliasesReachTheDirectory() {
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae")
        let profiles = [HallieTurnExecutor.ProfileSnapshot(
            stableID: "p1", canonicalName: "Richard Harding Breen Sr", aliases: ["Dick", "Dad Breen"])]
        let d = FamilyAssetIdentityDirectory(graph: Self.graph, speakers: speakers, profiles: profiles)
        #expect(d.attributedMembers(folderTokens: Self.tokens("DickAndMurielBreen")) == ["@I2@", "@I5@"])
    }
}
