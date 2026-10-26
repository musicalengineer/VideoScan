// FindMasterAnswer.swift — Provenance ▸ Find Master (by sound), the WORDS.
// Design: docs/design/provenance_retroactive_2026_10_26.md §Phase A.
//
// ONE SENTENCE: every sentence and log line the job shows or writes, as pure
// functions of the evidence, so the truth tests can read them directly.
//
// Rules the sentences keep (truth tests: FindMasterAnswerTests):
//   • every positive answer carries its verdict, the time span, the offset,
//     the coverage, the matching-landmark count and "sound" as the proof;
//   • geometry only — "inside", "contains", "same recording", "shares".
//     Never which copy is the original or "the master" (ruling 2026-09-23:
//     similarity never creates lineage; the menu name is Rick's to change);
//   • a negative says what was searched, and how many contents could not
//     be (no sound track, not fingerprinted);
//   • a refusal names its reason and the action that would lift it.

import Foundation
import VideoScanCore

enum FindMasterAnswer {

    // MARK: Refusals

    static func refusal(_ reason: FindMasterRefusalReason) -> String {
        switch reason {
        case .notHashed:
            return "Not hashed yet — run Fill In Full Hashes; a sampled hash is not identity."
        case .noSoundPrint:
            return "No sound print yet — run Fingerprint Sound."
        case .noSound:
            return "No sound to match. Picture matching comes with the picture timeline (Phase B)."
        case .tooLittleSound(let landmarks):
            return "Too little sound to match (\(landmarks) landmarks; \(AudioMatchPolicy.default.minMatchedLandmarks) needed)."
        case .olderRecipe:
            return "Its sound print is from an older recipe — re-run Fingerprint Sound."
        case .printUnreadable(let error):
            return "Its stored sound print could not be read, so nothing was searched (\(error))."
        }
    }

    /// A refusal the finder made after the print was loaded.
    static func reason(for refusal: AudioMasterRefusal) -> FindMasterRefusalReason {
        switch refusal {
        case .otherRecipe: return .olderRecipe
        case .tooLittleSound(let landmarks): return .tooLittleSound(landmarks: landmarks)
        }
    }

    // MARK: Negatives

    /// With `unreadable` > 0 this is NOT a negative: those candidates were
    /// chosen by the index but their prints could not be read (rule 1).
    static func noneFound(searched: Int, noSoundTrack: Int, notFingerprinted: Int, unreadable: Int = 0) -> String {
        let counts = "searched \(searched.formatted()) sounded contents; "
            + "\(noSoundTrack.formatted()) have no sound track; \(notFingerprinted.formatted()) not fingerprinted"
        guard unreadable > 0 else { return "No content shares its sound (\(counts))." }
        return "Not a negative: \(unreadable.formatted()) candidate\(unreadable == 1 ? "" : "s") could not be read, and no readable content shares its sound (\(counts))."
    }

    static func unreadableLine(name: String, key: AudioFingerprintStore.Key, unreadable: [AudioMasterUnreadable]) -> String {
        "find master: \(name) \(shortDigest(key.contentDigest)) → \(unreadable.count) candidate(s) could not be read: "
            + unreadable.map { "\(shortDigest($0.key.contentDigest)) \($0.reason)" }.joined(separator: "; ")
    }

    // MARK: Positives

    /// One found content, in words. `other` names it ("Cape-1993.mkv"),
    /// with its removal state when it is not live.
    static func sentence(_ c: AudioMasterCandidate, other: String) -> String {
        let m = c.match
        let e = m.evidence
        let evidence = String(format: "offset %.1f s, coverage %.2f, %@ matching landmarks; proof: sound",
                              e.offsetSeconds, e.coverage, m.matchedLandmarks.formatted())
        switch m.verdict {
        case .sameRecording:
            return "Same recording as \(other), \(span(0, e.queryDurationSeconds)) (\(evidence))."
        case .containedInMaster:
            return "This file's sound is inside \(other) from \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) (\(evidence))."
        case .masterContainedInQuery:
            // The other file's sound, placed on THIS file's timeline.
            let start = m.spanStartInMasterSeconds - e.offsetSeconds, end = m.spanEndInMasterSeconds - e.offsetSeconds
            return "Contains the sound of \(other), here from \(span(start, end)) (\(evidence))."
        case .overlap(_, let seconds):
            return "Shares \(Int(seconds.rounded())) s of sound with \(other), at \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) of it (\(evidence))."
        case .inconclusive(let reason):
            return "Sound lines up with \(other) at \(span(m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)) of it, but no verdict can be given — \(words(reason)) (\(evidence))."
        case .different:
            return "Different from \(other) (\(evidence))."
        }
    }

    /// How a found content is named: its label, or its digest when no
    /// record in the catalog list carries it.
    static func name(of key: AudioFingerprintStore.Key, label: FindMasterLabel?) -> String {
        guard let label else { return "\(shortDigest(key.contentDigest)) (not in the catalog list)" }
        var parts = [label.name]
        if label.isArchived { parts.append("archived") }
        switch label.removal {
        case .inTrash?: parts.append("In the Trash")
        case .missing?: parts.append("Missing")
        case .removedFromCatalog?: parts.append("removed from the catalog")
        case nil: break
        }
        return parts.count == 1 ? label.name : "\(label.name) (\(parts.dropFirst().joined(separator: ", ")))"
    }

    static func words(_ reason: AudioMatchInconclusiveReason) -> String {
        switch reason {
        case .incompatibleRecipe: return "the two prints were made by different recipes"
        case .queryIncomplete: return "only part of this file was analysed"
        case .masterIncomplete: return "only part of the other file was analysed"
        case .bothIncomplete: return "only part of each file was analysed"
        }
    }

    /// "00:12:40–00:13:20".
    static func span(_ start: Double, _ end: Double) -> String {
        "\(timecode(start))–\(timecode(end))"
    }

    static func timecode(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func shortDigest(_ digest: String) -> String {
        String(digest.prefix(15)) + "…"
    }

    // MARK: Weak overlaps (shown, but collapsed)
    //
    // The pair matcher is unchanged (rule 4); this only decides how its
    // `.overlap` answers are PRESENTED. An overlap is WEAK when both hold:
    //   • coverage < AudioMatchPolicy.minCoverage (0.5) — the matcher's own
    //     line for "not distributed over the audible query" (decision-table
    //     row 3: the reason it refused "same"/"contained"); and
    //   • matched landmarks < 3 × AudioMatchPolicy.minMatchedLandmarks (60)
    //     — three times the matcher's noise floor. On the real sidecar
    //     (2026-10-26 smoke, 3 queries) every coincidental-looking overlap
    //     had 20–29 landmarks (1–1.5× the floor), coverage ≤ 0.08, 5–15 s;
    //     a genuine shared stretch of 2 × minOverlapSeconds (10 s) at the
    //     catalog's MEDIAN density (15.7 landmarks/s) with half its
    //     landmarks surviving a re-encode carries ≈ 78 — above the line.
    // Weak overlaps are counted and listed on demand, never hidden.

    static let weakCoverageBelow = AudioMatchPolicy.default.minCoverage
    static let weakLandmarksBelow = 3 * AudioMatchPolicy.default.minMatchedLandmarks

    static func isWeak(_ c: AudioMasterCandidate) -> Bool {
        guard case .overlap = c.match.verdict else { return false }
        return c.match.coverage < weakCoverageBelow && c.match.matchedLandmarks < weakLandmarksBelow
    }

    /// Ranked order kept inside each half.
    static func split(_ found: [AudioMasterCandidate]) -> (strong: [AudioMasterCandidate], weak: [AudioMasterCandidate]) {
        (found.filter { !isWeak($0) }, found.filter(isWeak))
    }

    static func weakHeader(count: Int) -> String {
        String(format: "%d weak overlap%@ — short, sparse matches (coverage below %.2f and fewer than %d matching landmarks each); may be coincidence",
               count, count == 1 ? "" : "s", weakCoverageBelow, weakLandmarksBelow)
    }

    static func weakLine(name: String, key: AudioFingerprintStore.Key, weak: [AudioMasterCandidate]) -> String {
        let each = weak.map { c in
            String(format: "%@ %d s, %d landmarks, coverage %.2f", shortDigest(c.key.contentDigest),
                   Int(c.match.spanSeconds.rounded()), c.match.matchedLandmarks, c.match.coverage)
        }
        return "find master: \(name) \(shortDigest(key.contentDigest)) → \(weakHeader(count: weak.count)): " + each.joined(separator: "; ")
    }

    /// Short verdict word for the detail list's chip.
    static func chip(_ verdict: AudioMatchVerdict) -> String {
        switch verdict {
        case .sameRecording: return "same recording"
        case .containedInMaster: return "inside"
        case .masterContainedInQuery: return "contains"
        case .overlap: return "shares"
        case .inconclusive: return "inconclusive"
        case .different: return "different"
        }
    }

    // MARK: Log lines (the one sink: catalog.log, videoscan.log, OSLog)

    static func startLine(files: Int) -> String {
        "START find master — \(files.formatted()) file(s); sound index from \(AudioFingerprintStore.fileName)"
    }

    static func indexLine(_ r: AudioCatalogIndex.BuildReport, seconds: Double) -> String {
        String(format: "find master: sound index — %@ contents, %@ landmarks, %.1f s (skipped: %@ sampled-hash keys, %@ older recipe, %@ too little sound, %@ unreadable)",
               r.indexed.formatted(), r.landmarks.formatted(), seconds, r.notWholeFileKey.formatted(),
               r.otherRecipe.formatted(), r.tooFewLandmarks.formatted(), r.unreadable.formatted())
    }

    static func queryLine(name: String, key: AudioFingerprintStore.Key, answer: String) -> String {
        "find master: \(name) \(shortDigest(key.contentDigest)) → \(answer)"
    }

    static func refusalLine(name: String, reason: FindMasterRefusalReason) -> String {
        "find master: \(name) → refused — \(refusal(reason))"
    }

    struct Tally: Equatable, Sendable {
        var searched = 0, inside = 0, same = 0, contains = 0, shares = 0, inconclusive = 0, none = 0
        /// Searched files whose only hits were weak overlaps.
        var weakOnly = 0
        /// Searched files with no hit while a candidate could not be read.
        var notConclusive = 0
        var refused = 0, notStarted = 0
        var stopped = false
    }

    // MARK: Hit groups ("recordings") — presentation only
    //
    // Strong hits whose verdict, offset (to 0.5 s) and shown span (to the
    // second) agree are copies matching at the same place: one group is one
    // "recording", each hit one "file". The matcher's answers are unchanged;
    // this only decides how many lines the detail shows and what the
    // headline counts. Never says which copy is the original: members are in
    // a stable order (longest other-file duration, then name), not a ranking.

    struct HitGroup: Equatable, Sendable {
        let chip: String
        let start: Double, end: Double
        /// Longest other-file duration first, then name.
        let members: [AudioMasterCandidate]
    }

    /// The span the detail shows for a hit: the other file's timeline,
    /// except "contains", which is placed on THIS file's timeline (as in
    /// `sentence`).
    static func shownSpan(_ c: AudioMasterCandidate) -> (start: Double, end: Double) {
        let m = c.match
        switch m.verdict {
        case .sameRecording: return (0, m.evidence.queryDurationSeconds)
        case .masterContainedInQuery:
            return (m.spanStartInMasterSeconds - m.evidence.offsetSeconds, m.spanEndInMasterSeconds - m.evidence.offsetSeconds)
        default: return (m.spanStartInMasterSeconds, m.spanEndInMasterSeconds)
        }
    }

    /// Groups in first-appearance (rank) order. `name` names a hit for the
    /// tie-break. O(hits log hits); hits are the finder's few per query.
    static func groups(_ strong: [AudioMasterCandidate], name: (AudioMasterCandidate) -> String) -> [HitGroup] {
        struct Key: Hashable { let chip: String; let offsetHalves: Int; let start: Int; let end: Int }
        var order: [Key] = []
        var members: [Key: [AudioMasterCandidate]] = [:]
        for c in strong {
            let span = shownSpan(c)
            let key = Key(chip: chip(c.match.verdict), offsetHalves: Int((c.match.evidence.offsetSeconds * 2).rounded()),
                          start: Int(span.start.rounded()), end: Int(span.end.rounded()))
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(c)
        }
        return order.map { key in
            let sorted = members[key, default: []].map { (c: $0, name: name($0)) }.sorted {
                let (a, b) = ($0.c.match.evidence.masterDurationSeconds, $1.c.match.evidence.masterDurationSeconds)
                return a != b ? a > b : $0.name < $1.name
            }.map(\.c)
            let span = shownSpan(sorted[0])
            return HitGroup(chip: key.chip, start: span.start, end: span.end, members: sorted)
        }
    }

    /// "5:05–5:30" (h:mm:ss past an hour) — the detail's short span.
    static func shortSpan(_ start: Double, _ end: Double) -> String {
        "\(shortTime(start))–\(shortTime(end))"
    }

    static func shortTime(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded()))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    /// "+ 2 copies at the same spot: a.mov, b.dv" — nil for a lone hit.
    static func copiesLine(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        return "+ \(names.count) cop\(names.count == 1 ? "y" : "ies") at the same spot: " + names.joined(separator: ", ")
    }

    // MARK: Headline (the finished row's one line)

    private static func plural(_ n: Int, _ one: String, _ many: String) -> String {
        "\(n.formatted()) \(n == 1 ? one : many)"
    }

    /// The finished row's answer. Single-file run with hits: "FOUND this
    /// clip in 3 recordings (10 files)" (geometry words per the verdicts);
    /// multi-file: "FOUND 2 of 5 files in other recordings · …" with only
    /// non-zero counts; none: "Not found in any other recording (searched
    /// N …)". No timing (that stays in the OUTCOME line). Pure.
    static func headline(_ t: Tally, outcomes: [FindMasterResult.Outcome]) -> MediaFileOperationHeadline {
        let stop = t.stopped ? "Stopped — " : ""
        if !t.stopped, t.searched + t.refused == 1, outcomes.count == 1, let only = outcomes.first {
            return singleHeadline(only)
        }
        let found = t.inside + t.same + t.contains + t.shares
        var extras: [(Int, String)] = [
            (t.inside, "inside another"), (t.same, "same recording"), (t.contains, "contain another"),
            (t.shares, "share sound"), (t.inconclusive, "inconclusive"), (t.weakOnly, "only weak overlaps"),
            (t.notConclusive, "not conclusive (a candidate could not be read)"), (t.none, "none found"), (t.refused, "refused"),
        ]
        if t.stopped { extras.append((t.notStarted, "not started")) }
        let head: String
        if found > 0 {
            head = "FOUND \(found.formatted()) of \(t.searched.formatted()) files in other recordings"
        } else if t.none == t.searched {
            head = "Not found in any other recording (searched \(plural(t.searched, "file", "files")))"
            extras.removeAll { $0.1 == "none found" }
        } else {
            head = "No confirmed match in another recording (searched \(plural(t.searched, "file", "files")))"
        }
        let parts = [stop + head] + extras.filter { $0.0 > 0 }.map { "\($0.0.formatted()) \($0.1)" }
        return MediaFileOperationHeadline(text: parts.joined(separator: " · "), isFound: found > 0)
    }

    private static func singleHeadline(_ outcome: FindMasterResult.Outcome) -> MediaFileOperationHeadline {
        switch outcome {
        case .refused(let reason):
            return .init(text: "Refused — " + refusal(reason), isFound: false)
        case .noneFound(let searched, let unreadable):
            guard unreadable.isEmpty else {
                return .init(text: "Not a negative — \(plural(unreadable.count, "candidate", "candidates")) could not be read", isFound: false)
            }
            return .init(text: "Not found in any other recording (searched \(plural(searched, "content", "contents")))", isFound: false)
        case .found(let found, let searched, _):
            let strong = split(found).strong
            guard !strong.isEmpty else {
                return .init(text: "No confirmed match — only weak overlaps, may be coincidence (searched \(plural(searched, "content", "contents")))", isFound: false)
            }
            // Names do not change the counts; the tie-break name is the digest.
            let all = groups(strong, name: { $0.key.contentDigest })
            let open = ["inconclusive", "different"]
            let sure = all.filter { !open.contains($0.chip) }
            let unsure = all.count - sure.count
            guard !sure.isEmpty else {
                return .init(text: "No verdict — sound lines up with \(plural(all.count, "recording", "recordings")) (\(plural(all.reduce(0) { $0 + $1.members.count }, "file", "files")))", isFound: false)
            }
            let recordings = plural(sure.count, "recording", "recordings")
            let files = plural(sure.reduce(0) { $0 + $1.members.count }, "file", "files")
            let chips = Set(sure.map(\.chip))
            var text: String
            if chips == ["same recording"] {
                text = "FOUND — same recording as \(files)"
            } else if chips.isSubset(of: ["same recording", "inside"]) {
                text = "FOUND this clip in \(recordings) (\(files))"
            } else if chips == ["contains"] {
                text = "FOUND \(recordings) inside this clip (\(files))"
            } else {
                text = "FOUND shared sound with \(recordings) (\(files))"
            }
            if unsure > 0 { text += " · \(unsure.formatted()) inconclusive" }
            return .init(text: text, isFound: true)
        }
    }

    /// The tally line (OUTCOME log line; the run's terminal-state summary).
    static func summary(_ t: Tally, seconds: Double) -> String {
        var parts = ["\(t.searched) searched", "\(t.inside) found inside another", "\(t.same) same recording"]
        if t.contains > 0 { parts.append("\(t.contains) contain another") }
        if t.shares > 0 { parts.append("\(t.shares) share sound") }
        if t.inconclusive > 0 { parts.append("\(t.inconclusive) inconclusive") }
        if t.weakOnly > 0 { parts.append("\(t.weakOnly) only weak overlaps") }
        if t.notConclusive > 0 { parts.append("\(t.notConclusive) not conclusive (a candidate could not be read)") }
        parts.append("\(t.none) none found")
        parts.append("\(t.refused) refused")
        if t.stopped { parts.append("\(t.notStarted) not started") }
        let head = t.stopped ? "stopped — " : ""
        return head + parts.joined(separator: " · ") + String(format: " · %.1f s", seconds)
    }

    static func outcomeLine(_ t: Tally, seconds: Double) -> String {
        "OUTCOME find master — " + summary(t, seconds: seconds)
    }
}
