import Testing
import Foundation
import VideoScanCore
@testable import VideoScan

// MARK: - Launch cost (measured 2026-11-02, .scratch/launch-time-2026-11-02.md)
//
// Since #402 (12fc850a) the load-time dossier backfill ran the full
// `CaptionTextQuality.verdict` on every member of every duplicate group on
// every launch, on the main thread, even when the copies already agreed and
// nothing propagated: +3–4 s per launch. The fix judges nothing in a channel
// whose copies agree, and only the winning candidate in one that does not.
// These tests pin (1) how many verdicts a pass spends, (2) that the rows it
// writes are exactly the rows the pre-fix code wrote.

@MainActor
@Suite("Dossier backfill — verdicts spent per launch (launch-time fix 2026-11-02)")
struct DossierBackfillVerdictBudgetTests {

    /// A realistic, usable transcript of about `bytes` bytes, unique per `seed`.
    /// Built fresh per call so copies in a group are separate String
    /// instances, as rows loaded from SQLite are.
    static func transcript(seed: Int, bytes: Int = 1_400) -> String {
        let words = ["the", "kids", "ran", "down", "to", "beach", "and", "grandpa",
                     "said", "look", "at", "that", "boat", "out", "there", "now"]
        var s = "Clip \(seed):"
        var i = seed
        while s.utf8.count < bytes {
            s += " " + words[i % words.count]
            i = i &* 31 &+ 7
            if i < 0 { i = -i }
        }
        return String(decoding: Array(s.utf8), as: UTF8.self)
    }

    static func record(md5: String, path: String, transcript: String?,
                       ocrText: [SceneCaption] = [], ocrDates: [SceneCaption] = []) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioTranscript = transcript
        r.audioTranscriptModel = transcript == nil ? nil : "whisper-medium"
        r.ocrText = ocrText
        r.ocrDateCandidates = ocrDates
        return r
    }

    static func ocr(_ g: Int) -> (text: [SceneCaption], dates: [SceneCaption]) {
        ([SceneCaption(timestamp: 1, text: "HAPPY BIRTHDAY \(g)"),
          SceneCaption(timestamp: 4, text: "!!!!!!!!!!!!")],          // stored junk, as in the real catalog
         [SceneCaption(timestamp: 2, text: "JUN 21 199\(g % 10)")])
    }

    @Test("a group whose copies already agree costs zero verdicts and writes nothing")
    func agreeingGroupsCostNoVerdict() {
        let model = VideoScanModel()
        var records: [VideoRecord] = []
        for g in 0..<50 {
            let o = Self.ocr(g)
            for c in 0..<3 {
                records.append(Self.record(md5: "G\(g)", path: "/V\(c)/g\(g).mov",
                                           transcript: Self.transcript(seed: g),
                                           ocrText: o.text, ocrDates: o.dates))
            }
        }
        model.records = records
        var judge = DossierTextJudge()
        let updated = model.backfillDossierAcrossDuplicates(judge: &judge)
        #expect(updated == 0)
        #expect(judge.verdictCalls == 0,
                "50 agreeing groups must spend 0 verdicts; spent \(judge.verdictCalls)")
    }

    @Test("a group with one copy behind costs at most one verdict, and the copy is filled")
    func behindGroupCostsOneVerdict() {
        let model = VideoScanModel()
        var records: [VideoRecord] = []
        var behind: [VideoRecord] = []
        for g in 0..<50 {
            let o = Self.ocr(g)
            for c in 0..<3 {
                let r = Self.record(md5: "G\(g)", path: "/V\(c)/g\(g).mov",
                                    transcript: c == 2 ? nil : Self.transcript(seed: g),
                                    ocrText: o.text, ocrDates: o.dates)
                if c == 2 { behind.append(r) }
                records.append(r)
            }
        }
        model.records = records
        var judge = DossierTextJudge()
        let updated = model.backfillDossierAcrossDuplicates(judge: &judge)
        #expect(updated == 50)
        #expect(judge.verdictCalls <= 50,
                "≤ 1 verdict per group (50 groups); spent \(judge.verdictCalls)")
        #expect(behind.allSatisfy { $0.audioTranscript?.hasPrefix("Clip ") == true })
    }

    @Test("a degenerate longest transcript is judged, refused, and the next one wins")
    func degenerateLongestFallsThroughToNext() {
        let model = VideoScanModel()
        let junk = Self.record(md5: "M", path: "/A/x.mov", transcript: String(repeating: "!", count: 400))
        let real = Self.record(md5: "M", path: "/B/x.mov", transcript: "Happy birthday, Grandma.")
        let empty = Self.record(md5: "M", path: "/C/x.mov", transcript: nil)
        model.records = [junk, real, empty]
        var judge = DossierTextJudge()
        let updated = model.backfillDossierAcrossDuplicates(judge: &judge)
        #expect(updated == 2)
        #expect(junk.audioTranscript == "Happy birthday, Grandma.")
        #expect(empty.audioTranscript == "Happy birthday, Grandma.")
        #expect(judge.verdictCalls == 2, "the junk longest and the winner; spent \(judge.verdictCalls)")
    }

    @Test("the judge's usable(_:) is CaptionTextQuality.usable(_:), order kept")
    func judgeUsableMatchesCore() {
        let caps = ["JUN 21 1991", "!!!!!!!!!!", "", "none", "abababababab", "1991", "JUN 21 1991"]
            .enumerated().map { SceneCaption(timestamp: Double($0.offset), text: $0.element) }
        var judge = DossierTextJudge()
        #expect(judge.usable(caps) == CaptionTextQuality.usable(caps))
        #expect(judge.usable([]) == [])
    }
}

// MARK: - Equivalence with the pre-fix propagation (#402 as merged, 85fe3140)

@MainActor
@Suite("Dossier backfill — writes exactly what the pre-fix code wrote")
struct DossierBackfillEquivalenceTests {

    /// The pre-fix `propagateBestDossier` (VideoScanModel+DossierPropagation
    /// at 2b350118), kept verbatim as the oracle: every member judged.
    static func legacyPropagate(_ group: [VideoRecord]) -> Int {
        let eligible = group.filter { !VideoScanModel.isExcludedFromPropagation($0) }
        guard eligible.count >= 2 else { return 0 }
        var bestTx: (text: String, model: String?, date: Date?)?
        for rec in eligible {
            guard let tx = rec.audioTranscript, !tx.isEmpty else { continue }
            if CaptionTextQuality.verdict(tx).isDegenerate { continue }
            if bestTx == nil || tx.count > (bestTx?.text.count ?? 0) {
                bestTx = (tx, rec.audioTranscriptModel, rec.audioTranscriptDate)
            }
        }
        var bestCaps: (captions: [SceneCaption], model: String?, date: Date?)?
        var capScore = -1
        for rec in eligible {
            guard !rec.sceneCaptions.isEmpty else { continue }
            let score = rec.sceneCaptions.count * 1000 + rec.sceneCaptions.reduce(0) { $0 + $1.text.count }
            if score > capScore { capScore = score; bestCaps = (rec.sceneCaptions, rec.sceneCaptionModel, rec.sceneCaptionDate) }
        }
        func bestEntries(_ pick: (VideoRecord) -> [SceneCaption]) -> [SceneCaption]? {
            var best: [SceneCaption]?
            var bestScore = -1
            for rec in eligible {
                let usable = pick(rec)
                guard !usable.isEmpty else { continue }
                let score = usable.count * 1000 + usable.reduce(0) { $0 + $1.text.count }
                if score > bestScore { bestScore = score; best = usable }
            }
            return best
        }
        let bestOCRText = bestEntries { CaptionTextQuality.usable($0.ocrText) }
        let bestOCRDates = bestEntries { $0.usableOCRDates }
        var mutated = 0
        for rec in eligible {
            var changed = false
            if let b = bestTx, (rec.audioTranscript ?? "") != b.text {
                rec.audioTranscript = b.text; rec.audioTranscriptModel = b.model; rec.audioTranscriptDate = b.date
                changed = true
            }
            if let b = bestCaps, rec.sceneCaptions != b.captions {
                rec.sceneCaptions = b.captions; rec.sceneCaptionModel = b.model; rec.sceneCaptionDate = b.date
                changed = true
            }
            if let b = bestOCRText, CaptionTextQuality.usable(rec.ocrText) != b {
                rec.ocrText = b; changed = true
            }
            if let b = bestOCRDates, rec.usableOCRDates != b {
                rec.ocrDateCandidates = b; changed = true
            }
            if changed { mutated += 1 }
        }
        return mutated
    }

    /// SplitMix64 — a seeded, reproducible generator (C++: std::mt19937 with a fixed seed).
    struct SeededRNG: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    struct Snapshot: Equatable {
        let tx: String?, txModel: String?, txDate: Date?
        let caps: [SceneCaption], capModel: String?, capDate: Date?
        let ocrText: [SceneCaption], ocrDates: [SceneCaption]
        init(_ r: VideoRecord) {
            tx = r.audioTranscript; txModel = r.audioTranscriptModel; txDate = r.audioTranscriptDate
            caps = r.sceneCaptions; capModel = r.sceneCaptionModel; capDate = r.sceneCaptionDate
            ocrText = r.ocrText; ocrDates = r.ocrDateCandidates
        }
    }

    /// Groups that do and do not need propagation, on every channel: equal
    /// copies, a copy behind, divergent lengths, equal-length ties with
    /// different models, degenerate longest transcripts, junk-only OCR,
    /// junk mixed into OCR, empty vs nil, and unreadable members.
    static func fixture(seed: UInt64) -> [VideoRecord] {
        var rng = SeededRNG(state: seed)
        let txPool: [String?] = [nil, "", "Happy birthday, Grandma.", "Happy birthday Grandma",
                                 "Happy birthday, Grandpa.", String(repeating: "!", count: 60),
                                 "the the the the the the the the", "Look at the boat out there, kids.",
                                 "  ", "Merry Christmas everybody, from all of us."]
        let capPool: [[SceneCaption]] = [[], [SceneCaption(timestamp: 0, text: "a beach")],
                                         [SceneCaption(timestamp: 0, text: "a beach"), SceneCaption(timestamp: 3, text: "a boat")],
                                         [SceneCaption(timestamp: 0, text: "a lake")]]
        let ocrPool: [[SceneCaption]] = [[], [SceneCaption(timestamp: 1, text: "!!!!!!!!!!")],
                                         [SceneCaption(timestamp: 1, text: "HAPPY 4TH")],
                                         [SceneCaption(timestamp: 1, text: "HAPPY 4TH"), SceneCaption(timestamp: 2, text: "--------------")],
                                         [SceneCaption(timestamp: 1, text: "JULY 1988"), SceneCaption(timestamp: 2, text: "HAPPY 4TH")]]
        let datePool: [[SceneCaption]] = [[], [SceneCaption(timestamp: 2, text: "JUN 21 1991")],
                                          [SceneCaption(timestamp: 2, text: "!!!!"), SceneCaption(timestamp: 3, text: "!!!!"),
                                           SceneCaption(timestamp: 4, text: "!!!!")],
                                          [SceneCaption(timestamp: 2, text: "JUN 21 1991"), SceneCaption(timestamp: 5, text: "!!!!!!!!!")],
                                          [SceneCaption(timestamp: 7, text: "12/25/1985")]]
        let models: [String?] = [nil, "whisper-small", "whisper-medium"]
        var out: [VideoRecord] = []
        for g in 0..<600 {
            let size = Int.random(in: 1...4, using: &rng)
            let agree = Bool.random(using: &rng)          // about half the groups need nothing
            let base = (Int.random(in: 0..<txPool.count, using: &rng), Int.random(in: 0..<capPool.count, using: &rng),
                        Int.random(in: 0..<ocrPool.count, using: &rng), Int.random(in: 0..<datePool.count, using: &rng))
            for c in 0..<size {
                let r = VideoRecord()
                r.fullPath = "/V\(c)/g\(g).mov"
                r.filename = "g\(g).mov"
                r.partialMD5 = g % 37 == 0 ? "" : "G\(g)"
                let unreadable = Int.random(in: 0..<10, using: &rng) == 0
                r.streamTypeRaw = (unreadable ? StreamType.ffprobeFailed : StreamType.videoAndAudio).rawValue
                let pick = agree ? base : (Int.random(in: 0..<txPool.count, using: &rng), Int.random(in: 0..<capPool.count, using: &rng),
                                           Int.random(in: 0..<ocrPool.count, using: &rng), Int.random(in: 0..<datePool.count, using: &rng))
                r.audioTranscript = txPool[pick.0].map { String(decoding: Array($0.utf8), as: UTF8.self) }
                r.audioTranscriptModel = models[Int.random(in: 0..<models.count, using: &rng)]
                r.audioTranscriptDate = Date(timeIntervalSince1970: Double(1_700_000_000 + g * 10 + c))
                r.sceneCaptions = capPool[pick.1]
                r.sceneCaptionModel = models[Int.random(in: 0..<models.count, using: &rng)]
                r.sceneCaptionDate = Date(timeIntervalSince1970: Double(1_710_000_000 + g * 10 + c))
                r.ocrText = ocrPool[pick.2]
                r.ocrDateCandidates = datePool[pick.3]
                out.append(r)
            }
        }
        return out
    }

    /// Group the way `backfillDossierAcrossDuplicates` does, in record order.
    static func groups(_ records: [VideoRecord]) -> [[VideoRecord]] {
        var order: [String] = []
        var by: [String: [VideoRecord]] = [:]
        for r in records where !r.partialMD5.isEmpty {
            if by[r.partialMD5] == nil { order.append(r.partialMD5) }
            by[r.partialMD5, default: []].append(r)
        }
        return order.compactMap { key in by[key].flatMap { $0.count >= 2 ? $0 : nil } }
    }

    @Test("per group: same mutated count and the same field values as the pre-fix code", arguments: [UInt64(1), 2, 3, 402, 20261102])
    func sameWritesAsPreFix(seed: UInt64) {
        let model = VideoScanModel()
        let legacy = Self.fixture(seed: seed)
        let current = Self.fixture(seed: seed)
        let legacyGroups = Self.groups(legacy)
        let currentGroups = Self.groups(current)
        #expect(legacyGroups.count == currentGroups.count && legacyGroups.count > 100)
        var needed = 0, agreed = 0
        for (lg, cg) in zip(legacyGroups, currentGroups) {
            let lm = Self.legacyPropagate(lg)
            let cm = model.propagateBestDossier(in: cg)
            #expect(lm == cm, "mutated count differs in group \(cg.first?.partialMD5 ?? "")")
            if lm > 0 { needed += 1 } else { agreed += 1 }
        }
        #expect(needed > 50 && agreed > 50, "fixture must hold both kinds: \(needed) propagate, \(agreed) do not")
        #expect(legacy.map(Snapshot.init) == current.map(Snapshot.init))
    }

    @Test("whole backfill: same total, same rows, same one log line as the pre-fix code")
    func backfillSameAsPreFix() {
        let legacy = Self.fixture(seed: 77)
        let current = Self.fixture(seed: 77)
        let legacyTotal = Self.groups(legacy).reduce(0) { $0 + Self.legacyPropagate($1) }
        let model = VideoScanModel()
        model.records = current
        let total = model.backfillDossierAcrossDuplicates()
        #expect(total == legacyTotal && total > 0)
        #expect(legacy.map(Snapshot.init) == current.map(Snapshot.init))
        // Idempotent at launch: a second pass writes nothing (no log line, no save).
        var judge = DossierTextJudge()
        #expect(model.backfillDossierAcrossDuplicates(judge: &judge) == 0)
    }
}

// MARK: - The one `launch phases:` line (fix D)

@MainActor
@Suite("Launch phases — one line per launch, every phase named with a number")
struct LaunchPhaseLineTests {

    @Test("format: phases in launch order, whole milliseconds, total last")
    func lineFormatIsPinned() {
        let line = LaunchPhaseClock.line(
            spans: [.catalog: .milliseconds(3120), .repair: .microseconds(41_900),
                    .searchIndex: .seconds(2.87), .findTag: .milliseconds(7400)],
            total: .milliseconds(18_010))
        #expect(line == "launch phases: catalog 3120ms · repair 41ms · search index 2870ms · find-tag 7400ms · total 18010ms")
    }

    @Test("a phase that did not run still prints a number (0ms), never a gap")
    func missingPhasePrintsZero() {
        let line = LaunchPhaseClock.line(spans: [:], total: .zero)
        #expect(line == "launch phases: catalog 0ms · repair 0ms · search index 0ms · find-tag 0ms · total 0ms")
        let shape = #/^launch phases: catalog \d+ms · repair \d+ms · search index \d+ms · find-tag \d+ms · total \d+ms$/#
        #expect(line.wholeMatch(of: shape) != nil)
    }

    @Test("sensor: the clock reports once — a reopened window's onAppear writes no second line")
    func reportsOnce() {
        let clock = LaunchPhaseClock()
        clock.record(.catalog, since: clock.now)
        let first = clock.takeReportLine()
        #expect(first?.hasPrefix("launch phases: catalog ") == true)
        #expect(clock.takeReportLine() == nil)
    }

    @Test("sensor: a model built the way launch builds it yields one well-formed line")
    func modelYieldsWellFormedLine() throws {
        let model = VideoScanModel()
        let line = try #require(model.launchPhases.takeReportLine())
        #expect(line.wholeMatch(of: #/^launch phases: catalog \d+ms · repair \d+ms · search index \d+ms · find-tag \d+ms · total \d+ms$/#) != nil)
    }
}
