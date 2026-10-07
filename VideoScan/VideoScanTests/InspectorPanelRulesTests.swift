import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// Refactor R4 (GH #281): `InspectorPanel.body` (CCN 57) was split into one
// builder per section, and its decisions moved to `InspectorPanelRules`.
// These pin the decisions to the exact expressions the old body used, and
// the section ORDER to the old body's order, so the split cannot reorder,
// drop or reword anything.
struct InspectorPanelRulesTests {

    private func rec(_ type: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.filename = "clip.mov"
        r.fullPath = "/Volumes/Drive/clip.mov"
        r.streamTypeRaw = type.rawValue
        return r
    }

    private let fixity = ArchiveFixity(algorithm: "sha256", digest: String(repeating: "ab", count: 32),
                                       verifiedAt: Date(timeIntervalSince1970: 1_787_000_000), sizeBytes: 10)

    // MARK: - Header

    @Test func streamBadgeIsPlayabilityOnlyForProbeFailures() {
        let ok = rec(.videoOnly); ok.isPlayable = "Playable"
        #expect(InspectorPanelRules.streamBadgeText(ok) == "Video only")
        let failed = rec(.ffprobeFailed); failed.isPlayable = "Not playable"
        #expect(InspectorPanelRules.streamBadgeText(failed) == "Not playable")
    }

    @Test func missingStreamBadgeOnlyOnUnpairedHalves() {
        #expect(InspectorPanelRules.missingStreamBadge(rec(.videoOnly)) == "NO AUDIO")
        #expect(InspectorPanelRules.missingStreamBadge(rec(.audioOnly)) == "NO VIDEO")
        #expect(InspectorPanelRules.missingStreamBadge(rec(.videoAndAudio)) == nil)
        #expect(InspectorPanelRules.missingStreamBadge(rec(.ffprobeFailed)) == nil)
        let paired = rec(.videoOnly); paired.pairedWith = rec(.audioOnly)
        #expect(InspectorPanelRules.missingStreamBadge(paired) == nil)
        let pairedAudio = rec(.audioOnly); pairedAudio.pairedWith = rec(.videoOnly)
        #expect(InspectorPanelRules.missingStreamBadge(pairedAudio) == nil)
    }

    @Test func avidIdentityNeedsAvidMetadataAndATapeOrClip() {
        let r = rec()
        #expect(!InspectorPanelRules.showsAvidIdentity(r))
        r.avidMobID = "060a2b34"                       // Avid, but no tape / clip name
        #expect(!InspectorPanelRules.showsAvidIdentity(r))
        r.avidTapeName = "A001"
        #expect(InspectorPanelRules.showsAvidIdentity(r))
        let clipOnly = rec(); clipOnly.avidClipName = "Interview"   // clip name alone is Avid
        #expect(InspectorPanelRules.showsAvidIdentity(clipOnly))
        let tapeNoAvid = rec(); tapeNoAvid.avidTapeName = "A001"
        #expect(!InspectorPanelRules.showsAvidIdentity(tapeNoAvid))
    }

    // MARK: - Visibility

    @Test func conditionalSectionsAreHiddenOnAPlainRecord() {
        let r = rec()
        #expect(!InspectorPanelRules.showsDossier(r))
        #expect(!InspectorPanelRules.showsCorrelation(r))
        #expect(!InspectorPanelRules.showsTrim(r, hasDerivatives: false))
        #expect(!InspectorPanelRules.showsMasterArchive(masterCopy: nil, promotionSource: nil))
        #expect(!InspectorPanelRules.showsAngelAssessment(hasEvidence: false, masterCopy: nil, promotionSource: nil))
        #expect(!InspectorPanelRules.showsRepair(r))
        #expect(!InspectorPanelRules.showsDuplicates(r))
        #expect(!InspectorPanelRules.showsAvidProject(r))
        #expect(!InspectorPanelRules.showsUserNotes(r))
        #expect(!InspectorPanelRules.showsNotes(r))
    }

    @Test func eachConditionalSectionHasItsTrigger() {
        let d = rec(); d.dossierProcessedAt = Date()
        #expect(InspectorPanelRules.showsDossier(d))

        let p = rec(); p.pairedWith = rec(.audioOnly)
        #expect(InspectorPanelRules.showsCorrelation(p))
        let c = rec(); c.pairConfidence = .high
        #expect(InspectorPanelRules.showsCorrelation(c))

        let t = rec(); t.trimInSeconds = 1
        #expect(InspectorPanelRules.showsTrim(t, hasDerivatives: false))
        #expect(InspectorPanelRules.showsTrim(rec(), hasDerivatives: true))

        #expect(InspectorPanelRules.showsMasterArchive(masterCopy: rec(), promotionSource: nil))
        #expect(InspectorPanelRules.showsMasterArchive(masterCopy: nil, promotionSource: rec()))

        let dup = rec(); dup.duplicateDisposition = .keep
        #expect(InspectorPanelRules.showsDuplicates(dup))
        let best = rec(); best.duplicateBestMatchFilename = "other.mov"
        #expect(InspectorPanelRules.showsDuplicates(best))

        let avid = rec(); avid.avidMobID = "060a2b34"
        #expect(InspectorPanelRules.showsAvidProject(avid))

        let u = rec(); u.userNotes = "Donna at the piano"
        #expect(InspectorPanelRules.showsUserNotes(u))
        #expect(!InspectorPanelRules.showsNotes(u))          // the two notes are separate sections
        let n = rec(); n.notes = "probe note"
        #expect(InspectorPanelRules.showsNotes(n))
        #expect(!InspectorPanelRules.showsUserNotes(n))
    }

    @Test func angelAssessmentNeverShowsOnEitherSideOfAPromotion() {
        #expect(InspectorPanelRules.showsAngelAssessment(hasEvidence: true, masterCopy: nil, promotionSource: nil))
        #expect(!InspectorPanelRules.showsAngelAssessment(hasEvidence: true, masterCopy: rec(), promotionSource: nil))
        #expect(!InspectorPanelRules.showsAngelAssessment(hasEvidence: true, masterCopy: nil, promotionSource: rec()))
    }

    // MARK: - Repair lifecycle

    private func repairCopy() -> VideoRecord {
        let r = rec(); r.derivedFrom = UUID(); r.derivationKind = "rebuildAudio"
        return r
    }

    @Test func repairStatusFollowsTheOldIfChain() {
        let awaiting = repairCopy()
        #expect(InspectorPanelRules.showsRepair(awaiting))
        #expect(InspectorPanelRules.repairStatusText(awaiting) == "Waiting for your OK — play it, then confirm")

        let confirmed = repairCopy(); confirmed.repairConfirmedDate = Date(timeIntervalSince1970: 1_787_000_000)
        #expect(InspectorPanelRules.showsRepair(confirmed))
        #expect(InspectorPanelRules.repairStatusText(confirmed)?.hasPrefix("Confirmed ") == true)

        // A confirmed copy that was later superseded still reads "Confirmed"
        // (the else-if order), and a plain superseded original reads so.
        confirmed.supersededByID = UUID()
        #expect(InspectorPanelRules.repairStatusText(confirmed)?.hasPrefix("Confirmed ") == true)
        let original = rec(); original.supersededByID = UUID()
        #expect(InspectorPanelRules.showsRepair(original))
        #expect(InspectorPanelRules.repairStatusText(original)
                == "Superseded — hidden from the everyday view, never deleted")
        #expect(InspectorPanelRules.repairStatusText(rec()) == nil)
    }

    @Test func confirmButtonNeedsAwaitingASourceAndALiveRecord() {
        let awaiting = repairCopy()
        #expect(InspectorPanelRules.showsConfirmRepair(awaiting, hasRepairSource: true))
        #expect(!InspectorPanelRules.showsConfirmRepair(awaiting, hasRepairSource: false))
        let purged = repairCopy(); purged.purgedAt = Date()
        #expect(!InspectorPanelRules.showsConfirmRepair(purged, hasRepairSource: true))
        let aside = repairCopy(); aside.setAsideReason = "still"
        #expect(!InspectorPanelRules.showsConfirmRepair(aside, hasRepairSource: true))
        let confirmed = repairCopy(); confirmed.repairConfirmedDate = Date()
        #expect(!InspectorPanelRules.showsConfirmRepair(confirmed, hasRepairSource: true))
    }

    // MARK: - Text

    @MainActor @Test func goldenStrings() {
        #expect(InspectorPanelRules.trimKeptText(inSeconds: 0, outSeconds: 0)
                == "\(TrimTimecode.format(0)) – \(TrimTimecode.format(0))")
        #expect(InspectorPanelRules.editRateText(29.97) == "29.97 fps")
        #expect(InspectorPanelRules.editRateText(0) == "")
        #expect(InspectorPanelRules.editRateText(-1) == "")
        #expect(InspectorPanelRules.masterCopyFixityText(fixity) == "sha256 abababababababab…")
        #expect(InspectorPanelRules.archiveCopyFixityText(fixity)
                .hasPrefix("sha256 abababababababab… · verified "))
        #expect(InspectorPanelRules.duplicateGroupHeader(otherMembers: 2) == "Duplicate Group (3 total)")
        let embedded = Date(timeIntervalSince1970: 0)
        #expect(InspectorPanelRules.embeddedDateText(embedded)
                == InspectorDateView.embeddedFormatter.string(from: embedded) + " UTC")
    }

    @Test func masterCopyLabelSaysMasterOnlyForItsOwnCopy() {
        let src = rec()
        let own = rec(); own.derivedFrom = src.id
        #expect(InspectorPanelRules.masterCopyLabel(copy: own, record: src) == "Master copy ✓")
        let identical = rec(); identical.derivedFrom = UUID()
        #expect(InspectorPanelRules.masterCopyLabel(copy: identical, record: src) == "Identical copy in archive ✓")
    }

    @Test func duplicateStatusCountsMatchesFromTwo() {
        let r = rec(); r.duplicateDisposition = .keep
        r.duplicateGroupCount = 1
        #expect(InspectorPanelRules.duplicateStatusText(r) == "Keep")
        r.duplicateGroupCount = 2
        #expect(InspectorPanelRules.duplicateStatusText(r) == "Keep · 2 matches")
    }
}

// MARK: - Section order sensor

/// The body is now a list of section builders. This pins that list, and the
/// title each builder shows, to the order of the old 424-line body
/// (`ebcd2f09` InspectorPanel.swift lines 44–563), so a later edit cannot
/// silently reorder or drop a section.
struct InspectorPanelSectionOrderTests {

    static let expected: [(builder: String, title: String?)] = [
        ("headerSection", nil),
        ("generalSection", "General"),
        ("videoSection", "Video"),
        ("audioSection", "Audio"),
        ("familyTagsSection", "Family Tags"),
        ("workflowTagsSection", "Tags"),
        ("whenSection", "When Was This?"),
        ("whereSection", "Where Was This?"),
        ("historySection", "History"),
        ("dossierSection", "Dossier"),
        ("timestampsSection", "Timestamps"),
        ("correlationSection", "Correlation"),
        ("trimSection", "Trim"),
        ("masterArchiveSection", "Master Archive"),
        ("angelSection", "Archive Angel Assessment"),
        ("repairSection", "Repair"),
        ("duplicatesSection", "Duplicates"),
        ("avidProjectSection", "Avid Project"),
        ("userNotesSection", "Your Notes"),
        ("notesSection", "Notes"),
        ("locationSection", "Location"),
    ]

    private func code(_ name: String) throws -> String {
        let url = try #require(SourceTree.appSourceURL(named: name))
        let scanned = SourceTree.scan(try String(contentsOf: url, encoding: .utf8))
        #expect(scanned.unsupported.isEmpty, "\(scanned.unsupported)")
        return scanned.code
    }

    @Test func bodyCallsTheSectionsInTheOldOrder() throws {
        let src = try code("InspectorPanel.swift")
        let start = try #require(src.range(of: "var body: some View {"))
        let end = try #require(src.range(of: "func formatAllMetadata(", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        let pattern = try NSRegularExpression(pattern: #"\b([a-zA-Z]+Section)\("#)
        let ns = body as NSString
        let calls = pattern.matches(in: body, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
        #expect(calls == Self.expected.map(\.builder))
    }

    @Test func eachBuilderShowsItsOldTitle() throws {
        let src = try code("InspectorPanel+Sections.swift")
        for (builder, title) in Self.expected {
            let decl = try #require(src.range(of: "func \(builder)("), "no builder \(builder)")
            guard let title else { continue }
            let next = try #require(src.range(of: "inspectorSection(\"", range: decl.upperBound..<src.endIndex))
            let shown = src[next.upperBound...].prefix { $0 != "\"" }
            #expect(String(shown) == title, "\(builder)")
        }
    }
}
