// ResearchPerson.swift
// Research Person, Phase 1 (docs/research_person_design.md, Rick 2026-08-29:
// "I click a person in the tree, like David T McGill → right-click →
// Research Person … an internet search for records of the person from
// that time"). This file is the MODEL: who may be researched (privacy
// guard), the query plan the sources run, and the finding/dossier value
// types the pane shows and the store persists. No I/O, no network, no UI.
//
// Keying: a dossier is keyed by the FamilySearch ID (`_FSFTID`, survives
// re-pulls) and falls back to a content-derived key when a record has
// none — never a raw @I pointer, which a fresh export renumbers.
//
// Privacy: only DECEASED tree people go to the internet. A People-tab
// contemporary has no tree record and is refused; a tree record with no
// death date whose birth year is within 100 years is presumed living and
// refused too. The refusal is a value the pane can show, not a crash.
//
// C++ readers: everything here is a plain value type (struct/enum) — think
// PODs with member functions; `Codable` ≈ auto-generated JSON
// serialisation for the struct's fields.

import CryptoKit
import Foundation
import VideoScanCore

// MARK: - Subject

/// The person being researched, lifted from the tree record.
struct ResearchSubject: Equatable, Sendable, Codable {
    /// FamilySearch ID ("GVQV-NW3") or the `U-` content-derived fallback.
    let key: String
    /// Whether `key` is a FamilySearch ID (true) or the fallback (false).
    let isFamilySearchKey: Bool
    /// File-local GEDCOM pointer at the time of research ("@I12@"); passed
    /// to the CyberBrain writer so the attestation links to the tree.
    let gedcomPersonID: String
    let name: String
    let alternateNames: [String]
    let surname: String?
    let alternateSurnames: [String]
    let sex: String
    let birthDate: String?
    let deathDate: String?
    let birthPlace: String?
    let deathPlace: String?
    /// The tree records military service (GH #230: the TNA Discovery
    /// adapter runs only for these). Optional so dossiers saved before
    /// 2026-10-01 still decode; nil reads as "no".
    let servedInMilitary: Bool?

    var birthYear: Int? { GedcomFamilyGraph.year(in: birthDate) }
    var deathYear: Int? { GedcomFamilyGraph.year(in: deathDate) }

    /// "1847–1921" / "b. 1847" / "d. 1921" / "" for the pane header.
    var vitals: String {
        switch (birthYear, deathYear) {
        case let (b?, d?): return "\(b)–\(d)"
        case let (b?, nil): return "b. \(b)"
        case let (nil, d?): return "d. \(d)"
        default: return ""
        }
    }

    init(person: GedcomFamilyGraph.Person) {
        let fsid = person.familySearchID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !fsid.isEmpty, GedcomFamilyGraph.isFamilySearchID(fsid) {
            key = fsid
            isFamilySearchKey = true
        } else {
            key = Self.fallbackKey(name: person.name, birthDate: person.birthDate,
                                   deathDate: person.deathDate)
            isFamilySearchKey = false
        }
        gedcomPersonID = person.id
        name = person.name
        alternateNames = person.alternateNames
        surname = person.surname
        alternateSurnames = person.alternateSurnames
        sex = person.sex
        birthDate = person.birthDate
        deathDate = person.deathDate
        birthPlace = person.birthPlace
        deathPlace = person.deathPlace
        // A US draft registration is not service (most registrants never
        // served), so it does not send anyone to the British Army records.
        servedInMilitary = person.militaryFacts.contains { !$0.isDraftRegistration }
    }

    /// Stable across re-pulls as long as the name and the raw dates are the
    /// same: "U-" + 12 hex of SHA-256(name|birth|death). Two records with
    /// identical name AND dates would collide — acceptable for a fallback
    /// that only applies when FamilySearch gave the record no ID.
    static func fallbackKey(name: String, birthDate: String?, deathDate: String?) -> String {
        let material = [name, birthDate ?? "", deathDate ?? ""]
            .map { FamilyIdentityText.normalized($0) }
            .joined(separator: "|")
        let digest = SHA256.hash(data: Data(material.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "U-" + hex.prefix(12)
    }

    /// Only these characters may reach the filesystem as a folder name.
    static func isSafeKey(_ key: String) -> Bool {
        !key.isEmpty && key.count <= 40 && key.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "-"
        }
    }
}

// MARK: - Eligibility (privacy guard)

enum ResearchEligibility: Equatable, Sendable {
    case eligible(ResearchSubject)
    case refused(reason: String)

    /// How many years back a birth must be before someone with no death
    /// date is treated as deceased. The number lives in `LifeStatus`, the
    /// one rule for living / passed on (2026-09-01); read it from there.
    static var presumedLivingYears: Int { LifeStatus.presumedLivingYears }

    /// The ONLY way to obtain a subject: from a tree record. A People-tab
    /// profile (contemporary, no GEDCOM record) never reaches here, so it
    /// can never be researched — `refusedForProfile` is what the caller
    /// shows instead. With `graph`, the family around the record is
    /// consulted too (an ancestor of someone deceased is deceased); the
    /// default keeps the record-only verdict every existing caller had.
    static func evaluate(_ person: GedcomFamilyGraph.Person?,
                         graph: GedcomFamilyGraph? = nil,
                         now: Date = Date(),
                         calendar: Calendar = .current) -> ResearchEligibility {
        guard let person else {
            return .refused(reason: "Only people with a family-tree record can be researched.")
        }
        let subject = ResearchSubject(person: person)
        if LifeStatus.of(person, in: graph, now: now, calendar: calendar) != .living {
            return .eligible(subject)
        }
        if subject.birthYear == nil {
            return .refused(reason: "\(subject.name) has no death date and no birth year in the tree, so I can't tell whether they're living. Add a date to the tree first — only deceased people are researched online.")
        }
        return .refused(reason: "\(subject.name) has no death date and was born within the last \(presumedLivingYears) years, so they're presumed living. Only deceased people are researched online.")
    }

    /// A People-tab profile — always refused, with the reason to show.
    static func refusedForProfile(named name: String) -> ResearchEligibility {
        .refused(reason: "\(name) is a People-tab profile, not a family-tree record. Living family are never researched online; pick their card in the Family Tree if they have one and have passed away.")
    }
}

// MARK: - Query plan

/// What the sources will be asked, shown to Rick before "Run" so nothing
/// leaves the machine that he hasn't seen.
struct ResearchQueryPlan: Equatable, Sendable, Codable {
    /// Ordered, deduplicated: full name first, then given+surname, alternate
    /// names, maiden/alternate-surname combinations.
    let nameVariants: [String]
    /// Inclusive year window the sources constrain to.
    let yearFrom: Int
    let yearTo: Int
    /// Comma-split, trimmed, deduplicated place tokens from birth/death PLAC.
    let placeTokens: [String]
    /// A U.S. state name found in the place tokens, for Chronicling
    /// America's `state=` filter. Nil = unfiltered.
    let stateHint: String?

    static let defaultTolerance = 5
    /// A life used when only one of birth/death is known.
    static let assumedLifespan = 90

    /// Pure. `now` bounds a window with no death date.
    static func build(subject: ResearchSubject,
                      tolerance: Int = defaultTolerance,
                      now: Date = Date(),
                      calendar: Calendar = .current) -> ResearchQueryPlan {
        let currentYear = calendar.component(.year, from: now)
        let (from, to): (Int, Int)
        switch (subject.birthYear, subject.deathYear) {
        case let (b?, d?): (from, to) = (b - tolerance, d + tolerance)
        case let (b?, nil): (from, to) = (b - tolerance, min(b + assumedLifespan + tolerance, currentYear))
        case let (nil, d?): (from, to) = (d - assumedLifespan - tolerance, d + tolerance)
        case (nil, nil): (from, to) = (1700, currentYear)
        }
        return ResearchQueryPlan(
            nameVariants: nameVariants(for: subject),
            yearFrom: from,
            yearTo: max(from, to),
            placeTokens: placeTokens(for: subject),
            stateHint: stateHint(in: placeTokens(for: subject)))
    }

    /// "David McGill Latta Sr" → ["David McGill Latta Sr", "David McGill
    /// Latta", "David Latta", "D. M. Latta"?]. We keep it to real-name
    /// forms: initials generate too much noise on 1870s OCR.
    static func nameVariants(for subject: ResearchSubject) -> [String] {
        var out: [String] = []
        func add(_ raw: String) {
            let cleaned = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            guard !cleaned.isEmpty,
                  !out.contains(where: { $0.caseInsensitiveCompare(cleaned) == .orderedSame })
            else { return }
            out.append(cleaned)
        }
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
        func tokens(_ name: String) -> [String] {
            name.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        }
        func withoutSuffix(_ parts: [String]) -> [String] {
            var p = parts
            while let last = p.last, suffixes.contains(last.lowercased()) { p.removeLast() }
            return p
        }
        let allNames = [subject.name] + subject.alternateNames
        for name in allNames {
            add(name)
            let parts = withoutSuffix(tokens(name))
            if parts.count != tokens(name).count { add(parts.joined(separator: " ")) }
            // given + surname, when the surname is known and there is a
            // middle name in between.
            if let surname = subject.surname, parts.count >= 3,
               let first = parts.first,
               parts.last?.caseInsensitiveCompare(surname) == .orderedSame {
                add("\(first) \(surname)")
            }
        }
        // Maiden / alternate surnames: a woman recorded under her married
        // name is in the papers under her maiden one and vice versa.
        if let first = withoutSuffix(tokens(subject.name)).first {
            for alt in subject.alternateSurnames where !alt.isEmpty {
                add("\(first) \(alt)")
            }
        }
        return out
    }

    static func placeTokens(for subject: ResearchSubject) -> [String] {
        var out: [String] = []
        for place in [subject.birthPlace, subject.deathPlace] {
            guard let place else { continue }
            for piece in place.split(separator: ",") {
                let token = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !token.isEmpty,
                      !out.contains(where: { $0.caseInsensitiveCompare(token) == .orderedSame })
                else { continue }
                out.append(token)
            }
        }
        return out
    }

    /// The first comma part that names a US state, as its full name. The
    /// shared reader (USPlaceNames), so "Mass.", "Conn", "N. H." and "MA"
    /// count as they do everywhere else — not only the full spelling.
    static func stateHint(in tokens: [String]) -> String? {
        for token in tokens {
            if let state = USPlaceNames.stateName(recorded: token) { return state }
        }
        return nil
    }

    /// The family name the adapters filter on: the last token of the first
    /// variant once a Jr/Sr/II… suffix is dropped ("David McGill Latta Sr"
    /// → "Latta").
    var surnameToken: String {
        let suffixes: Set<String> = ["jr", "jr.", "sr", "sr.", "ii", "iii", "iv"]
        var parts = (nameVariants.first ?? "").split(separator: " ").map(String.init)
        while let last = parts.last, suffixes.contains(last.lowercased()) { parts.removeLast() }
        return parts.last ?? ""
    }

    /// One-line summary for the log and the pane ("3 names · 1842–1926 ·
    /// 4 places"). Counts only — no names — so the log stays private.
    var countsSummary: String {
        "\(nameVariants.count) names · \(yearFrom)–\(yearTo) · \(placeTokens.count) places"
    }
}

// MARK: - Findings

enum ResearchSourceKind: String, Codable, Sendable, CaseIterable, Equatable {
    case chroniclingAmerica
    case findAGrave
    case wikipedia
    case wikidata
    case web
    /// GH #230 Phase B: the 1901/1911 Census of Ireland JSON index.
    case irishCensus
    /// GH #230 Phase B: The National Archives (UK) Discovery catalogue —
    /// references only (their "do not cache" line).
    case tnaDiscovery
    /// GH #230 Phase A: a record Rick found himself and filed with
    /// "I found a record…" — not the output of any search.
    case recordFinder

    var label: String {
        switch self {
        case .chroniclingAmerica: return "Chronicling America"
        case .findAGrave: return "Find a Grave"
        case .wikipedia: return "Wikipedia"
        case .wikidata: return "Wikidata"
        case .web: return "Web"
        case .irishCensus: return "Census of Ireland"
        case .tnaDiscovery: return "TNA Discovery"
        case .recordFinder: return "Filed record"
        }
    }

    /// True for the kinds a Run produces; false for records Rick filed.
    var isSearchSource: Bool { self != .recordFinder }

    /// How the CyberBrain classifies a confirmed finding from here.
    var cyberBrainSourceKind: CyberBrainSource.Kind {
        switch self {
        case .chroniclingAmerica, .findAGrave, .irishCensus, .tnaDiscovery, .recordFinder:
            return .officialRecord
        case .wikipedia, .wikidata, .web: return .curatedBiography
        }
    }
}

enum ResearchVerdict: String, Codable, Sendable, CaseIterable, Equatable {
    case unreviewed, confirmed, plausible, wrong

    var label: String {
        switch self {
        case .unreviewed: return "Unreviewed"
        case .confirmed: return "Confirmed"
        case .plausible: return "Plausible"
        case .wrong: return "Wrong"
        }
    }
}

/// How a screening source judged whether a finding is ABOUT this person
/// (bug 2026-10-01; Rick's ruling the same day: keep near-misses for
/// serendipity, but rank them below the likely matches and say why).
/// Advisory only — it never sets a verdict, and nothing reaches Hallie
/// without Rick's explicit Confirm.
struct ResearchScreening: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case likelyMatch
        case nearMiss
    }
    let outcome: Outcome
    /// Plain words for the pane: "likely match", "a film", "surname only",
    /// "different era — born 1725", "couldn't be checked", …
    let reason: String

    static let likely = ResearchScreening(outcome: .likelyMatch, reason: "likely match")
    static func nearMiss(_ reason: String) -> ResearchScreening {
        ResearchScreening(outcome: .nearMiss, reason: reason)
    }
    var isNearMiss: Bool { outcome == .nearMiss }
}

/// One thing a source returned. Evidence, never a fact: it carries where it
/// came from, when it was fetched, and Rick's verdict.
struct ResearchFinding: Identifiable, Equatable, Sendable, Codable {
    /// Stable per (source, url): a re-run replaces the excerpt but keeps
    /// the verdict and lore Rick already entered.
    let id: String
    let source: ResearchSourceKind
    let title: String
    /// The document's own date as the source gave it ("1875-05-12",
    /// "1847–1921"), or nil.
    let date: String?
    let excerpt: String
    let url: String
    let retrievedAt: Date
    var verdict: ResearchVerdict
    /// Free text Rick adds ("this is the Latta who ran the mill").
    var lore: String
    /// Set once the finding has been told to Hallie (the CyberBrain item).
    var toldItemID: String?
    /// For a `.recordFinder` finding: the filed document, archive-relative
    /// (`People/<folder>/Documents/<file>`) — the CyberBrain source locator.
    /// Optional, so dossiers saved before 2026-10-01 still decode.
    var documentPath: String?
    /// For a `.recordFinder` finding: Rick's WHOLE transcription. The
    /// excerpt is capped at `maxExcerptLength` for display; what Hallie is
    /// told must never be cut (QA 2026-10-01 P1-1). Optional, so dossiers
    /// saved before today still decode.
    var fullText: String?
    /// Set by a source that screens its hits (Wikipedia / Wikidata): a
    /// likely match, or a near-miss with its reason. Nil for sources that do
    /// not screen. Optional, so dossiers saved before 2026-10-01 still
    /// decode; a re-run replaces it with the fresh judgement.
    var screening: ResearchScreening?

    /// True for a hit the source judged probably not this person. The pane
    /// lists these in a separate, collapsed group below the findings.
    var isNearMiss: Bool { screening?.isNearMiss == true }

    static let maxExcerptLength = 600

    /// `idSeed` replaces the URL as the identity material when one URL can
    /// carry several records — a filed record is identified by its file's
    /// SHA-256, so two certificates found on one results page stay two.
    init(source: ResearchSourceKind, title: String, date: String?, excerpt: String,
         url: String, retrievedAt: Date, verdict: ResearchVerdict = .unreviewed,
         lore: String = "", toldItemID: String? = nil, documentPath: String? = nil,
         idSeed: String? = nil, fullText: String? = nil, screening: ResearchScreening? = nil) {
        self.id = Self.makeID(source: source, url: idSeed ?? url)
        self.source = source
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.date = date
        self.excerpt = String(excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(Self.maxExcerptLength))
        self.url = url
        self.retrievedAt = retrievedAt
        self.verdict = verdict
        self.lore = lore
        self.toldItemID = toldItemID
        self.documentPath = documentPath
        let whole = fullText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.fullText = whole.isEmpty ? nil : whole
        self.screening = screening
    }

    static func makeID(source: ResearchSourceKind, url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return source.rawValue + "." + digest.map { String(format: "%02x", $0) }.joined().prefix(16)
    }

    /// The text that becomes the CyberBrain item: lore when Rick wrote
    /// some, else the whole transcription of a filed record, else the
    /// excerpt.
    var attestationText: String {
        let trimmedLore = lore.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLore.isEmpty { return trimmedLore }
        return fullText ?? excerpt
    }

    /// A filed record with no words of Rick's — no lore, no transcription.
    /// Its excerpt is only the "not yet transcribed" placeholder, which must
    /// never reach Hallie as a fact (QA 2026-10-01 P2-2).
    var isUntranscribedFiledRecord: Bool {
        source == .recordFinder
            && lore.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (fullText ?? "").isEmpty
    }

    /// True when the finding carries anything of Rick's: a verdict, lore
    /// (any non-empty text — even whitespace is something he typed), a
    /// told Hallie item, a filed document, or it IS a record he filed.
    /// A re-run or the 500-finding trim never drops such a finding
    /// (adversarial review 2026-10-02 F2: an Unreviewed finding with lore
    /// was dropped, lore and all, when its source failed).
    var holdsRicksWork: Bool {
        verdict != .unreviewed || !source.isSearchSource || !lore.isEmpty
            || toldItemID != nil || documentPath != nil
    }
}

/// Everything kept for one subject: People/<key>/research/dossier.json.
struct ResearchDossier: Equatable, Sendable, Codable {
    static let schemaVersion = 1

    var schemaVersion: Int = ResearchDossier.schemaVersion
    let subject: ResearchSubject
    var plan: ResearchQueryPlan?
    var lastRunAt: Date?
    /// Source → "12 findings" / "failed: timeout"; counts and status only.
    var sourceStatus: [String: String] = [:]
    var findings: [ResearchFinding] = []

    /// Findings the pane is allowed to hold. Beyond this, a re-run keeps
    /// reviewed findings and the newest unreviewed ones (memory: 500 ×
    /// ≤ 1 KB ≈ 0.5 MB worst case).
    static let maxFindings = 500

    init(subject: ResearchSubject) {
        self.subject = subject
    }

    /// Merge a fresh run into the dossier: verdict, lore and told-id
    /// survive for findings whose id is already here; new ones are
    /// appended unreviewed; findings no longer returned stay if they carry
    /// any of Rick's work (`holdsRicksWork`: a verdict, lore, a told item or
    /// a filed document — a source's whim never discards it) and are
    /// dropped only when they are bare search hits. Records Rick FILED
    /// (`.recordFinder`) are never a source's output, so a run never drops
    /// or trims them. The 500-finding trim spares the same set.
    mutating func merge(fresh: [ResearchFinding], at date: Date) {
        var byID: [String: ResearchFinding] = [:]
        for finding in findings { byID[finding.id] = finding }
        var merged: [ResearchFinding] = []
        var seen: Set<String> = []
        for var finding in fresh where seen.insert(finding.id).inserted {
            if let prior = byID[finding.id] {
                finding.verdict = prior.verdict
                finding.lore = prior.lore
                finding.toldItemID = prior.toldItemID
                finding.documentPath = prior.documentPath
            }
            merged.append(finding)
        }
        for finding in findings where !seen.contains(finding.id) && finding.holdsRicksWork {
            merged.append(finding)
        }
        if merged.count > Self.maxFindings {
            let kept = merged.filter(\.holdsRicksWork)
            let trimmable = merged.filter { !$0.holdsRicksWork }
            merged = kept + trimmable.prefix(max(0, Self.maxFindings - kept.count))
        }
        findings = merged
        lastRunAt = date
    }

    /// Add one record Rick filed. Refuses (returns false) when a finding
    /// with the same id is already here. A filed record's id is derived from
    /// its FILE's SHA-256 (`idSeed`), not its URL, so the same file is never
    /// listed twice while two records found on one results page stay two.
    mutating func addFiled(_ finding: ResearchFinding) -> Bool {
        guard !findings.contains(where: { $0.id == finding.id }) else { return false }
        findings.append(finding)
        return true
    }

    mutating func setVerdict(_ verdict: ResearchVerdict, for id: String) {
        guard let at = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[at].verdict = verdict
    }

    mutating func setLore(_ lore: String, for id: String) {
        guard let at = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[at].lore = lore
    }

    mutating func markTold(id: String, itemID: String) {
        guard let at = findings.firstIndex(where: { $0.id == id }) else { return }
        findings[at].toldItemID = itemID
    }

    /// Confirmed and not yet told — what "Tell Hallie" will write. A
    /// near-miss is here only if Rick confirmed it himself, like any other
    /// finding; screening never sets a verdict.
    var untoldConfirmed: [ResearchFinding] {
        findings.filter { $0.verdict == .confirmed && $0.toldItemID == nil }
    }

    /// The pane's "Also turned up — probably not this person" group: hits a
    /// source screened as near-misses that Rick has not promoted (by
    /// marking them Confirmed or Plausible). Search order.
    var nearMissFindings: [ResearchFinding] {
        findings.filter(Self.isInNearMissGroup)
    }

    /// Everything else, likely matches first (Rick 2026-10-01), otherwise
    /// in dossier order.
    var mainFindings: [ResearchFinding] {
        let main = findings.filter { !Self.isInNearMissGroup($0) }
        let likely = main.filter { $0.screening?.outcome == .likelyMatch }
        return likely + main.filter { $0.screening?.outcome != .likelyMatch }
    }

    static func isInNearMissGroup(_ finding: ResearchFinding) -> Bool {
        finding.isNearMiss && (finding.verdict == .unreviewed || finding.verdict == .wrong)
    }
}
