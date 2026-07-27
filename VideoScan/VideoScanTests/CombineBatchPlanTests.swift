import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineBatchPlanTests
//
// Drives every reachability/substitution combination through
// VideoScanModel.prepareCombineBatch by injecting a reachability closure
// — no real volumes touched, no logging side-effects. If the substitution
// decision logic is wrong, these tests catch it before a bulk overnight
// run silently does the wrong thing.
//
// Step 2B-1 of [[project_archive_combine_pipeline_order]].

@MainActor
struct CombineBatchPlanTests {

    private let macProUMID = "0x060A2B340101010101010F00130000004B9428AB29070371060E2B347F7F2A80"
    private let backupUMID = "0x060A2B340101010101010F00130000004B9428AB29080371060E2B347F7F2A80"

    private func rec(
        _ name: String,
        _ path: String,
        umid: String = "",
        duration: Double = 0
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path
        r.materialPackageUMID = umid
        r.durationSeconds = duration
        return r
    }

    // Convenience: reachability closure for a given set of "online" prefixes.
    private func online(_ prefixes: String...) -> (String) -> Bool {
        { path in prefixes.contains { path.hasPrefix($0) } }
    }

    // MARK: - Trivial cases

    @Test
    func bothReachableNeedsNoSubstitution() {
        let model = VideoScanModel()
        let v = rec("X.mxf", "/V1/X.mxf", umid: macProUMID)
        let a = rec("X.WAV", "/V1/X.WAV")
        model.records = [v, a]

        let plan = model.prepareCombineBatch(
            pairs: [(v, a)],
            isReachable: online("/V1/")
        )
        #expect(plan.items.count == 1)
        #expect(plan.runnable.count == 1)
        #expect(plan.substituted.isEmpty)
        #expect(plan.blocked.isEmpty)
        let item = plan.items[0]
        #expect(item.resolvedVideo.fullPath == v.fullPath)
        #expect(item.resolvedAudio.fullPath == a.fullPath)
        #expect(!item.isSubstituted)
    }

    // regression: GH #125 escaped a persisted 3,808-second video paired
    // with 125 seconds of audio. The output verifier caught it only after
    // ffmpeg had spent ten minutes producing a ~96 GiB ProRes file. Batch
    // planning is the last cheap gate shared by correlated and manually
    // selected pairs, so it must refuse the mismatch before any job starts.
    @Test
    func knownShortAudioIsBlockedBeforeCombineStarts() {
        let model = VideoScanModel()
        let video = rec(
            "Untitled Sequence.04D1C4907.mxf",
            "/V1/Untitled Sequence.04D1C4907.mxf",
            duration: 3_808.271
        )
        let audio = rec(
            "00047.PHYSA01.1_4D14D1C5284.mxf",
            "/V1/00047.PHYSA01.1_4D14D1C5284.mxf",
            duration: 125.6255
        )
        model.records = [video, audio]

        let plan = model.prepareCombineBatch(
            pairs: [(video, audio)],
            isReachable: online("/V1/")
        )

        #expect(plan.runnable.isEmpty,
                "a persisted or manually selected gross duration mismatch must never reach ffmpeg")
        #expect(plan.blocked.count == 1)
        let reason = plan.blocked.first?.blockReason ?? ""
        #expect(reason.contains("audio duration mismatch"))
        #expect(reason.contains("3.3%"))
    }

    // MARK: - Substitution paths

    @Test
    func videoOfflineWithReachableUmidSubstituteIsRunnable() {
        let model = VideoScanModel()
        // Same media, two copies: one on MacPro (offline), one on MyBook (online).
        let onMacPro = rec("X.mxf", "/Volumes/MacPro/X.mxf", umid: macProUMID)
        let onMyBook = rec("X.mxf", "/Volumes/MyBook3Terabytes/AvidBackup/X.mxf",
                           umid: macProUMID)
        let audio = rec("X.WAV", "/Volumes/MacStudio/Audio/X.WAV")
        model.records = [onMacPro, onMyBook, audio]

        let plan = model.prepareCombineBatch(
            pairs: [(onMacPro, audio)],
            isReachable: online("/Volumes/MyBook3Terabytes/", "/Volumes/MacStudio/")
        )
        #expect(plan.runnable.count == 1)
        #expect(plan.substituted.count == 1)
        #expect(plan.blocked.isEmpty)
        let item = plan.items[0]
        #expect(item.videoSubstituted == true)
        #expect(item.audioSubstituted == false)
        #expect(item.resolvedVideo.fullPath == onMyBook.fullPath,
                "must use the reachable substitute, not the offline original")
        // Original is preserved so the UI/log can show "X@MacPro → X@MyBook".
        #expect(item.originalVideo.fullPath == onMacPro.fullPath)
    }

    @Test
    func audioOfflineWithReachableUmidSubstituteIsRunnable() {
        let model = VideoScanModel()
        let video = rec("X.mxf", "/Volumes/MacStudio/X.mxf", umid: macProUMID)
        let onMacPro = rec("X.WAV", "/Volumes/MacPro/X.WAV", umid: backupUMID)
        let onMyBook = rec("X.WAV", "/Volumes/MyBook3Terabytes/X.WAV", umid: backupUMID)
        model.records = [video, onMacPro, onMyBook]

        let plan = model.prepareCombineBatch(
            pairs: [(video, onMacPro)],
            isReachable: online("/Volumes/MacStudio/", "/Volumes/MyBook3Terabytes/")
        )
        let item = plan.items[0]
        #expect(item.isSubstituted)
        #expect(item.audioSubstituted == true)
        #expect(item.videoSubstituted == false)
        #expect(item.resolvedAudio.fullPath == onMyBook.fullPath)
    }

    @Test
    func bothOfflineWithBothSubstitutesAvailableIsRunnable() {
        let model = VideoScanModel()
        let vMacPro  = rec("X.mxf", "/Volumes/MacPro/X.mxf",   umid: macProUMID)
        let vMyBook  = rec("X.mxf", "/Volumes/MyBook/X.mxf",   umid: macProUMID)
        let aMacPro  = rec("X.WAV", "/Volumes/MacPro/X.WAV",   umid: backupUMID)
        let aMyBook  = rec("X.WAV", "/Volumes/MyBook/X.WAV",   umid: backupUMID)
        model.records = [vMacPro, vMyBook, aMacPro, aMyBook]

        let plan = model.prepareCombineBatch(
            pairs: [(vMacPro, aMacPro)],
            isReachable: online("/Volumes/MyBook/")
        )
        let item = plan.items[0]
        #expect(item.isRunnable)
        #expect(item.videoSubstituted)
        #expect(item.audioSubstituted)
        #expect(item.resolvedVideo.fullPath == vMyBook.fullPath)
        #expect(item.resolvedAudio.fullPath == aMyBook.fullPath)
    }

    // MARK: - Blocked paths

    @Test
    func videoOfflineWithNoSubstituteIsBlocked() {
        let model = VideoScanModel()
        let v = rec("X.mxf", "/Volumes/MacPro/X.mxf", umid: macProUMID)
        let a = rec("X.WAV", "/Volumes/MacStudio/X.WAV")
        model.records = [v, a]

        let plan = model.prepareCombineBatch(
            pairs: [(v, a)],
            isReachable: online("/Volumes/MacStudio/")
        )
        #expect(plan.blocked.count == 1)
        #expect(plan.runnable.isEmpty)
        #expect(plan.items[0].blockReason?.contains("video offline") == true)
        #expect(plan.items[0].blockReason?.contains("no reachable copy") == true)
    }

    @Test
    func offlineRecordWithoutUMIDProducesDistinctBlockReason() {
        // When materialPackageUMID is empty (legacy record / non-MXF /
        // pre-2B-1 catalog), the user needs a different hint: "re-scan
        // to enable substitute lookup" — not "no reachable copy", since
        // no lookup was even attempted.
        let model = VideoScanModel()
        let v = rec("X.mxf", "/Volumes/MacPro/X.mxf", umid: "")  // <-- no UMID
        let a = rec("X.WAV", "/Volumes/MacStudio/X.WAV")
        model.records = [v, a]

        let plan = model.prepareCombineBatch(
            pairs: [(v, a)],
            isReachable: online("/Volumes/MacStudio/")
        )
        #expect(plan.items[0].blockReason?.contains("no UMID") == true,
                "UMID-missing case must surface a distinct, actionable reason")
        #expect(plan.items[0].blockReason?.contains("re-scan") == true)
    }

    @Test
    func bothOfflineWithNoSubstitutesGetsCombinedReason() {
        let model = VideoScanModel()
        let v = rec("X.mxf", "/Volumes/MacPro/X.mxf", umid: macProUMID)
        let a = rec("X.WAV", "/Volumes/MacPro/X.WAV", umid: backupUMID)
        model.records = [v, a]

        let plan = model.prepareCombineBatch(
            pairs: [(v, a)],
            isReachable: online("/Volumes/MacStudio/")
        )
        let reason = plan.items[0].blockReason ?? ""
        #expect(reason.contains("video offline"))
        #expect(reason.contains("audio offline"))
    }

    @Test
    func substituteThatIsAlsoOfflineIsIgnored() {
        // If the only "substitute" lives on another offline volume, the
        // pair must still be blocked — the resolver must scan past the
        // first match if it's not reachable.
        let model = VideoScanModel()
        let onMacPro     = rec("X.mxf", "/Volumes/MacPro/X.mxf",     umid: macProUMID)
        let onAlsoOffline = rec("X.mxf", "/Volumes/AnotherOffline/X.mxf", umid: macProUMID)
        let onMyBook     = rec("X.mxf", "/Volumes/MyBook/X.mxf",     umid: macProUMID)
        let audio        = rec("X.WAV", "/Volumes/MacStudio/X.WAV")
        model.records = [onMacPro, onAlsoOffline, onMyBook, audio]

        // MyBook is reachable, MacPro and AnotherOffline are not.
        let plan = model.prepareCombineBatch(
            pairs: [(onMacPro, audio)],
            isReachable: online("/Volumes/MyBook/", "/Volumes/MacStudio/")
        )
        #expect(plan.runnable.count == 1)
        #expect(plan.items[0].resolvedVideo.fullPath == onMyBook.fullPath,
                "must skip the offline substitute and find the reachable one")
    }

    @Test
    func noSubstituteIsAlsoOfflineEverywhereBlocks() {
        let model = VideoScanModel()
        let onMacPro       = rec("X.mxf", "/Volumes/MacPro/X.mxf",       umid: macProUMID)
        let onAlsoOffline  = rec("X.mxf", "/Volumes/AnotherOffline/X.mxf", umid: macProUMID)
        let audio          = rec("X.WAV", "/Volumes/MacStudio/X.WAV")
        model.records = [onMacPro, onAlsoOffline, audio]

        let plan = model.prepareCombineBatch(
            pairs: [(onMacPro, audio)],
            isReachable: online("/Volumes/MacStudio/")  // no copy reachable
        )
        #expect(plan.blocked.count == 1)
    }

    // MARK: - Mixed batch

    @Test
    func mixedBatchPartitionsCorrectly() {
        let model = VideoScanModel()
        // Pair 1: both reachable → ready
        let v1 = rec("A.mxf", "/Volumes/MyBook/A.mxf", umid: "U1")
        let a1 = rec("A.WAV", "/Volumes/MyBook/A.WAV")
        // Pair 2: video offline with substitute → substituted
        let v2_macPro = rec("B.mxf", "/Volumes/MacPro/B.mxf", umid: "U2")
        let v2_myBook = rec("B.mxf", "/Volumes/MyBook/B.mxf", umid: "U2")
        let a2 = rec("B.WAV", "/Volumes/MyBook/B.WAV")
        // Pair 3: video offline with no substitute → blocked
        let v3 = rec("C.mxf", "/Volumes/MacPro/C.mxf", umid: "U3")
        let a3 = rec("C.WAV", "/Volumes/MyBook/C.WAV")
        model.records = [v1, a1, v2_macPro, v2_myBook, a2, v3, a3]

        let plan = model.prepareCombineBatch(
            pairs: [(v1, a1), (v2_macPro, a2), (v3, a3)],
            isReachable: online("/Volumes/MyBook/")
        )
        #expect(plan.items.count == 3)
        #expect(plan.runnable.count == 2)
        #expect(plan.substituted.count == 1)
        #expect(plan.blocked.count == 1)
        #expect(plan.substituted.first?.resolvedVideo.fullPath == v2_myBook.fullPath)
        #expect(plan.blocked.first?.originalVideo.fullPath == v3.fullPath)
    }

    @Test
    func emptyInputProducesEmptyPlan() {
        let model = VideoScanModel()
        let plan = model.prepareCombineBatch(pairs: [], isReachable: { _ in true })
        #expect(plan.items.isEmpty)
        #expect(plan.runnable.isEmpty)
        #expect(plan.blocked.isEmpty)
    }
}
