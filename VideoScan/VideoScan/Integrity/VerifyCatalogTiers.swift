// VerifyCatalogTiers.swift
// The seven tiers of Verify Catalog (docs/design/integrity_first_2026_10_16.md
// §3), each a pure function from the snapshot to one IntegrityTier line and
// its findings. THIS SLICE fills tiers 0, 1, 3, 4 and 5 from what the
// catalog already records — the audit's marker, the fixity and sound-print
// stamps, the rows' relations — and the catalog file's own hash. Tiers 2
// (bytes re-read against the stored digest) and 6 (the UI truth sweep) say
// "not built yet" rather than claim anything (`builtTiers` is the list the
// Catalog Status verdict reads; the other two never colour the row).
//
// ONE GENERATION (codex, Verify Catalog slice 1, P1): the snapshot carries
// the catalog generation its rows came from; tier 5 reads the generation
// in the file it hashes and, when the two differ (a save landed between
// the snapshot and the hash — Pause, save, Resume; the snapshot is never
// retaken), says so in words. The report then marks the hash "not
// certified" and `catalogChangedDuringRun`; the run still completes.
//
// No I/O here except two reads: the audit marker (tier 0) and the catalog
// file hash (tier 5), both of files beside the catalog — never a media file.
// Nothing is written. Runs off the main actor on Sendable values.
//
// (For Rick: `evaluate(_:input:)` is the dispatcher — a switch over the tier
// number to one function each; `TierInput` / `TierOutcome` are the plain
// structs that cross the thread boundary.)

import Foundation
import VideoScanCore

/// Which store the rows were read from (GH #342).
enum VerifyCatalogStore: String, Sendable, Equatable {
    /// catalog.json (before the switch, or Import's audited file).
    case json
    /// catalog.sqlite — the authority named by catalog.cutover; the rows
    /// came through the database's own read path, never memory, never JSON.
    case sqlite

    var fileName: String { self == .sqlite ? CatalogAuthority.databaseFileName : "catalog.json" }
}

/// Everything the tiers read, taken on the main actor in one pass (JSON)
/// or in one read transaction of catalog.sqlite (the authority).
struct VerifyCatalogSnapshot: Sendable {
    var rows: [IntegrityRow]
    var events: [IntegrityEventFact]
    /// catalog.sqlite's `footage_likeness` pairs with the latest person's
    /// verdict (schema v1.11) — read in the snapshot's pass; empty for
    /// catalog.json (no table). Tier 5 lists the undecided weak ones as
    /// informational (yellow).
    var likeness: [IntegrityLikenessFact] = []
    /// The catalog file the rows came from — catalog.sqlite under the
    /// SQLite authority, else catalog.json (the marker and the report live
    /// beside it; both are in the same folder).
    var catalogFile: String
    /// The generation the rows derive from: catalog.sqlite's own generation
    /// (read in the same transaction as the rows), or for catalog.json
    /// `CatalogStore.currentGeneration`. The findings describe THIS
    /// generation; tier 5 checks the store still carries it.
    var catalogGeneration: Int
    /// Which store `catalogFile` is.
    var store: VerifyCatalogStore = .json
    /// The volume roots connected when the snapshot was taken ("/" and
    /// each "/Volumes/<name>" — the job's ONE readdir of /Volumes; tests
    /// inject it). Tier 1 splits its words by it: a sampled-only file on
    /// a connected drive is one Fill In Full Hashes away; one on a drive
    /// that is not connected is not.
    var mountedVolumeRoots: Set<String>
    var liveCount: Int

    init(rows: [IntegrityRow], events: [IntegrityEventFact], catalogFile: String, catalogGeneration: Int = 0,
         mountedVolumeRoots: Set<String> = ["/"], store: VerifyCatalogStore = .json) {
        self.rows = rows
        self.events = events
        self.catalogFile = catalogFile
        self.catalogGeneration = catalogGeneration
        self.store = store
        self.mountedVolumeRoots = mountedVolumeRoots
        liveCount = rows.reduce(0) { $0 + ($1.isLive ? 1 : 0) }
    }

    var catalogURL: URL { URL(fileURLWithPath: catalogFile) }
}

enum VerifyCatalogTiers {

    static let order = [0, 1, 2, 3, 4, 5, 6]

    /// The tiers this build actually evaluates. Catalog Status derives its
    /// verdict from these alone; the rest say "not built yet".
    static let builtTiers: Set<Int> = [0, 1, 3, 4, 5]

    static var notBuiltTiers: [Int] { order.filter { !builtTiers.contains($0) } }

    static func name(_ tier: Int) -> String {
        switch tier {
        case 0: return "File presence"
        case 1: return "File identity"
        case 2: return "Bytes still the bytes"
        case 3: return "Decodes and sounds"
        case 4: return "Derived knowledge"
        case 5: return "Relations and constraints"
        default: return "The UI tells the truth"
        }
    }

    /// What one tier evaluation is given.
    struct TierInput: Sendable {
        var snapshot: VerifyCatalogSnapshot
        /// The last report (for the catalog-file hash comparison); nil = none.
        var previous: IntegrityReport?
        /// The constraint findings computed by tier 4, handed on to tier 5
        /// so the rows are walked once for both.
        var constraintFindings: [CatalogConstraints.Finding]?
        var runID: UUID
        var now: Date
        /// catalog.sqlite only: the store's generation as read just before
        /// tier 5 (the job asks the repository); nil = not read yet.
        var databaseGeneration: DatabaseGenerationRead?
    }

    /// What the job learned about catalog.sqlite's generation for tier 5.
    enum DatabaseGenerationRead: Sendable, Equatable {
        case read(Int)
        /// The store could not be asked — the words why.
        case unreadable(String)
    }

    /// What one tier evaluation returns.
    struct TierOutcome: Sendable {
        var tier: IntegrityTier
        var findings: [IntegrityFinding]
        /// Tier 4 fills this for tier 5.
        var constraintFindings: [CatalogConstraints.Finding]?
        /// Tier 5 fills this for the report (so the file is hashed once);
        /// nil when the file is not on disk or could not be read.
        var catalogHash: CatalogFileHash?

        init(tier: IntegrityTier, findings: [IntegrityFinding] = [], constraintFindings: [CatalogConstraints.Finding]? = nil,
             catalogHash: CatalogFileHash? = nil) {
            self.tier = tier
            self.findings = findings
            self.constraintFindings = constraintFindings
            self.catalogHash = catalogHash
        }
    }

    /// The dispatcher.
    static func evaluate(_ tier: Int, input: TierInput) -> TierOutcome {
        let clock = ContinuousClock.now
        var outcome: TierOutcome
        switch tier {
        case 0: outcome = presence(input)
        case 1: outcome = identity(input)
        case 2: outcome = notBuilt(2, "weekly deep pass — not built yet")
        case 3: outcome = sound(input)
        case 4: outcome = derivedKnowledge(input)
        case 5: outcome = constraints(input)
        default: outcome = notBuilt(6, "truth sweep — not built yet")
        }
        outcome.tier.elapsedSeconds = seconds(since: clock)
        return outcome
    }

    /// A tier the run did not reach (Stop ends after the current tier).
    static func stopped(_ tier: Int) -> IntegrityTier {
        IntegrityTier(tier: tier, name: name(tier), result: .notRun("stopped before this tier"), summary: "stopped before this tier")
    }

    static func notBuilt(_ tier: Int, _ why: String) -> TierOutcome {
        TierOutcome(tier: IntegrityTier(tier: tier, name: name(tier), result: .notRun(why), summary: why))
    }

    // MARK: Tier 0 — from the audit's marker

    /// Reads `catalog-audit.json` beside the catalog (the one small read)
    /// and `catalog.cutover`'s date (a run from before the switch to
    /// SQLite is catalog.json's, not this catalog's).
    static func presence(_ input: TierInput) -> TierOutcome {
        let folder = input.snapshot.catalogURL.deletingLastPathComponent()
        return presence(audit: CatalogFreshnessFactsReader.auditRecord(in: folder),
                        switchedAt: CatalogFreshnessFactsReader.cutoverSwitchedAt(in: folder))
    }

    static func presence(audit record: CatalogAuditRunRecord?, switchedAt: Date? = nil) -> TierOutcome {
        var t = IntegrityTier(tier: 0, name: name(0), result: .notRun(""), summary: "")
        guard let record else {
            t.result = .notRun("Audit Catalog has not run — Catalog ▸ Audit Catalog… (the nightly runs it too)")
            t.summary = "Audit Catalog has not run"
            return TierOutcome(tier: t)
        }
        let facts = CatalogAuditPresenceFacts.from(record, switchedAt: switchedAt)
        if facts.predatesSwitch {
            t.result = .notRun("the last audit ran on catalog.json, before the switch to SQLite — run Audit Catalog again")
            t.summary = "the last audit ran before the switch to SQLite"
            return TierOutcome(tier: t)
        }
        t.verifiedAt = record.finishedAt
        t.checked = facts.checked
        t.couldNotCheck = record.counts[CatalogAuditResult.couldNotCheck.rawValue] ?? 0
        t.needsDecision = facts.needsDecision
        t.passed = max(0, facts.checked - facts.needsDecision - t.couldNotCheck)
        let planned = record.counts["planned"] ?? facts.checked
        switch facts.outcome {
        case .ok where facts.needsDecision > 0:
            t.result = .needsDecision(facts.needsDecision)
            t.summary = "\(facts.needsDecision.formatted()) rows point at nothing or changed on disk — Fix Links"
        case .ok:
            t.result = .ok
            t.summary = "\(facts.checked.formatted()) rows present at their path"
        case .partial:
            let left = max(1, planned - facts.checked)
            t.result = .couldNotCheck(left)
            t.couldNotCheck = left
            t.summary = "the last audit stopped part way — \(left.formatted()) rows not asked; run it again"
        case .failed:
            t.result = .couldNotCheck(max(1, planned))
            t.couldNotCheck = max(1, planned)
            t.summary = "the last audit failed or was killed — run Audit Catalog again"
        case .neverRan:
            t.result = .notRun("the last audit was refused — run Audit Catalog again")
            t.summary = "the last audit was refused"
        }
        return TierOutcome(tier: t)
    }

    // MARK: Tier 1 — identity from the stamps

    /// Every active row with bytes should carry a whole-file SHA-256; the
    /// sampled `v1:` hash never counts (`IntegrityRow.fullDigest` is nil
    /// for it by construction — `storedFullDigest`). The words split the
    /// sampled-only rows by the snapshot's connected roots: the ones on a
    /// connected drive are one Fill In Full Hashes away; the rest are not.
    static func identity(_ input: TierInput) -> TierOutcome {
        var checked = 0
        var known = 0
        var connected = 0
        let mounted = input.snapshot.mountedVolumeRoots
        for r in input.snapshot.rows where r.isActive && r.hasBytes {
            checked += 1
            if r.fullDigest != nil {
                known += 1
            } else if mounted.contains(VolumeReachability.volumeRootKey(forPath: r.fullPath, mountedRoots: mounted)) {
                connected += 1
            }
        }
        let unknown = checked - known
        var t = IntegrityTier(tier: 1, name: name(1), verifiedAt: input.now, runID: input.runID, result: .ok,
                              checked: checked, passed: known, couldNotCheck: unknown, summary: "")
        if unknown > 0 {
            t.result = .couldNotCheck(unknown)
            t.summary = identityWords(sampledOnly: unknown, connected: connected)
        } else {
            t.summary = "every live file has a whole-file SHA-256 (\(known.formatted()))"
        }
        return TierOutcome(tier: t)
    }

    /// "712 files still have only a sampled hash — 616 on connected drives
    /// (Fill In Full Hashes) · 96 on drives not connected"; all connected
    /// keeps the short words; none connected says so.
    static func identityWords(sampledOnly n: Int, connected: Int) -> String {
        let head = "\(n.formatted()) files still have only a sampled hash — "
        let offline = n - connected
        if offline == 0 { return head + "Fill In Full Hashes" }
        if connected == 0 { return head + "all on drives not connected" }
        return head + "\(connected.formatted()) on connected drives (Fill In Full Hashes) · \(offline.formatted()) on drives not connected"
    }

    // MARK: Tier 3 — the header against the sound print

    static let silentPrintRule = "headerSaysSoundPrintHeardNone"

    /// A Video+Audio row whose CURRENT sound print heard nothing (or found
    /// no stream) is a header that says sound the print never heard. A
    /// print made from other content (`staleStampReason`, tier 4's rule)
    /// is not evidence about this row either way: it is tier 4's finding,
    /// and here the row counts as having no current print (codex, slice 1,
    /// P1: an old audible print must never pass new content).
    ///
    /// A possible REFERENCE MOVIE whose print found no audio is not judged
    /// either (2026-10-18: 25 of Rick's 131 were iMovie "Shared Movies"):
    /// its own bytes hold pointers, not samples, so "no audio" says nothing
    /// about the header and "Fingerprint Sound again" cannot help. Tier 5
    /// names it and Verify Media decides; here it could not be checked. A
    /// SILENT print of one still counts — ffmpeg followed the reference
    /// and heard the media.
    ///
    /// EXPECTED SILENCE (Rick 2026-10-19 — "let the machine settle what the
    /// machine can settle"): a silent print is PASSED, with words, when
    ///   * the row is a Live Photo's motion clip (`isLivePhotoMotionClip`):
    ///     the 2-second video beside a still, which iOS records with a
    ///     silent or near-silent track by design; or
    ///   * a person looked and said so — the workflow tag "Silent — checked"
    ///     on the content (`IntegrityRow.silenceCheckedByPerson`), stored in
    ///     catalog.sqlite's workflow_tags like every other tag.
    /// Everything else silent still needs a decision.
    ///
    /// SILENT MEANS MEASURED (2026-10-20): the stamp is read through
    /// `AudioFingerprintStamp.hearing` — "silent" only for a print that
    /// decoded the sound and measured every second quiet (stamp rule 4).
    /// A stamp that is not evidence — a version-2 "no sound" written on a
    /// decode failure (0 samples; 6 rows on 10/20), or a pre-4 zero-landmark
    /// print (8 AVCHD clips with real sound read as "silent") — is counted
    /// under could-not-check, never as a decision.
    static func sound(_ input: TierInput) -> TierOutcome {
        var tally = SoundTally()
        for r in input.snapshot.rows where r.isActive && r.streamTypeRaw == StreamType.videoAndAudio.rawValue {
            tally.judge(r)
        }
        let findings = tally.findings
        let couldNotCheck = tally.unstamped + tally.referenced + tally.notEvidence
        var t = IntegrityTier(tier: 3, name: name(3), verifiedAt: input.now, runID: input.runID, result: .ok,
                              checked: tally.stamped, passed: tally.stamped - findings.count, needsDecision: findings.count,
                              couldNotCheck: couldNotCheck, summary: "")
        var parts: [String] = []
        if !findings.isEmpty {
            t.result = .needsDecision(findings.count)
            parts.append("\(findings.count.formatted()) headers say sound the print never heard")
        } else if couldNotCheck > 0 {
            t.result = .couldNotCheck(couldNotCheck)
            parts.append(soundGapWords(unstamped: tally.unstamped, referenced: tally.referenced, notEvidence: tally.notEvidence))
        } else if tally.livePhoto + tally.checkedByPerson == 0 {
            parts.append("every Video+Audio file's print heard sound (\(tally.stamped.formatted()))")
        } else {
            parts.append("every Video+Audio file's print heard sound or is silent for a known reason (\(tally.stamped.formatted()))")
        }
        if let expected = expectedSilenceWords(livePhoto: tally.livePhoto, checked: tally.checkedByPerson) { parts.append(expected) }
        t.summary = parts.joined(separator: " · ")
        return TierOutcome(tier: t, findings: findings)
    }

    /// Tier 3's running count — one row at a time (≈ a fold's accumulator).
    struct SoundTally {
        var findings: [IntegrityFinding] = []
        var stamped = 0
        var unstamped = 0
        var referenced = 0
        /// A current stamp that is not evidence about the sound (a decode
        /// failure, or a print from before silence was measured).
        var notEvidence = 0
        /// Silent and passed: a Live Photo's motion clip.
        var livePhoto = 0
        /// Silent and passed: a person tagged it "Silent — checked".
        var checkedByPerson = 0

        mutating func judge(_ r: IntegrityRow) {
            guard let stamp = r.audioFingerprint, CatalogConstraints.staleStampReason(stamp, row: r) == nil else {
                unstamped += 1
                return
            }
            if stamp.outcome == .noAudio, CatalogConstraints.isPossibleReferenceMovie(r) {
                referenced += 1
                return
            }
            let hearing = stamp.hearing(headerHasAudio: !r.audioCodec.isEmpty)
            if hearing == .notEvidence {
                notEvidence += 1
                return
            }
            stamped += 1
            guard let why = silentPrintReason(hearing) else { return }
            if isLivePhotoMotionClip(r) {
                livePhoto += 1
            } else if r.silenceCheckedByPerson {
                checkedByPerson += 1
            } else {
                findings.append(IntegrityFinding(tier: 3, rule: silentPrintRule, recordID: r.id, filename: r.filename,
                                                 words: "the header says Video+Audio, \(why)", needsDecision: true))
            }
        }
    }

    /// "72 Live Photo motion clips — silent by design · 3 silent clips
    /// checked by a person"; nil when neither.
    static func expectedSilenceWords(livePhoto: Int, checked: Int) -> String? {
        var parts: [String] = []
        if livePhoto > 0 { parts.append("\(livePhoto.formatted()) \(livePhotoSilentWords)") }
        if checked > 0 { parts.append("\(checked.formatted()) silent clip\(checked == 1 ? "" : "s") checked by a person") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static let livePhotoSilentWords = "Live Photo motion clips — silent by design"

    /// A Live Photo's motion clip never runs longer than this (iOS records
    /// ~1.5 s either side of the still; the library's copies measure 2–3 s).
    static let livePhotoMaxSeconds = 3.5

    /// NARROW on purpose: SHORT (known duration, ≤ `livePhotoMaxSeconds`)
    /// AND either inside a photo library (a `.photoslibrary`,
    /// `.photolibrary` or `.migratedphotolibrary` package, or an "iPhoto
    /// Library" folder) or named like Photos' own complement file
    /// (`videocomplementoutput…`). A long file, or a short one outside a
    /// photo library, still needs a decision.
    static func isLivePhotoMotionClip(_ r: IntegrityRow) -> Bool {
        guard r.durationSeconds > 0, r.durationSeconds <= livePhotoMaxSeconds else { return false }
        if r.filename.lowercased().hasPrefix("videocomplementoutput") { return true }
        return r.fullPath.split(separator: "/").contains { isPhotoLibraryComponent($0) }
    }

    static func isPhotoLibraryComponent(_ component: Substring) -> Bool {
        let c = component.lowercased()
        return c.hasSuffix(".photoslibrary") || c.hasSuffix(".photolibrary") || c.hasSuffix(".migratedphotolibrary")
            || c.hasPrefix("iphoto library")
    }

    /// What tier 3 could not check, each with its door: no current print
    /// (Fingerprint Sound), a reference movie (Verify Media decides).
    static func soundGapWords(unstamped: Int, referenced: Int, notEvidence: Int = 0) -> String {
        var parts: [String] = []
        if unstamped > 0 {
            parts.append("\(unstamped.formatted()) Video+Audio files have no current sound print yet — Fingerprint Sound")
        }
        if notEvidence > 0 {
            parts.append("\(notEvidence.formatted()) sound prints could not tell sound from silence (a failed decode, or made before silence was measured) — Fingerprint Sound looks again")
        }
        if referenced > 0 {
            parts.append("\(referenced.formatted()) possible reference movies — their sound lives in other files; Verify Media decides")
        }
        return parts.joined(separator: " · ")
    }

    /// Why a stamp's reading contradicts a Video+Audio header; nil when it
    /// does not (or is not evidence — the caller counts that apart). The
    /// evidence is the sound-print STAMP (what Fingerprint Sound recorded),
    /// never a fresh ffmpeg read — the words say so.
    static func silentPrintReason(_ hearing: AudioFingerprintStamp.Hearing) -> String? {
        switch hearing {
        case .noAudioTrack: return "but the sound print recorded no audio — Fingerprint Sound again"
        case .measuredSilence: return "but the sound print heard nothing (silent)"
        case .heardSound, .notEvidence: return nil
        }
    }

    // MARK: Tier 4 — derived knowledge (and the constraints pass, once)

    static func derivedKnowledge(_ input: TierInput) -> TierOutcome {
        let all = CatalogConstraints.check(rows: input.snapshot.rows, events: input.snapshot.events, likeness: input.snapshot.likeness)
        let stale = all.filter { $0.rule.tier == 4 }
        let stamped = input.snapshot.rows.reduce(0) { $0 + ($1.audioFingerprint == nil ? 0 : 1) }
        var t = IntegrityTier(tier: 4, name: name(4), verifiedAt: input.now, runID: input.runID, result: .ok,
                              checked: stamped, passed: stamped - stale.count, needsDecision: stale.count, summary: "")
        if stale.isEmpty {
            t.summary = "every derived stamp is about its row's content (\(stamped.formatted()) checked)"
        } else {
            t.result = .needsDecision(stale.count)
            t.summary = "\(stale.count.formatted()) sound prints were made from other content"
        }
        return TierOutcome(tier: t, findings: findings(stale, rows: input.snapshot.rows), constraintFindings: all)
    }

    // MARK: Tier 5 — relations, constraints, the catalog file's hash

    static let catalogFileRule = "catalogFileChanged"

    /// What tier 5 learned about the catalog file itself.
    enum CatalogFileRead: Sendable, Equatable {
        case notOnDisk
        /// Exists and could not be read (or not read whole) — the errno words.
        case unreadable(String)
        case hashed(CatalogFileHash)

        var hash: CatalogFileHash? {
            if case .hashed(let h) = self { return h }
            return nil
        }
    }

    static func constraints(_ input: TierInput) -> TierOutcome {
        if input.snapshot.store == .sqlite { return databaseConstraints(input) }
        let all = input.constraintFindings
            ?? CatalogConstraints.check(rows: input.snapshot.rows, events: input.snapshot.events, likeness: input.snapshot.likeness)
        var found = findings(all.filter { $0.rule.tier == 5 }, rows: input.snapshot.rows)
        let file = catalogFile(input.snapshot.catalogURL)
        let comparison = CatalogFileHash.compare(previousSHA: input.previous?.catalogSHA256,
                                                 previousGeneration: input.previous?.catalogGeneration, current: file.hash)
        if comparison.needsDecision {
            found.append(IntegrityFinding(tier: 5, rule: catalogFileRule, recordID: nil, filename: nil,
                                          words: comparison.words, needsDecision: true))
        }
        let decided = found.filter(\.needsDecision)
        let unverified = found.count - decided.count
        let rows = input.snapshot.rows.count
        let unreadable = file.hash == nil && file != .notOnDisk
        let couldNotCheck = unverified + (unreadable ? 1 : 0)
        var t = IntegrityTier(tier: 5, name: name(5), verifiedAt: input.now, runID: input.runID, result: .ok,
                              checked: rows, passed: rows - Set(found.compactMap(\.recordID)).count,
                              needsDecision: decided.count, couldNotCheck: couldNotCheck, summary: "")
        if !decided.isEmpty {
            t.result = .needsDecision(decided.count)
        } else if couldNotCheck > 0 {
            t.result = .couldNotCheck(couldNotCheck)
        }
        t.summary = relationWords(found, rows: rows, fileWords: unreadable ? nil : comparison.words)
        if let said = fileProblemWords(file, snapshotGeneration: input.snapshot.catalogGeneration) {
            t.summary += " · " + said
        }
        return TierOutcome(tier: t, findings: found, catalogHash: file.hash)
    }

    /// Tier 5 over catalog.sqlite (GH #342): the same constraints over the
    /// rows the database returned, and — instead of a file hash — the
    /// store's own generation. A WAL database's bytes change at every
    /// checkpoint with no new generation, so a byte hash would manufacture
    /// "changed with the SAME generation" decisions; the generation is the
    /// store's own monotonic counter (every commit is +1, a CAS). A store
    /// that moved on since the rows were read is said (run again), never a
    /// decision; a store whose generation could not be read could not be
    /// checked.
    static func databaseConstraints(_ input: TierInput) -> TierOutcome {
        let all = input.constraintFindings
            ?? CatalogConstraints.check(rows: input.snapshot.rows, events: input.snapshot.events, likeness: input.snapshot.likeness)
        let found = findings(all.filter { $0.rule.tier == 5 }, rows: input.snapshot.rows)
        let decided = found.filter(\.needsDecision)
        let rows = input.snapshot.rows.count
        let unreadable: String? = {
            switch input.databaseGeneration {
            case .unreadable(let why): return why
            case nil: return "not asked"
            case .read: return nil
            }
        }()
        let couldNotCheck = found.count - decided.count + (unreadable == nil ? 0 : 1)
        var t = IntegrityTier(tier: 5, name: name(5), verifiedAt: input.now, runID: input.runID, result: .ok,
                              checked: rows, passed: rows - Set(found.compactMap(\.recordID)).count,
                              needsDecision: decided.count, couldNotCheck: couldNotCheck, summary: "")
        if !decided.isEmpty {
            t.result = .needsDecision(decided.count)
        } else if couldNotCheck > 0 {
            t.result = .couldNotCheck(couldNotCheck)
        }
        let file = VerifyCatalogStore.sqlite.fileName
        let generationWords: String
        if let unreadable {
            generationWords = "\(file)'s generation could not be read (\(unreadable)) — run again"
        } else if case .read(let now) = input.databaseGeneration,
                  let moved = generationMismatch(snapshot: input.snapshot.catalogGeneration, file: now) {
            generationWords = moved.replacingOccurrences(of: "the file on disk", with: file)
        } else {
            generationWords = "\(file) at generation \(input.snapshot.catalogGeneration) — the findings describe it"
        }
        t.summary = relationWords(found, rows: rows, fileWords: generationWords)
        if !decided.isEmpty { t.summary += " · " + generationWords }   // relationWords names it only when nothing is decided
        return TierOutcome(tier: t, findings: found)
    }

    /// The decisions by rule (most first), then the UNVERIFIED findings
    /// by rule (a lineage link to a purged row — kept as history), then,
    /// when nothing needs a decision, "every [other] relation holds (N
    /// rows)" and the catalog-file comparison (`fileWords`; nil when the
    /// file could not be read, so nothing is claimed about it).
    static func relationWords(_ found: [IntegrityFinding], rows: Int, fileWords: String?) -> String {
        let decided = found.filter(\.needsDecision)
        let kept = found.filter { !$0.needsDecision }
        var parts: [String] = []
        if !decided.isEmpty { parts.append(constraintSummary(decided, decided: true)) }
        if !kept.isEmpty { parts.append(constraintSummary(kept, decided: false)) }
        if decided.isEmpty {
            parts.append("every \(kept.isEmpty ? "" : "other ")relation holds (\(rows.formatted()) rows)")
            if let fileWords { parts.append(fileWords) }
        }
        return parts.joined(separator: " · ")
    }

    /// The catalog file's streamed SHA-256, or why there is none: not on
    /// disk, or on disk and unreadable (the words carry the errno).
    static func catalogFile(_ url: URL) -> CatalogFileRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .notOnDisk }
        do {
            return .hashed(try CatalogFileHash.of(fileAt: url))
        } catch {
            return .unreadable(CatalogFileHash.readProblemWords(error))
        }
    }

    /// What a person must hear about the file beyond the routine
    /// comparison: it could not be read; or its generation is not the
    /// snapshot's; or it carries no generation, so nothing is certified.
    static func fileProblemWords(_ file: CatalogFileRead, snapshotGeneration: Int) -> String? {
        switch file {
        case .notOnDisk:
            return nil
        case .unreadable(let why):
            return "catalog.json exists but could not be read (\(why)) — its hash is not recorded"
        case .hashed(let hash):
            guard hash.generation != nil else { return "catalog.json carries no generation header — hash recorded, not certified" }
            return generationMismatch(snapshot: snapshotGeneration, file: hash.generation)
        }
    }

    /// "findings describe generation N; the file on disk is generation M —
    /// run again" when they differ; nil when they agree or the file's is
    /// unknown. The report derives `catalogChangedDuringRun` from the same.
    static func generationMismatch(snapshot: Int, file: Int?) -> String? {
        guard let file, file != snapshot else { return nil }
        return "findings describe generation \(snapshot); the file on disk is generation \(file) — run again"
    }

    /// "3 rows share a path · 2 lineage links point at nothing" — the rules
    /// with findings, most findings first. `decided` picks the rule's
    /// decided or unverified phrase (the lineage rule has both).
    static func constraintSummary(_ findings: [IntegrityFinding], decided: Bool) -> String {
        var counts: [String: Int] = [:]
        for f in findings { counts[f.rule, default: 0] += 1 }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { rule, n in ruleWords(rule, count: n, decided: decided) }
            .joined(separator: " · ")
    }

    /// A constraint rule's counted phrase (its own table), or the one
    /// tier-5 rule that is not a constraint: the catalog file's hash.
    static func ruleWords(_ rule: String, count n: Int, decided: Bool = true) -> String {
        guard let r = CatalogConstraints.Rule(rawValue: rule) else { return "catalog.json changed without a new generation" }
        return r.words(count: n, decided: decided)
    }

    // MARK: Helpers

    /// Constraint findings → report findings, with the row's filename.
    static func findings(_ found: [CatalogConstraints.Finding], rows: [IntegrityRow]) -> [IntegrityFinding] {
        guard !found.isEmpty else { return [] }
        var names: [UUID: String] = [:]
        for r in rows { names[r.id] = r.filename }
        return found.map {
            IntegrityFinding(tier: $0.rule.tier, rule: $0.rule.rawValue, recordID: $0.recordID,
                             filename: $0.recordID.flatMap { names[$0] }, words: $0.words, needsDecision: $0.needsDecision)
        }
    }

    static func seconds(since start: ContinuousClock.Instant) -> Double {
        let d = (ContinuousClock.now - start).components
        return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
}
