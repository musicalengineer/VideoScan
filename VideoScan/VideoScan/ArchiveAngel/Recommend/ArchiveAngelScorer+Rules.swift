// ArchiveAngelScorer+Rules.swift
// The scorer's rule interpreter (Consolidation S3b): what each built-in
// floor and signal KIND does. WHICH of them run, in what order, and any
// rule Rick adds, come from the recommendation policy's `floors` /
// `signals` arrays (AngelPolicyDefaults, policy.json); the numbers from its
// `weights`, the lookups from its `tables`. Split out of
// ArchiveAngelScorer.swift so each file stays readable.
//
// (For Rick: a switch over the rule's tag — the "virtual dispatch" of the
// rule table — with the thresholds passed in, never read from globals.)

import Foundation
import VideoScanCore

extension ArchiveAngelScorer {

    // MARK: Floors

    /// The first enabled floor that rejects `c`, in the policy's order
    /// (the order = the reason the user should hear first), with the rule
    /// itself so a policy rule's own words can be shown. A `starExempt`
    /// floor passes any starred file (machine evidence yields to a
    /// person's star); `when` narrows any floor to the files it names.
    static func floorHit(_ c: ArchiveAngelCandidate, policy p: AngelRecommendationPolicy,
                         now: Date = Date()) -> (rejection: ArchiveAngelRejection, rule: AngelRule)? {
        // Read the rules in place (a `for rule in` loop copies each rule —
        // its strings and arrays — per record: most of the interpreter's
        // cost at 100k). ≈ iterating a const std::vector by reference.
        // The weights and tables are hoisted once per record; each floor
        // gets only what it reads (no rule or policy copy per floor).
        // One context per record, shared by every floor's `when` (it only
        // caches the date resolution, which is per candidate anyway).
        var ctx = AngelEvalContext(now: now)
        // Through the element POINTER: `buffer[i].field` returns a copy of
        // the whole rule (strings, arrays) in an unoptimized build; a
        // pointer subscript is an in-place address (≈ `const Rule&`).
        return p.floors.withUnsafeBufferPointer { buffer -> (rejection: ArchiveAngelRejection, rule: AngelRule)? in
            guard let floors = buffer.baseAddress else { return nil }
            for i in 0..<buffer.count {
                guard floors[i].enabled, let kind = floors[i].resolvedKind else { continue }
                if floors[i].starExempt && c.starRating > 0 { continue }
                if !floors[i].when.isEmpty {
                    guard AngelCondition.all(floors[i].when, c, &ctx) else { continue }
                    if kind == .match {
                        let reason = floors[i].rejection.flatMap(ArchiveAngelRejection.named) ?? .policyRule
                        return (reason, floors[i])
                    }
                }
                if let rejection = floorFires(kind, c, policy: p, now: now) { return (rejection, floors[i]) }
            }
            return nil
        }
    }

    /// One built-in floor's verdict on `c` (nil = passes); thresholds come
    /// from `weights` and `tables`. A `match` floor is decided by its `when`
    /// in `floorHit` (never here — an empty `when` matches nothing).
    static func floorFires(_ kind: AngelRuleKind, _ c: ArchiveAngelCandidate,
                           policy p: AngelRecommendationPolicy, now: Date) -> ArchiveAngelRejection? {
        switch kind {
        case .match:
            return nil
        case .notVideo:
            switch c.streamTypeRaw {
            case StreamType.videoAndAudio.rawValue, StreamType.videoOnly.rawValue: return nil
            default: return .notVideo
            }
        case .onMasterArchive:
            return c.isOnMasterArchive ? .alreadyArchived : nil
        case .archivedCopy:
            return c.hasArchivedDuplicate ? .duplicateArchived : nil
        case .notPlayable:
            let playable = c.isPlayable.lowercased()
            return playable.hasPrefix("no") || playable.contains("unsupported") ? .notPlayable : nil
        case .pairedHalf:
            return c.isPairedHalf ? .pairedHalf : nil
        case .livePhotoMotion:
            // Rick 2026-09-21. Ahead of `.tooShort` so a 3 s Live Photo
            // half is counted as what it is, not as a short clip.
            return p.weights.excludeLivePhotoMotion && c.isLivePhotoMotion ? .livePhotoMotion : nil
        case .recentPhoneClip:
            guard p.weights.excludeRecentPhoneClips, c.isPhoneClip,
                  Self.isRecent(captureDate: c.captureDate, years: p.weights.recentPhoneClipYears, now: now) else { return nil }
            return .recentPhoneClip
        case .appCache:
            return Self.looksLikeAppCache(filename: c.filename, fullPath: c.fullPath, tables: p.tables) ? .appCache : nil
        case .derivativeOfOriginal:
            return c.derivativeOfOriginal != nil ? .derivativeOfOriginal : nil
        case .tooShort:
            return c.durationSeconds < p.weights.minimumDurationSeconds ? .tooShort : nil
        case .proxyStream:
            guard c.durationSeconds > 0, c.sizeBytes > 0,
                  Double(c.sizeBytes) * 8 / c.durationSeconds / 1000 < p.weights.minimumAverageKilobitsPerSecond else { return nil }
            return .proxyStream
        case .markedJunk:
            return c.mediaDisposition == .confirmedJunk ? .junk : nil
        case .suspectedJunk:
            return c.mediaDisposition == .suspectedJunk ? .suspectedJunk : nil
        case .junkScore:
            return c.junkScore >= p.weights.junkFloor ? .suspectedJunk : nil
        case .volumeOffline:
            return c.volumeOnline ? nil : .volumeOffline
        case .resting:
            return c.attention.restingUntil(now: now, weights: p.weights) != nil ? .resting : nil
        default:
            return nil   // a signal kind in the floors list — validation refuses it
        }
    }

    // MARK: Signals

    /// One signal's evidence line, or nil when it has nothing to say.
    /// The built-in kinds read their numbers from `weights`; `match` adds
    /// the rule's own points and line. The cap and fatigue act on `lines`
    /// (the total so far), so they belong at the end of the list.
    static func signal(_ kind: AngelRuleKind, rule: AngelRule, _ c: ArchiveAngelCandidate,
                       lines: [ArchiveAngelEvidence], policy p: AngelRecommendationPolicy,
                       now: Date) -> ArchiveAngelEvidence? {
        let w = p.weights
        switch kind {
        case .match:
            return .init(points: rule.points, line: rule.displayLine)
        case .stars:
            switch c.starRating {
            case 3...: return .init(points: w.threeStars, line: "You rated it best (★★★)")
            case 2:    return .init(points: w.twoStars, line: "You rated it better (★★)")
            case 1:    return .init(points: w.oneStar, line: "You rated it good (★)")
            default:   return nil
            }
        case .confirmedPeople:
            guard !c.confirmedPeople.isEmpty else { return nil }
            let pts = min(w.confirmedPersonCap, Self.product(w.confirmedPersonEach, c.confirmedPeople.count))
            return .init(points: pts, line: c.confirmedPeople.joined(separator: ", ") + " (confirmed)")
        case .machinePeople:
            var seen = Set<String>()
            let machineOnly = (c.detectedPeople + c.suspectedPeople).filter {
                !c.confirmedPeople.contains($0) && seen.insert($0).inserted
            }
            guard !machineOnly.isEmpty else { return nil }
            let pts = min(w.machinePersonCap, Self.product(w.machinePersonEach, machineOnly.count))
            return .init(points: pts, line: "Looks like " + machineOnly.joined(separator: ", ") + " (machine)")
        case .playHistory:
            return playHistoryLine(c, weights: w, now: now)
        case .richness:
            let richness = Self.richnessItems(c)
            guard !richness.isEmpty else { return nil }
            return .init(points: min(w.richnessCap, Self.product(w.richnessEach, richness.count)),
                         line: "Has " + richness.joined(separator: ", "))
        case .date:
            return dateLine(c, weights: w)
        case .duration:
            guard let (pts, tier) = Self.durationTier(c.durationSeconds, weights: w) else { return nil }
            return .init(points: pts, line: "Runs \(Self.durationText(c.durationSeconds)) — \(tier)")
        case .formatAtRisk:
            return c.formatAtRisk ? .init(points: w.formatAtRisk, line: "At-risk format — archive sooner") : nil
        case .onlyCopy:
            return c.isOnlyCopy ? .init(points: w.onlyCopy, line: "This is the only copy") : nil
        case .unassignedVolume:
            return c.volumeRole == .unassigned
                ? .init(points: w.riskyVolume, line: "Lives on \(c.volumeName) (no role assigned)") : nil
        case .audioProblem:
            guard let problem = c.audioProblem, !problem.isEmpty else { return nil }
            return .init(points: 0, line: "Audio: \(problem) — will balance")
        case .downloadCap:
            return downloadCapLine(c, lines: lines, policy: p)
        case .fatigue:
            // Attention memory (Phase 1): fatigue last, as a negative line
            // over everything above it, so the score stays the sum of its
            // printed reasons. Novelty is deliberately NOT points — being
            // new earns a reserved slot (`withFreshSlots`), not a grade.
            return fatigueLine(c, lines: lines, weights: w, now: now)
        default:
            return nil   // a floor kind in the signals list — validation refuses it
        }
    }

    static func playHistoryLine(_ c: ArchiveAngelCandidate, weights w: ArchiveAngelWeights,
                                now: Date) -> ArchiveAngelEvidence? {
        guard c.useCount > 0 else { return nil }
        var pts = min(w.playHistoryCap,
                      Self.clampedInt((w.playHistoryPerDoubling * log2(1.0 + Double(c.useCount))).rounded()))
        var line = c.useCount == 1 ? "Played once" : "Played \(c.useCount) times"
        if let last = c.lastUsed {
            line += ", last on " + Self.dayFormatter.string(from: last)
            if now.timeIntervalSince(last) < w.playedRecentlyDays * 86_400 { pts = Self.sum(pts, w.playedRecentlyBonus) }
        }
        return .init(points: pts, line: line)
    }

    static func dateLine(_ c: ArchiveAngelCandidate, weights w: ArchiveAngelWeights) -> ArchiveAngelEvidence? {
        if let userDate = c.userDate, !userDate.isEmpty {
            return .init(points: w.dateKnown, line: "Dated \(userDate) (yours)")
        }
        if let d = c.inferredRecordDate {
            let conf = c.inferredDateConfidence ?? 0
            if conf >= w.dateConfidenceKnown {
                return .init(points: w.dateKnown, line: "Dated " + Self.dayFormatter.string(from: d)
                             + String(format: " (consensus %.2f)", conf))
            }
            return .init(points: w.dateLowConfidence, line: "Date uncertain — "
                         + Self.dayFormatter.string(from: d) + String(format: " (%.2f)", conf))
        }
        return c.hasEmbeddedDate ? .init(points: w.dateKnown, line: "Dated by the camera") : nil
    }
}
