// ArchiveAngelReadinessExplanation.swift
// "Archive Readiness" (Rick 2026-09-24): what the informational sheet says
// about one file, in plain sentences a family member can read —
//   • why Archive Angel chose it (the scorer's evidence lines and the
//     classifier's reasons, translated);
//   • what it is still missing, and what the person would do about each;
//   • whether it is worth archiving;
//   • the facts: length, date and era, people, copies, where it lives.
// The internal score is NOT part of any sentence; it appears once, in the
// small grey footer ("internal score 88 (rules v11)").
//
// PURE: a function of ArchiveAngelRowFacts. Built when the button is
// pressed (O(1) — a handful of lines), never in a view body.
//
// The translations key on the exact wording the scorer prints
// (ArchiveAngelScorer+Rules.swift). A line this file does not recognise —
// a rule Rick wrote in policy.json — passes through as its own sentence,
// so nothing is ever hidden. If a scorer line changes wording,
// ArchiveAngelReadinessExplanationTests' table goes red.

import Foundation

struct ArchiveAngelReadinessExplanation: Identifiable, Equatable, Sendable {

    /// One missing thing and what to do about it.
    struct Step: Equatable, Sendable, Hashable {
        var what: String
        var todo: String
    }

    /// One labelled fact ("Length" · "1 h 2 min").
    struct Fact: Equatable, Sendable, Hashable {
        var label: String
        var value: String
    }

    let id: UUID
    var filename: String
    var statusWords: String
    var isReady: Bool
    var whyChosen: [String]
    var missing: [Step]
    var worthIt: String
    var facts: [Fact]
    /// "internal score 88 (rules v11)" — the only place the number shows.
    var footer: String

    // MARK: Build

    static func make(_ f: ArchiveAngelRowFacts,
                     rulesVersion: Int = ArchiveAngelScorer.rulesVersion) -> ArchiveAngelReadinessExplanation {
        let needs = ArchiveAngelStatusWords.needs(f)
        let ready = ArchiveAngelStatusWords.isReady(kind: f.kind, needs: needs)
        return ArchiveAngelReadinessExplanation(
            id: f.id,
            filename: f.filename,
            statusWords: ArchiveAngelStatusWords.words(kind: f.kind, needs: needs),
            isReady: ready,
            whyChosen: whyChosen(f),
            missing: needs.map(step),
            worthIt: worthIt(kind: f.kind, needs: needs, ready: ready),
            facts: facts(f),
            footer: "internal score \(f.score) (rules v\(rulesVersion))")
    }

    /// Evidence first (the scorer's reasons, in its order), then the
    /// classifier's; each sentence once.
    static func whyChosen(_ f: ArchiveAngelRowFacts) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        let sentences = f.evidenceLines.compactMap(sentence(forEvidenceLine:))
            + f.reasons.compactMap(sentence(forReason:))
        for s in sentences where seen.insert(s).inserted { out.append(s) }
        return out
    }

    // MARK: Evidence lines → sentences

    // One function per family of lines keeps each branch short (the
    // cyclomatic-complexity lint); the dispatcher tries them in turn.
    // `[(String) -> String?]` ≈ a C++ array of function pointers.
    private static let evidenceTranslators: [@Sendable (String) -> String?] = [
        exactEvidence, peopleEvidence, playEvidence, dateEvidence, otherEvidence,
    ]

    static func sentence(forEvidenceLine raw: String) -> String? {
        let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        for translate in evidenceTranslators {
            if let s = translate(line) { return s }
        }
        return asSentence(line)
    }

    private static func exactEvidence(_ line: String) -> String? {
        switch line {
        case "You rated it best (★★★)": return "You gave it three stars — your best."
        case "You rated it better (★★)": return "You gave it two stars."
        case "You rated it good (★)": return "You gave it one star."
        case "At-risk format — archive sooner":
            return "It is in an aging format, so it is safer to archive it sooner rather than later."
        case "This is the only copy":
            return "It is the only copy the catalog knows of — if that drive fails, it is gone."
        case "Dated by the camera": return "The camera recorded the date it was filmed."
        case ArchiveAngelScorer.freshLine: return "Archive Angel has not shown it to you before."
        default: return nil
        }
    }

    private static func peopleEvidence(_ line: String) -> String? {
        if line.hasPrefix("Looks like a download or rip") {
            return "It looks like a download or a copy of a film rather than a family original, so it ranks lower."
        }
        if line.hasPrefix("Looks like "), line.hasSuffix(" (machine)") {
            let names = line.dropFirst("Looks like ".count).dropLast(" (machine)".count)
            return "Face recognition thinks \(names) may be in it (not yet confirmed)."
        }
        if line.hasSuffix(" (confirmed)") {
            return "You confirmed who is in it: \(line.dropLast(" (confirmed)".count))."
        }
        return nil
    }

    private static func playEvidence(_ line: String) -> String? {
        if line.hasPrefix("Played ") {
            // "Played once" / "Played 14 times, last on 2026-05-01"
            let rest = line.dropFirst("Played ".count)
                .replacingOccurrences(of: ", last on ", with: ", most recently on ")
            return "It has been played \(rest)."
        }
        if line.hasPrefix("You skipped") || line.hasPrefix("You passed on") {
            return "You passed on it before, so it ranks a little lower."
        }
        return nil
    }

    private static func dateEvidence(_ line: String) -> String? {
        if line.hasPrefix("Dated "), line.hasSuffix(" (yours)") {
            return "You dated it \(line.dropFirst("Dated ".count).dropLast(" (yours)".count))."
        }
        if line.hasPrefix("Dated "), let paren = line.range(of: " (consensus") {
            return "The catalog's clues date it \(line[line.index(line.startIndex, offsetBy: 6)..<paren.lowerBound])."
        }
        if line.hasPrefix("Date uncertain — ") {
            let rest = line.dropFirst("Date uncertain — ".count)
            let date = rest.range(of: " (").map { rest[..<$0.lowerBound] } ?? rest
            return "Its date is only a guess — maybe \(date)."
        }
        return nil
    }

    private static func otherEvidence(_ line: String) -> String? {
        if line.hasPrefix("Has ") {
            return "It already has helpful details: \(line.dropFirst("Has ".count))."
        }
        if line.hasPrefix("Runs ") {
            return "It runs \(line.dropFirst("Runs ".count))."
        }
        if line.hasPrefix("Fills a gap — ") {
            // Rules v13: "Fills a gap — 2010 has 156 videos still to archive and 27 archived"
            return "It helps fill a gap in the archive: \(line.dropFirst("Fills a gap — ".count))."
        }
        if line.hasPrefix("Lives on "), line.hasSuffix(" (no role assigned)") {
            let volume = line.dropFirst("Lives on ".count).dropLast(" (no role assigned)".count)
            return "It lives on \(volume), a drive that has not been given a role yet."
        }
        if line.hasPrefix("Audio: "), line.hasSuffix(" — will balance") {
            let problem = line.dropFirst("Audio: ".count).dropLast(" — will balance".count)
            return "Its sound has a problem (\(problem)); Archive Angel will make a balanced copy."
        }
        return nil
    }

    // MARK: Classifier reasons → sentences

    static func sentence(forReason raw: String) -> String? {
        let r = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !r.isEmpty else { return nil }
        // Stars alone ("★★") — already said from the evidence line.
        if r.allSatisfy({ $0 == "★" }) { return nil }
        if r.hasPrefix("Archive Angel grade ") { return gradeSentence(r) }
        switch r {
        case "marked Important": return "You marked it Important."
        case "stage: Ready": return "You set its archive stage to Ready."
        case "stage: Master": return "Its archive stage says Master."
        case "the copy to keep": return "You chose this copy as the one to keep."
        case "Not assessed yet": return "Archive Angel has not looked at it yet."
        case ArchiveAngelRejection.footageOriginalArchived.rawValue:
            return "Find Similar Footage matched it to footage whose original is already in the archive, so it is not new material."
        // Rules v13 coverage: batch limits, never exclusions.
        case ArchiveAngelRejection.sameEventAsPick.rawValue:
            return "Another file from the same day is already in this batch, so this one waits for a later batch."
        case ArchiveAngelRejection.yearCoverage.rawValue:
            return "This batch already has its share of that year; Archive Angel spreads each batch across the years still to archive, so this one waits for a later batch."
        // Rules v12 class-rule lines (AngelPolicyDefaults).
        case AngelPolicyDefaults.absurdBitrateLine:
            return "The file is far larger than its length explains — probably a broken encode. Play it before archiving."
        default: break
        }
        if r.hasPrefix("Dated "), r.hasSuffix(" — confirm when it was filmed"),
           let comma = r.range(of: ", but it looks like") {
            let year = r[r.index(r.startIndex, offsetBy: "Dated ".count)..<comma.lowerBound]
            return "Its date says \(year), but it looks like a tape or film digitized recently — confirm the year it was actually filmed."
        }
        if r.hasSuffix(" files of the same footage — this one") {
            let n = r.dropLast(" files of the same footage — this one".count)
            return "\(n) files hold the same footage; this one is the original to archive."
        }
        if r.hasSuffix(" copies — this one") {
            return "The catalog holds \(r.dropLast(" — this one".count)) of this recording; this one is the best to archive."
        }
        return asSentence(r)
    }

    /// "Archive Angel grade A (112)" → words, never the number.
    private static func gradeSentence(_ r: String) -> String {
        let letter = r.dropFirst("Archive Angel grade ".count).first.map(String.init) ?? ""
        switch letter {
        case "A": return "Everything Archive Angel knows about it adds up to its top rating."
        case "B": return "What Archive Angel knows about it is promising, but nobody has vouched for it yet."
        default: return "Archive Angel has only a little evidence about it so far."
        }
    }

    // MARK: Missing → what to do

    static func step(_ need: ArchiveAngelNeed) -> Step {
        switch need {
        case .audioRepair(let note):
            return Step(what: "The sound check found a problem: \(stripPrefix(note, "Damaged audio — ", fallback: "damaged sound")).",
                        todo: "Play it and listen. Prepare to Archive makes a repaired copy of the sound; the original is kept exactly as it is.")
        case .videoRepair(let note):
            return Step(what: "The picture check found a problem: \(stripPrefix(note, "Broken video — ", fallback: "damaged picture")).",
                        todo: "Play it to judge whether it is still worth keeping. The original is archived as it is; a repaired copy can be made later.")
        case .date:
            return Step(what: "It needs a date.",
                        todo: "Press Show in Catalog, then type the year — or your best guess — in the date field on the right. A year is enough.")
        case .audioCheck:
            return Step(what: "Nobody has checked its sound yet.",
                        todo: "Press Prepare to Archive — Archive Angel checks the sound before anything is archived. Or press Play and listen.")
        case .audioChecking:
            return Step(what: "Archive Angel is checking its sound right now.",
                        todo: "Nothing to do — a long tape takes a minute or two; the row updates when the check is done.")
        case .look:
            return Step(what: "It needs a look from you.",
                        todo: "Press Play and decide. If it is worth keeping, give it stars in the Catalog — that tells Archive Angel it matters.")
        }
    }

    private static func stripPrefix(_ note: String, _ prefix: String, fallback: String) -> String {
        let n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty { return fallback }
        return n.hasPrefix(prefix) ? String(n.dropFirst(prefix.count)) : n
    }

    // MARK: Worth it?

    static func worthIt(kind: ArchiveAngelRecommendationClass, needs: [ArchiveAngelNeed], ready: Bool) -> String {
        if ready { return "Yes — Archive Angel thinks it is worth keeping, and it is ready now." }
        switch kind {
        case .ready: return "Yes — it is worth keeping once the steps below are done."
        case .needsDate:
            return needs.count > 1 ? "Yes, once it has a date and the other steps below are done." : "Yes, once it has a date."
        case .worthALook: return "Maybe — nobody has vouched for it yet. Play it and decide."
        case .notNow: return "Not right now — there is little evidence yet that it matters."
        case .excluded: return "No — it is left out of the archive list."
        case .anotherCopy: return "Not this copy — another copy of the same recording is the one to keep."
        case .prepared: return "Yes — it is already prepared and waiting for your review."
        case .promoted: return "It is already in the archive."
        }
    }

    // MARK: Facts

    static func facts(_ f: ArchiveAngelRowFacts) -> [Fact] {
        var out: [Fact] = []
        if f.durationSeconds > 0 {
            out.append(Fact(label: "Length", value: ArchiveAngelScorer.durationText(f.durationSeconds)))
        }
        out.append(Fact(label: "Date", value: dateValue(f)))
        out.append(Fact(label: "Sound", value: soundValue(f)))
        out.append(Fact(label: "People", value: peopleValue(f)))
        out.append(Fact(label: "Copies", value: copiesValue(f)))
        out.append(Fact(label: "Where", value: whereValue(f)))
        return out
    }

    private static func dateValue(_ f: ArchiveAngelRowFacts) -> String {
        guard let label = f.dateLabel, !label.isEmpty else { return "Not known yet" }
        var s = label
        if let decade = decade(in: label) { s += " — the \(decade)s" }
        if f.date == .lowConfidence { s += " (a guess)" }
        return s
    }

    /// 1994 → 1990. The first plausible year (1800–2099) in the text.
    static func decade(in text: String) -> Int? {
        guard let r = text.range(of: #"\b(18|19|20)\d{2}\b"#, options: .regularExpression),
              let y = Int(text[r]) else { return nil }
        return y / 10 * 10
    }

    /// The sound check, as information (QA P2-1: an "ok" verdict with a
    /// note is checked, and the note is worth knowing — not a need).
    private static func soundValue(_ f: ArchiveAngelRowFacts) -> String {
        if f.audioVerifyStatus == "damaged" {
            return "Damaged — " + stripPrefix(f.audioVerifyNote, "Damaged audio — ", fallback: "the sound check found a problem")
        }
        switch f.audio {
        case .verifiedOK: return "Checked — sounds fine"
        case .verifiedProblem(let note): return "Checked — " + note
        case .notVerified: return "Not checked yet"
        case .noAudioTrack: return "No sound track (picture only)"
        }
    }

    private static func peopleValue(_ f: ArchiveAngelRowFacts) -> String {
        let names = f.confirmedPeople + f.otherPeople.filter { !f.confirmedPeople.contains($0) }.map { $0 + " (not confirmed)" }
        return names.isEmpty ? "Nobody tagged yet" : names.joined(separator: ", ")
    }

    private static func copiesValue(_ f: ArchiveAngelRowFacts) -> String {
        let n = max(f.copies, f.duplicateCount)
        if n > 1 { return "\(n) copies of this recording are in the catalog — this is the one to archive" }
        if f.evidenceLines.contains("This is the only copy") { return "This is the only copy" }
        return "No other copies known"
    }

    private static func whereValue(_ f: ArchiveAngelRowFacts) -> String {
        var s = f.volumeName.isEmpty ? f.fullPath : "\(f.volumeName) — \(f.fullPath)"
        switch ArchiveAngelFileLocation.from(volumeReachable: f.isReachable, fileExists: f.fileExists) {
        case .driveNotConnected: s += " (that drive is not connected right now)"
        case .fileNotFound: s += " (the drive is connected but the file is not there — moved or deleted?)"
        case .available: break
        }
        return s
    }

    // MARK: Helpers

    /// Capital first letter, a period at the end.
    static func asSentence(_ s: String) -> String {
        guard let first = s.first else { return s }
        var out = first.uppercased() + s.dropFirst()
        if let last = out.last, !".!?".contains(last) { out += "." }
        return out
    }
}
