// RelatedScore.swift
// The ladder of evidence for TWO recordings — "how are these connected?"
// (docs/design/related_score_2026_10_14.md, event_analyzer_compare_media_2026_10_15.md).
//
// Pure: the app projects what it knows about each side into `RelatedEvidence`
// (hashes, the audio match, dates, people, words, folders, archive state,
// stream facts) and `RelatedLadder.judge` answers with ONE rung, ONE band for
// the page (the colour and the word), a headline, and every line that holds,
// contradicts, differs or is a non-clue — never a blended number.
//
//   rung 6  identical copy        same whole-file SHA-256 and size
//   rung 5  same recording /      the audio match: sameRecording, or one
//           clip of               contained in the other; or, for silent
//                                 footage, the video barcode aligned
//   rung 4  recorded at the same  a short audio overlap at one offset (two
//           moment                cameras in one room); blocked by a reliable
//                                 date conflict
//   rung 3  same occasion         same reliable day and (people in common,
//                                 or the same folder label, or names said in
//                                 both); blocked by a reliable date conflict
//   rung 2  related               people in common, or the same folder label,
//                                 on a different day
//   rung 1  no connection found
//   —       not enough evidence   nothing above could be asked
//
// Bands (Rick 2026-10-15): SAME EVENT (6, 5 whole) · CLIP FROM SAME EVENT (5
// contained) · SAME EVENT, DIFFERENT CAPTURE (4, 3) · DIFFERENT EVENTS (2, 1) ·
// NOT ENOUGH EVIDENCE. Contradictions are shown, never subtracted.
//
// (For Rick: everything here is a value type; `judge` is a function of its
// argument and nothing else, so the truth table in RelatedLadderTests is the
// whole specification.)

import Foundation

// MARK: - Input

/// What a recording's codec says about its generation: an original-quality
/// capture (DV, FFV1, ProRes, uncompressed PCM) or a delivery format
/// (H.264, MPEG-2, AAC, AC-3…).
public enum CodecGeneration: String, Sendable, Equatable {
    case original, delivery, unknown
}

/// The video barcode's answer for a pair (Compare Footage), when it ran.
public enum VideoAlignment: Sendable, Equatable {
    /// The shorter file's frames sit inside the other's at `offsetSeconds`.
    case aligned(coverage: Double, offsetSeconds: Double)
    case noRunInCommon
}

public struct RelatedEvidence: Sendable, Equatable {

    /// One side of the pair, as the catalog knows it.
    public struct Side: Sendable, Equatable {
        /// Whole-file SHA-256 (lowercase), only when it covers the whole file.
        public var digest: String?
        public var sizeBytes: Int64
        public var durationSeconds: Double
        /// Seconds the fingerprint heard sound in; nil = no fingerprint yet.
        public var audibleSeconds: Double?
        /// The recording's day, and whether a person or a tape label stands
        /// behind it (a file date from a rip or a copy is not reliable).
        public var day: EventDay?
        public var dayIsReliable: Bool
        /// People a person confirmed in the recording.
        public var people: Set<String>
        /// Names heard in the transcript.
        public var namesSaid: Set<String>
        /// Scene / occasion words (captions, transcript phrases): "cake", "happy birthday".
        public var occasionWords: Set<String>
        /// The folder's event label, lowercased ("timmy 10th bday"), when one exists.
        public var folderLabel: String?
        /// This file IS the archive's (promoted copy, inside the root).
        public var isArchiveFile: Bool
        /// The archive holds this content (this file, or an identical one).
        public var isArchived: Bool
        public var codec: CodecGeneration
        public var frameHeight: Int?
        public var bitRate: Int64?
        /// Whether the file is at its path right now (nil = not asked, e.g.
        /// its drive is not connected). The catalog's hashes describe what
        /// WAS there; a gone file gets no verdict (Rick 2026-10-15: the
        /// staging copy had been gone eleven days and the band said "byte
        /// for byte").
        public var isOnDisk: Bool?

        public init(digest: String? = nil, sizeBytes: Int64 = 0, durationSeconds: Double = 0,
                    audibleSeconds: Double? = nil, day: EventDay? = nil, dayIsReliable: Bool = false,
                    people: Set<String> = [], namesSaid: Set<String> = [], occasionWords: Set<String> = [],
                    folderLabel: String? = nil, isArchiveFile: Bool = false, isArchived: Bool = false,
                    codec: CodecGeneration = .unknown, frameHeight: Int? = nil, bitRate: Int64? = nil,
                    isOnDisk: Bool? = nil) {
            self.digest = digest.map { $0.lowercased() }
            self.sizeBytes = sizeBytes
            self.durationSeconds = durationSeconds
            self.audibleSeconds = audibleSeconds
            self.day = day
            self.dayIsReliable = dayIsReliable
            self.people = people
            self.namesSaid = namesSaid
            self.occasionWords = occasionWords
            self.folderLabel = folderLabel?.lowercased()
            self.isArchiveFile = isArchiveFile
            self.isArchived = isArchived
            self.codec = codec
            self.frameHeight = frameHeight
            self.bitRate = bitRate
            self.isOnDisk = isOnDisk
        }

        public var hasFingerprint: Bool { audibleSeconds != nil }
        public var isSilent: Bool { (audibleSeconds ?? 0) <= 0 && hasFingerprint }
        public var year: Int? { day?.year }
    }

    public var a: Side
    public var b: Side
    /// The audio matcher's answer with `a` as the query and `b` as the
    /// master; nil = not compared (a side has no fingerprint).
    public var audio: AudioMatchVerdict?
    /// The matcher's coverage of the query's audible seconds (0…1).
    public var audioCoverage: Double?
    /// The video barcode's answer, when Compare Footage ran.
    public var video: VideoAlignment?

    public init(a: Side, b: Side, audio: AudioMatchVerdict? = nil, audioCoverage: Double? = nil,
                video: VideoAlignment? = nil) {
        self.a = a
        self.b = b
        self.audio = audio
        self.audioCoverage = audioCoverage
        self.video = video
    }
}

// MARK: - Output

public enum RelatedRung: Int, Sendable, Comparable {
    case none = 1, related, sameOccasion, sameMoment, sameRecording, identicalCopy
    public static func < (l: RelatedRung, r: RelatedRung) -> Bool { l.rawValue < r.rawValue }
}

/// Which side a band or a recommendation points at.
public enum PairSide: Sendable, Equatable { case a, b }

/// The page's band: the word and the colour (Rick 2026-10-15).
public enum RelatedBand: Sendable, Equatable {
    /// Medium green: identical copy, or the same recording whole.
    case sameEvent
    /// Light green: `clip` is cut from the other at `offsetSeconds`, `seconds` long.
    case clipFromSameEvent(clip: PairSide, seconds: Double, offsetSeconds: Double)
    /// Yellow: one occasion, different footage; `sharedSeconds` of common sound (0 for rung 3).
    case differentCapture(sharedSeconds: Double)
    /// Red.
    case differentEvents
    /// Grey.
    case notEnoughEvidence

    public var word: String {
        switch self {
        case .sameEvent: return "Same event"
        case .clipFromSameEvent: return "Clip from same event"
        case .differentCapture: return "Same event · different capture"
        case .differentEvents: return "Different events"
        case .notEnoughEvidence: return "Not enough evidence"
        }
    }
}

/// One line of evidence, in words, with what it does to the verdict.
public struct RelatedLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Holds the rung up.
        case supports
        /// Argues against it — shown, never subtracted.
        case contradicts
        /// A difference that is not a verdict (bytes, codecs, sizes).
        case differs
        /// Looks like a clue and is not ("happy birthday" in both).
        case nonClue
        /// Something the catalog does not have yet.
        case missing
    }
    public var kind: Kind
    public var words: String
    public init(_ kind: Kind, _ words: String) {
        self.kind = kind
        self.words = words
    }
}

/// Which of two transfers of ONE recording is the better keep.
public enum BetterTransfer: Sendable, Equatable {
    case a(why: String), b(why: String), tie
    public var side: PairSide? {
        switch self {
        case .a: return .a
        case .b: return .b
        case .tie: return nil
        }
    }
}

public struct RelatedVerdict: Sendable, Equatable {
    public var rung: RelatedRung?
    public var band: RelatedBand
    public var headline: String
    public var lines: [RelatedLine]
    /// Rung 5 only: the better transfer, by the ordered list.
    public var better: BetterTransfer?
    public var isIdenticalCopy: Bool { rung == .identicalCopy }
}

// MARK: - The ladder

public enum RelatedLadder {

    /// Rung 4 needs at least this much shared sound.
    public static let minSharedSeconds: Double = 5
    /// Two reliable days this far apart or less are "the same day" (an
    /// occasion that ran past midnight; a date written the morning after).
    public static let sameDayToleranceDays = 1

    /// The ladder, top rung first: each step answers or adds its lines and
    /// passes the pair down. A file that is not on disk gets no verdict at
    /// all: the catalog's hashes and fingerprints describe a file that was
    /// there, and nothing can be verified against one that is not.
    public static func judge(_ e: RelatedEvidence) -> RelatedVerdict {
        var lines: [RelatedLine] = []
        if let v = notOnDisk(e, into: &lines) { return v }
        let dates = dateRelation(e, into: &lines)
        if let v = identicalCopy(e, into: &lines) { return v }
        if let v = whatTheSoundSays(e, dates: dates, into: &lines) { return v }
        if let v = whatTheFramesSay(e, into: &lines) { return v }
        return calendarAndPeople(e, dates: dates, into: &lines)
    }

    // MARK: Before the ladder — is the file there?

    static func notOnDisk(_ e: RelatedEvidence, into lines: inout [RelatedLine]) -> RelatedVerdict? {
        let goneA = e.a.isOnDisk == false, goneB = e.b.isOnDisk == false
        guard goneA || goneB else { return nil }
        let which = goneA && goneB ? "Neither file is" : goneA ? "The first file is not" : "The second file is not"
        lines.append(.init(.missing, "\(which) at its path — the catalog row points at nothing. Rescan the drive."))
        if let da = e.a.digest, let db = e.b.digest, da == db, e.a.sizeBytes == e.b.sizeBytes {
            lines.append(.init(.nonClue, "The catalog's stored SHA-256s match (\(short(da))) — what WAS there, not what is."))
        }
        return RelatedVerdict(rung: nil, band: .notEnoughEvidence,
                              headline: goneA && goneB ? "Neither file is on disk." : "One file is not on disk — nothing can be verified.",
                              lines: lines, better: nil)
    }

    // MARK: Rung 6

    static func identicalCopy(_ e: RelatedEvidence, into lines: inout [RelatedLine]) -> RelatedVerdict? {
        if let da = e.a.digest, let db = e.b.digest, da == db, e.a.sizeBytes == e.b.sizeBytes, e.a.sizeBytes > 0 {
            lines.insert(.init(.supports, "Whole-file SHA-256 equal (\(short(da))), \(bytes(e.a.sizeBytes)) both."), at: 0)
            peopleAndWords(e, rung: .identicalCopy, into: &lines)
            return RelatedVerdict(rung: .identicalCopy, band: .sameEvent,
                                  headline: "The same recording, byte for byte.", lines: lines, better: nil)
        }
        if e.a.digest != nil, e.b.digest != nil {
            lines.append(.init(.differs, "Different bytes (SHA-256 differs)."))
        }
        return nil
    }

    // MARK: Rungs 5 and 4 — the sound

    static func whatTheSoundSays(_ e: RelatedEvidence, dates: DateRelation, into lines: inout [RelatedLine]) -> RelatedVerdict? {
        switch e.audio {
        case .sameRecording?:
            lines.insert(.init(.supports, "Sound: \(pct(e.audioCoverage)) of the audible seconds match at one offset, the whole length."), at: 0)
            peopleAndWords(e, rung: .sameRecording, into: &lines)
            return RelatedVerdict(rung: .sameRecording, band: .sameEvent, headline: "Two transfers of one recording.",
                                  lines: lines, better: betterTransfer(e, into: &lines))
        case .containedInMaster(let offset)?:
            return clip(e, clip: .a, offset: offset, into: &lines)
        case .masterContainedInQuery(let offset)?:
            return clip(e, clip: .b, offset: offset, into: &lines)
        case .overlap(let offset, let seconds)? where seconds >= minSharedSeconds:
            return sameMoment(e, offset: offset, seconds: seconds, dates: dates, into: &lines)
        case .overlap?, .different?:
            lines.append(.init(.contradicts, "Sound: nothing in common at any offset."))
        case .inconclusive(let why)?:
            lines.append(.init(.missing, "Sound: the fingerprints can't be compared (\(inconclusive(why)))."))
        case nil:
            soundAbsence(e, into: &lines)
        }
        return nil
    }

    /// One side is cut from the other.
    static func clip(_ e: RelatedEvidence, clip: PairSide, offset: Double, into lines: inout [RelatedLine]) -> RelatedVerdict {
        let clipSide = clip == .a ? e.a : e.b
        let off = max(0, offset)
        lines.insert(.init(.supports, "Sound: \(pct(e.audioCoverage)) of the clip's audible seconds match the other at one offset, \(mmss(off)), spread end to end."), at: 0)
        peopleAndWords(e, rung: .sameRecording, into: &lines)
        return RelatedVerdict(rung: .sameRecording,
                              band: .clipFromSameEvent(clip: clip, seconds: clipSide.durationSeconds, offsetSeconds: off),
                              headline: "A \(mmss(clipSide.durationSeconds)) clip cut from the other at \(mmss(off)).",
                              lines: lines, better: nil)
    }

    /// Two microphones in one room — unless the reliable dates say otherwise.
    static func sameMoment(_ e: RelatedEvidence, offset: Double, seconds: Double, dates: DateRelation,
                           into lines: inout [RelatedLine]) -> RelatedVerdict? {
        let shared = Int(seconds.rounded()), at = mmss(max(0, offset))
        if dates == .conflict {
            lines.insert(.init(.contradicts, "\(shared) s of shared sound at \(at), but the reliable dates disagree — the same song at two parties, or one date is wrong."), at: 0)
            return nil
        }
        lines.insert(.init(.supports, "Sound: \(shared) s shared at \(at), then each goes its own way — two microphones in one room."), at: 0)
        peopleAndWords(e, rung: .sameMoment, into: &lines)
        return RelatedVerdict(rung: .sameMoment, band: .differentCapture(sharedSeconds: seconds),
                              headline: "Two cameras at one moment: \(shared) s of shared sound at \(at).",
                              lines: lines, better: nil)
    }

    /// Why the sound could not be asked: silence, or no fingerprint yet.
    static func soundAbsence(_ e: RelatedEvidence, into lines: inout [RelatedLine]) {
        func which(_ a: Bool, _ b: Bool) -> String { a && b ? "either file" : a ? "the first file" : "the second file" }
        if e.a.isSilent || e.b.isSilent {
            lines.append(.init(.nonClue, "No sound in \(which(e.a.isSilent, e.b.isSilent)) — the sound can't say."))
        } else if !e.a.hasFingerprint || !e.b.hasFingerprint {
            lines.append(.init(.missing, "No sound fingerprint yet for \(which(!e.a.hasFingerprint, !e.b.hasFingerprint)) — Catalog ▸ Fingerprint Sound…"))
        }
    }

    // MARK: Rung 5 for silent footage — the frames

    static func whatTheFramesSay(_ e: RelatedEvidence, into lines: inout [RelatedLine]) -> RelatedVerdict? {
        switch e.video {
        case .aligned(let coverage, let offset)? where coverage >= 0.5:
            let clip: PairSide = e.a.durationSeconds <= e.b.durationSeconds ? .a : .b
            let clipSide = clip == .a ? e.a : e.b
            let off = max(0, offset)
            lines.insert(.init(.supports, "Frames: \(pct(coverage)) of the shorter file's frames sit inside the other at \(mmss(off))."), at: 0)
            peopleAndWords(e, rung: .sameRecording, into: &lines)
            let whole = coverage >= 0.95 && abs(e.a.durationSeconds - e.b.durationSeconds) <= 2
            return RelatedVerdict(rung: .sameRecording,
                                  band: whole ? .sameEvent : .clipFromSameEvent(clip: clip, seconds: clipSide.durationSeconds, offsetSeconds: off),
                                  headline: whole ? "Two transfers of one recording (by the frames; no sound to compare)."
                                                  : "A \(mmss(clipSide.durationSeconds)) clip cut from the other at \(mmss(off)) (by the frames).",
                                  lines: lines, better: whole ? betterTransfer(e, into: &lines) : nil)
        case .aligned?, .noRunInCommon?:
            lines.append(.init(.contradicts, "Frames: no run in common."))
            return nil
        case nil:
            return nil
        }
    }

    // MARK: Rungs 3, 2, 1 — the calendar and the people

    static func calendarAndPeople(_ e: RelatedEvidence, dates: DateRelation, into lines: inout [RelatedLine]) -> RelatedVerdict {
        let people = e.a.people.intersection(e.b.people)
        let names = e.a.namesSaid.intersection(e.b.namesSaid)
        let sameFolder = e.a.folderLabel != nil && e.a.folderLabel == e.b.folderLabel
        peopleAndWords(e, rung: nil, into: &lines)
        guard evidenceAvailable(e) else {
            return RelatedVerdict(rung: nil, band: .notEnoughEvidence, headline: "Not enough evidence yet.", lines: lines, better: nil)
        }
        guard !people.isEmpty || !names.isEmpty || sameFolder else {
            return RelatedVerdict(rung: RelatedRung.none, band: .differentEvents,
                                  headline: "These files do not represent the same event in any way.", lines: lines, better: nil)
        }
        if dates == .sameDay {
            return RelatedVerdict(rung: .sameOccasion, band: .differentCapture(sharedSeconds: 0),
                                  headline: "The same day, the same people — different footage.", lines: lines, better: nil)
        }
        let what = people.isEmpty ? (names.isEmpty ? "a folder" : "names") : "people"
        return RelatedVerdict(rung: .related, band: .differentEvents,
                              headline: "Different occasions that share \(what).", lines: lines, better: nil)
    }

    // MARK: Pieces

    enum DateRelation { case sameDay, conflict, unknown }

    /// Both days reliable: the same day (within tolerance) or a conflict.
    /// Anything else is unknown — and said so, as a non-clue, when one side
    /// has only an unreliable date.
    static func dateRelation(_ e: RelatedEvidence, into lines: inout [RelatedLine]) -> DateRelation {
        guard let da = e.a.day, let db = e.b.day else {
            if e.a.day == nil && e.b.day == nil { lines.append(.init(.missing, "No date on either file.")) }
            return .unknown
        }
        let both = e.a.dayIsReliable && e.b.dayIsReliable
        let gap = abs(daysBetween(da, db))
        if both {
            if gap <= sameDayToleranceDays {
                lines.append(.init(.supports, "Same day: \(words(da))."))
                return .sameDay
            }
            lines.append(.init(.contradicts, "Dates disagree: \(words(da)) vs \(words(db))."))
            return .conflict
        }
        if gap <= sameDayToleranceDays {
            lines.append(.init(.nonClue, "Same day on the file (\(words(da))), but one date is not reliable."))
        } else {
            lines.append(.init(.nonClue, "File dates differ (\(words(da)) vs \(words(db))) — one is a file date, not the event's."))
        }
        return .unknown
    }

    /// People, names and words — supports or contradicts by rung; occasion
    /// words in common are never more than a non-clue.
    static func peopleAndWords(_ e: RelatedEvidence, rung: RelatedRung?, into lines: inout [RelatedLine]) {
        let people = e.a.people.intersection(e.b.people).sorted()
        if !people.isEmpty {
            lines.append(.init(.supports, "\(people.joined(separator: ", ")) seen in both."))
        } else if !e.a.people.isEmpty, !e.b.people.isEmpty {
            let kind: RelatedLine.Kind = (rung ?? RelatedRung.none) >= .sameRecording ? .differs : .contradicts
            lines.append(.init(kind, "Different people: \(e.a.people.sorted().joined(separator: ", ")) vs \(e.b.people.sorted().joined(separator: ", "))."))
        }
        let names = e.a.namesSaid.intersection(e.b.namesSaid).sorted()
        if !names.isEmpty { lines.append(.init(.supports, "Names said in both: \(names.joined(separator: ", ")).")) }
        let words = e.a.occasionWords.intersection(e.b.occasionWords).sorted()
        if !words.isEmpty { lines.append(.init(.nonClue, "Both say \"\(words.joined(separator: "\", \""))\": the kind of occasion, not the occasion.")) }
        if let fa = e.a.folderLabel, fa == e.b.folderLabel { lines.append(.init(.supports, "Same folder label: \(fa).")) }
        if let r = rung, r >= .sameRecording { codecLines(e, into: &lines) }
    }

    static func codecLines(_ e: RelatedEvidence, into lines: inout [RelatedLine]) {
        if e.a.codec != e.b.codec, e.a.codec != .unknown, e.b.codec != .unknown {
            lines.append(.init(.differs, "Codecs differ: \(e.a.codec.rawValue) vs \(e.b.codec.rawValue) — expected between a capture and an export."))
        }
    }

    /// Rung 5: which transfer to keep. Ordered: longer audible duration
    /// (by more than 5 %), original-generation codec, frame size, bit rate.
    static func betterTransfer(_ e: RelatedEvidence, into lines: inout [RelatedLine]) -> BetterTransfer {
        let la = e.a.audibleSeconds ?? e.a.durationSeconds, lb = e.b.audibleSeconds ?? e.b.durationSeconds
        if la > lb * 1.05 { return .a(why: "longer: \(mmss(la)) vs \(mmss(lb))") }
        if lb > la * 1.05 { return .b(why: "longer: \(mmss(lb)) vs \(mmss(la))") }
        if e.a.codec == .original, e.b.codec == .delivery { return .a(why: "an original-generation codec; the other is a delivery re-encode") }
        if e.b.codec == .original, e.a.codec == .delivery { return .b(why: "an original-generation codec; the other is a delivery re-encode") }
        if let ha = e.a.frameHeight, let hb = e.b.frameHeight, ha != hb { return ha > hb ? .a(why: "larger frame: \(ha) vs \(hb) lines") : .b(why: "larger frame: \(hb) vs \(ha) lines") }
        if let ra = e.a.bitRate, let rb = e.b.bitRate, ra != rb { return ra > rb ? .a(why: "higher bit rate") : .b(why: "higher bit rate") }
        return .tie
    }

    /// Could the ladder ask anything at all?
    static func evidenceAvailable(_ e: RelatedEvidence) -> Bool {
        if let v = e.audio { if case .inconclusive = v { } else { return true } }
        if e.video != nil { return true }
        if e.a.dayIsReliable, e.b.dayIsReliable, e.a.day != nil, e.b.day != nil { return true }
        if !e.a.people.isEmpty, !e.b.people.isEmpty { return true }
        if e.a.folderLabel != nil, e.b.folderLabel != nil { return true }
        return false
    }

    static func inconclusive(_ why: AudioMatchInconclusiveReason) -> String {
        switch why {
        case .incompatibleRecipe: return "different fingerprint recipes — fingerprint again"
        case .queryIncomplete: return "the first file's fingerprint is partial"
        case .masterIncomplete: return "the second file's fingerprint is partial"
        case .bothIncomplete: return "both fingerprints are partial"
        }
    }

    // MARK: Words

    static func daysBetween(_ a: EventDay, _ b: EventDay) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let da = cal.date(from: DateComponents(year: a.year, month: a.month, day: a.day)),
              let db = cal.date(from: DateComponents(year: b.year, month: b.month, day: b.day)) else { return Int.max / 2 }
        return cal.dateComponents([.day], from: da, to: db).day ?? Int.max / 2
    }
    public static func mmss(_ s: Double) -> String {
        let t = max(0, Int(s.rounded()))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t % 3600 / 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
    static func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded())) %" } ?? "most" }
    static func short(_ digest: String) -> String { digest.count > 8 ? "\(digest.prefix(4))…\(digest.suffix(4))" : digest }
    static func bytes(_ n: Int64) -> String {
        let gb = Double(n) / 1_000_000_000
        return gb >= 1 ? String(format: "%.1f GB", gb) : String(format: "%.0f MB", Double(n) / 1_000_000)
    }
    static func words(_ d: EventDay) -> String {
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let m = (1...12).contains(d.month) ? months[d.month - 1] : "\(d.month)"
        return "\(m) \(d.day), \(d.year)"
    }
}
