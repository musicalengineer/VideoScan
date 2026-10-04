// StewardCaseBuilder.swift
// Knowledge already on the records → the steward's queue of cases (trial
// UI, 2026-10-03; design §5.6). NO new analysis: duplicate groups and
// keepers come from Find Duplicates, footage groups from Find Similar
// Footage, junk scores from Triage's own Analyze, and the per-drive numbers
// from ReclaimableCalculator — the same arithmetic the Storage tab shows.
//
// Contract = VolumeDashboard / AnalyzeCoverage: the model projects ONE
// Sendable row per active record on the main actor (`project`), this
// builder runs in a detached task (`build`), the result is cached on the
// model and read O(1) by the views. Budgeted for 100k records
// (StewardScaleTests).
//
// RULE 2 of §5.6 lives in the projection: a record the canonical predicates
// protect (archive copy / archive drive / Archive Angel's pick — see
// VideoScanModel+Steward.swift) arrives here with `protection != .none`,
// and from then on it can be a KEEPER but never a copy a case proposes to
// let go. A duplicate set whose only other copies are protected produces no
// Reclaim card. The Angel's picks and filed-as-Archived copies are NOT
// refused by the Delete planner, though: where a drive's cleanup would
// still check them the card says so (`.stillChecked`, `stillCheckedOnDrive`)
// and the proof counts them as rows of the run (QA 2026-10-03, F1).
//
// WHAT A RECLAIM SET COUNTS. "Reclaimable" = extra copies that are not
// protected. "The flow would check" = those whose keeper is on the same
// drive, or — when "Also clean up working copies" is on — those the Delete
// planner's OWN cross-drive rule takes (QA F6(a): the model's
// `duplicateKeeperPolicy()`, handed in by value, asked through
// `crossVolumeVerdict` exactly as `volumesWithDeletableDuplicates` asks it:
// the keeper's drive known, connected, not retired and ranked above the
// copy's). A set the flow would not touch today still gets a card, with the
// action off and the reason in words. (The per-DRIVE card's numbers are
// still ReclaimableCalculator's, which counts every working copy in that
// mode — the Storage tab's arithmetic, not changed here.)
//
// JUNK CLUSTERS. A record counts when its junk score is at or above
// `junkThreshold` (the score Triage's Analyze calls Suspected Junk, and
// colours orange), nobody has decided about it yet (`Unreviewed`, or the
// machine's own `Suspected Junk` suggestion), it is in Triage's table (not
// filed as Archived) and it is not protected. Each record joins ONE
// cluster: its first reason other than "duplicate extra copy" (those are
// Reclaim's), with the numbers in brackets dropped, on its drive.
//
// EVENTS LEAD (Rick 2026-10-03). The occasion of each clip — a holiday, a
// family birthday, a word in a folder name — is worked out by the Angel's
// own derivation over VideoScanCore.EventLabeler (StewardEvents.swift);
// this builder carries the date facts that derivation reads and puts the
// lanes in order: events, days to name, same footage, reclaim space, junk.
//
// MEMORY. One StewardInput per active record: ~330 bytes of flags, ids and
// dates plus references to strings the record already owns ≈ 35–40 MB at
// 100k, and one StewardPlacement beside it (~8 MB), all freed when the
// build ends. The queue keeps at most `StewardEvents.maxEventCases` events
// and `maxCasesPerKind` of each other kind (plus the skipped ones kept for
// "Show skipped"), each with ≤ `maxCopiesPerCase` rows and ≤
// `maxIDsPerCase` ids (16 bytes each) — a few MB at the very worst.
//
// (For Rick: a pure `enum` namespace of static functions; `[UUID: [Int]]`
// ≈ std::unordered_map<uuid, std::vector<int>> of indexes into `inputs`.)

import Foundation
import VideoScanCore

// MARK: - Input projection

struct StewardInput: Sendable, Equatable {
    var id: UUID
    var fullPath: String
    var filename: String
    var sizeBytes: Int64
    var durationSeconds: Double

    // Duplicates
    var isExtraCopy: Bool
    var isKeeper: Bool
    var duplicateGroupID: UUID?
    /// `contentFixity` present and usable for verification.
    var hasUsableDigest: Bool
    var dupAnalyzedAt: Date?

    /// Rule 2 — decided by the canonical predicates on the main actor.
    var protection: StewardProtection

    // Footage
    var footageGroupID: UUID?
    /// FootageConfidence.strength (0 = Possible … 3 = Identical).
    var footageStrength: Int
    var footageRank: Int
    var footageRoleLabel: String
    var footageLikelyOriginalID: UUID?
    var footageOriginalInCatalog: Bool
    var footageEvidence: [String]

    // Dates
    /// The best date the catalog has (any precision) — the Same-footage
    /// card's span. NOT what places a clip in an event: that is the
    /// Angel's trusted-day rule over the facts below (StewardEvents.place).
    var bestDate: Date?
    /// The date facts RecordDateResolver reads, as the Angel projects them
    /// (StewardEvents.facts hands them to the Angel's occasion reader).
    var userDate: String?
    var userDateConfidence: String?
    var embeddedDate: Date?
    var originMake: String?
    var originModel: String?
    var originEncoder: String?
    var inferredDate: Date?
    var inferredConfidence: Float?
    var inferredRange: InferredDateRange?

    // Junk
    var junkScore: Int
    /// The cluster key: first reason other than "duplicate extra copy",
    /// bracketed numbers dropped. nil = no usable reason.
    var junkReasonKey: String?
    /// Nobody has decided about it yet.
    var isUndecided: Bool
    /// In Triage's table (not filed as Archived there).
    var inTriageTable: Bool

    init(id: UUID = UUID(), fullPath: String, filename: String = "", sizeBytes: Int64 = 1,
         durationSeconds: Double = 60, isExtraCopy: Bool = false, isKeeper: Bool = false,
         duplicateGroupID: UUID? = nil, hasUsableDigest: Bool = false, dupAnalyzedAt: Date? = nil,
         protection: StewardProtection = .none, footageGroupID: UUID? = nil, footageStrength: Int = 0,
         footageRank: Int = 0, footageRoleLabel: String = "", footageLikelyOriginalID: UUID? = nil,
         footageOriginalInCatalog: Bool = true, footageEvidence: [String] = [], bestDate: Date? = nil,
         userDate: String? = nil, userDateConfidence: String? = nil, embeddedDate: Date? = nil,
         originMake: String? = nil, originModel: String? = nil, originEncoder: String? = nil,
         inferredDate: Date? = nil, inferredConfidence: Float? = nil, inferredRange: InferredDateRange? = nil,
         junkScore: Int = 0, junkReasonKey: String? = nil,
         isUndecided: Bool = true, inTriageTable: Bool = true) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename.isEmpty ? (fullPath as NSString).lastPathComponent : filename
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.isExtraCopy = isExtraCopy
        self.isKeeper = isKeeper
        self.duplicateGroupID = duplicateGroupID
        self.hasUsableDigest = hasUsableDigest
        self.dupAnalyzedAt = dupAnalyzedAt
        self.protection = protection
        self.footageGroupID = footageGroupID
        self.footageStrength = footageStrength
        self.footageRank = footageRank
        self.footageRoleLabel = footageRoleLabel
        self.footageLikelyOriginalID = footageLikelyOriginalID
        self.footageOriginalInCatalog = footageOriginalInCatalog
        self.footageEvidence = footageEvidence
        self.bestDate = bestDate
        self.userDate = userDate
        self.userDateConfidence = userDateConfidence
        self.embeddedDate = embeddedDate
        self.originMake = originMake
        self.originModel = originModel
        self.originEncoder = originEncoder
        self.inferredDate = inferredDate
        self.inferredConfidence = inferredConfidence
        self.inferredRange = inferredRange
        self.junkScore = junkScore
        self.junkReasonKey = junkReasonKey
        self.isUndecided = isUndecided
        self.inTriageTable = inTriageTable
    }

    /// Project one live record. Main actor (the record lives there).
    @MainActor
    init(record r: VideoRecord, protection: StewardProtection, calendar: Calendar) {
        let best = StewardCaseBuilder.bestDate(userDate: r.userDate, inferred: r.inferredRecordDate,
                                               embedded: r.embeddedCreationDate, created: r.dateCreatedRaw,
                                               calendar: calendar)
        self.init(id: r.id,
                  fullPath: r.fullPath,
                  filename: r.filename,
                  sizeBytes: r.sizeBytes,
                  durationSeconds: r.durationSeconds,
                  isExtraCopy: r.duplicateDisposition == .extraCopy,
                  isKeeper: r.duplicateDisposition == .keep,
                  duplicateGroupID: r.duplicateGroupID,
                  hasUsableDigest: r.contentFixity?.isUsableForVerification ?? false,
                  dupAnalyzedAt: r.dupAnalyzedAt,
                  protection: protection,
                  footageGroupID: r.footage?.groupID,
                  footageStrength: r.footage?.confidence.strength ?? 0,
                  footageRank: r.footage?.rank ?? 0,
                  footageRoleLabel: r.footage?.role.label ?? "",
                  footageLikelyOriginalID: r.footage?.likelyOriginalID,
                  footageOriginalInCatalog: r.footage?.originalInCatalog ?? true,
                  footageEvidence: r.footage?.evidence ?? [],
                  bestDate: best,
                  userDate: r.userDate,
                  userDateConfidence: r.userDateConfidence,
                  embeddedDate: r.embeddedCreationDate,
                  originMake: r.originMake,
                  originModel: r.originModel,
                  originEncoder: r.originEncoder,
                  inferredDate: r.inferredRecordDate,
                  inferredConfidence: r.inferredDateConfidence,
                  inferredRange: r.inferredDateRange,
                  junkScore: r.junkScore,
                  junkReasonKey: StewardCaseBuilder.junkReasonKey(r.junkReasons),
                  isUndecided: r.mediaDisposition == .unreviewed || r.mediaDisposition == .suspectedJunk,
                  inTriageTable: r.lifecycleStage != .archived)
    }
}

// MARK: - Builder (pure)

enum StewardCaseBuilder {

    /// Triage's own line: MediaAnalyzer suggests Suspected Junk at 5, and
    /// the Triage table's Score column turns orange there (sensor:
    /// StewardSourceSensorTests pins both spellings).
    static let junkThreshold = 5
    /// A junk "cluster" is at least this many files.
    static let minJunkCluster = 2
    /// Cases kept per kind that are NOT skipped (one is shown at a time; the
    /// rest wait).
    static let maxCasesPerKind = 25
    /// Skipped cases kept per kind beside them, for "Show skipped".
    static let maxSkippedPerKind = 100
    static let maxCopiesPerCase = 50
    static let maxIDsPerCase = 20_000
    /// FootageConfidence.likely.strength — "Likely or stronger".
    static let minFootageStrength = 1
    static let maxEvidenceLines = 6

    // MARK: Projection (main actor side)

    /// One pass over the live records → Sendable rows. Hidden records
    /// (purged / set-aside / superseded) are dropped. `protection` is the
    /// model's canonical-predicate closure (VideoScanModel+Steward.swift).
    @MainActor
    static func project(_ records: [VideoRecord], calendar: Calendar = .current,
                        protection: (VideoRecord) -> StewardProtection) -> [StewardInput] {
        var out: [StewardInput] = []
        out.reserveCapacity(records.count)
        for r in records where !(r.isPurged || r.isSetAside || r.isSuperseded) {
            out.append(StewardInput(record: r, protection: protection(r), calendar: calendar))
        }
        return out
    }

    // MARK: Entry point

    /// `volumes`: every scan target's root + reachability. `mountedRoots`:
    /// the kernel mount table. `events`: the Angel's occasion reader — the
    /// birthday window and the People tab's birthdays as the Angel holds
    /// them (`archiveAngel.occasionReader`; the default is the built-in
    /// rules with no birthdays). `now` only bounds the date resolver's
    /// search for a year in a file name; nothing in the result carries it.
    /// Pure — no disk, no defaults.
    static func build(inputs: [StewardInput],
                      volumes: [AnalyzeVolumeFact],
                      mountedRoots: Set<String>,
                      alsoCleanUpWorkingCopies: Bool,
                      workingCopyPolicy: DuplicateKeeperPolicy = .unconfigured,
                      events: ArchiveAngel.OccasionReader = ArchiveAngel.OccasionReader(),
                      skipped: [String: StewardFacts] = [:],
                      calendar: Calendar = .current,
                      now: Date = Date()) -> StewardQueue {
        let scanRoots = volumes.map(\.root).sorted { $0.count > $1.count }
        var rootCache: [String: String] = [:]
        // The drive a path lives on, memoised per FOLDER (files in one
        // folder share a drive) so 100k paths cost a few thousand lookups.
        func drive(_ path: String) -> String {
            let folder = (path as NSString).deletingLastPathComponent
            if let hit = rootCache[folder] { return hit }
            let root = driveRoot(of: path, scanRoots: scanRoots)
            rootCache[folder] = root
            return root
        }
        func online(_ root: String) -> Bool { isConnected(root, mountedRoots: mountedRoots) }

        var queue = StewardQueue()
        queue.isBuilt = true

        // One pass: index the groups and the junk clusters, and ask the
        // Angel's derivation what occasion each clip records.
        var placements: [StewardPlacement] = []
        placements.reserveCapacity(inputs.count)
        var folders = EventLabeler.FolderWordCache()   // one per build: each folder's words scanned once
        var dupGroups: [UUID: [Int]] = [:]
        var footageGroups: [UUID: [Int]] = [:]
        var junk: [String: [Int]] = [:]
        var drivesWithReclaimable = Set<String>()
        var roots: [String] = []
        roots.reserveCapacity(inputs.count)
        for (i, r) in inputs.enumerated() {
            let root = drive(r.fullPath)
            roots.append(root)
            let placement = StewardEvents.place(r, now: now, reader: events, folders: &folders)
            if placement.isCounted {
                queue.placeableClips += 1
                if placement.day != nil { queue.placedClips += 1 }
            }
            placements.append(placement)
            if let d = r.dupAnalyzedAt, queue.duplicatesLastChecked.map({ d > $0 }) ?? true {
                queue.duplicatesLastChecked = d
            }
            if let g = r.duplicateGroupID {
                dupGroups[g, default: []].append(i)
                if r.isExtraCopy, !r.protection.isProtected { drivesWithReclaimable.insert(root) }
            }
            if let g = r.footageGroupID { footageGroups[g, default: []].append(i) }
            if r.junkScore >= junkThreshold, r.isUndecided, r.inTriageTable, !r.protection.isProtected,
               let key = r.junkReasonKey {
                junk[key + "|" + root, default: []].append(i)
            }
        }

        let reclaim = reclaimDriveCases(inputs: inputs, roots: roots, groups: dupGroups,
                                        drives: drivesWithReclaimable, mountedRoots: mountedRoots,
                                        alsoCleanUpWorkingCopies: alsoCleanUpWorkingCopies, skipped: skipped)
            + reclaimGroupCases(inputs: inputs, roots: roots, groups: dupGroups, online: online,
                                alsoCleanUpWorkingCopies: alsoCleanUpWorkingCopies,
                                workingCopyPolicy: workingCopyPolicy, skipped: skipped)
        let footage = footageCases(inputs: inputs, roots: roots, groups: footageGroups, online: online,
                                   placements: placements, skipped: skipped, calendar: calendar)
        let junkCases = junkCases(inputs: inputs, roots: roots, clusters: junk, online: online, skipped: skipped)
        let occasions = StewardEvents.cases(
            StewardEvents.Catalog(inputs: inputs, roots: roots, placements: placements,
                                  footageGroups: footageGroups, skipped: skipped),
            online: online)

        // Lane after lane (Rick 2026-10-03: events are the point; the
        // duplicates are housekeeping, lower in the order).
        queue.cases = occasions.events + occasions.days + footage + reclaim.sorted(by: reclaimOrder) + junkCases
        return queue
    }

    /// The per-kind limit, spent on what is NOT skipped (QA F4: 25 skips
    /// must bring the next 25 forward, not empty the lane). `sorted` is in
    /// payoff order; the order is kept. Skipped cases ride along (up to
    /// `maxSkippedPerKind`) so "Show skipped" can bring them back.
    nonisolated static func limit(_ sorted: [StewardCase], skipped: [String: StewardFacts]) -> [StewardCase] {
        var out: [StewardCase] = []
        var active = 0, hidden = 0
        for c in sorted {
            if StewardSkipStore.isSkipped(c, remembered: skipped[c.id]) {
                guard hidden < maxSkippedPerKind else { continue }
                hidden += 1
            } else {
                guard active < maxCasesPerKind else { continue }
                active += 1
            }
            out.append(c)
            if active >= maxCasesPerKind, hidden >= maxSkippedPerKind { break }
        }
        return out
    }

    // MARK: Reclaim space — per drive

    /// One card per drive that holds duplicate copies the flow would check,
    /// largest first. The numbers are ReclaimableCalculator's — with every
    /// protected row passed in as "not an extra copy", so it can still be
    /// the keeper or a counted sibling but is never counted as reclaimable.
    static func reclaimDriveCases(inputs: [StewardInput], roots: [String], groups: [UUID: [Int]],
                                  drives: Set<String>, mountedRoots: Set<String>,
                                  alsoCleanUpWorkingCopies: Bool,
                                  skipped: [String: StewardFacts] = [:]) -> [StewardCase] {
        guard !drives.isEmpty else { return [] }
        // The copies behind each drive's number, for "Show these in the
        // Catalog": the calculator's rule again (keeper on this drive, or
        // any drive when working copies are cleaned too).
        var idsByDrive: [String: [UUID]] = [:]
        // …and the copies no card proposes but the drive's cleanup would
        // still check (the Angel's picks, filed as Archived) — QA F1.
        var stillCheckedByDrive: [String: Int] = [:]
        for members in groups.values {
            guard let keeper = members.first(where: { inputs[$0].isKeeper }) else { continue }
            for i in members where inputs[i].isExtraCopy && !inputs[i].protection.plannerRefuses
                && (roots[i] == roots[keeper] || alsoCleanUpWorkingCopies) {
                if inputs[i].protection.isProtected {
                    stillCheckedByDrive[roots[i], default: 0] += 1
                } else if idsByDrive[roots[i], default: []].count < maxIDsPerCase {
                    idsByDrive[roots[i], default: []].append(inputs[i].id)
                }
            }
        }
        let rows = inputs.map { r in
            ReclaimableInput(fullPath: r.fullPath, sizeBytes: r.sizeBytes,
                             isExtraCopy: r.isExtraCopy && !r.protection.isProtected,
                             isKeeper: r.isKeeper, groupID: r.duplicateGroupID,
                             hasUsableDigest: r.hasUsableDigest, dupAnalyzedAt: r.dupAnalyzedAt)
        }
        var out: [StewardCase] = []
        for root in drives.sorted() {
            // A fixed `now`: the estimate's own timestamp must not make two
            // identical queues compare unequal (the snapshot's gate).
            let e = ReclaimableCalculator.compute(inputs: rows, volumeRoot: root, mountedRoots: mountedRoots,
                                                  alsoCleanUpWorkingCopies: alsoCleanUpWorkingCopies,
                                                  now: Date(timeIntervalSince1970: 0))
            guard e.copies > 0 else { continue }
            let label = driveLabel(root)
            let size = ByteCountFormatter.string(fromByteCount: e.bytes, countStyle: .file)
            var c = StewardCase(id: "drive:" + root, kind: .reclaimDrive,
                                title: "\(label): \(size) in \(e.copies.formatted()) duplicate cop\(e.copies == 1 ? "y" : "ies")",
                                facts: StewardFacts(bytes: e.bytes, count: e.copies))
            c.detail = e.copiesLine
            c.payoffBytes = e.bytes
            c.actionableBytes = e.bytes
            c.memberCount = e.copies
            c.driveRoot = root
            c.driveLabel = label
            c.driveConnected = isConnected(root, mountedRoots: mountedRoots)
            c.estimate = e
            c.recordIDs = idsByDrive[root] ?? []
            c.stillCheckedOnDrive = stillCheckedByDrive[root] ?? 0
            out.append(c)
        }
        out.sort { $0.payoffBytes != $1.payoffBytes ? $0.payoffBytes > $1.payoffBytes : $0.id < $1.id }
        return limit(out, skipped: skipped)
    }

    // MARK: Reclaim space — one set of copies

    static func reclaimGroupCases(inputs: [StewardInput], roots: [String], groups: [UUID: [Int]],
                                  online: (String) -> Bool, alsoCleanUpWorkingCopies: Bool,
                                  workingCopyPolicy: DuplicateKeeperPolicy = .unconfigured,
                                  skipped: [String: StewardFacts] = [:]) -> [StewardCase] {
        var out: [StewardCase] = []
        // The planner's cross-drive verdict, memoised per (copy's drive,
        // keeper's drive) — the same memo `volumesWithDeletableDuplicates`
        // keeps; a handful of drives, so O(set) overall.
        var verdicts: [String: DuplicateKeeperPolicy.CrossVolumeVerdict] = [:]
        func verdict(copyRoot: String, keeperRoot: String, keeperPath: String) -> DuplicateKeeperPolicy.CrossVolumeVerdict {
            let key = copyRoot + "\u{0}" + keeperRoot
            if let hit = verdicts[key] { return hit }
            let v = workingCopyPolicy.crossVolumeVerdict(extraPath: copyRoot, volumeRoot: copyRoot,
                                                         keeperPath: keeperPath, keeperRoot: keeperRoot)
            verdicts[key] = v
            return v
        }
        for (groupID, members) in groups {
            guard members.count > 1, let keeperIndex = members.first(where: { inputs[$0].isKeeper }) else { continue }
            let keeperRoot = roots[keeperIndex]
            var reclaimable: Int64 = 0, actionable: Int64 = 0, total: Int64 = 0
            var reclaimableCopies = 0, needMode = 0, protected = 0
            var bytesByDrive: [String: Int64] = [:]
            var actionableByDrive: [String: Int64] = [:]
            var drives = Set<String>()
            var copies: [StewardCopy] = []
            var stillCheckedByDrive: [String: Int] = [:]
            var runRows: [StewardRunRow] = []
            for i in members {
                let r = inputs[i]
                let root = roots[i]
                drives.insert(root)
                total += max(0, r.sizeBytes)
                // QA F6(a): in working-copy mode, only what the planner's
                // own rule would take — not every copy on another drive.
                let crossVerdict = root == keeperRoot || !alsoCleanUpWorkingCopies ? nil
                    : verdict(copyRoot: root, keeperRoot: keeperRoot, keeperPath: inputs[keeperIndex].fullPath)
                let flowWouldCheck = root == keeperRoot || crossVerdict?.isEligible == true
                let standing: StewardCopyStanding
                if r.isKeeper {
                    standing = .keeper
                } else if !r.isExtraCopy {
                    // In the set, but not marked as an extra copy (a
                    // "review" row): never proposed.
                    standing = .member
                } else if r.protection.plannerRefuses {
                    protected += 1
                    standing = .protected(r.protection)
                } else if r.protection.isProtected {
                    // The steward's own restraint (the Angel's pick, filed
                    // as Archived): never proposed, never counted as
                    // reclaimable — but the planner does not refuse it.
                    if flowWouldCheck {
                        stillCheckedByDrive[root, default: 0] += 1
                        if runRows.count < maxIDsPerCase { runRows.append(StewardRunRow(id: r.id, driveRoot: root)) }
                        standing = .stillChecked(r.protection)
                    } else {
                        standing = .protected(r.protection)
                    }
                } else {
                    reclaimableCopies += 1
                    reclaimable += max(0, r.sizeBytes)
                    bytesByDrive[root, default: 0] += max(0, r.sizeBytes)
                    if flowWouldCheck {
                        actionable += max(0, r.sizeBytes)
                        actionableByDrive[root, default: 0] += max(0, r.sizeBytes)
                        if runRows.count < maxIDsPerCase { runRows.append(StewardRunRow(id: r.id, driveRoot: root)) }
                        standing = .wouldBeChecked
                    } else if let crossVerdict {
                        standing = .workingCopyNotTaken(crossVerdict)
                    } else {
                        needMode += 1
                        standing = .keeperOnAnotherDrive
                    }
                }
                copies.append(copy(r, root: root, online: online(root), standing: standing))
            }
            // Rule 2: a set whose only other copies are protected (or are
            // not extra copies at all) proposes nothing.
            guard reclaimableCopies > 0 else { continue }

            // The drive the action works on: where the flow would reclaim
            // the most; failing that, where the most could be reclaimed.
            let target = (actionableByDrive.isEmpty ? bytesByDrive : actionableByDrive)
                .max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
            let keeperLabel = driveLabel(keeperRoot)
            let n = members.count
            // Keyed by the KEEPER's record id: a duplicate check renumbers
            // the group every time, and a skip must survive that (QA F5).
            var c = StewardCase(id: "dup:" + inputs[keeperIndex].id.uuidString, kind: .reclaimGroup,
                                title: "\(n) copies over \(drives.count) drive\(drives.count == 1 ? "" : "s") · \(size(total))"
                                    + " · keep the one on \(keeperLabel) · reclaim \(size(reclaimable))",
                                facts: StewardFacts(bytes: reclaimable, count: n))
            c.detail = inputs[keeperIndex].filename
            c.payoffBytes = reclaimable
            c.actionableBytes = actionable
            c.memberCount = n
            c.driveRoot = target
            c.driveLabel = target.map(driveLabel) ?? ""
            c.driveConnected = target.map(online) ?? false
            c.recordIDs = members.prefix(maxIDsPerCase).map { inputs[$0].id }
            c.copies = Array(copies.sorted(by: copyOrder).prefix(maxCopiesPerCase))
            c.duplicateGroupID = groupID
            c.keeperID = inputs[keeperIndex].id
            c.copiesNeedingWorkingCopyMode = needMode
            c.protectedCopies = protected
            c.stillCheckedOnDrive = target.flatMap { stillCheckedByDrive[$0] } ?? 0
            c.runRows = runRows
            out.append(c)
        }
        out.sort(by: reclaimOrder)
        return limit(out, skipped: skipped)
    }

    /// What the flow would reclaim today first, then what could be, then id.
    static func reclaimOrder(_ a: StewardCase, _ b: StewardCase) -> Bool {
        if a.actionableBytes != b.actionableBytes { return a.actionableBytes > b.actionableBytes }
        if a.payoffBytes != b.payoffBytes { return a.payoffBytes > b.payoffBytes }
        return a.id < b.id
    }

    // MARK: Same footage

    static func footageCases(inputs: [StewardInput], roots: [String], groups: [UUID: [Int]],
                             online: (String) -> Bool, placements: [StewardPlacement],
                             skipped: [String: StewardFacts] = [:],
                             calendar: Calendar) -> [StewardCase] {
        var out: [StewardCase] = []
        for (groupID, unsorted) in groups {
            guard unsorted.count > 1 else { continue }
            // A group's confidence is its weakest link; every member
            // carries it, so the weakest seen is the group's.
            let strength = unsorted.map { inputs[$0].footageStrength }.min() ?? 0
            guard strength >= minFootageStrength else { continue }
            let members = unsorted.sorted {
                inputs[$0].footageRank != inputs[$1].footageRank
                    ? inputs[$0].footageRank < inputs[$1].footageRank : inputs[$0].fullPath < inputs[$1].fullPath
            }
            var bytes: Int64 = 0
            var drives = Set<String>()
            var earliest: Date?, latest: Date?
            var evidence: [String] = []
            var seenEvidence = Set<String>()
            for i in members {
                let r = inputs[i]
                bytes += max(0, r.sizeBytes)
                drives.insert(roots[i])
                if let d = r.bestDate {
                    if earliest.map({ d < $0 }) ?? true { earliest = d }
                    if latest.map({ d > $0 }) ?? true { latest = d }
                }
                for line in r.footageEvidence where evidence.count < maxEvidenceLines && seenEvidence.insert(line).inserted {
                    evidence.append(line)
                }
            }
            let first = inputs[members[0]]
            let originalID = first.footageLikelyOriginalID
            let original = members.first { inputs[$0].id == originalID }.map { inputs[$0] }
            let n = members.count
            let span = dateSpanText(earliest: earliest, latest: latest, calendar: calendar)
            let description = "\(n) clips on \(drives.count) drive\(drives.count == 1 ? "" : "s") — \(sameFootageWords(strength: strength))"
                + (span.isEmpty ? "" : " · \(span)")
            var c = StewardCase(id: "footage:" + groupID.uuidString, kind: .sameFootage, title: description,
                                facts: StewardFacts(bytes: bytes, count: n))
            c.payoffBytes = bytes
            c.memberCount = n
            c.recordIDs = members.prefix(maxIDsPerCase).map { inputs[$0].id }
            c.copies = members.prefix(maxCopiesPerCase).map { i in
                var row = copy(inputs[i], root: roots[i], online: online(roots[i]), standing: .member)
                row.roleLabel = inputs[i].footageRoleLabel
                return row
            }
            c.footageGroupID = groupID
            c.likelyOriginalID = original?.id ?? first.id
            c.likelyOriginalName = (original ?? first).filename
            c.originalInCatalog = first.footageOriginalInCatalog
            c.evidenceLines = evidence
            c.plainDescription = description
            out.append(c)
        }
        // By member count, then bytes (the brief's order), then id.
        out.sort {
            if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
            if $0.payoffBytes != $1.payoffBytes { return $0.payoffBytes > $1.payoffBytes }
            return $0.id < $1.id
        }
        var kept = limit(out, skipped: skipped)
        // Title precedence: the person's name, else the occasion guess,
        // else the description. Footage groups have nowhere to keep a name
        // yet (shown as a gap on the card) — `name` is nil until they do.
        // The guess is the labeller's (StewardEvents.footageGuess), worked
        // out only for the groups that made the cut.
        for i in kept.indices {
            let members = kept[i].footageGroupID.flatMap { groups[$0] } ?? []
            let guess = StewardEvents.footageGuess(members: members, placements: placements)
            let lines = StewardFootageTitle.lines(name: nil, guess: guess, description: kept[i].plainDescription)
            kept[i].title = lines.title
            kept[i].detail = lines.caption ?? ""
            kept[i].occasionGuess = guess
        }
        return kept
    }

    static func sameFootageWords(strength: Int) -> String {
        switch strength {
        case 3: return "the same footage, byte for byte"
        case 2: return "the same footage (you confirmed)"
        default: return "likely the same footage"
        }
    }

    // MARK: Probably not worth keeping

    static func junkCases(inputs: [StewardInput], roots: [String], clusters: [String: [Int]],
                          online: (String) -> Bool, skipped: [String: StewardFacts] = [:]) -> [StewardCase] {
        var out: [StewardCase] = []
        for (key, members) in clusters where members.count >= minJunkCluster {
            guard let first = members.first, let reason = inputs[first].junkReasonKey else { continue }
            let root = roots[first]
            let label = driveLabel(root)
            let bytes = members.reduce(Int64(0)) { $0 + max(0, inputs[$1].sizeBytes) }
            let n = members.count
            var c = StewardCase(id: "junk:" + key, kind: .junk,
                                title: "\(n.formatted()) \(junkNoun(reason)) on \(label)",
                                facts: StewardFacts(bytes: bytes, count: n))
            c.detail = "\(size(bytes)) in all. Short or odd clips are not deleted from here — look them over and decide."
            c.payoffBytes = bytes
            c.memberCount = n
            c.driveRoot = root
            c.driveLabel = label
            c.driveConnected = online(root)
            c.recordIDs = members.prefix(maxIDsPerCase).map { inputs[$0].id }
            c.copies = members.prefix(maxCopiesPerCase).map {
                copy(inputs[$0], root: root, online: online(root), standing: .member)
            }
            c.junkReason = reason
            out.append(c)
        }
        out.sort {
            if $0.memberCount != $1.memberCount { return $0.memberCount > $1.memberCount }
            if $0.payoffBytes != $1.payoffBytes { return $0.payoffBytes > $1.payoffBytes }
            return $0.id < $1.id
        }
        return limit(out, skipped: skipped)
    }

    /// The cluster key for a record's reasons: the first one that is not
    /// "duplicate extra copy", with bracketed numbers dropped
    /// ("Very short (2.1s)" → "Very short").
    nonisolated static func junkReasonKey(_ reasons: [String]) -> String? {
        for reason in reasons where !reason.hasPrefix("Duplicate extra copy") {
            var out = ""
            var depth = 0
            for ch in reason {
                if ch == "(" { depth += 1; continue }
                if ch == ")" { depth = max(0, depth - 1); continue }
                if depth == 0 { out.append(ch) }
            }
            let key = out.replacingOccurrences(of: " ,", with: ",")
                .replacingOccurrences(of: "  ", with: " ")
                .trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { return key }
        }
        return nil
    }

    /// Family words for each of MediaAnalyzer's reasons ("38 very short
    /// clips on SanDisk"). An unknown reason is quoted as it stands.
    nonisolated static func junkNoun(_ key: String) -> String {
        junkNouns[key] ?? "files marked “\(key)”"
    }

    /// MediaAnalyzer's reason (brackets dropped) → the words on the card.
    nonisolated static let junkNouns: [String: String] = [
        "Very short": "very short clips",
        "Probe failed — file may be corrupted": "files that could not be read",
        "No audio or video streams found": "files with no picture or sound",
        "Zero duration": "clips with no length",
        "Zero-byte file": "empty files",
        "Short audio-only clip, no pair found": "short sound-only clips",
        "Audio-only file, no pair found": "sound-only files with no matching picture",
        "Video-only file, no audio pair found": "picture-only files with no matching sound",
        "Low audio sample rate — voicemail/VoIP": "phone-quality recordings",
        "Mono 8kHz — likely phone recording": "phone-quality recordings",
        "Screencast resolution, no audio": "screen recordings",
        "Short clip at screencast resolution": "short screen recordings",
        "Avid render/precompute file": "Avid render files",
        "Final Cut Pro render/scratch file": "Final Cut render files",
        "System/hidden directory artifact": "system leftovers",
        "Filename suggests test/temp/sample content": "test or temporary clips",
        "Filename suggests NLE transition or render output": "editing transitions and renders",
        "File appears truncated": "files that look cut off",
        "Very low resolution — below usable threshold": "very small pictures",
    ]

    // MARK: What the pane shows

    /// The pane's filter above the list (pure view state).
    enum Filter: String, Sendable, CaseIterable {
        case all, events, footage, space, junk

        var label: String {
            switch self {
            case .all: return "All"
            case .events: return "Events"
            case .footage: return "Same footage"
            case .space: return "Space"
            case .junk: return "Not worth keeping"
            }
        }

        func shows(_ kind: StewardCaseKind) -> Bool {
            switch self {
            case .all: return true
            case .events: return kind == .event || kind == .unlabelledDay
            case .footage: return kind == .sameFootage
            case .space: return kind == .reclaimDrive || kind == .reclaimGroup
            case .junk: return kind == .junk
            }
        }
    }

    /// The list as the pane shows it: the built order (lane after lane),
    /// narrowed by the filter; with `eventsByYear` the events are put in
    /// year order (earliest first, the built order within a year) and
    /// everything else keeps its place. O(n log n) over at most a few
    /// hundred rows — called from the pane's event handlers, never a body.
    nonisolated static func arrange(_ cases: [StewardCase], filter: Filter, eventsByYear: Bool) -> [StewardCase] {
        let shown = filter == .all ? cases : cases.filter { filter.shows($0.kind) }
        guard eventsByYear else { return shown }
        let events = shown.enumerated().filter { $0.element.kind == .event }
            .sorted { a, b in
                let ya = a.element.eventYear ?? Int.max, yb = b.element.eventYear ?? Int.max
                return ya != yb ? ya < yb : a.offset < b.offset
            }
            .map(\.element)
        return events + shown.filter { $0.kind != .event }
    }

    // MARK: Small pure helpers

    /// `/Volumes/X/…` → `/Volumes/X`; otherwise the longest scan root the
    /// path is under; otherwise its folder. Same answer as
    /// `VideoScanModel.volumeRoot(for:)` and the Delete flow's volume list.
    nonisolated static func driveRoot(of path: String, scanRoots: [String]) -> String {
        if path.hasPrefix("/Volumes/") {
            let name = path.dropFirst(9).prefix { $0 != "/" }
            return "/Volumes/" + name
        }
        for root in scanRoots where VolumeDashboardCalculator.isUnder(path, root: root) { return root }
        return (path as NSString).deletingLastPathComponent
    }

    nonisolated static func isConnected(_ root: String, mountedRoots: Set<String>) -> Bool {
        guard root.hasPrefix("/Volumes/") else { return true }
        return mountedRoots.contains(root)
    }

    nonisolated static func driveLabel(_ root: String) -> String {
        let name = (root as NSString).lastPathComponent
        return name.isEmpty ? root : name
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func copy(_ r: StewardInput, root: String, online: Bool,
                     standing: StewardCopyStanding) -> StewardCopy {
        let directory = (r.fullPath as NSString).deletingLastPathComponent
        var folder = directory.hasPrefix(root) ? String(directory.dropFirst(root.count)) : directory
        while folder.hasPrefix("/") { folder.removeFirst() }
        return StewardCopy(id: r.id, filename: r.filename, drive: driveLabel(root), driveRoot: root, folder: folder,
                           sizeBytes: r.sizeBytes, durationSeconds: r.durationSeconds, isOnline: online,
                           standing: standing)
    }

    /// Keeper first, then the copies the flow would check, then the rest.
    private static func copyOrder(_ a: StewardCopy, _ b: StewardCopy) -> Bool {
        func weight(_ s: StewardCopyStanding) -> Int {
            switch s {
            case .keeper: return 0
            case .wouldBeChecked: return 1
            case .stillChecked: return 2
            case .keeperOnAnotherDrive, .workingCopyNotTaken: return 3
            case .member: return 4
            case .protected: return 5
            }
        }
        let wa = weight(a.standing), wb = weight(b.standing)
        if wa != wb { return wa < wb }
        if a.drive != b.drive { return a.drive < b.drive }
        return a.filename < b.filename
    }

    /// "Dec 2006" · "Dec 2006 – Jan 2007" · "2004 – 2006" · "".
    nonisolated static func dateSpanText(earliest: Date?, latest: Date?, calendar: Calendar) -> String {
        guard let earliest, let latest else { return "" }
        let a = calendar.dateComponents([.year, .month], from: earliest)
        let b = calendar.dateComponents([.year, .month], from: latest)
        guard let ay = a.year, let am = a.month, let by = b.year, let bm = b.month else { return "" }
        // The app's words are English; a Calendar built without a locale
        // has no month names of its own.
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        func month(_ m: Int, _ y: Int) -> String { (1...months.count).contains(m) ? "\(months[m - 1]) \(y)" : "\(y)" }
        if ay == by, am == bm { return month(am, ay) }
        if by - ay >= 2 { return "\(ay) – \(by)" }
        return "\(month(am, ay)) – \(month(bm, by))"
    }

    /// The best date the catalog has for a record, at any precision: the
    /// person's date when there is one ("1994" reads as 1 Jan 1994), else
    /// the inferred date, else the one in the file, else the file-system
    /// one. Only the Same-footage card's month span reads this; what DAY a
    /// clip records is the Angel's rule (StewardEvents.place), not this.
    nonisolated static func bestDate(userDate: String?, inferred: Date?, embedded: Date?, created: Date?,
                                     calendar: Calendar) -> Date? {
        if let userDate, let parsed = parseUserDate(userDate, calendar: calendar) { return parsed.date }
        return inferred ?? embedded ?? created
    }

    /// "1994-12-25" → that day (precise); "1994-12" / "1994" / "1994-xx-xx"
    /// → the first of the month / year (not precise); anything else → nil.
    nonisolated static func parseUserDate(_ raw: String, calendar: Calendar) -> (date: Date, isDayPrecise: Bool)? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
        guard let first = parts.first, first.count == 4, let year = Int(first) else { return nil }
        let month = parts.count > 1 ? Int(parts[1]) : nil
        let day = parts.count > 2 ? Int(parts[2].prefix(2)) : nil
        guard let date = calendar.date(from: DateComponents(year: year, month: month ?? 1,
                                                            day: month == nil ? 1 : (day ?? 1), hour: 12)) else { return nil }
        return (date, month != nil && day != nil)
    }
}
