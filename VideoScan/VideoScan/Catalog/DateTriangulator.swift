// DateTriangulator.swift
// GH #201 (Rick 2026-09-26): the inferred date is a machine GUESSTIMATE
// that COMBINES criteria and shows a WRITTEN reason; Rick confirms.
//
// Two live cases drove this:
//   * CapeCod_notsure_NTSC.mov — the Date column showed 2008-10-23, the
//     Final Cut EXPORT stamp (make "Apple", no model), while the transcript
//     says "Say what year it is. 2004. How old are you? Eight" three times.
//   * TimmyBaby-1996/Media/Clip 19 (DV) — inferred 1955 from "I think it
//     was 1955 or 6 and it was On the Waterfront, Marlon Brando": a
//     REFERENCED year, not "now"; and DV cannot predate 1995.
//
// Every criterion becomes a CLAIM (the years it allows, a weight, a
// sentence). Agreement raises confidence (noisy-OR: two independent
// 0.65s ≈ 0.88); disagreement lowers it and WIDENS the range; constraints
// (an export stamp is a ceiling, a media-era floor, the family's catalog
// priors) prune claims and are written into the reason. The output is a
// point date (what every existing reader sorts and files by), a year span
// when only the year is known, a 0–1 confidence and the reason.
//
// Criteria and weights (docs/guides/date_inference_catchup_and_propagation.md
// §GH #201 lists the same table):
//   on-screen burn-in date   0.95 ≥3 frames · 0.85 2 frames · 0.75 1 frame   (day)
//   camera stamp             0.90 — a MODEL or an action-camera maker         (day)
//   spoken NOW-cue year      0.65, +0.05 per repeat (cap 0.75)               (year)
//   spoken year, no cue      0.45, +0.05 per repeat (cap 0.55)               (year)
//   caption year (VLM)       0.45                                             (year)
//   age + birth year         0.60 one named person · 0.30 any known person    (2-year window)
//   folder year hint         0.55 — beside other content; alone only in a dossier pass
//   spoken REFERENCE year    0    — logged in the reason, never dates the tape
//   export stamp             ceiling — a claim after the export is doubtful (×0.25)
//   media-era floor          DV ≥ 1995 · HDV ≥ 2003 · AVCHD/phone ≥ 2006 — claims below are set aside
//   catalog priors           1950s/1970s need ≥ 2 criteria at ≥ 0.90; 1940s/1960s ×0.85;
//                            a lone soft claim outside 1984–2016 ×0.5
// A camera stamp alone is NOT an inference (the resolver already ranks it);
// the triangulator answers only when some CONTENT criterion spoke.
// A softer claim (a folder year, a cue-less mention) never pulls a harder
// one (a burn-in, a camera stamp) down — it is only written into the reason.
//
// PURE and nonisolated: values in, value out, no clock unless injected.
// Nonisolated means it CAN run off the main actor — but today both callers
// (applyDossier, one record at a time, and catchUpInferredDates, the load /
// writeback pass) call it SYNCHRONOUSLY ON THE MAIN ACTOR. Never from a view
// body. Cost: one regex pass per text channel plus a few short-window
// regexes per year mention — ~0.2 ms for a 3 kB transcript (Debug); the SCALE test
// pins 100k realistic records inside a load-aware budget. If a load-time
// re-triangulation of thousands of rows ever shows as a beachball, move
// the pure calls to a detached task (the inputs are Sendable values). Regexes are compiled once
// (`nonisolated(unsafe) static let` — NSRegularExpression is immutable
// and documented thread-safe; ≈ a `static const std::regex`).
//
// (For Rick: `struct` claims + a free function ≈ PODs through a pure
// C function; `[ClosedRange<Int>]` ≈ a vector of {lo, hi} pairs; the
// private `DateTriangulation` builder below ≈ a stack-local context object
// whose methods each add one criterion — split that way so no one
// function is a 60-branch wall.)

import Foundation
import VideoScanCore

// MARK: - Inputs

/// A person the People tab knows a birth year for.
struct DateTriangulationPerson: Equatable, Sendable {
    var name: String
    var aliases: [String]
    var birthYear: Int
}

/// Everything the triangulator reads, lifted off a record as plain values.
struct DateTriangulationInput: Equatable, Sendable {
    var ocrDateCandidates: [String] = []
    var audioTranscript: String?
    var sceneCaptionTexts: [String] = []
    /// Directory-year hints, deepest first (`pfPathYearHints`).
    var pathYearHints: [Int] = []
    /// A folder year is a CORROBORATOR: it claims only beside some other
    /// content signal (a burn-in, a spoken or captioned year — even a
    /// referenced one — or an age). The dossier pass sets this true: a
    /// VLM + Whisper pass that found nothing better is itself evidence,
    /// and there the folder year stands alone (the old 0.50 tier).
    var pathHintStandsAlone: Bool = false
    var embeddedCreationDate: Date?
    var originMake: String?
    var originModel: String?
    var originEncoder: String?
    var videoCodec: String = ""
    var container: String = ""
    var fullPath: String = ""
    /// People tagged / detected on the record — the age subject when the
    /// transcript names nobody near the age.
    var peopleOnRecord: [String] = []
    /// The People tab's birth years. Empty ⇒ ages are neutral (isolation).
    var people: [DateTriangulationPerson] = []
    var now: Date = Date()
}

// MARK: - Claims

/// One criterion's vote: the years it allows, how much it counts, and the
/// sentence the reason shows.
struct DateCriterionClaim: Equatable, Sendable {
    enum Kind: String, Sendable {
        case ocrBurnIn, cameraStamp, spokenNow, spokenNeutral, captionYear, age, pathHint
        case spokenReference, exportStamp, eraFloor, prior
    }
    var kind: Kind
    /// The years this criterion allows: one year, a tape run, or one
    /// two-year window per candidate person for an age.
    var spans: [ClosedRange<Int>]
    /// Day-precise anchor when the criterion knows the day.
    var day: Date?
    /// 0 = logged in the reason, never counted.
    var weight: Float
    var reason: String

    func contains(_ year: Int) -> Bool { spans.contains { $0.contains(year) } }
    var lowestYear: Int? { spans.map(\.lowerBound).min() }
    var highestYear: Int? { spans.map(\.upperBound).max() }

    /// How HARD a claim is: a burn-in / camera stamp 3, a spoken now-cue or
    /// a named person's age 2, everything else 1.
    var hardness: Int {
        switch kind {
        case .ocrBurnIn, .cameraStamp: return 3
        case .spokenNow: return 2
        case .age: return weight >= DateTriangulationWeights.ageNamedPerson ? 2 : 1
        default: return 1
        }
    }
}

/// The triangulator's answer.
struct DateTriangulationResult: Equatable, Sendable {
    var date: Date?
    var range: InferredDateRange?
    var confidence: Float
    var reason: String
    var claims: [DateCriterionClaim]
    var precision: RecordDateResolution.Precision

    static let noEvidenceReason = "no evidence"

    static func noEvidence(_ notes: [String] = [], claims: [DateCriterionClaim] = []) -> DateTriangulationResult {
        DateTriangulationResult(date: nil, range: nil, confidence: 0,
                                reason: ([noEvidenceReason] + notes).joined(separator: "; "),
                                claims: claims, precision: .unknown)
    }
}

// MARK: - Weights and priors

enum DateTriangulationWeights {
    static let ocrConsensus: Float = 0.95      // ≥ 3 frames agree
    static let ocrTwoFrames: Float = 0.85
    static let ocrOneFrame: Float = 0.75
    static let cameraStamp: Float = 0.90
    static let spokenNow: Float = 0.65
    static let spokenNowCap: Float = 0.75
    static let spokenNeutral: Float = 0.45
    static let spokenNeutralCap: Float = 0.55
    static let repeatBonus: Float = 0.05       // per extra mention of the same year
    static let captionYear: Float = 0.45
    static let ageNamedPerson: Float = 0.60
    static let ageAnyPerson: Float = 0.30
    static let pathHint: Float = 0.55
    /// A claim that puts the footage AFTER its export stamp.
    static let afterExportFactor: Float = 0.25
    /// A lone soft claim outside the family's video window.
    static let outsideWindowFactor: Float = 0.5
    /// confidence *= 1 − factor × (strongest disagreeing weight).
    static let conflictFactor: Float = 0.5
    static let sparseDecadeFactor: Float = 0.85
    static let cap: Float = 0.95
}

/// Rick's catalog priors (GH #201): few 1940s films, no 1950s video, few
/// 1960s, no 1970s, the bulk 1984 → present; post-2016 is phones and
/// Canon with clear stamps.
enum DateCatalogPriors {
    static let videoWindow: ClosedRange<Int> = 1984...2016
    /// Decade starts with NO family video: a date there needs two
    /// independent criteria agreeing at ≥ 0.90.
    static let emptyDecades: Set<Int> = [1950, 1970]
    static let emptyDecadeConfidence: Float = 0.90
    static let emptyDecadeCriteria = 2
    /// Decade starts with only a few reels: confidence is shaded.
    static let sparseDecades: Set<Int> = [1940, 1960]
}

// MARK: - Media-era floors

struct MediaEraFloor: Equatable, Sendable {
    var year: Int
    var label: String
}

/// The earliest year a file in this format can have been RECORDED. DV
/// tape ≥ 1995, HDV ≥ 2003, AVCHD / phone H.264 ≥ 2006 — only when a
/// camera is named, since an H.264 EXPORT can hold anything. Film scans
/// (16mm / Super 8 / "film" / "reel" in the path) are exempt. nil = no floor.
nonisolated func pfMediaEraFloor(videoCodec: String, container: String,
                                 originMake: String?, originModel: String?,
                                 fullPath: String) -> MediaEraFloor? {
    let path = fullPath.lowercased()
    for token in ["16mm", "super8", "super 8", "film", "reel"] where path.contains(token) { return nil }
    let codec = videoCodec.lowercased()
    let cont = container.lowercased()
    if codec == "dvvideo" { return MediaEraFloor(year: 1995, label: "DV") }
    if codec == "mpeg2video",
       cont.contains("mpegts") || path.hasSuffix(".m2t") || path.hasSuffix(".m2ts") || path.hasSuffix(".mts") {
        return MediaEraFloor(year: 2003, label: "HDV")
    }
    if codec == "h264" || codec == "hevc",
       RecordDateResolver.namesDevice(originMake: originMake, originModel: originModel) {
        return MediaEraFloor(year: 2006, label: "AVCHD / phone")
    }
    return nil
}

// MARK: - Spoken years: NOW-cue vs reference

enum SpokenYearRole: String, Sendable {
    /// "What year is it? 2004", "Christmas 2002", "happy new year 2000".
    case now
    /// "back in 1962", "it was 1955 or 6", "born in 1929", "the film…".
    case reference
    /// A bare year with no cue either way.
    case neutral
}

struct SpokenYearMention: Equatable, Sendable {
    var year: Int
    var role: SpokenYearRole
    /// The words around the year, for the reason ("what year it is… 2004").
    var cue: String
}

/// Compiled once. NSRegularExpression is immutable and thread-safe.
enum DateTriangulationRegex {
    nonisolated(unsafe) static let year = try? NSRegularExpression(
        pattern: #"(?<!\d)(?:((?:19|20)\d{2})|['’](\d{2}))(?!\d)"#)

    // NOW cues, tested against the (lower-cased) text BEFORE the year.
    /// Occasion words a year can hang off ("Christmas 2002", "Cape 2004").
    static let occasions = #"christmas|xmas|new year'?s?(?: eve| day)?|thanksgiving|easter|halloween|fourth of july|4th of july|summer|winter|spring|fall|autumn|vacation|birthday|wedding|graduation|reunion|cape(?: cod)?"#

    // NOW cues, tested against the (lower-cased) text BEFORE the year.
    // Every cue starts at a word boundary (QA M3: "escape" is not "cape").
    nonisolated(unsafe) static let nowBefore: [NSRegularExpression] = [
        #"\bwhat year (?:is it|it is|are we in|is this|is it now)\b.{0,40}$"#,
        #"\b(?:the year is|it'?s|it is|this is|today is|today'?s|we'?re in|we are in|welcome to|here we are in|now it'?s|the date is|it'?s now|it is now)[\s,:'"“”]*(?:the year\s*)?$"#,
        #"\b(?:"# + occasions + #")[\s,:'"]*(?:of\s*)?$"#,
        #"\bhappy new year[\s,!]*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // NOW cues in the text AFTER the year ("2004 Cape trip"). "now" is NOT
    // one: "that was 1975, now he's all grown up" contrasts then with now.
    nonisolated(unsafe) static let nowAfter: [NSRegularExpression] = [
        #"^[\s,:'"]*(?:cape|trip|vacation|christmas|thanksgiving|summer|winter|reunion|birthday|wedding|graduation|here)\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // STRONG reference cues ("the class of 1982 reunion": the reunion is
    // now, 1982 is not), including reminiscences about an occasion:
    // "remember Christmas 1985", "ever since Thanksgiving '98".
    nonisolated(unsafe) static let strongReferenceBefore: [NSRegularExpression] = [
        #"\b(?:back in|born in|was born|born|class of|the movie|the film|the song)[\s,:'"]*$"#,
        #"\b(?:remember|since|until|till|before|after)\s+(?:the\s+|that\s+|our\s+|last\s+|when\s+)?(?:"# + occasions + #")[\s,:'"]*(?:of\s*)?$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    // REFERENCE cues (past tense, "ago", "since"…). The second pattern
    // reads a past-tense verb earlier in the clause with "in" right before
    // the year: "Dad was in Korea in 1951".
    nonisolated(unsafe) static let referenceBefore: [NSRegularExpression] = [
        #"\b(?:was|were|had|did|since|until|till|before|after|around|about|circa|remember|used to|when i was|way back|in the year|the summer of|the winter of|the spring of|the fall of)[\s,:'"]*(?:the year\s*)?(?:in\s*)?$"#,
        #"\b(?:was|were|had|did|went|moved|lived|married|died|served|graduated)\b[^.!?]{0,40}\bin[\s,:'"]*$"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    nonisolated(unsafe) static let referenceAfter: [NSRegularExpression] = [
        #"^\s*or\s+(?:['’]?\d{1,2}|\d{4})\b"#,          // "1955 or 6"
        #"^[\s,]*(?:years? ago|ago)\b"#,
        #"^['’"]?\s*(?:was|were|had been)\b"#,         // "our wedding 1979 was the best day"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static let numberWords = "one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety"
    static let numberToken = #"(\d{1,2}|(?:"# + numberWords + #")(?:[- ](?:one|two|three|four|five|six|seven|eight|nine))?)"#

    // Ages, tested against the lower-cased text.
    nonisolated(unsafe) static let ages: [NSRegularExpression] = [
        #"how old (?:are you|is (?:he|she|[a-z]+))\W{0,3}(?:i'?m |i am |he'?s |she'?s |is |she is |he is )?"# + numberToken + #"\b"#,
        #"\b"# + numberToken + #"[- ]years?[- ]old\b"#,
        #"\b"# + numberToken + #"(?:st|nd|rd|th) birthday\b"#,
        #"\b(?:turned|turning|just turned)\s+"# + numberToken + #"\b"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Cheap pre-check so the four age regexes run only when they can hit.
    static let ageTriggers = ["old", "birthday", "turned", "turning"]

    nonisolated(unsafe) static let directoryYear = try? NSRegularExpression(
        pattern: #"(?<!\d)((?:19|20)\d{2})(?!\d)"#)
}

/// Every plausible year in `text`, each classified NOW / reference /
/// neutral by the words around it. Same year grammar as `pfYearMentions`
/// (bounded 19xx/20xx, camcorder apostrophe years), same future ceiling.
nonisolated func pfClassifyYearMentions(in text: String, now: Date = Date()) -> [SpokenYearMention] {
    guard !text.isEmpty, let regex = DateTriangulationRegex.year else { return [] }
    var utcCal = Calendar(identifier: .gregorian)
    utcCal.timeZone = TimeZone(identifier: "UTC") ?? .current
    let maxYear = utcCal.component(.year, from: now) + 1
    let ns = text as NSString
    var out: [SpokenYearMention] = []
    for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
        let year: Int
        if m.range(at: 1).location != NSNotFound, let y = Int(ns.substring(with: m.range(at: 1))) {
            year = y
        } else if m.range(at: 2).location != NSNotFound, let yy = Int(ns.substring(with: m.range(at: 2))) {
            year = pfExpandTwoDigitYear(yy)
        } else { continue }
        guard year >= 1900, year <= maxYear else { continue }
        let beforeStart = max(0, m.range.location - 60)
        let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart)).lowercased()
        let afterEnd = min(ns.length, m.range.location + m.range.length + 30)
        let after = ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                               length: afterEnd - (m.range.location + m.range.length))).lowercased()
        let role = pfSpokenYearRole(before: before, after: after)
        out.append(SpokenYearMention(year: year, role: role, cue: pfCueSnippet(before: before, year: year)))
    }
    return out
}

/// Reference cues win over NOW cues (QA M3): a reminiscence ("remember
/// Christmas 1985", "the summer of 1994 was hot", "that was 1975, now…")
/// must never date the tape, and a missed now-cue only costs weight while
/// a false one files a wrong year. Then NOW cues; neither ⇒ neutral.
/// Pure over the two windows.
nonisolated func pfSpokenYearRole(before: String, after: String) -> SpokenYearRole {
    func hit(_ regexes: [NSRegularExpression], _ s: String) -> Bool {
        let r = NSRange(location: 0, length: (s as NSString).length)
        return regexes.contains { $0.firstMatch(in: s, range: r) != nil }
    }
    if hit(DateTriangulationRegex.strongReferenceBefore, before)
        || hit(DateTriangulationRegex.referenceBefore, before)
        || hit(DateTriangulationRegex.referenceAfter, after) { return .reference }
    if hit(DateTriangulationRegex.nowBefore, before) || hit(DateTriangulationRegex.nowAfter, after) { return .now }
    return .neutral
}

/// "what year it is… 2004" — the last few words before the year, for the reason.
nonisolated func pfCueSnippet(before: String, year: Int) -> String {
    let words = before.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        .suffix(4)
        .map { $0.trimmingCharacters(in: .punctuationCharacters) }
        .filter { !$0.isEmpty }
    return words.isEmpty ? String(year) : words.joined(separator: " ") + "… \(year)"
}

// MARK: - Ages

struct SpokenAgeMention: Equatable, Sendable {
    var age: Int
    /// The People-tab name found near the mention, if any.
    var subject: String?
}

/// "How old are you? Eight", "8 years old", "5th birthday", "turned six".
/// `names` are the People tab's names + aliases; the closest one within
/// 80 characters before / 30 after becomes the subject.
nonisolated func pfAgeMentions(in text: String, names: [String]) -> [SpokenAgeMention] {
    guard !text.isEmpty else { return [] }
    let lower = text.lowercased()
    guard DateTriangulationRegex.ageTriggers.contains(where: { lower.contains($0) }) else { return [] }
    let ns = lower as NSString
    let full = NSRange(location: 0, length: ns.length)
    var seen = Set<Int>()   // the NUMBER's location, so overlapping patterns count once
    var out: [SpokenAgeMention] = []
    for regex in DateTriangulationRegex.ages {
        for m in regex.matches(in: lower, range: full) {
            guard m.numberOfRanges >= 2, m.range(at: 1).location != NSNotFound else { continue }
            let token = ns.substring(with: m.range(at: 1))
            guard let age = pfAgeNumber(token), age >= 1, age <= 99 else { continue }
            // "How old are you? Eight years old" hits two patterns on the
            // same number — count the NUMBER once.
            guard seen.insert(m.range(at: 1).location).inserted else { continue }
            let beforeStart = max(0, m.range.location - 80)
            let before = ns.substring(with: NSRange(location: beforeStart, length: m.range.location - beforeStart))
            let afterEnd = min(ns.length, m.range.location + m.range.length + 30)
            let after = ns.substring(with: NSRange(location: m.range.location + m.range.length,
                                                   length: afterEnd - (m.range.location + m.range.length)))
            out.append(SpokenAgeMention(age: age, subject: pfNearestName(names, before: before, after: after)))
        }
    }
    return out
}

/// "8" → 8, "eight" → 8, "twenty-one" → 21.
nonisolated func pfAgeNumber(_ token: String) -> Int? {
    if let n = Int(token) { return n }
    let small: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15,
        "sixteen": 16, "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]
    let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]
    let parts = token.split(whereSeparator: { $0 == "-" || $0 == " " }).map(String.init)
    guard let first = parts.first else { return nil }
    if parts.count == 1 { return small[first] ?? tens[first] }
    guard let t = tens[first], let u = small[parts[1]], u < 10 else { return nil }
    return t + u
}

/// The name nearest the mention (closest before wins over after).
/// Whole-word, case-insensitive.
nonisolated func pfNearestName(_ names: [String], before: String, after: String) -> String? {
    var best: (name: String, distance: Int)?
    for name in names {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        guard n.count >= 2 else { continue }
        var distance: Int?
        if let r = pfLastWholeWord(n, in: before) {
            distance = before.count - r
        } else if let r = pfFirstWholeWord(n, in: after) {
            distance = before.count + r + 1_000   // after the mention counts as farther
        }
        if let distance, best.map({ distance < $0.distance }) ?? true { best = (name, distance) }
    }
    return best?.name
}

/// Offset (in characters) of the END of the last whole-word occurrence, or nil.
nonisolated func pfLastWholeWord(_ word: String, in text: String) -> Int? {
    var last: Int?
    var search = text.startIndex
    while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
        let beforeOK = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
        let afterOK = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
        if beforeOK && afterOK { last = text.distance(from: text.startIndex, to: r.upperBound) }
        search = r.upperBound
    }
    return last
}

/// Offset of the START of the first whole-word occurrence, or nil.
nonisolated func pfFirstWholeWord(_ word: String, in text: String) -> Int? {
    var search = text.startIndex
    while let r = text.range(of: word, options: [.caseInsensitive], range: search..<text.endIndex) {
        let beforeOK = r.lowerBound == text.startIndex || !text[text.index(before: r.lowerBound)].isLetter
        let afterOK = r.upperBound == text.endIndex || !text[r.upperBound].isLetter
        if beforeOK && afterOK { return text.distance(from: text.startIndex, to: r.lowerBound) }
        search = r.upperBound
    }
    return nil
}

// MARK: - The triangulator

nonisolated func pfTriangulateRecordDate(_ input: DateTriangulationInput) -> DateTriangulationResult {
    var t = DateTriangulation(input: input)
    t.collectBurnIns()
    t.collectSpokenYears()
    t.collectCaptionYears()
    t.collectAges()
    t.collectFolderHint()
    t.collectStamp()
    guard t.hasContent else { return t.noEvidence() }
    t.applyExportCeiling()
    t.applyEraFloor()
    t.applyWindowPrior()
    return t.combine()
}

/// The working state of one triangulation: the claims collected so far,
/// the notes for the reason, and the facts the constraint steps read.
private struct DateTriangulation {
    let input: DateTriangulationInput
    let utcCal: Calendar
    let nowYear: Int
    var claims: [DateCriterionClaim] = []
    /// Reason lines for things that are not claims.
    var notes: [String] = []
    var parsedOcr: [Date] = []
    var mentions: [SpokenYearMention] = []
    var captionYearCount = 0
    var exportYear: Int?

    typealias W = DateTriangulationWeights

    init(input: DateTriangulationInput) {
        self.input = input
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        utcCal = cal
        nowYear = cal.component(.year, from: input.now)
    }

    static let contentKinds: Set<DateCriterionClaim.Kind> = [
        .ocrBurnIn, .spokenNow, .spokenNeutral, .captionYear, .age, .pathHint,
    ]

    /// A stamp alone is the resolver's business, not an inference.
    var hasContent: Bool {
        claims.contains { Self.contentKinds.contains($0.kind) && $0.weight > 0 }
    }

    var referenceLines: [String] { claims.filter { $0.kind == .spokenReference }.map(\.reason) }

    func noEvidence(_ extra: [String] = []) -> DateTriangulationResult {
        .noEvidence(extra + notes + referenceLines, claims: claims)
    }

    // ---- 1. On-screen burn-ins (day precision). Majority day wins; a
    //         second, different day is a weaker claim of its own.
    mutating func collectBurnIns() {
        parsedOcr = input.ocrDateCandidates.compactMap(pfParseOcrDate(_:))
        guard !parsedOcr.isEmpty else { return }
        let cal = utcCal
        let bucketed = Dictionary(grouping: parsedOcr) { d -> Date in
            var dc = cal.dateComponents([.year, .month, .day], from: d)
            dc.hour = 12; dc.timeZone = TimeZone(identifier: "UTC")
            return cal.date(from: dc) ?? d
        }
        let ordered = bucketed.sorted { a, b in
            a.value.count != b.value.count ? a.value.count > b.value.count : a.key < b.key
        }
        for (index, (day, hits)) in ordered.enumerated() {
            let weight: Float
            switch (index, hits.count) {
            case (0, 3...): weight = W.ocrConsensus
            case (0, 2):    weight = W.ocrTwoFrames
            default:        weight = W.ocrOneFrame
            }
            let y = utcCal.component(.year, from: day)
            claims.append(DateCriterionClaim(
                kind: .ocrBurnIn, spans: [y...y], day: day, weight: weight,
                reason: "on-screen date \(pfIsoDay(day, utcCal)) ×\(hits.count)"))
        }
    }

    // ---- 2. Spoken years: NOW-cues date the tape, references are logged,
    //         bare mentions count a little.
    mutating func collectSpokenYears() {
        mentions = pfClassifyYearMentions(in: input.audioTranscript ?? "", now: input.now)
        var nowCounts: [Int: (count: Int, cue: String)] = [:]
        var neutralCounts: [Int: Int] = [:]
        var referenceYears: [Int] = []
        for m in mentions {
            switch m.role {
            case .now:
                var e = nowCounts[m.year] ?? (0, m.cue)
                e.count += 1
                nowCounts[m.year] = e
            case .neutral:
                neutralCounts[m.year, default: 0] += 1
            case .reference:
                if !referenceYears.contains(m.year) { referenceYears.append(m.year) }
            }
        }
        for (year, e) in nowCounts.sorted(by: { $0.key < $1.key }) {
            let weight = min(W.spokenNowCap, W.spokenNow + Float(e.count - 1) * W.repeatBonus)
            claims.append(DateCriterionClaim(
                kind: .spokenNow, spans: [year...year], day: nil, weight: weight,
                reason: "spoken now-cue '\(e.cue)'" + (e.count > 1 ? " ×\(e.count)" : "")))
        }
        for (year, count) in neutralCounts.sorted(by: { $0.key < $1.key }) where nowCounts[year] == nil {
            let weight = min(W.spokenNeutralCap, W.spokenNeutral + Float(count - 1) * W.repeatBonus)
            claims.append(DateCriterionClaim(
                kind: .spokenNeutral, spans: [year...year], day: nil, weight: weight,
                reason: "\(year) mentioned in speech" + (count > 1 ? " ×\(count)" : "") + " (no cue)"))
        }
        for year in referenceYears where nowCounts[year] == nil {
            claims.append(DateCriterionClaim(
                kind: .spokenReference, spans: [year...year], day: nil, weight: 0,
                reason: "\(year) mentioned as a reference (past), not the recording year"))
        }
    }

    // ---- 3. Caption years (the VLM read a calendar, a banner…).
    mutating func collectCaptionYears() {
        var captionYears: [Int: Int] = [:]
        for text in input.sceneCaptionTexts {
            for y in pfYearMentions(in: text, now: input.now) { captionYears[y, default: 0] += 1 }
        }
        captionYearCount = captionYears.count
        for (year, count) in captionYears.sorted(by: { $0.key < $1.key }) {
            claims.append(DateCriterionClaim(
                kind: .captionYear, spans: [year...year], day: nil, weight: W.captionYear,
                reason: "caption mentions \(year)" + (count > 1 ? " ×\(count)" : "")))
        }
    }

    // ---- 4. Ages + People-tab birth years. Isolation: no people ⇒ neutral.
    mutating func collectAges() {
        guard !input.people.isEmpty else { return }
        let names = input.people.flatMap { [$0.name] + $0.aliases }
        let onRecord = Set(input.peopleOnRecord.map { $0.lowercased() })
        for age in pfAgeMentions(in: input.audioTranscript ?? "", names: names) {
            let (candidates, named) = ageSubjects(for: age, onRecord: onRecord)
            let spans = candidates
                .map { ($0.birthYear + age.age)...($0.birthYear + age.age + 1) }
                .filter { $0.lowerBound <= nowYear }
            guard !spans.isEmpty else { continue }
            let who: String
            if candidates.count == 1, let p = candidates.first {
                // Named nearby, the record's one tagged person, or the
                // only birth year the People tab knows — say who.
                who = "fits \(p.name) (born \(p.birthYear))"
            } else {
                who = "fits \(candidates.count) known birth years"
            }
            let windows = spans.prefix(3).map { "\($0.lowerBound)–\($0.upperBound)" }.joined(separator: ", ")
                + (spans.count > 3 ? ", …" : "")
            claims.append(DateCriterionClaim(
                kind: .age, spans: spans, day: nil, weight: named ? W.ageNamedPerson : W.ageAnyPerson,
                reason: "age \(age.age) \(who) → \(windows)"))
        }
    }

    /// Whose age is it? The person named nearby; else the record's ONE
    /// tagged person; else everyone the People tab knows a birth year for.
    func ageSubjects(for age: SpokenAgeMention, onRecord: Set<String>) -> (people: [DateTriangulationPerson], named: Bool) {
        if let subject = age.subject, let person = input.people.first(where: { pfPersonMatches($0, subject) }) {
            return ([person], true)
        }
        let tagged = input.people.filter { p in
            onRecord.contains(p.name.lowercased()) || p.aliases.contains { onRecord.contains($0.lowercased()) }
        }
        if tagged.count == 1 { return (tagged, true) }
        return (input.people, false)
    }

    // ---- 5. Folder year hint (deepest directory first; one claim) —
    //         beside other content, or alone only in a dossier pass.
    mutating func collectFolderHint() {
        let hasOtherContent = !parsedOcr.isEmpty || !mentions.isEmpty || captionYearCount > 0
            || claims.contains { $0.kind == .age }
        guard let year = input.pathYearHints.first, year >= 1900, year <= nowYear + 1,
              hasOtherContent || input.pathHintStandsAlone else { return }
        let folder = pfDirectoryComponent(naming: year, in: input.fullPath) ?? "folder"
        claims.append(DateCriterionClaim(
            kind: .pathHint, spans: [year...year], day: nil, weight: W.pathHint,
            reason: "folder '\(folder)' names \(year)"))
    }

    // ---- 6. The container stamp: a camera's is a claim; an export's is a ceiling.
    mutating func collectStamp() {
        guard let stamp = input.embeddedCreationDate else { return }
        let y = utcCal.component(.year, from: stamp)
        if RecordDateResolver.namesDevice(originMake: input.originMake, originModel: input.originModel) {
            let origin = EmbeddedOriginTags.description(EmbeddedOriginTags.Origin(
                make: input.originMake, model: input.originModel, encoder: input.originEncoder)) ?? "camera"
            claims.append(DateCriterionClaim(
                kind: .cameraStamp, spans: [y...y], day: stamp, weight: W.cameraStamp,
                reason: "camera stamp \(pfIsoDay(stamp, utcCal)) (\(origin))"))
            return
        }
        exportYear = y
        let origin: String
        if let make = input.originMake { origin = "\(make), no model" }
        else if let enc = input.originEncoder { origin = EmbeddedOriginTags.encoderFamily(enc) }
        else { origin = "no camera named" }
        claims.append(DateCriterionClaim(
            kind: .exportStamp, spans: [y...y], day: stamp, weight: 0,
            reason: "export stamp \(pfIsoDay(stamp, utcCal)) set aside as ingest (\(origin))"))
    }

    // ---- 7a. A claim that puts the footage AFTER its export is doubtful.
    mutating func applyExportCeiling() {
        guard let exportYear else { return }
        for i in claims.indices where claims[i].weight > 0 && claims[i].kind != .cameraStamp {
            if let lo = claims[i].lowestYear, lo > exportYear {
                claims[i].weight *= W.afterExportFactor
                claims[i].reason += " (after the export stamp — doubtful)"
            }
        }
    }

    // ---- 7b. The media-era floor: claims below it are set aside.
    mutating func applyEraFloor() {
        guard let floor = pfMediaEraFloor(videoCodec: input.videoCodec, container: input.container,
                                          originMake: input.originMake, originModel: input.originModel,
                                          fullPath: input.fullPath) else { return }
        var clipped = false
        for i in claims.indices where claims[i].weight > 0 {
            let kept = claims[i].spans.compactMap { span -> ClosedRange<Int>? in
                span.upperBound < floor.year ? nil : max(span.lowerBound, floor.year)...span.upperBound
            }
            if kept.isEmpty {
                clipped = true
                notes.append("\(claims[i].reason) is below the \(floor.label) era floor (\(floor.year)) — set aside")
                claims[i].weight = 0
            } else if kept != claims[i].spans {
                clipped = true
                claims[i].spans = kept
            }
        }
        claims.append(DateCriterionClaim(
            kind: .eraFloor, spans: [floor.year...nowYear], day: nil, weight: 0,
            reason: clipped ? "\(floor.label) era floor \(floor.year) applied" : "\(floor.label) era floor \(floor.year) respected"))
    }

    // ---- 7c. A lone soft claim outside the family's video window is shaded.
    mutating func applyWindowPrior() {
        let window = DateCatalogPriors.videoWindow
        for i in claims.indices where claims[i].weight > 0 && ![.cameraStamp, .ocrBurnIn].contains(claims[i].kind) {
            if let lo = claims[i].lowestYear, let hi = claims[i].highestYear,
               hi < window.lowerBound || lo > window.upperBound {
                claims[i].weight *= W.outsideWindowFactor
            }
        }
    }

    // ---- 8–11. Score, partition, priors, date + range, reason.
    func combine() -> DateTriangulationResult {
        let voting = claims.filter { $0.weight > 0 }
        guard let best = bestYear(among: voting) else { return noEvidence() }
        let parts = partition(voting, around: best.year)

        // Cue-less years that disagree are AMBIGUOUS, not a date: "1962"
        // and "1997" with nothing around either must not date the tape
        // (the old ambiguity guard). Now-cues that disagree do produce a
        // widened range.
        let cueless: Set<DateCriterionClaim.Kind> = [.spokenNeutral, .captionYear]
        if !parts.conflicting.isEmpty,
           parts.agreeing.allSatisfy({ cueless.contains($0.kind) }),
           parts.conflicting.allSatisfy({ cueless.contains($0.kind) }) {
            let years = (parts.agreeing + parts.conflicting).compactMap(\.lowestYear).sorted()
            return noEvidence(["years \(years.map(String.init).joined(separator: ", ")) mentioned without a cue — ambiguous"])
        }

        var confidence = best.score
        if let strongest = parts.penalizing.first {
            confidence *= (1 - W.conflictFactor * strongest.weight)
        }
        var extraNotes: [String] = []
        switch applyDecadePriors(year: best.year, agreeing: parts.agreeing, confidence: &confidence) {
        case .rejected(let reason):
            return DateTriangulationResult(date: nil, range: nil, confidence: 0, reason: reason,
                                           claims: claims, precision: .unknown)
        case .shaded(let note):
            extraNotes.append(note)
        case .clear:
            break
        }
        confidence = min(W.cap, confidence)

        guard let placed = place(bestYear: best.year, parts: parts) else { return noEvidence() }
        return DateTriangulationResult(
            date: placed.date, range: placed.range, confidence: confidence,
            reason: reasonText(parts: parts, extraNotes: extraNotes),
            claims: claims, precision: placed.precision)
    }

    /// Every candidate year scored by noisy-OR over the claims allowing it;
    /// ties go to the year with more supporters, then the earlier year.
    func bestYear(among voting: [DateCriterionClaim]) -> (year: Int, score: Float)? {
        var candidateYears = Set<Int>()
        for c in voting { for s in c.spans { for y in s { candidateYears.insert(y) } } }
        var best: (year: Int, score: Float, supporters: Int)?
        for y in candidateYears.sorted() {
            var miss: Float = 1
            var supporters = 0
            for c in voting where c.contains(y) { miss *= (1 - c.weight); supporters += 1 }
            let score = 1 - miss
            let better: Bool
            if let b = best {
                better = score > b.score + 0.0001 || (abs(score - b.score) <= 0.0001 && supporters > b.supporters)
            } else {
                better = true
            }
            if better { best = (y, score, supporters) }
        }
        return best.map { ($0.year, $0.score) }
    }

    struct Partition {
        var agreeing: [DateCriterionClaim]
        /// A spoken / captioned year one off the best: the tape ran across a New Year.
        var adjacent: [DateCriterionClaim]
        var conflicting: [DateCriterionClaim]
        /// Conflicts no softer than the best evidence — the only ones that
        /// lower confidence or widen the range.
        var penalizing: [DateCriterionClaim]
    }

    func partition(_ voting: [DateCriterionClaim], around bestYear: Int) -> Partition {
        let agreeing = voting.filter { $0.contains(bestYear) }.sorted { $0.weight > $1.weight }
        let adjacentKinds: Set<DateCriterionClaim.Kind> = [.spokenNow, .spokenNeutral, .captionYear]
        let adjacent = voting.filter { c in
            !c.contains(bestYear) && adjacentKinds.contains(c.kind)
                && c.spans.contains { abs($0.lowerBound - bestYear) == 1 || abs($0.upperBound - bestYear) == 1 }
        }
        let conflicting = voting.filter { !$0.contains(bestYear) && !adjacent.contains($0) }
            .sorted { $0.weight > $1.weight }
        let topHardness = agreeing.map(\.hardness).max() ?? 1
        let penalizing = conflicting.filter { $0.hardness >= topHardness - 1 }
        return Partition(agreeing: agreeing, adjacent: adjacent, conflicting: conflicting, penalizing: penalizing)
    }

    enum PriorVerdict {
        case clear
        case shaded(String)
        case rejected(String)
    }

    /// Rick's catalog priors: no 1950s / 1970s video without two
    /// independent criteria at ≥ 0.90; 1940s / 1960s shaded.
    func applyDecadePriors(year: Int, agreeing: [DateCriterionClaim], confidence: inout Float) -> PriorVerdict {
        let decade = (year / 10) * 10
        let independentKinds = Set(agreeing.map(\.kind)).count
        if DateCatalogPriors.emptyDecades.contains(decade),
           independentKinds < DateCatalogPriors.emptyDecadeCriteria || confidence < DateCatalogPriors.emptyDecadeConfidence {
            let had = agreeing.map(\.reason).joined(separator: "; ")
            return .rejected("\(DateTriangulationResult.noEvidenceReason) strong enough: \(year) falls in the \(decade)s — this family has no \(decade)s video; needs two independent criteria agreeing at ≥ 0.90 (had: \(had))")
        }
        if DateCatalogPriors.sparseDecades.contains(decade) {
            confidence *= W.sparseDecadeFactor
            return .shaded("\(decade)s is a sparse decade for this family — shaded")
        }
        return .clear
    }

    /// The point date: the strongest agreeing day (a burn-in, a camera
    /// stamp) at day precision, else Jan 1 noon UTC of the year with the
    /// span everything that agreed allows — widened by adjacent spoken
    /// years and by penalizing disagreement.
    func place(bestYear: Int, parts: Partition) -> (date: Date, range: InferredDateRange?, precision: RecordDateResolution.Precision)? {
        if let anchor = parts.agreeing.first(where: { $0.day != nil }), let day = anchor.day {
            return (day, nil, .day)
        }
        guard let jan1 = pfJanuaryFirst(of: bestYear) else { return nil }
        var lo = bestYear, hi = bestYear
        for c in parts.agreeing {
            if let s = c.spans.first(where: { $0.contains(bestYear) }) {
                lo = max(lo, s.lowerBound); hi = min(hi, s.upperBound)
            }
        }
        if lo > hi { lo = bestYear; hi = bestYear }
        for c in parts.adjacent + parts.penalizing where c.weight >= 0.4 {
            if let l = c.lowestYear { lo = min(lo, l) }
            if let h = c.highestYear { hi = max(hi, h) }
        }
        return (jan1, InferredDateRange(startYear: lo, endYear: hi), .year)
    }

    /// Agreeing (strongest first); adjacent; the export set-aside; the era
    /// floor; conflicts; references; notes.
    func reasonText(parts: Partition, extraNotes: [String]) -> String {
        var lines = parts.agreeing.map(\.reason)
        lines += parts.adjacent.map { "\($0.reason) — adjacent year, tape may span both" }
        lines += claims.filter { $0.kind == .exportStamp }.map(\.reason)
        lines += claims.filter { $0.kind == .eraFloor }.map(\.reason)
        lines += parts.conflicting.map { "but \($0.reason) disagrees" }
        lines += referenceLines
        lines += notes + extraNotes
        return lines.joined(separator: "; ")
    }
}

// MARK: - Small helpers

nonisolated func pfIsoDay(_ d: Date, _ cal: Calendar) -> String {
    let dc = cal.dateComponents([.year, .month, .day], from: d)
    return String(format: "%04d-%02d-%02d", dc.year ?? 0, dc.month ?? 0, dc.day ?? 0)
}

nonisolated func pfPersonMatches(_ p: DateTriangulationPerson, _ name: String) -> Bool {
    let n = name.lowercased()
    return p.name.lowercased() == n || p.aliases.contains { $0.lowercased() == n }
}

/// The deepest DIRECTORY component whose text contains `year`.
nonisolated func pfDirectoryComponent(naming year: Int, in fullPath: String) -> String? {
    let directory = (fullPath as NSString).deletingLastPathComponent
    let needle = String(year)
    for component in (directory as NSString).pathComponents.reversed() where component.contains(needle) {
        return component
    }
    return nil
}
