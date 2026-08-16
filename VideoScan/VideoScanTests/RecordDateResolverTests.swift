// RecordDateResolverTests.swift
// The ONE shared "when was this shot?" ranking (2026-08-16), and the two
// consumers that must agree with it: ArchivePathResolver placement and
// ArchiveReadiness' date state.
//
//   LOGIC   — precedence matrix (user > embedded > inferred≥0.6 > filename
//             patterns), confidence tiers by origin, user-date refinement,
//             the filename pattern table (incl. Rick's three examples).
//   SENSOR  — the RickGuitar placement: embedded 2025-06-15T22:47:45Z →
//             30_Video/2020-2029/2025/2025-06-15_RickGuitar2025.mov (was
//             2025-xx-xx from the filename year).
//   SCALE   — 100k synthetic records through the resolver in budget.
//   Filesystem dates are NEVER consulted — pinned.

import Foundation
import Testing
@testable import VideoScan

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    var dc = DateComponents()
    dc.year = y; dc.month = mo; dc.day = d; dc.hour = h; dc.minute = mi; dc.second = s
    return cal.date(from: dc)!
}

private let testNow = utc(2026, 8, 16, 12)

// MARK: - Precedence

@Suite("Record date resolver — precedence matrix")
struct RecordDateResolverPrecedenceTests {

    private func resolve(user: String? = nil, userConf: String? = nil,
                         embedded: Date? = nil, make: String? = nil, model: String? = nil, encoder: String? = nil,
                         inferred: Date? = nil, inferredConf: Float? = nil,
                         filename: String? = nil) -> RecordDateResolution {
        RecordDateResolver.resolve(userDate: user, userDateConfidence: userConf,
                                   embeddedCreationDate: embedded, originMake: make, originModel: model, originEncoder: encoder,
                                   inferredRecordDate: inferred, inferredDateConfidence: inferredConf,
                                   filename: filename, now: testNow)
    }

    @Test("user full date beats everything, at its precision")
    func userFullDate() {
        let r = resolve(user: "1992-06-14", userConf: "known", embedded: utc(2025, 6, 15), make: "Apple",
                        inferred: utc(2010, 1, 1), inferredConf: 0.99, filename: "Rick-and-Matt-Podcast-11-19-2005.m4v")
        #expect(r.isoString == "1992-06-14"); #expect(r.precision == .day)
        #expect(r.source == .userDate); #expect(r.confidence == 1.0)
        let est = resolve(user: "1992-06-14")
        #expect(est.confidence == 0.8, "best guess is still ≥ 0.6 → known for readiness")
    }

    @Test("embedded beats inferred (even at 0.99) and filename; confidence by origin: device 0.95 / none 0.85 / encoder-only 0.80")
    func embeddedTiers() {
        let dev = resolve(embedded: utc(2025, 6, 15, 22, 47, 45), make: "Canon", model: "Canon EOS R6m2", encoder: "Lavf63",
                          inferred: utc(2010, 1, 1), inferredConf: 0.99, filename: "Rick-and-Matt-Podcast-11-19-2005.m4v")
        #expect(dev.isoString == "2025-06-15"); #expect(dev.source == .embedded); #expect(dev.precision == .day)
        #expect(dev.confidence == 0.95)
        #expect(resolve(embedded: utc(2025, 6, 15), model: "iPhone 15 Pro").confidence == 0.95)
        #expect(resolve(embedded: utc(2025, 6, 15)).confidence == 0.85)
        #expect(resolve(embedded: utc(2025, 6, 15), encoder: "HandBrake 1.7.3").confidence == 0.80)
        // Evening-in-Boston stamps are read as UTC calendar days — pinned so a change is deliberate.
        #expect(resolve(embedded: utc(2025, 6, 16, 1, 30)).isoString == "2025-06-16")
    }

    @Test("inferred ≥ 0.6 beats filename; < 0.6 falls through to filename (flagged) or unknown+rejected")
    func inferredFloor() {
        let ok = resolve(inferred: utc(2005, 3, 9), inferredConf: 0.6, filename: "Christmas1995Etc.mkv")
        #expect(ok.isoString == "2005-03-09"); #expect(ok.source == .inferred); #expect(ok.confidence == 0.6)
        let low = resolve(inferred: utc(2005, 3, 9), inferredConf: 0.59, filename: "Christmas1995Etc.mkv")
        #expect(low.isoString == "1995"); #expect(low.source == .filename); #expect(low.hadRejectedSignal)
        let none = resolve(inferred: utc(2005, 3, 9), inferredConf: 0.59, filename: "tape7.dv")
        #expect(none.precision == .unknown); #expect(none.hadRejectedSignal); #expect(none.date == nil)
        let nothing = resolve(filename: "tape7.dv")
        #expect(nothing == .unknown()); #expect(!nothing.hadRejectedSignal)
    }

    @Test("a year-only / month-only user date is REFINED by an agreeing finer machine date, never overruled by a disagreeing one")
    func userRefinement() {
        // Agreeing camera stamp sharpens "1992" to the day; confidence stays the user's.
        let r1 = resolve(user: "1992", embedded: utc(1992, 6, 15), make: "Sony")
        #expect(r1.isoString == "1992-06-15"); #expect(r1.source == .embedded); #expect(r1.confidence == 0.95)
        // Disagreeing camera stamp (the VHS-transferred-in-2010 case): user wins.
        let r2 = resolve(user: "1992", embedded: utc(2010, 5, 3), make: "Sony", inferred: utc(2010, 1, 1), inferredConf: 0.99)
        #expect(r2.isoString == "1992"); #expect(r2.source == .userDate); #expect(r2.precision == .year)
        // Month-only user date + agreeing filename day → day.
        let r3 = resolve(user: "2005-11", filename: "Rick-and-Matt-Podcast-11-19-2005.m4v")
        #expect(r3.isoString == "2005-11-19"); #expect(r3.source == .filename); #expect(r3.confidence == 0.8)
        // Month-only user date + filename in a different month → user month stays.
        let r4 = resolve(user: "2005-10", filename: "Rick-and-Matt-Podcast-11-19-2005.m4v")
        #expect(r4.isoString == "2005-10")
        // Rejected (low) inferred never refines.
        let r5 = resolve(user: "1992", inferred: utc(1992, 2, 2), inferredConf: 0.3)
        #expect(r5.isoString == "1992")
    }

    @Test("filesystem dates are never an input — the resolver has no parameter for them (compile-time pin) and unknown stays unknown")
    func noFilesystemDates() {
        #expect(resolve(filename: "IMG_0001.mov").precision == .unknown)
        #expect(resolve(filename: "clip_1994.mov").precision == .unknown, "clip_N is a counter (scale-test names)")
    }
}

// MARK: - Filename patterns

@Suite("Record date resolver — filename date patterns")
struct FilenameDatePatternTests {

    private func m(_ name: String) -> String {
        guard let r = FilenameDatePattern.match(name, now: testNow) else { return "-" }
        var s = String(format: "%04d", r.year)
        if let mo = r.month { s += String(format: "-%02d", mo) }
        if let d = r.day { s += String(format: "-%02d", d) }
        return s + " \(r.precision)"
    }

    @Test("Rick's three examples and the documented forms",
          arguments: [
            ("Rick-and-Matt-Podcast-11-19-2005.m4v", "2005-11-19 day"),
            ("Westford_1994-1995.mkv",               "1994 year"),
            ("Christmas1995Etc.mkv",                 "1995 year"),
            ("RickGuitar2025.mov",                   "2025 year"),
            ("Vacation 2003-07-04 beach.mov",        "2003-07-04 day"),
            ("2003_07_04_beach.mov",                 "2003-07-04 day"),
            ("2003.07.04.mov",                       "2003-07-04 day"),
            ("19-11-2005 podcast.m4v",               "2005-11-19 day"),   // DD-MM only when MM is impossible
            ("03-04-2005.mov",                       "2005-03-04 day"),   // ambiguous → US month-first
            ("Reunion 20051119.mov",                 "2005-11-19 day"),
            ("VID_20190302_101500.mp4",              "2019-03-02 day"),
            ("June 1994 cookout.dv",                 "1994-06 month"),
            ("Jun1994.dv",                           "1994-06 month"),
            ("Sept-1998-Fair.avi",                   "1998-09 month"),
            ("Tape 1998-09.avi",                     "1998-09 month"),
            ("Thomas 1995.mov",                      "1995 year"),        // "mas" is not a month
            ("Grandpa 1947 8mm reel.mp4",            "1947 year"),
            ("Christmas 2027 Etc.mkv",               "2027 year"),        // now+1 is the ceiling
            ("Christmas 2028 Etc.mkv",               "-"),
            ("IMG_1995.MOV",                         "-"),                // camera counter
            ("DSC_2001.mov",                         "-"),
            ("MVI_1985.AVI",                         "-"),
            ("GOPR2010.MP4",                         "-"),
            ("100_2005.MOV",                         "-"),                // Kodak folder_frame
            ("clip_1994.mov",                        "-"),
            ("P1010203.MOV",                         "-"),
            ("test_pm_h264.mp4",                     "-"),
            ("x264_1080p.mkv",                       "-"),
            ("tape7.dv",                             "-"),
            ("noext",                                "-"),
            ("",                                     "-"),
          ] as [(String, String)])
    func patterns(name: String, expected: String) {
        #expect(m(name) == expected, "\(name)")
    }
}

// MARK: - Placement (ArchivePathResolver) — the RickGuitar sensor

@Suite("Master Archive — embedded date placement")
struct EmbeddedDatePlacementTests {

    @Test("SENSOR: RickGuitar2025.mov with embedded 2025-06-15T22:47:45Z lands in 30_Video/2020-2029/2025/2025-06-15_RickGuitar2025.mov (not 2025-xx-xx)")
    @MainActor
    func rickGuitar() {
        let rec = VideoRecord()
        rec.filename = "RickGuitar2025.mov"; rec.ext = "mov"
        rec.fullPath = "/Volumes/MediaExpansion/Guitar/RickGuitar2025.mov"
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.dateCreatedRaw = utc(2026, 8, 1); rec.dateCreated = "2026-08-01 10:00"   // a copy — never used
        rec.inferredRecordDate = utc(2025, 1, 1); rec.inferredDateConfidence = 0.5   // filename-year dossier guess

        // Before: no embedded date → filename year (deliberate improvement over Undated: 0.5 confidence, flagged).
        let before = ArchivePathResolver.facts(for: rec)
        #expect(before.dateHint == .year(2025))
        #expect(before.dateIsLowConfidence)
        #expect(ArchivePathResolver.baseRelativePath(facts: before) == "30_Video/2020-2029/2025/2025-xx-xx_RickGuitar2025.mov")

        // After the scan / backfill captured the container stamp:
        rec.embeddedCreationDate = utc(2025, 6, 15, 22, 47, 45)
        rec.embeddedCreationSource = "format:creation_time"
        let after = ArchivePathResolver.facts(for: rec)
        #expect(after.dateHint == .day(year: 2025, month: 6, day: 15))
        #expect(!after.dateIsLowConfidence)
        #expect(ArchivePathResolver.baseRelativePath(facts: after) == "30_Video/2020-2029/2025/2025-06-15_RickGuitar2025.mov")
        #expect(after.dateHint.manifestDate == "2025-06-15")

        // Rick's own date still outranks the camera.
        rec.userDate = "2024"; rec.userDateConfidence = "known"
        #expect(ArchivePathResolver.facts(for: rec).dateHint == .year(2024))
        // …unless it agrees, in which case the camera sharpens it.
        rec.userDate = "2025"
        #expect(ArchivePathResolver.facts(for: rec).dateHint == .day(year: 2025, month: 6, day: 15))
    }

    @Test("dateHint: existing 3-argument behavior is unchanged; filename patterns place at year precision, low-confidence")
    func dateHintCompat() {
        #expect(ArchivePathResolver.dateHint(userDate: "1992", inferredRecordDate: Date(), inferredDateConfidence: 0.99).hint == .year(1992))
        let low = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: utc(2005, 3, 9), inferredDateConfidence: 0.59)
        #expect(low.hint == .unknown); #expect(low.lowConfidence)
        let fn = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: nil, inferredDateConfidence: nil,
                                              filename: "Christmas1995Etc.mkv")
        #expect(fn.hint == .year(1995)); #expect(fn.lowConfidence)
        let day = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: nil, inferredDateConfidence: nil,
                                               filename: "Rick-and-Matt-Podcast-11-19-2005.m4v")
        #expect(day.hint == .day(year: 2005, month: 11, day: 19)); #expect(day.lowConfidence, "0.5 from a filename is still a guess")
        let undated = ArchivePathResolver.dateHint(userDate: nil, inferredRecordDate: nil, inferredDateConfidence: nil, filename: "tape7.dv")
        #expect(undated.hint == .unknown); #expect(!undated.lowConfidence)
    }

    @Test("readiness date state follows the same resolver: embedded → known; filename → lowConfidence with a placed warning; user year → known")
    func readinessDateState() {
        func inputs(_ f: (inout ArchiveReadiness.Inputs) -> Void) -> ArchiveReadiness.Inputs {
            var i = ArchiveReadiness.Inputs()
            i.isPlayable = "Yes"; i.streamTypeRaw = StreamType.videoAndAudio.rawValue
            i.videoCodec = "hevc"; i.audioCodec = "aac"; i.audioVerifyStatus = "ok"
            f(&i); return i
        }
        let emb = ArchiveReadiness.assess(inputs { $0.embeddedCreationDate = utc(2025, 6, 15); $0.originMake = "Apple"; $0.filename = "RickGuitar2025.mov" })
        #expect(emb.date == .known); #expect(emb.token.hasSuffix("date=known"))
        let hb = ArchiveReadiness.assess(inputs { $0.embeddedCreationDate = utc(2025, 6, 15); $0.originEncoder = "HandBrake 1.7.3" })
        #expect(hb.date == .known, "0.80 ≥ 0.6 at day precision")
        let fn = ArchiveReadiness.assess(inputs { $0.filename = "Christmas1995Etc.mkv" })
        #expect(fn.date == .lowConfidence)
        #expect(fn.warnings.contains { $0.hasPrefix("Date 1995 is a low-confidence guess from the filename") }, "\(fn.warnings)")
        let user = ArchiveReadiness.assess(inputs { $0.userDate = "1992"; $0.filename = "Christmas1995Etc.mkv" })
        #expect(user.date == .known, "Rick's own year is never nagged")
        let none = ArchiveReadiness.assess(inputs { $0.filename = "tape7.dv" })
        #expect(none.date == .undated)
        let rejected = ArchiveReadiness.assess(inputs { $0.inferredRecordDate = utc(2005, 3, 9); $0.inferredDateConfidence = 0.3; $0.filename = "tape7.dv" })
        #expect(rejected.date == .lowConfidence)
        #expect(rejected.warnings.contains { $0.hasPrefix("Date is a low-confidence guess — filed as undated") })
    }
}

// MARK: - Scale

@Suite("Record date resolver — scale")
struct RecordDateResolverScaleTests {

    @Test("100k synthetic records resolve well inside budget (< 3 s; the filename scanner is the hot path)", .timeLimit(.minutes(1)))
    func hundredThousand() {
        let names = ["Rick-and-Matt-Podcast-11-19-2005.m4v", "Westford_1994-1995.mkv", "Christmas1995Etc.mkv",
                     "RickGuitar2025.mov", "IMG_1995.MOV", "tape7.dv", "Vacation 2003-07-04 beach.mov",
                     "clip_1994.mov", "June 1994 cookout.dv", "Reunion 20051119.mov"]
        let embedded: [Date?] = [nil, utc(2025, 6, 15), nil, utc(2010, 5, 3), nil]
        let start = Date()
        var buckets: [RecordDateResolution.Source: Int] = [:]
        for i in 0..<100_000 {
            let r = RecordDateResolver.resolve(userDate: i % 7 == 0 ? "1992" : nil,
                                               embeddedCreationDate: embedded[i % embedded.count],
                                               originMake: i % 3 == 0 ? "Apple" : nil,
                                               inferredRecordDate: i % 11 == 0 ? utc(2005, 3, 9) : nil,
                                               inferredDateConfidence: i % 22 == 0 ? 0.9 : 0.4,
                                               filename: names[i % names.count], now: testNow)
            buckets[r.source, default: 0] += 1
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 3.0, "100k resolves took \(elapsed)s")
        #expect((buckets[.embedded] ?? 0) > 30_000)
        #expect((buckets[.filename] ?? 0) > 10_000)
        #expect((buckets[.userDate] ?? 0) > 5_000)
    }
}
