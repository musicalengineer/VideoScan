// StewardEvents.swift
// The EVENTS lane of the Triage tab's suggestions (trial UI, 2026-10-03).
//
// Rick, 2026-10-03: "it should help find events, groups of similar events
// in time … we can't reliably find a person's face since the family looks
// too similar, but we can use heuristic metadata, like the Archive Angel
// does for promotion recommendations, to identify 'someone's birthday' or
// Christmas or Thanksgiving or 'down the Cape'."
//
// NOTHING HERE LABELS ANYTHING ITSELF. The occasion of a clip is whatever
// VideoScanCore.EventLabeler says it is (Archive Angel rules v14): a holiday
// from a trusted day, a People-tab birthday within the window, a curated
// word in the file or folder name with the year. And the DAY a clip is
// trusted to record is the Angel's own answer — `ArchiveAngelEvent.derive`,
// the one derivation behind the Angel's event key and its Occasion line:
// RecordDateResolver (a person's date, a camera's stamp, the dossier's
// date, a date in the name — never a file-system date, never a year range)
// and the rule that a stamp with no camera behind it dates the COPY. This
// file only GROUPS what those two say:
//
//   Event          every clip that carries the same labelled occasion in
//                  the same year (the labeller's own key: "e:christmas:1994",
//                  "e:birthday:alex:2006"). A clip with several labels is in
//                  each of its events, and its card row says "also in: …".
//   …by footage    a clip in a footage group that is Likely or stronger
//                  belongs to the events its group-mates belong to, unless
//                  its own date says otherwise (`conflicts`). A copy with no
//                  date still belongs where its twin belongs.
//   A day to name  `minDayCluster` or more clips that share one trusted day
//                  (or up to `maxDayRun` days running) and carry no label.
//   Same footage   the title guess: the occasion most of the group's dated
//                  members carry; a tie is no guess.
//
// ONE RULE OF ITS OWN, kept from the first trial's QA (F7): a 1 January day
// that no person typed is a camera whose clock was reset far more often
// than it is New Year's Day, so it places nothing. It is a filter on the
// Angel's answer, not a second resolver. Live Photo motion halves (the
// Angel's `isLivePhotoMotion`) are parts of photos and are left out.
//
// NOTHING IS STORED. Events are derived on every build from what the
// records already hold; no record, no catalog file and no log line ever
// receives an event's name.
//
// COST. One `derive` per record (O(characters) of its name; each folder's
// words are scanned once per build — the labeller's FolderWordCache), then
// O(records) grouping. Only the events that make the cut get their rows
// built. Memory: one StewardPlacement per record (~80 bytes, most with no
// labels) ≈ 8 MB at 100k, freed with the build.
//
// (For Rick: `enum StewardEvents` is a namespace of static functions over
// plain value structs — a C++ header of free functions. `inout` ≈ passing
// by non-const reference.)

import Foundation
import VideoScanCore

/// What the catalog can say about ONE clip's occasion.
struct StewardPlacement: Sendable, Equatable {
    /// The day the clip is trusted to record (the Angel's day rule).
    var day: EventDay?
    /// The year it is trusted to record, at any precision.
    var year: Int?
    /// The labeller's labels, in its own order.
    var labels: [EventLabel] = []
    /// False for a Live Photo's motion half — part of a photo, not a clip.
    var isCounted = true
}

/// The occasion a Same-footage group's members point to. Always shown as a
/// question; never stored, never logged.
struct StewardOccasionGuess: Sendable, Equatable {
    /// "Alex's 12th birthday" · "Christmas 2006" · "Cape 1996"
    var text: String
    /// "a guess from the date" · "a guess from the folder name"
    var caption: String

    /// The card title: always phrased as a question.
    var title: String { "Around \(text)?" }
}

/// Title precedence for a Same-footage card (Rick 2026-10-03): the person's
/// NAME for the footage when there is one, else the occasion guess (as a
/// question), else the plain description. `name` is always nil today —
/// footage groups have nowhere to keep a name yet — but the precedence is
/// pinned so a name wins the day it exists.
enum StewardFootageTitle {
    struct Lines: Sendable, Equatable {
        var title: String
        /// Under the title: the guess caption plus the plain description,
        /// or nil when the title IS the plain description.
        var caption: String?
        var isGuess: Bool
    }

    nonisolated static func lines(name: String?, guess: StewardOccasionGuess?, description: String) -> Lines {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            return Lines(title: trimmed, caption: description, isGuess: false)
        }
        if let guess {
            return Lines(title: guess.title, caption: "\(guess.caption) · \(description)", isGuess: true)
        }
        return Lines(title: description, caption: nil, isGuess: false)
    }
}

enum StewardEvents {

    /// An unnamed day gets a card at this many clips.
    static let minDayCluster = 4
    /// Days running that count as one unnamed occasion (a weekend, not a
    /// month of daily phone clips).
    static let maxDayRun = 3
    /// Events kept that are NOT skipped (the headline lane: far more than
    /// the housekeeping lanes' `maxCasesPerKind`).
    static let maxEventCases = 200
    static let maxSkippedEvents = 100
    /// Other occasions named on the "also in" line before "and N more".
    static let maxAlsoInNames = 3
    /// Likely originals named on the "Best copy of each" line.
    static let maxBestCopyNames = 3

    // MARK: The Angel's context, with labels always on

    /// The labeller's inputs as the Angel holds them — its birthday window
    /// and the People tab's birthdays — with the labels switched ON: a
    /// policy that turns the Angel's event labels off changes what the Angel
    /// spreads a batch over, not what an occasion is.
    nonisolated static func context(coverage: AngelCoverageRules, birthdays: [FamilyBirthday]) -> ArchiveAngelEventContext {
        var rules = coverage
        rules.eventLabels = true
        return ArchiveAngelEventContext(coverage: rules, birthdays: birthdays)
    }

    // MARK: One clip (the Angel's derivation, reused)

    /// The clip's trusted day, year and labels — `ArchiveAngelEvent.derive`
    /// over the same date facts the Angel projects, then the one filter
    /// described in the file header.
    nonisolated static func place(_ r: StewardInput, now: Date, context: ArchiveAngelEventContext,
                                  folders: inout EventLabeler.FolderWordCache) -> StewardPlacement {
        let candidate = ArchiveAngelCandidate(
            id: r.id, filename: r.filename, fullPath: r.fullPath,
            userDate: r.userDate, inferredRecordDate: r.inferredDate, inferredDateConfidence: r.inferredConfidence,
            deviceModel: r.originModel ?? "", captureDate: r.embeddedDate,
            userDateConfidence: r.userDateConfidence, originMake: r.originMake, originEncoder: r.originEncoder,
            inferredDateRange: r.inferredRange)
        guard !candidate.isLivePhotoMotion else { return StewardPlacement(isCounted: false) }
        let derived = ArchiveAngelEvent.derive(candidate, now: now, context: context, keysOnly: false, folders: &folders)
        var placement = StewardPlacement(day: trustedDay(inKey: derived.key), year: nil, labels: derived.labels)
        if let claim = derived.claim {
            // The Angel lends a copy-era stamp's year to nothing; neither
            // does this (same threshold, same constant).
            let copyStamp = claim.sourceRank == 1
                && claim.confidenceMilli < Int((ArchiveAngelEvent.dayKeyMinimumConfidence * 1000).rounded())
            placement.year = copyStamp ? nil : derived.year
            // QA F7: 1 January that nobody typed is a reset clock.
            if let day = placement.day, day.month == 1, day.day == 1, claim.sourceRank != 0 {
                placement.day = nil
                placement.labels.removeAll { $0.source != .name }
            }
        }
        return placement
    }

    /// The day in the Angel's event key ("e:christmas:1994|d:1994-12-25" →
    /// 25 Dec 1994); nil when the key carries no day — the file has no
    /// trusted day.
    nonisolated static func trustedDay(inKey key: String) -> EventDay? {
        guard !key.isEmpty, let part = key.split(separator: ArchiveAngelEvent.keySeparator).last,
              part.hasPrefix("d:") else { return nil }
        let numbers = part.dropFirst(2).split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        return EventDay(year: numbers[0], month: numbers[1], day: numbers[2])
    }

    // MARK: Words

    /// "Alex's 12th birthday" for a People-tab birthday (the labeller's own
    /// ordinal), else the labeller's title: "Christmas 1994", "Cape 1996".
    nonisolated static func title(_ label: EventLabel) -> String {
        if let person = label.person, case .birthday(_, let age) = label.why {
            return "\(person)'s \(EventLabeler.ordinal(age)) birthday"
        }
        return label.title
    }

    /// "event:christmas:-:1994" · "event:birthday:alex:2006" — the
    /// labeller's key ("e:christmas:1994", "e:birthday:alex:2006") with the
    /// subject made explicit. Stable across builds and launches.
    nonisolated static func caseID(_ label: EventLabel) -> String? {
        guard let key = label.key, let year = label.year else { return nil }
        guard label.person != nil else { return "event:\(label.event):-:\(year)" }
        let subject = key.dropFirst("e:birthday:".count).dropLast(String(year).count + 1)
        return "event:birthday:\(subject):\(year)"
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August",
                             "September", "October", "November", "December"]

    nonisolated static func shortMonth(_ m: Int) -> String {
        (1...12).contains(m) ? String(monthNames[m - 1].prefix(3)) : "?"
    }

    /// "Dec 25, 1994" · "Dec 24–26, 1994" · "Jul 30 – Aug 1, 1996" ·
    /// "Dec 31, 1994 – Jan 1, 1995".
    nonisolated static func dayRangeText(_ a: EventDay, _ b: EventDay) -> String {
        if a == b { return "\(shortMonth(a.month)) \(a.day), \(a.year)" }
        if a.year == b.year, a.month == b.month { return "\(shortMonth(a.month)) \(a.day)–\(b.day), \(a.year)" }
        if a.year == b.year { return "\(shortMonth(a.month)) \(a.day) – \(shortMonth(b.month)) \(b.day), \(a.year)" }
        return "\(shortMonth(a.month)) \(a.day), \(a.year) – \(shortMonth(b.month)) \(b.day), \(b.year)"
    }

    /// "2 h 10 m" · "48 m" · "30 s".
    nonisolated static func lengthText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(max(0, total)) s" }
        let h = total / 3600, m = (total % 3600) / 60
        if h == 0 { return "\(m) m" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) m"
    }

    /// "14 clips · 3 drives · 2 h 10 m · Dec 24–26, 1994"
    nonisolated static func subtitle(clips: Int, drives: Int, seconds: Double, when: String) -> String {
        var parts = ["\(clips.formatted()) clip\(clips == 1 ? "" : "s")", "\(drives) drive\(drives == 1 ? "" : "s")"]
        if seconds > 0 { parts.append(lengthText(seconds)) }
        if !when.isEmpty { parts.append(when) }
        return parts.joined(separator: " · ")
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar (plain
    /// integer arithmetic — two days running differ by one).
    nonisolated static func dayNumber(_ d: EventDay) -> Int {
        let y = d.month <= 2 ? d.year - 1 : d.year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((d.month + 9) % 12) + 2) / 5 + d.day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }

    // MARK: Footage siblings

    /// Does a footage sibling's own date say it is NOT this event? A clip
    /// with a trusted day would have been labelled by its day, so it
    /// conflicts with any event that clips were placed in by date, and with
    /// any event of another year. A clip that only knows its year conflicts
    /// when the year differs (New Year's Eve belongs to the new year, so
    /// the year before is allowed there). A clip with no date conflicts
    /// with nothing.
    nonisolated static func conflicts(_ sibling: StewardPlacement, event: String, year: Int, hasDatedMembers: Bool) -> Bool {
        if let day = sibling.day {
            return hasDatedMembers || day.year != year
        }
        guard let known = sibling.year else { return false }
        if known == year { return false }
        return !(event == "newyear" && known == year - 1)
    }

    // MARK: The lanes

    /// What the build pass hands over (≈ a const struct of references).
    struct Catalog {
        var inputs: [StewardInput]
        var roots: [String]
        var placements: [StewardPlacement]
        var footageGroups: [UUID: [Int]]
        var skipped: [String: StewardFacts]
    }

    private struct Bucket {
        var label: EventLabel
        var direct: [Int] = []
        var pulled: [Int] = []
        /// Direct members placed by a date (a holiday, a birthday).
        var dated = 0
        var bytes: Int64 = 0
        var seconds: Double = 0
        var count: Int { direct.count + pulled.count }
    }

    /// The Events lane and the days-to-name lane, each in its own order
    /// (most clips first, then the longest, then the id).
    nonisolated static func cases(_ catalog: Catalog, online: (String) -> Bool) -> (events: [StewardCase], days: [StewardCase]) {
        let placed = directMembership(catalog)
        var buckets = placed.buckets
        let unlabelled = placed.unlabelled
        let pulledKeys = pullInFootageSiblings(&buckets, catalog: catalog)

        // Order, then spend the limit on what is not skipped; only the
        // events that make the cut get their rows built.
        let ordered = buckets.sorted { a, b in
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.value.seconds != b.value.seconds { return a.value.seconds > b.value.seconds }
            return a.key < b.key
        }
        var events: [StewardCase] = []
        var active = 0, hidden = 0
        for (key, bucket) in ordered {
            guard let id = caseID(bucket.label) else { continue }
            let facts = StewardFacts(bytes: bucket.bytes, count: bucket.count)
            if let remembered = catalog.skipped[id], !StewardSkipStore.isMaterialChange(from: remembered, to: facts) {
                guard hidden < maxSkippedEvents else { continue }
                hidden += 1
            } else {
                guard active < maxEventCases else { continue }
                active += 1
            }
            events.append(eventCase(id: id, key: key, bucket: bucket, catalog: catalog, online: online,
                                    pulledKeys: pulledKeys, titleOf: { buckets[$0].map { title($0.label) } }))
            if active >= maxEventCases, hidden >= maxSkippedEvents { break }
        }
        return (events, dayCases(unlabelled, catalog: catalog, online: online))
    }

    /// Step 1 — each clip joins each of its labelled occasions once; a
    /// clip with a trusted day and no label goes to its day (day number →
    /// clips), for the days-to-name lane.
    private static func directMembership(_ catalog: Catalog) -> (buckets: [String: Bucket], unlabelled: [Int: [Int]]) {
        let inputs = catalog.inputs, placements = catalog.placements
        var buckets: [String: Bucket] = [:]
        var unlabelled: [Int: [Int]] = [:]
        for i in inputs.indices where placements[i].isCounted {
            var joined: [String] = []
            for label in placements[i].labels {
                guard let key = label.key, !joined.contains(key) else { continue }
                joined.append(key)
                var b = buckets[key] ?? Bucket(label: label)
                b.direct.append(i)
                b.bytes += max(0, inputs[i].sizeBytes)
                b.seconds += max(0, inputs[i].durationSeconds)
                if placements[i].labels.contains(where: { $0.key == key && $0.source != .name }) { b.dated += 1 }
                buckets[key] = b
            }
            if joined.isEmpty, let day = placements[i].day {
                unlabelled[dayNumber(day), default: []].append(i)
            }
        }
        return (buckets, unlabelled)
    }

    /// Step 2 — a footage group that is Likely or stronger shares its
    /// events: every member joins the events its group-mates are in,
    /// unless its own date says otherwise. Returns, per pulled clip, the
    /// events it was pulled into (for the "also in" lines).
    private static func pullInFootageSiblings(_ buckets: inout [String: Bucket], catalog: Catalog) -> [Int: [String]] {
        let inputs = catalog.inputs, placements = catalog.placements
        var pulledKeys: [Int: [String]] = [:]
        for members in catalog.footageGroups.values where members.count > 1 {
            guard (members.map { inputs[$0].footageStrength }.min() ?? 0) >= StewardCaseBuilder.minFootageStrength else { continue }
            var keys: [String] = []
            for m in members {
                for label in placements[m].labels {
                    if let key = label.key, !keys.contains(key) { keys.append(key) }
                }
            }
            for key in keys.sorted() {
                guard var b = buckets[key], let year = b.label.year else { continue }
                for m in members where placements[m].isCounted
                    && !placements[m].labels.contains(where: { $0.key == key })
                    && !conflicts(placements[m], event: b.label.event, year: year, hasDatedMembers: b.dated > 0) {
                    b.pulled.append(m)
                    b.bytes += max(0, inputs[m].sizeBytes)
                    b.seconds += max(0, inputs[m].durationSeconds)
                    pulledKeys[m, default: []].append(key)
                }
                buckets[key] = b
            }
        }
        return pulledKeys
    }

    // MARK: One event card

    // The parameter list is the pass's shared state; a wrapper type would only move it.
    // swiftlint:disable:next function_parameter_count
    private static func eventCase(id: String, key: String, bucket: Bucket, catalog: Catalog, online: (String) -> Bool,
                                  pulledKeys: [Int: [String]], titleOf: (String) -> String?) -> StewardCase {
        let inputs = catalog.inputs, placements = catalog.placements
        let direct = bucket.direct.sorted { a, b in
            let da = placements[a].day.map(dayNumber) ?? Int.max, db = placements[b].day.map(dayNumber) ?? Int.max
            return da != db ? da < db : inputs[a].fullPath < inputs[b].fullPath
        }
        let pulled = bucket.pulled.sorted { inputs[$0].fullPath < inputs[$1].fullPath }
        let members = direct + pulled
        let placed = howPlaced(direct: direct, pulled: pulled.count, key: key, placements: placements)

        // Also in — the other occasions these clips carry.
        func otherKeys(_ i: Int) -> [String] {
            var keys: [String] = []
            for label in placements[i].labels {
                if let k = label.key, k != key, !keys.contains(k) { keys.append(k) }
            }
            for k in pulledKeys[i] ?? [] where k != key && !keys.contains(k) { keys.append(k) }
            return keys
        }
        var shared: [String: Int] = [:]
        var clipsElsewhere = 0
        for i in members {
            let keys = otherKeys(i)
            if !keys.isEmpty { clipsElsewhere += 1 }
            for k in keys { shared[k, default: 0] += 1 }
        }
        let sharedNames = shared.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .compactMap { titleOf($0.key) }

        let when = placed.span.map { dayRangeText($0.first, $0.last) } ?? bucket.label.year.map(String.init) ?? ""
        var drives = Set<String>()
        for i in members { drives.insert(catalog.roots[i]) }

        var c = StewardCase(id: id, kind: .event, title: title(bucket.label),
                            facts: StewardFacts(bytes: bucket.bytes, count: members.count))
        c.detail = subtitle(clips: members.count, drives: drives.count, seconds: bucket.seconds, when: when)
        c.payoffBytes = bucket.bytes
        c.memberCount = members.count
        c.durationSeconds = bucket.seconds
        c.eventKind = bucket.label.event
        c.eventYear = bucket.label.year
        c.whyLine = placed.line
        c.recordIDs = members.prefix(StewardCaseBuilder.maxIDsPerCase).map { inputs[$0].id }
        let pulledSet = Set(pulled)
        c.copies = members.prefix(StewardCaseBuilder.maxCopiesPerCase).map { i in
            var row = StewardCaseBuilder.copy(inputs[i], root: catalog.roots[i], online: online(catalog.roots[i]), standing: .member)
            row.reason = pulledSet.contains(i) ? "by matching footage"
                : placements[i].labels.filter { $0.key == key }.map(\.reason).joined(separator: "; ")
            row.alsoIn = otherKeys(i).compactMap(titleOf).joined(separator: " · ")
            return row
        }
        if clipsElsewhere > 0, !sharedNames.isEmpty {
            let more = sharedNames.count - maxAlsoInNames
            c.alsoInLine = "\(clipsElsewhere.formatted()) of these \(clipsElsewhere == 1 ? "is" : "are") also in: "
                + sharedNames.prefix(maxAlsoInNames).joined(separator: " · ") + (more > 0 ? " and \(more) more" : "")
        }
        fillInside(&c, members: members, catalog: catalog)
        return c
    }

    /// How an event's clips were placed in it — each clip counted once,
    /// under the first reason it has: "9 by date · 5 by folder name 'xmas'
    /// · 2 by matching footage" — and the span of the trusted days among
    /// the clips placed directly (nil when none has a day).
    private static func howPlaced(direct: [Int], pulled: Int, key: String, placements: [StewardPlacement])
        -> (line: String, span: (first: EventDay, last: EventDay)?) {
        var dated = 0
        var named: [String: Int] = [:]
        var first: EventDay?, last: EventDay?
        for i in direct {
            let mine = placements[i].labels.first { $0.key == key }
            if case .word(let place, let word)? = mine?.why {
                named["by \(place) name '\(word)'", default: 0] += 1
            } else {
                dated += 1
            }
            guard let day = placements[i].day else { continue }
            if first.map({ dayNumber(day) < dayNumber($0) }) ?? true { first = day }
            if last.map({ dayNumber(day) > dayNumber($0) }) ?? true { last = day }
        }
        var why: [String] = dated > 0 ? ["\(dated.formatted()) by date"] : []
        why += named.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.value.formatted()) \($0.key)" }
        if pulled > 0 { why.append("\(pulled.formatted()) by matching footage") }
        var span: (first: EventDay, last: EventDay)?
        if let first, let last { span = (first, last) }
        return (why.joined(separator: " · "), span)
    }

    // MARK: What is inside (existing knowledge only)

    /// The INSIDE lines, the copies to review and the one footage group to
    /// open — all from what Find Duplicates, Find Similar Footage and the
    /// archive already put on the records.
    private static func fillInside(_ c: inout StewardCase, members: [Int], catalog: Catalog) {
        let inputs = catalog.inputs
        var bySet: [UUID: [Int]] = [:]
        var byFootage: [UUID: [Int]] = [:]
        var archived = 0
        for i in members {
            if let g = inputs[i].duplicateGroupID { bySet[g, default: []].append(i) }
            if let g = inputs[i].footageGroupID, inputs[i].footageStrength >= StewardCaseBuilder.minFootageStrength {
                byFootage[g, default: []].append(i)
            }
            if inputs[i].protection == .archived || inputs[i].protection == .filedArchived { archived += 1 }
        }
        let sets = bySet.filter { $0.value.count > 1 }
        let groups = byFootage.filter { $0.value.count > 1 }
        var lines: [String] = []
        if !sets.isEmpty {
            let n = sets.values.reduce(0) { $0 + $1.count }
            lines.append("\(n.formatted()) of these are copies of each other (\(sets.count.formatted()) set\(sets.count == 1 ? "" : "s"))")
            let memberOrder = Set(sets.values.joined())
            c.copyReviewIDs = members.filter(memberOrder.contains).prefix(StewardCaseBuilder.maxIDsPerCase).map { inputs[$0].id }
        }
        if !groups.isEmpty {
            let n = groups.values.reduce(0) { $0 + $1.count }
            lines.append("\(n.formatted()) are the same footage (\(groups.count.formatted()) group\(groups.count == 1 ? "" : "s"))")
        }
        if archived > 0 {
            lines.append("\(archived.formatted()) \(archived == 1 ? "is" : "are") in the archive")
        }
        // "Best copy of each" only where Find Similar Footage has already
        // named a likely original that is in the catalog.
        var best: [String] = []
        var originals: [UUID: UUID] = [:]
        for (group, inEvent) in groups.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            guard let lead = inEvent.first, inputs[lead].footageOriginalInCatalog,
                  let originalID = inputs[lead].footageLikelyOriginalID,
                  let original = (catalog.footageGroups[group] ?? inEvent).first(where: { inputs[$0].id == originalID })
            else { continue }
            originals[group] = originalID
            best.append(inputs[original].filename)
        }
        if !best.isEmpty {
            best.sort()
            let more = best.count - maxBestCopyNames
            lines.append((best.count == 1 ? "Best copy: " : "Best copy of each: ")
                + best.prefix(maxBestCopyNames).joined(separator: ", ") + (more > 0 ? " and \(more) more" : ""))
        }
        c.insideLines = lines
        if groups.count == 1, let (group, inEvent) = groups.first {
            c.footageGroupID = group
            c.likelyOriginalID = originals[group] ?? inEvent.first.map { inputs[$0].id }
        }
    }

    // MARK: Days nobody has named

    private static func dayCases(_ unlabelled: [Int: [Int]], catalog: Catalog, online: (String) -> Bool) -> [StewardCase] {
        let inputs = catalog.inputs
        let days = unlabelled.keys.sorted()
        var out: [StewardCase] = []
        var at = 0
        while at < days.count {
            // A run of days one after another, at most `maxDayRun` long.
            var end = at
            while end + 1 < days.count, days[end + 1] == days[end] + 1, end + 1 - at < maxDayRun { end += 1 }
            let members = days[at...end].flatMap { unlabelled[$0] ?? [] }
                .sorted { inputs[$0].fullPath < inputs[$1].fullPath }
            defer { at = end + 1 }
            guard members.count >= minDayCluster,
                  let first = catalog.placements[unlabelled[days[at]]?.first ?? members[0]].day,
                  let last = catalog.placements[unlabelled[days[end]]?.first ?? members[0]].day else { continue }
            var bytes: Int64 = 0
            var seconds = 0.0
            var drives = Set<String>()
            for i in members {
                bytes += max(0, inputs[i].sizeBytes)
                seconds += max(0, inputs[i].durationSeconds)
                drives.insert(catalog.roots[i])
            }
            let span = end - at + 1
            let month = (1...12).contains(first.month) ? monthNames[first.month - 1] : ""
            var c = StewardCase(id: String(format: "day:%04d-%02d-%02d", first.year, first.month, first.day),
                                kind: .unlabelledDay,
                                title: (span == 1 ? "A day" : "\(span) days") + " in \(month) \(first.year)",
                                facts: StewardFacts(bytes: bytes, count: members.count))
            let when = dayRangeText(first, last)
            c.detail = subtitle(clips: members.count, drives: drives.count, seconds: seconds, when: when)
            c.payoffBytes = bytes
            c.memberCount = members.count
            c.durationSeconds = seconds
            c.eventYear = first.year
            c.whyLine = "\(members.count.formatted()) clips are dated \(when), and nothing on them says what the occasion was"
            c.recordIDs = members.prefix(StewardCaseBuilder.maxIDsPerCase).map { inputs[$0].id }
            c.copies = members.prefix(StewardCaseBuilder.maxCopiesPerCase).map { i in
                var row = StewardCaseBuilder.copy(inputs[i], root: catalog.roots[i], online: online(catalog.roots[i]), standing: .member)
                if let day = catalog.placements[i].day { row.reason = "dated " + dayRangeText(day, day) }
                return row
            }
            fillInside(&c, members: members, catalog: catalog)
            out.append(c)
        }
        out.sort {
            if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
            if $0.durationSeconds != $1.durationSeconds { return $0.durationSeconds > $1.durationSeconds }
            return $0.id < $1.id
        }
        return StewardCaseBuilder.limit(out, skipped: catalog.skipped)
    }

    // MARK: The Same-footage title guess

    /// The occasion most of a footage group's DATED members carry: each
    /// member with a trusted day votes for every labelled occasion it has;
    /// the one with strictly the most votes is the guess, and a tie is no
    /// guess at all. The caption says where the winning label came from.
    nonisolated static func footageGuess(members: [Int], placements: [StewardPlacement]) -> StewardOccasionGuess? {
        var votes: [String: (count: Int, dated: Int, label: EventLabel)] = [:]
        for m in members where placements[m].isCounted && placements[m].day != nil {
            var voted: [String] = []
            for label in placements[m].labels {
                guard let key = label.key, !voted.contains(key) else { continue }
                voted.append(key)
                var v = votes[key] ?? (0, 0, label)
                v.count += 1
                if placements[m].labels.contains(where: { $0.key == key && $0.source != .name }) { v.dated += 1 }
                votes[key] = v
            }
        }
        let ranked = votes.sorted { $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key }
        guard let top = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].value.count == top.value.count { return nil }
        let caption: String
        if top.value.dated * 2 >= top.value.count {
            caption = "a guess from the date"
        } else if case .word(let place, _) = top.value.label.why {
            caption = "a guess from the \(place) name"
        } else {
            caption = "a guess from the name"
        }
        return StewardOccasionGuess(text: title(top.value.label), caption: caption)
    }
}
