import Testing
import Foundation
@testable import VideoScan

/// Sensors for the 2026-09-06 director ruling: the People tab is the source
/// of truth for the family Rick knew personally. Each test here pins one
/// behaviour that ruling changed, at the seam where it was actually broken —
/// not at a helper the production route never calls.
@Suite("People tab is the source of truth")
struct PeopleTabSourceOfTruthTests {

    // MARK: notInFamilyTree reaches the deriver

    /// The bug: `TreeIdentitySubject.init(_ snapshot:)` defaulted
    /// `notInFamilyTree` to false, and the app turn path builds its subjects
    /// from exactly that initializer. `deriveAll()` skips subjects marked
    /// "not in the tree", so the guard could never fire and a living
    /// relative Rick had excluded on privacy grounds was auto-bridged
    /// anyway. Rick, 2026-09-06: only Ma, Dad, Rick and Donna are in the
    /// tree; the other nine are alive and stay out.
    @Test func aProfileMarkedNotInTheTreeIsNeverDerivedAPin() {
        let excluded = HallieTurnExecutor.ProfileSnapshot(
            stableID: "beth", canonicalName: "Beth",
            surname: "Breen", notInFamilyTree: true)
        let ordinary = HallieTurnExecutor.ProfileSnapshot(
            stableID: "tim", canonicalName: "Tim", surname: "Breen")

        #expect(TreeIdentitySubject(excluded).notInFamilyTree,
                "the flag must survive the snapshot boundary")
        #expect(!TreeIdentitySubject(ordinary).notInFamilyTree)
    }

    /// The quarantine flag rides the same initializer and fails closed for
    /// the same reason: never invent a pin for a profile that already has
    /// one this build cannot read.
    @Test func anUnreadablePinAlsoSurvivesTheSnapshotBoundary() {
        let quarantined = HallieTurnExecutor.ProfileSnapshot(
            stableID: "ma", canonicalName: "Ma", treeIdentityUnreadable: true)
        #expect(TreeIdentitySubject(quarantined).treeIdentityUnreadable)
    }

    /// `deathdate` was dropped by the same initializer.
    @Test func aRecordedDeathSurvivesTheSnapshotBoundary() {
        let died = Date(timeIntervalSince1970: 1_214_352_000)  // 25 Jun 2008
        let snapshot = HallieTurnExecutor.ProfileSnapshot(
            stableID: "richard", canonicalName: "Richard", deathdate: died)
        #expect(TreeIdentitySubject(snapshot).deathdate == died)
    }

    // MARK: the biography quote

    private func snapshot(note: String,
                          name: String = "Tim",
                          surname: String? = "Breen",
                          maidenName: String? = nil) -> HallieTurnExecutor.ProfileSnapshot {
        HallieTurnExecutor.ProfileSnapshot(
            stableID: name.lowercased(), canonicalName: name,
            note: note, surname: surname, maidenName: maidenName)
    }

    /// The retired hedge. Rick corrects these biographies by hand; calling
    /// them unverified told the family the opposite of the truth.
    @Test func aQuotedBiographyIsAttributedAndNotHedged() throws {
        let quoted = try #require(
            HallieTurnExecutor.PeopleTab.quotedNote(snapshot(note: "Rick's older brother.")))
        #expect(quoted.contains("From Rick's People profile for Tim Breen:"))
        #expect(quoted.contains("Rick's older brother."))
        #expect(!quoted.contains("not something I've verified"))
        #expect(!quoted.lowercased().contains("unverified"))
    }

    @Test func anEmptyOrBlankBiographyIsSaidNothingAbout() {
        #expect(HallieTurnExecutor.PeopleTab.quotedNote(snapshot(note: "")) == nil)
        #expect(HallieTurnExecutor.PeopleTab.quotedNote(snapshot(note: "   \n ")) == nil)
    }

    /// The whole point of raising 400 → 1000: a biography Rick actually
    /// writes now survives intact. Dad's live note is 256 characters and
    /// the longest on the tab is 347.
    @Test func aBiographyUnderTheLimitIsQuotedWhole() throws {
        let long = String(repeating: "He served in the Marine Corps. ", count: 20)  // 600 chars
        let quoted = try #require(HallieTurnExecutor.PeopleTab.quotedNote(snapshot(note: long)))
        #expect(quoted.contains(long.trimmingCharacters(in: .whitespaces)))
        #expect(!quoted.contains("…"))
    }

    // MARK: sentence-aware trimming

    @Test func textUnderTheLimitIsUntouched() {
        let text = "He was a Marine."
        #expect(HallieTurnExecutor.PeopleTab.trimmedToSentence(text, limit: 100) == text)
    }

    /// The old `prefix(400)` stopped mid-clause — "they married in 1956,
    /// then…" — which reads as if the archivist lost her place.
    @Test func anOverlongBiographyStopsAtASentenceEnd() {
        let text = "One sentence here. Two sentence here. Three sentence here that runs on and on."
        let cut = HallieTurnExecutor.PeopleTab.trimmedToSentence(text, limit: 50)
        #expect(cut.hasSuffix(". …"), Comment(rawValue: cut))
        #expect(cut.hasPrefix("One sentence here. Two sentence here."), Comment(rawValue: cut))
    }

    /// The `limit / 2` floor: without it, a biography opening with a short
    /// sentence would be cut down to that sentence alone.
    @Test func anEarlySentenceEndDoesNotCollapseTheWholeQuote() {
        let text = "He was a Marine. " + String(repeating: "and then a very long clause ", count: 20)
        let cut = HallieTurnExecutor.PeopleTab.trimmedToSentence(text, limit: 200)
        #expect(cut.count > 100, Comment(rawValue: cut))
        #expect(cut.hasSuffix("…"))
    }

    /// No sentence terminator anywhere: fall back to a word boundary, never
    /// mid-word.
    @Test func proseWithNoSentenceEndIsCutOnAWordBoundary() {
        let text = String(repeating: "word ", count: 100)
        let cut = HallieTurnExecutor.PeopleTab.trimmedToSentence(text, limit: 52)
        #expect(cut.hasSuffix(" …"))
        #expect(!cut.contains("wor …"), Comment(rawValue: cut))
    }

    // MARK: maiden name in prose

    /// Rick's mother is Eileen Latta in the tree, Ma in the family, and a
    /// Breen by marriage. Until 2026-09-06 all three resolved a query and
    /// none of them was ever spoken.
    @Test func aBiographyFirstMentionCarriesTheMaidenName() {
        let ma = snapshot(note: "", name: "Eileen", surname: "Breen", maidenName: "Latta")
        #expect(ma.biographyFullName == "Eileen Breen (née Latta)")
        // Every other route keeps the plain form.
        #expect(ma.displayFullName == "Eileen Breen")
    }

    @Test func aProfileWithNoMaidenNameReadsExactlyAsBefore() {
        let tim = snapshot(note: "", name: "Tim", surname: "Breen")
        #expect(tim.biographyFullName == tim.displayFullName)
        #expect(tim.biographyFullName == "Tim Breen")
    }

    /// A woman who kept her name, or was never married: "née" would be
    /// wrong, not merely redundant.
    @Test func aMaidenNameEqualToTheSurnameIsNotAnnounced() {
        let same = snapshot(note: "", name: "Ellen", surname: "Latta", maidenName: "Latta")
        #expect(same.biographyFullName == "Ellen Latta")
    }

    /// A maiden name with no married surname on file is simply the last
    /// name — there is no "née" relationship to draw.
    @Test func aMaidenNameWithoutASurnameIsNotAnnounced() {
        let bare = snapshot(note: "", name: "Anna", surname: nil, maidenName: "Hudson")
        #expect(!bare.biographyFullName.contains("née"))
    }
}

/// The save path. Rick's ruling only means anything if the edit reaches
/// disk — and until 2026-09-06 `updateProfile` swallowed the error with
/// `try?` while the card flashed "Saved", so Hallie went on answering from
/// a profile.json that was never replaced.
@Suite("A profile save reports what actually happened")
@MainActor
struct ProfileSaveOutcomeTests {

    private func throwaway() -> POIProfile {
        POIProfile(name: "ZZTestPerson-\(UUID().uuidString.prefix(8))",
                   referencePath: "")
    }

    private func cleanUp(_ names: String...) {
        for name in names { try? POIProfile.delete(name: name) }
    }

    @Test func aSaveThatReachesDiskReportsSaved() throws {
        let model = PersonFinderModel()
        var profile = throwaway()
        defer { cleanUp(profile.name) }
        profile.notes = "A throwaway biography."
        let outcome = model.updateProfile(profile)
        #expect(outcome == .saved)
        #expect(outcome.reachedDisk)
        #expect(outcome.problem == nil)
        #expect(try POIProfile.load(name: profile.name).notes == "A throwaway biography.")
    }

    /// The bug, at the seam. A refused write must be REPORTED, not swallowed.
    @Test func aRefusedSaveIsReportedAsFailed() throws {
        let model = PersonFinderModel()
        let profile = throwaway()
        defer { cleanUp(profile.name); ViewerModeCenter.shared.reset() }

        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        let outcome = model.updateProfile(profile)

        #expect(!outcome.reachedDisk)
        #expect(outcome.problem?.hasPrefix("Not saved") == true,
                Comment(rawValue: outcome.problem ?? "nil"))
        if case .failed = outcome {} else {
            Issue.record("expected .failed, got \(outcome)")
        }
    }

    /// The data-loss half. The old order was delete-then-`try?`-save, so a
    /// RENAME whose write failed moved the person into .trash/ and never
    /// wrote the replacement — gone from the People tab, "Saved" on screen.
    /// The fix writes first; a failed write must leave the original intact.
    @Test func aFailedRenameLeavesTheOriginalProfileOnDisk() throws {
        let model = PersonFinderModel()
        var original = throwaway()
        original.notes = "The biography that must survive."
        defer { cleanUp(original.name, original.name + "Renamed"); ViewerModeCenter.shared.reset() }
        #expect(model.updateProfile(original) == .saved)

        var renamed = original
        renamed.name = original.name + "Renamed"
        ViewerModeCenter.shared.install(.viewer(masterHostname: "RicksM4.local"))
        let outcome = model.updateProfile(renamed, oldName: original.name)
        ViewerModeCenter.shared.reset()

        #expect(!outcome.reachedDisk)
        let survivor = try POIProfile.load(name: original.name)
        #expect(survivor.notes == "The biography that must survive.",
                "a failed rename must not retire the original")
    }

    @Test func theOutcomeVocabularyIsHonestAboutEachCase() {
        #expect(PersonFinderModel.ProfileSaveOutcome.saved.reachedDisk)
        #expect(PersonFinderModel.ProfileSaveOutcome.saved.problem == nil)
        let stale = PersonFinderModel.ProfileSaveOutcome.savedOldNameRemains("busy")
        #expect(stale.reachedDisk, "the edit IS on disk; only the old folder lingers")
        #expect(stale.problem?.contains("old name is still there") == true)
        let failed = PersonFinderModel.ProfileSaveOutcome.failed("disk full")
        #expect(!failed.reachedDisk)
        #expect(failed.problem?.contains("disk full") == true)
    }
}
