// ArchiveAngelAttentionTests.swift
// Phase 1 of docs/archive_angel_curation_direction.md (Rick 2026-09-19):
// the Angel REMEMBERS what it showed you. Five dimensions:
//   LOGIC     the summary, the family key, the scorer's novelty / fatigue /
//             resting lines, one-per-family, the fresh slots, the evidence
//             pick's fresh scan and staleness, explicit picks ignoring it;
//   SCALE     the 10k-record simulation with a skip-everything user — THE
//             METRIC (distinct files seen, catalog touched, max repeats)
//             against today's behaviour, under a time budget;
//   ISOLATION pure values and a store fed from event arrays; the one
//             model test writes to a sandbox ledger, never the real file;
//   SENSOR    the simulation pins the numbers, the store rebuild pins the
//             ledger-is-the-truth contract;
//   MEDIA     n/a — no media is opened here.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let day = 86_400.0
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func event(_ kind: MediaLedgerEvent.Kind, _ id: UUID, at: Date, content: String = "",
                   by: MediaLedgerEvent.Actor = .rick) -> MediaLedgerEvent {
    MediaLedgerEvent(at: at, event: kind, recordID: id, contentKey: content,
                     filename: "f.mov", fullPath: "/Volumes/T/f.mov", by: by)
}

// MARK: - 1. The summary

@Suite("Archive Angel attention — the per-record summary")
struct ArchiveAngelAttentionSummaryTests {

    @Test("a fresh summary is new; a proposal, a skip and a clear are counted and dated")
    func counts() {
        var a = ArchiveAngelAttention.none
        #expect(a.isNew)
        a.note(.angelProposed, at: t0)
        #expect(!a.isNew && a.timesProposed == 1 && a.lastProposedAt == t0)
        a.note(.angelSkipped, at: t0 + 60)
        a.note(.angelCleared, at: t0 + 120)
        #expect(a.timesSkipped == 1 && a.timesCleared == 1)
        #expect(a.lastSkippedAt == t0 + 120, "a clear is a pass too")
        a.note(.archived, at: t0 + 200)   // not an attention kind
        #expect(a.timesProposed == 1 && a.timesSkipped == 1 && a.timesCleared == 1)
    }

    @Test("effective skips: recent = 1, older than 90 days = ½, a clear = ½ of a skip")
    func effectiveSkips() {
        var a = ArchiveAngelAttention.none
        a.note(.angelSkipped, at: t0 - 100 * day)
        a.note(.angelSkipped, at: t0 - 1 * day)
        a.note(.angelCleared, at: t0 - 2 * day)
        #expect(a.effectiveSkips(now: t0) == 0.5 + 1 + 0.5)
    }

    @Test("resting after 3 effective skips, for 90 days from the LAST pass; an old third skip does not rest")
    func resting() {
        var a = ArchiveAngelAttention.none
        for d in [30.0, 20.0, 10.0] { a.note(.angelSkipped, at: t0 - d * day) }
        #expect(a.restingUntil(now: t0) == t0 + 80 * day)
        #expect(a.restingUntil(now: t0 + 81 * day) == nil, "back after 90 days from the last pass")
        var b = ArchiveAngelAttention.none
        for d in [200.0, 150.0, 10.0] { b.note(.angelSkipped, at: t0 - d * day) }
        #expect(b.effectiveSkips(now: t0) == 2.0)
        #expect(b.restingUntil(now: t0) == nil, "two old skips count one — not resting")
    }

    @Test("merging two summaries deduplicates the same ledger line seen through two keys")
    func merge() {
        var a = ArchiveAngelAttention.none; a.note(.angelSkipped, at: t0)
        var b = ArchiveAngelAttention.none; b.note(.angelSkipped, at: t0); b.note(.angelSkipped, at: t0 + 10)
        let m = a.merged(with: b)
        #expect(m.timesSkipped == 2)
    }

    @Test("bounded: only the most recent 12 of a kind are kept")
    func bounded() {
        var a = ArchiveAngelAttention.none
        for i in 0..<40 { a.note(.angelProposed, at: t0 + Double(i)) }
        #expect(a.timesProposed == ArchiveAngelAttention.keep)
        #expect(a.lastProposedAt == t0 + 39)
    }
}

// MARK: - 2. The store

@Suite("Archive Angel attention — the store is derived from the ledger")
@MainActor
struct ArchiveAngelAttentionStoreTests {

    @Test("build from events: per record, content twins share, lastEventAt is the newest line, other kinds ignored")
    func build() {
        let a = UUID(), twin = UUID(), other = UUID()
        let s = ArchiveAngelAttentionStore()
        s.replace(from: [
            event(.angelProposed, a, at: t0, content: "h:one", by: .angel),
            event(.angelSkipped, a, at: t0 + 10, content: "h:one"),
            event(.angelProposed, twin, at: t0 + 20, content: "h:one", by: .angel),
            event(.archived, other, at: t0 + 30, content: "h:two", by: .promote),
        ])
        #expect(s.isLoaded)
        #expect(s.recordCount == 2)
        #expect(s.summary(recordID: a, contentKey: "h:one").timesProposed == 2, "the twin's proposal counts")
        #expect(s.summary(recordID: twin, contentKey: "h:one").timesSkipped == 1, "the twin was passed on too")
        #expect(s.summary(recordID: other, contentKey: "h:two").isNew, "archived is not attention")
        #expect(s.summary(recordID: UUID(), contentKey: "").isNew)
        #expect(s.lastEventAt == t0 + 20)
    }

    @Test("note() folds new lines in incrementally and equals a rebuild — the ledger is the truth (SENSOR)")
    func incrementalEqualsRebuild() {
        let ids = (0..<20).map { _ in UUID() }
        var events: [MediaLedgerEvent] = []
        for (i, id) in ids.enumerated() {
            events.append(event(.angelProposed, id, at: t0 + Double(i), content: "h:\(i % 5)", by: .angel))
            if i % 3 == 0 { events.append(event(.angelSkipped, id, at: t0 + 100 + Double(i), content: "h:\(i % 5)")) }
        }
        let incremental = ArchiveAngelAttentionStore()
        for e in events { incremental.note([e]) }
        let rebuilt = ArchiveAngelAttentionStore()
        rebuilt.replace(from: events)
        for id in ids {
            #expect(incremental.summary(recordID: id, contentKey: "h:1") == rebuilt.summary(recordID: id, contentKey: "h:1"))
        }
        #expect(incremental.lastEventAt == rebuilt.lastEventAt)
        #expect(incremental.revision == events.count)
    }

    @Test("load(from:) reads a ledger file off-main; a missing file leaves an empty, loaded store")
    func loadsFromLedger() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_attention_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = MediaLedger(directory: dir)
        let id = UUID()
        ledger.append([event(.angelProposed, id, at: t0, by: .angel), event(.angelSkipped, id, at: t0 + 5)])
        await ledger.waitForPendingWrites()
        let s = ArchiveAngelAttentionStore()
        await s.load(from: ledger)
        #expect(s.summary(recordID: id, contentKey: "").timesSkipped == 1)
        let empty = ArchiveAngelAttentionStore()
        await empty.load(from: MediaLedger(directory: dir.appendingPathComponent("nope")))
        #expect(empty.isLoaded && empty.recordCount == 0)
    }

    @Test("codex 2026-09-20 #8: a skip noted WHILE the launch read is open survives the load; lastEventAt never moves backward; a line seen both ways is one line")
    func loadFoldsInEventsNotedDuringTheRead() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_attention_fold_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let ledger = MediaLedger(directory: dir)
        let a = UUID(), b = UUID()
        ledger.append([event(.angelProposed, a, at: t0, by: .angel), event(.angelSkipped, a, at: t0 + 5)])
        await ledger.waitForPendingWrites()

        let s = ArchiveAngelAttentionStore()
        let gate = TestGate()
        let loading = Task { @MainActor in
            await s.load(from: ledger, reader: { l in
                await gate.wait()
                return await ArchiveAngelAttentionStore.readOffMain(l)
            })
        }
        // The read is open. The person skips b — the production path notes
        // it in memory AND appends the same line to the ledger.
        let skipB = event(.angelSkipped, b, at: t0 + 100, content: "h:b")
        s.note([skipB])
        ledger.append([skipB])
        await ledger.waitForPendingWrites()
        let revisionBeforeLoad = s.revision
        #expect(s.lastEventAt == t0 + 100)
        #expect(!s.isLoaded)

        gate.open()
        await loading.value
        #expect(s.isLoaded)
        #expect(s.summary(recordID: a, contentKey: "").timesProposed == 1)
        #expect(s.summary(recordID: a, contentKey: "").timesSkipped == 1, "the loaded lines are there")
        #expect(s.summary(recordID: b, contentKey: "h:b").timesSkipped == 1, "the mid-read skip survived — and is ONE skip, not two")
        #expect(s.lastEventAt == t0 + 100, "the older ledger tail did not move lastEventAt backward")
        #expect(s.revision > revisionBeforeLoad)
        #expect(s.recordsByContent["h:b"] == [b])
    }
}

/// A latch a test holds shut while it does something, then opens.
private final class TestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    func open() { lock.withLock { isOpen = true } }
    func wait() async {
        while !(lock.withLock { isOpen }) { try? await Task.sleep(nanoseconds: 10_000_000) }
    }
}

// MARK: - 3. Event families

@Suite("Archive Angel attention — event families")
struct ArchiveAngelFamilyTests {

    @Test("share-out and derivative tokens are stripped from the end; the folder is part of the key", arguments: [
        ("Thanksgiving_2009.mov", "thanksgiving_2009"),
        ("Thanksgiving_2009_fixedup.mov", "thanksgiving_2009"),
        ("Thanksgiving_2009_clip1.mov", "thanksgiving_2009"),
        ("Thanksgiving_2009 clip 2.mov", "thanksgiving_2009"),
        ("Thanksgiving_2009_1.mov", "thanksgiving_2009_1"),   // a bare number is not a token
        ("Thanksgiving_2009 (2).mov", "thanksgiving_2009"),
        ("Thanksgiving_2009_balanced.vs.edit.mov", "thanksgiving_2009"),
        ("Thanksgiving_2009_fixed_clip1.mov", "thanksgiving_2009"),
        ("Christmas 1995 part 2.dv", "christmas 1995"),
        ("Beach-v2.mov", "beach"),
        ("cape-1992.mov", "cape-1992"),          // a year is not a counter
        ("Tape 12.dv", "tape 12"),               // two tapes are two families
        ("v2.mov", "v2"),                        // a bare token is the whole name — kept
        ("Clip 08.mov", "clip 08"),
    ])
    func baseStems(filename: String, expected: String) {
        let key = ArchiveAngelFamily.key(filename: filename, fullPath: "/Volumes/T/Family/" + filename)
        #expect(key == "/volumes/t/family|" + expected, Comment(rawValue: key))
    }

    @Test("the same stem in two folders is two families; the key is case-insensitive")
    func folders() {
        let a = ArchiveAngelFamily.key(filename: "Tape 1.dv", fullPath: "/Volumes/A/Tape 1.dv")
        let b = ArchiveAngelFamily.key(filename: "Tape 1.dv", fullPath: "/Volumes/B/Tape 1.dv")
        let c = ArchiveAngelFamily.key(filename: "TAPE 1.DV", fullPath: "/Volumes/A/TAPE 1.DV")
        #expect(a != b)
        #expect(a == c)
    }
}

// MARK: - 4. The scorer

@Suite("Archive Angel attention — the scorer reads it")
struct ArchiveAngelAttentionScorerTests {

    private func skipped(_ n: Int, daysAgo: Double = 1) -> ArchiveAngelAttention {
        var a = ArchiveAngelAttention.none
        a.note(.angelProposed, at: t0 - (daysAgo + 1) * day)
        for i in 0..<n { a.note(.angelSkipped, at: t0 - (daysAgo + Double(i)) * day) }
        return a
    }

    private func score(_ c: ArchiveAngelCandidate) -> (Int, [String]) {
        guard case .eligible(let s, let lines) = ArchiveAngelScorer.verdict(c, now: t0) else { return (-1, []) }
        return (s, lines.map(\.line))
    }

    @Test("being new is not points: a never-proposed file and a once-proposed file score the same; a proposal alone is no fatigue")
    func noveltyIsNotAGrade() {
        let fresh = score(.init(durationSeconds: 900, starRating: 2))
        var seen = ArchiveAngelAttention.none; seen.note(.angelProposed, at: t0 - day)
        let shown = score(.init(durationSeconds: 900, starRating: 2, attention: seen))
        #expect(fresh.0 == shown.0)
        #expect(!fresh.1.contains { $0.hasPrefix("New to you") }, "the line is added by the pick, not the grade")
        #expect(!shown.1.contains { $0.hasPrefix("You skipped") })
        // A capped download stays capped whether or not it is new (the fault the old suites caught).
        let rip = ArchiveAngelCandidate(filename: "Gladiator.mp4", sizeBytes: 2_640_000_000, durationSeconds: 10_260, videoCodec: "h264")
        #expect(score(rip).0 == ArchiveAngelWeights.standard.downloadCapScore)
    }

    @Test("fatigue: one skip halves the score, two quarter it — printed as ONE negative line, score = sum of lines")
    func fatigue() {
        let base = score(.init(durationSeconds: 3600, starRating: 3, attention: {
            var a = ArchiveAngelAttention.none; a.note(.angelProposed, at: t0 - 3 * day); return a }()))
        let once = score(.init(durationSeconds: 3600, starRating: 3, attention: skipped(1)))
        let twice = score(.init(durationSeconds: 3600, starRating: 3, attention: skipped(2)))
        #expect(base.0 == 165, "3★ 100 + whole tape 60 + richness 5")
        #expect(once.0 == Int((Double(base.0) * 0.5).rounded()))
        #expect(twice.0 == Int((Double(base.0) * 0.25).rounded()))
        #expect(once.1.last?.hasPrefix("You skipped it once") == true, Comment(rawValue: once.1.last ?? ""))
        #expect(twice.1.last?.contains("score × 0.25") == true)
        guard case .eligible(_, let lines) = ArchiveAngelScorer.verdict(.init(durationSeconds: 3600, starRating: 3, attention: skipped(1)), now: t0) else { return }
        #expect(lines.reduce(0) { $0 + $1.points } == once.0, "the score is still the sum of its printed reasons")
    }

    @Test("three skips within 90 days → resting (a floor reason); 91 days after the last one it is back, fatigued")
    func resting() {
        let c = ArchiveAngelCandidate(durationSeconds: 3600, starRating: 3, attention: skipped(3))
        #expect(ArchiveAngelScorer.verdict(c, now: t0) == .rejected(.resting))
        guard case .eligible(let s, _) = ArchiveAngelScorer.verdict(c, now: t0 + 91 * day) else {
            Issue.record("must be back after the rest"); return
        }
        #expect(s < 160 && s > 0)
    }

    @Test("a clear is half a skip: two clears ≈ one skip")
    func clears() {
        var a = ArchiveAngelAttention.none
        a.note(.angelProposed, at: t0 - 3 * day)
        a.note(.angelCleared, at: t0 - 2 * day); a.note(.angelCleared, at: t0 - 1 * day)
        let s = score(.init(durationSeconds: 3600, starRating: 3, attention: a))
        #expect(s.0 == Int((165.0 * 0.5).rounded()))
        #expect(s.1.last?.hasPrefix("You passed on it (a batch cleared 2 times undecided)") == true, Comment(rawValue: s.1.last ?? ""))
    }

    @Test("family share: a variant of a skipped file carries half its skips and is not 'new'")
    func familyShare() {
        var cs = [
            ArchiveAngelCandidate(filename: "Thanksgiving_2009.mov", fullPath: "/V/T/Thanksgiving_2009.mov",
                                  durationSeconds: 3600, starRating: 3, attention: skipped(2)),
            ArchiveAngelCandidate(filename: "Thanksgiving_2009_clip1.mov", fullPath: "/V/T/Thanksgiving_2009_clip1.mov",
                                  durationSeconds: 3600, starRating: 3),
            ArchiveAngelCandidate(filename: "Easter_2009.mov", fullPath: "/V/T/Easter_2009.mov",
                                  durationSeconds: 3600, starRating: 3),
        ]
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: t0)
        #expect(cs[0].familySkips == 0)
        #expect(cs[1].familySkips == 2)
        #expect(cs[2].familySkips == 0)
        let variant = score(cs[1]), unrelated = score(cs[2])
        #expect(variant.0 == Int((165.0 * 0.5).rounded()), "2 family skips × ½ share = 1 effective skip → halved")
        #expect(variant.1.last?.contains("variants") == true, Comment(rawValue: variant.1.last ?? ""))
        #expect(!cs[1].isFreshToPerson, "a variant of a skipped file is not fresh eyes")
        #expect(cs[2].isFreshToPerson)
        #expect(unrelated.0 == 165)
    }

    @Test("one member per event family per batch; the rest counted under sameFamilyAsPick")
    func onePerFamily() {
        func c(_ name: String, _ stars: Int) -> ArchiveAngelCandidate {
            .init(filename: name, fullPath: "/V/T/" + name, durationSeconds: 3600, starRating: stars)
        }
        let sel = ArchiveAngelScorer.select([c("X_2009.mov", 3), c("X_2009_fixedup.mov", 3), c("X_2009_clip1.mov", 2), c("Y.mov", 1)], count: 3, now: t0)
        #expect(sel.picks.map(\.candidate.filename) == ["X_2009.mov", "Y.mov"])
        #expect(sel.rejected[.sameFamilyAsPick] == 2)
    }

    @Test("fresh slots: 3 of 10 go to never-proposed files past the cut; the lowest already-proposed picks make room; result stays ranked")
    func freshSlots() {
        var seen = ArchiveAngelAttention.none; seen.note(.angelProposed, at: t0 - day)
        var cs: [ArchiveAngelCandidate] = []
        for i in 0..<12 {   // 12 proposed favourites, 3★ + long → ~160 each (ties broken by name)
            cs.append(.init(filename: String(format: "fav%02d.mov", i), fullPath: "/V/F/fav\(i).mov",
                            durationSeconds: 3600 + Double(12 - i), starRating: 3, attention: seen))
        }
        for i in 0..<5 {    // 5 new plain files, 15 min → 25 (the fresh floor)
            cs.append(.init(filename: "new\(i).mov", fullPath: "/V/N/new\(i).mov", durationSeconds: 900 + Double(5 - i)))
        }
        let sel = ArchiveAngelScorer.select(cs, count: 10, now: t0)
        let names = sel.picks.map(\.candidate.filename)
        #expect(names.filter { $0.hasPrefix("new") }.count == 3, "\(names)")
        #expect(names.filter { $0.hasPrefix("fav") } == (0..<7).map { String(format: "fav%02d.mov", $0) }, "the top 7 favourites stay; 7–9 make room")
        #expect(sel.picks.map(\.score) == sel.picks.map(\.score).sorted(by: >), "still in rank order")
        for p in sel.picks where p.candidate.filename.hasPrefix("new") {
            #expect(p.evidence.last?.line == ArchiveAngelScorer.freshLine && p.evidence.last?.points == 0, "the person reads why it is here")
        }
        // Below the fresh floor a new file does not get a slot.
        let weak = ArchiveAngelScorer.withFreshSlots(
            [ArchiveAngelPick(candidate: cs[0], score: 160, evidence: []),
             ArchiveAngelPick(candidate: .init(filename: "weak.mov"), score: 10, evidence: [])], count: 1)
        #expect(weak.map(\.candidate.filename) == ["fav00.mov"])
    }

    @Test("an explicit 'Prepare with Archive Angel' pick ignores resting and fatigue — the person chose it")
    func explicitIgnoresAttention() {
        let id = UUID()
        let sel = ArchiveAngelJob.explicitSelection(ids: [id], inFlight: [], now: t0) { _ in
            ArchiveAngelCandidate(id: id, durationSeconds: 3600, starRating: 3, attention: skipped(3))
        }
        #expect(sel.picks.count == 1)
        guard case .eligible(let unfatigued, _) = ArchiveAngelScorer.verdict(.init(id: id, durationSeconds: 3600, starRating: 3), now: t0) else { return }
        #expect(sel.picks.first?.score == unfatigued, "no fatigue — scored as if never seen")
    }

    @Test("a resting original still counts as the original of its derivative export")
    func restingOriginalStillOriginal() {
        var cs = [
            ArchiveAngelCandidate(filename: "Tape.mov", fullPath: "/V/T/Tape.mov", durationSeconds: 3600, attention: skipped(3)),
            ArchiveAngelCandidate(filename: "Tape_balanced.mov", fullPath: "/V/T/Tape_balanced.mov", durationSeconds: 3600),
        ]
        ArchiveAngelScorer.markDerivatives(&cs)
        #expect(cs[1].derivativeOfOriginal == "Tape.mov")
    }
}

// MARK: - 5. The evidence pick

@Suite("Archive Angel attention — the evidence pick")
@MainActor
struct ArchiveAngelAttentionEvidencePickTests {

    private func rec(_ score: Int, proposed: Int = 0, at: Date) -> ArchiveAngelEvidenceRecord {
        .init(score: score, lines: [.init(points: score, line: "why \(score)")], rejection: nil,
              useCount: 0, lastUsed: nil, computedAt: at, timesProposed: proposed)
    }

    private func store(records: [UUID: ArchiveAngelEvidenceRecord], computedAt: Date) -> ArchiveAngelEvidenceStore {
        let s = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_att_pick_\(UUID().uuidString.prefix(8))"))
        s.replace(with: .init(computedAt: computedAt, complete: true, considered: records.count,
                              eligible: records.count, records: records))
        return s
    }

    @Test("evidence computed before the newest attention event is not trusted — the caller walks")
    func staleAgainstAttention() {
        let a = UUID(), b = UUID()
        let s = store(records: [a: rec(150, at: t0 - 3600), b: rec(90, at: t0 - 3600)], computedAt: t0 - 3600)
        let stale = ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionChangedAt: t0 - 60) { ArchiveAngelCandidate(id: $0) }
        #expect(stale == nil)
        let ok = ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionChangedAt: t0 - 7200) { ArchiveAngelCandidate(id: $0) }
        #expect(ok?.selection.picks.count == 1)
    }

    @Test("past the band only never-proposed records are projected, until 3 fresh files are in hand; they take the lowest proposed slots")
    func freshScanPastBand() {
        var seen = ArchiveAngelAttention.none; seen.note(.angelProposed, at: t0 - day)
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        var proposed: [UUID] = [], fresh: [UUID] = [], weakFresh: [UUID] = []
        for i in 0..<10 { let id = UUID(); proposed.append(id); records[id] = rec(200 - i, proposed: 1, at: t0) }
        for i in 0..<4 { let id = UUID(); fresh.append(id); records[id] = rec(60 - i, at: t0) }
        for i in 0..<3 { let id = UUID(); weakFresh.append(id); records[id] = rec(10 - i, at: t0) }
        let s = store(records: records, computedAt: t0)
        var projected: [UUID] = []
        let pick = ArchiveAngelJob.selectFromEvidence(store: s, count: 10, now: t0) { id in
            projected.append(id)
            return ArchiveAngelCandidate(id: id, filename: "\(id).mov", fullPath: "/V/\(id).mov",
                                         attention: proposed.contains(id) ? seen : .none)
        }
        let ids = pick?.selection.picks.map(\.candidate.id) ?? []
        #expect(ids.count == 10)
        #expect(Set(ids).intersection(fresh).count == 3, "three fresh slots")
        #expect(Set(ids).intersection(proposed) == Set(proposed.prefix(7)), "the lowest three favourites made room")
        #expect(!projected.contains { weakFresh.contains($0) }, "under the fresh floor nothing is projected")
        #expect(projected.count == 13, "10 heads + exactly 3 fresh looks")
    }

    @Test("codex 2026-09-20 #5: evidence stamped with an OLDER attention revision than the store holds now is refused, whatever computedAt says; the same revision is trusted")
    func staleByRevision() {
        let a = UUID(), b = UUID()
        let s = ArchiveAngelEvidenceStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("test_angel_att_rev_\(UUID().uuidString.prefix(8))"))
        // Scored under revision 3 with the newest event at t0 - 600; the
        // file was WRITTEN at t0 (a skip at t0 - 60 landed while scoring).
        s.replace(with: .init(computedAt: t0, complete: true, considered: 2, eligible: 2,
                              records: [a: rec(150, at: t0), b: rec(90, at: t0)],
                              attentionRevision: 3, attentionLastEventAt: t0 - 600))
        let byRevision = ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionRevision: 4) { ArchiveAngelCandidate(id: $0) }
        #expect(byRevision == nil, "revision 4 > stamped 3 → walk")
        let byDate = ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionChangedAt: t0 - 60) { ArchiveAngelCandidate(id: $0) }
        #expect(byDate == nil, "the fallback compares to the STAMPED lastEventAt, not computedAt: t0 - 60 > t0 - 600 → walk")
        let current = ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0,
                                                         attentionChangedAt: t0 - 600, attentionRevision: 3) { ArchiveAngelCandidate(id: $0) }
        #expect(current?.selection.picks.count == 1, "same revision, same newest event → trusted")
        // Never stamped (a pre-v9 shape) counts as revision 0: any live revision refuses it.
        s.replace(with: .init(computedAt: t0, complete: true, considered: 2, eligible: 2,
                              records: [a: rec(150, at: t0), b: rec(90, at: t0)]))
        #expect(ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionRevision: 1) { ArchiveAngelCandidate(id: $0) } == nil)
        #expect(ArchiveAngelJob.selectFromEvidence(store: s, count: 1, now: t0, attentionRevision: 0) { ArchiveAngelCandidate(id: $0) }?.selection.picks.count == 1)
    }

    @Test("codex 2026-09-20 #6: the record's familySkips reaches the projected candidate — a never-proposed variant of skipped footage is not 'New to you' from the cache")
    func familySkipsTravelInEvidence() {
        let variant = UUID(), fresh = UUID()
        var records: [UUID: ArchiveAngelEvidenceRecord] = [:]
        for i in 0..<3 { records[UUID()] = rec(200 - i, proposed: 1, at: t0) }
        records[variant] = .init(score: 80, lines: [], rejection: nil, useCount: 0, lastUsed: nil, computedAt: t0,
                                 timesProposed: 0, familySkips: 2)
        records[fresh] = rec(30, at: t0)
        let s = store(records: records, computedAt: t0)
        var projected: [UUID] = []
        let pick = ArchiveAngelJob.selectFromEvidence(store: s, count: 3, now: t0) { id in
            projected.append(id)
            var c = ArchiveAngelCandidate(id: id, filename: "\(id).mov", fullPath: "/V/\(id).mov")
            if s.record(for: id)?.timesProposed == 1 { c.attention.note(.angelProposed, at: t0 - day) }
            return c   // the projection never runs the family pass: familySkips is 0 here
        }
        let picks = pick?.selection.picks ?? []
        #expect(picks.count == 3)
        #expect(!projected.contains(variant), "past the band a variant of skipped footage is not a fresh look")
        #expect(picks.contains { $0.candidate.id == fresh }, "the genuinely fresh file took the slot instead")
        #expect(picks.first { $0.candidate.id == fresh }?.candidate.familySkips == 0)
        // In the band the variant is projected — and carries its family skips.
        let inBand = ArchiveAngelJob.selectFromEvidence(store: s, count: 5, now: t0) { id in
            ArchiveAngelCandidate(id: id, filename: "\(id).mov", fullPath: "/V/\(id).mov")
        }
        let v = inBand?.selection.picks.first { $0.candidate.id == variant }
        #expect(v?.candidate.familySkips == 2)
        #expect(v?.candidate.isFreshToPerson == false)
        #expect(v?.evidence.contains { $0.line == ArchiveAngelScorer.freshLine } == false)
    }
}

// MARK: - 5b. Unchecked at Promote — once per batch and row (codex 2026-09-20 #7)

@Suite("Archive Angel attention — unchecked at Promote is one decision")
struct ArchiveAngelUncheckedAtPromoteTests {

    @Test("a failed Promote retried three times with B still unchecked leaves ONE angelSkipped line for B; the stamp is in plan.json")
    @MainActor
    func retriedPromoteNotesOnce() async throws {
        let sandbox = try MasterArchiveTestSupport.makeSandbox("angel_unchecked")
        defer { sandbox.cleanup() }
        let fileA = try MasterArchiveTestSupport.writeBlob(at: sandbox.sources.appendingPathComponent("a.mov"), bytes: 4096, seed: 7)
        let fileB = try MasterArchiveTestSupport.writeBlob(at: sandbox.sources.appendingPathComponent("b.mov"), bytes: 4096, seed: 8)
        let model = MasterArchiveTestSupport.makeModel(sandbox)
        let recA = MasterArchiveTestSupport.makeRecord(path: fileA.path, starRating: 3)
        recA.contentHash = "aaa"
        let recB = MasterArchiveTestSupport.makeRecord(path: fileB.path, starRating: 2)
        recB.contentHash = "bbb"
        model.records = [recA, recB]
        try MasterArchiveTestSupport.initialize(model, in: sandbox)
        func entry(_ rec: VideoRecord, selected: Bool) -> ArchiveAngelPlan.Entry {
            var e = ArchiveAngelPlan.Entry(
                id: rec.id, sourcePath: rec.fullPath, filename: rec.filename, sizeBytes: 4096,
                sourceContentHash: rec.contentHash, sourceModifiedAt: nil,
                durationSeconds: 600, score: 105, evidence: [], proposedName: rec.filename,
                proposedDate: "1993", status: .ready)
            e.selected = selected
            return e
        }
        var plan = ArchiveAngelPlan(batchDir: sandbox.root.appendingPathComponent("batch-test").path,
                                    requestedCount: 10, makeLossless: false,
                                    entries: [entry(recA, selected: true), entry(recB, selected: false)])
        plan.status = .ready
        // A's source was rewritten since preparation: Promote refuses it every time.
        try MasterArchiveTestSupport.writeBlob(at: fileA, bytes: 1, seed: 9)
        let promoter = ArchiveAngelPromoter()
        let center = MediaFileOperationsCenter()
        var notedPerClick: [Int] = []
        for _ in 0..<3 {
            notedPerClick.append(ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &plan, model: model).count)
            let job = promoter.promote(plan: &plan, model: model, center: center) { _ in }
            #expect(job == nil, "the retry keeps failing")
        }
        #expect(notedPerClick == [1, 0, 0])
        // The sheet reopened from disk: the stamp travelled with the plan.
        var reloaded = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        #expect(reloaded.entries.first { $0.id == recB.id }?.uncheckedNotedAt != nil)
        #expect(ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &reloaded, model: model).isEmpty)

        await model.mediaLedger.waitForPendingWrites()
        let linesForB = model.mediaLedger.allEvents().filter { $0.event == .angelSkipped && $0.recordID == recB.id }
        #expect(linesForB.count == 1, "one decision, one line — not one per click")
        #expect(linesForB.first?.detail[MediaLedgerEvent.Detail.reason] == "unchecked")
        #expect(model.archiveAngel.attention.summary(recordID: recB.id, contentKey: "").timesSkipped == 1)
        #expect(model.mediaLedger.allEvents().filter { $0.event == .angelSkipped && $0.recordID == recA.id }.isEmpty, "the checked row is never a pass")
    }
}

// MARK: - 6. THE METRIC — the simulation (SCALE + SENSOR)

/// A 10k-record synthetic catalog and a person who skips everything, for
/// 10 rounds of "Assess 10". Today's rules (no memory) show the same ten
/// files every round; Phase 1 must show mostly different ones, never the
/// same file more than three times, and stay fast.
@Suite("Archive Angel attention — the curation simulation")
struct ArchiveAngelCurationSimulationTests {

    struct Outcome {
        var distinct = 0
        var slots = 0
        var maxRepeats = 0
        var familiesTouched = 0
        var seconds = 0.0
    }

    static func catalog(_ n: Int) -> [ArchiveAngelCandidate] {
        var rng = SystemRandomNumberGenerator()   // shape matters, not the seed
        var out: [ArchiveAngelCandidate] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let roll = Int.random(in: 0..<100, using: &rng)
            let folder = "/Volumes/LaCie/Family/\(i / 200)"
            let stem = "event_\(i)"
            var c = ArchiveAngelCandidate(filename: stem + ".mov", fullPath: folder + "/" + stem + ".mov",
                                          durationSeconds: 600, videoCodec: "dvvideo")
            switch roll {
            case 0..<2:   // favourites: ★★★, whole tape, two people, played
                c.starRating = 3; c.durationSeconds = 3600; c.confirmedPeople = ["Donna", "Rick"]; c.useCount = 7
                c.userDate = "199\(i % 10)"
            case 2..<12:  // good: ★★ or a half tape
                if i % 2 == 0 { c.starRating = 2 } else { c.durationSeconds = 2400 }
                c.inferredRecordDate = t0 - Double(i) * day; c.inferredDateConfidence = 0.9
            case 12..<30: // dated scenes
                c.durationSeconds = 900; c.inferredRecordDate = t0 - Double(i) * day; c.inferredDateConfidence = 0.6
            default:      // plain
                c.durationSeconds = Double(300 + i % 600)
            }
            out.append(c)
            if roll < 12, i % 3 == 0 {   // variants beside the favourites and good ones
                var v = c; v.id = UUID(); v.filename = stem + "_fixedup.mov"; v.fullPath = folder + "/" + v.filename
                out.append(v)
                var w = c; w.id = UUID(); w.filename = stem + "_clip1.mov"; w.fullPath = folder + "/" + w.filename
                w.durationSeconds = 400
                out.append(w)
            }
        }
        return out
    }

    static func simulate(rounds: Int, batch: Int, weights: ArchiveAngelWeights,
                         catalog: [ArchiveAngelCandidate]) -> Outcome {
        let clock = ContinuousClock()
        let start = clock.now
        var attention: [UUID: ArchiveAngelAttention] = [:]
        var shown: [UUID: Int] = [:]
        var families = Set<String>()
        var out = Outcome()
        for round in 0..<rounds {
            let now = t0 + Double(round) * day
            var cs = catalog
            for i in cs.indices { if let a = attention[cs[i].id] { cs[i].attention = a } }
            ArchiveAngelScorer.applyFamilyAttention(&cs, weights: weights, now: now)
            let sel = ArchiveAngelScorer.select(cs, count: batch, weights: weights, now: now)
            for pick in sel.picks {
                shown[pick.id, default: 0] += 1
                families.insert(pick.candidate.familyKey)
                attention[pick.id, default: .none].note(.angelProposed, at: now)
                attention[pick.id, default: .none].note(.angelSkipped, at: now + 60)   // skips everything
                out.slots += 1
            }
        }
        out.distinct = shown.count
        out.maxRepeats = shown.values.max() ?? 0
        out.familiesTouched = families.count
        out.seconds = Double((clock.now - start).components.seconds)
            + Double((clock.now - start).components.attoseconds) / 1e18
        return out
    }

    /// Today's behaviour, expressed as weights: no novelty, no fatigue, no
    /// rest, no fresh slots (the family rule is still on — it is structural).
    static var yesterday: ArchiveAngelWeights {
        var w = ArchiveAngelWeights.standard
        w.fatigueFactor = 1; w.restAfterSkips = .infinity; w.freshShare = 0
        return w
    }

    @Test("THE METRIC: 10k records, a skip-everything user, 10 rounds of 10 — Phase 1 shows ≥ 60 distinct files (today: 10), never one more than 3×, under 5 s")
    func skipEverything() {
        let catalog = Self.catalog(10_000)
        let before = Self.simulate(rounds: 10, batch: 10, weights: Self.yesterday, catalog: catalog)
        let after = Self.simulate(rounds: 10, batch: 10, weights: .standard, catalog: catalog)
        print("[angel-sim] records \(catalog.count) · before: distinct \(before.distinct)/\(before.slots), max repeats \(before.maxRepeats), families \(before.familiesTouched)"
              + " · after: distinct \(after.distinct)/\(after.slots), max repeats \(after.maxRepeats), families \(after.familiesTouched), \(String(format: "%.2f", after.seconds)) s")
        #expect(before.distinct <= 12, "today: the same ten every round (\(before.distinct))")
        #expect(after.distinct >= 60, "Phase 1: mostly new files each round (\(after.distinct))")
        #expect(after.maxRepeats <= 3, "no file proposed more than three times (\(after.maxRepeats))")
        #expect(after.familiesTouched >= 60)
        #expect(after.seconds < 5, "10 rounds over 10k records in \(after.seconds) s")
    }

    @Test("SCALE (codex #1573): 100k candidates, a tenth of them with skips — the family pass + one selection under 4 s, ranked output, one per family")
    func hundredThousandBudget() {
        var cs = Self.catalog(100_000)
        var skippedOnce = ArchiveAngelAttention.none
        skippedOnce.note(.angelProposed, at: t0 - 2 * day); skippedOnce.note(.angelSkipped, at: t0 - day)
        for i in stride(from: 0, to: cs.count, by: 10) { cs[i].attention = skippedOnce }
        let clock = ContinuousClock()
        let elapsed = clock.measure {
            ArchiveAngelScorer.applyFamilyAttention(&cs, now: t0)
            let sel = ArchiveAngelScorer.select(cs, count: 10, now: t0)
            #expect(sel.picks.count == 10)
            #expect(Set(sel.picks.map(\.candidate.resolvedFamilyKey)).count == 10, "one per family")
            #expect(sel.picks.filter(\.candidate.isFreshToPerson).count >= 3, "the fresh slots are honoured at scale")
        }
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("[angel-sim] 100k family pass + select: \(String(format: "%.2f", seconds)) s")
        #expect(seconds < 4, "100k in \(seconds) s")
    }

    @Test("a promote-everything user is never slowed down: Phase 1 picks the same top ten as today on round one")
    func firstRoundUnchanged() {
        let catalog = Self.catalog(2_000)
        var cs = catalog
        ArchiveAngelScorer.applyFamilyAttention(&cs, now: t0)
        let before = ArchiveAngelScorer.select(cs, count: 10, weights: Self.yesterday, now: t0).picks.map(\.id)
        let after = ArchiveAngelScorer.select(cs, count: 10, weights: .standard, now: t0).picks.map(\.id)
        #expect(before == after, "with nothing remembered, novelty is uniform and changes no order")
    }
}
