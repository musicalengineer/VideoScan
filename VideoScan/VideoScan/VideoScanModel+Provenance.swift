import Foundation

// MARK: - VideoScanModel+Provenance
//
// Pure builders for the Provenance & Audit Trail feature (View 1, View 2,
// View 3). These functions are `nonisolated static` wherever they don't
// need MainActor state — the views call thin MainActor wrappers further
// down that snapshot the model and hand off to the pure builders.
//
// Design notes:
//   - No new schema. Everything reads from existing `VideoRecord` fields
//     (`fullPath`, `originalFullPath`, `originVolume`, `notes`, `partialMD5`,
//     `sizeBytes`, `archiveStage`, `combinedFromPairID`) plus `scanTargets`.
//   - Reuses the `formatSafelyRedundantNote` parser exposed by
//     `VideoScanModel+RetireVolume` so we never duplicate the witness-note
//     format.
//   - Resolver follows the same longest-prefix shape as the safe-witness
//     ranking in §1A.2.
//
// Worst-case memory: each builder walks `records` once and emits values
// bounded by `records.count`. For a 50K-record catalog with ~256B paths
// this is a transient ~12 MB during the build, freed when the view
// dismisses. No streaming concerns.

extension VideoScanModel {

    // MARK: - Witness-note event parsing (View 2)

    /// One parsed entry from a record's `notes` field. Used by the
    /// File Journey builder to lift Reconcile/Combine/Relocate lines
    /// into typed timeline events.
    struct ParsedNoteEvent: Equatable {
        let timestamp: Date?
        let kind: JourneyEventKind
        let icon: String
        /// Already friendly-toned sentence ready for the timeline.
        let sentence: String
    }

    /// Parse a record's `notes` field into a list of `ParsedNoteEvent`.
    /// One line per event — order preserved so the journey timeline can
    /// render oldest-first naturally.
    ///
    /// Recognizes four shapes the rest of the codebase produces:
    ///   - `Reconcile <stamp>: ...` (every flavor — Bucket B, D, E, source-move)
    ///   - `Relocate <stamp>: ...`
    ///   - `Combined: <summary>`
    ///   - anything else → kept as `.freeForm` with no timestamp
    nonisolated static func parseRelocateEventsFromNotes(_ notes: String) -> [ParsedNoteEvent] {
        guard !notes.isEmpty else { return [] }
        var out: [ParsedNoteEvent] = []
        for raw in notes.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if let evt = parseReconcileLine(line) {
                out.append(evt)
                continue
            }
            if let evt = parseRelocateLine(line) {
                out.append(evt)
                continue
            }
            if let evt = parseCombineLine(line) {
                out.append(evt)
                continue
            }
            // Free-form user note — keep it on the timeline so the user
            // can see their own notes in context. No timestamp.
            out.append(ParsedNoteEvent(
                timestamp: nil,
                kind: .freeForm,
                icon: JourneyEventKind.freeForm.defaultIcon,
                sentence: line
            ))
        }
        return out
    }

    /// `Reconcile <ISO8601>: <body>` — every flavor goes through here.
    /// ISO8601 stamps contain `:` (HH:MM:SS) so we split on the literal
    /// `": "` separator which can't appear inside the timestamp.
    nonisolated private static func parseReconcileLine(_ line: String) -> ParsedNoteEvent? {
        guard line.hasPrefix("Reconcile ") else { return nil }
        let afterPrefix = line.dropFirst("Reconcile ".count)
        guard let sepRange = afterPrefix.range(of: ": ") else { return nil }
        let stamp = String(afterPrefix[..<sepRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let body = String(afterPrefix[sepRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        let date = parseISO8601(stamp)
        let sentence: String
        if body.contains("reason=dup-on-other-volume") {
            // Pull just the totalWitnesses count for the human-readable
            // sentence; the full witness list lives on the disclosure.
            let count = extractTotalWitnesses(body)
            if count > 0 {
                sentence = "Found backup copies on \(count) other drive\(count == 1 ? "" : "s") — kept the record for reference."
            } else {
                sentence = "Found backup copies on other drives — kept the record for reference."
            }
        } else if body.contains("adopted existing copy") {
            sentence = "Adopted an existing copy at the destination."
        } else if body.contains("source file not found") {
            sentence = "Source file was missing — record marked deleted."
        } else if body.contains("source-side move detected") {
            sentence = "Source file had moved — path updated."
        } else {
            sentence = body
        }
        return ParsedNoteEvent(
            timestamp: date,
            kind: .reconcile,
            icon: JourneyEventKind.reconcile.defaultIcon,
            sentence: sentence
        )
    }

    /// `Migrate <ISO8601>: <body>` (or legacy `Relocate <ISO8601>: <body>`)
    /// — currently only emitted on salvage failures. The body carries
    /// `<stage> — <reason>`. Same `": "` separator trick as
    /// `parseReconcileLine`. Both prefixes are accepted so catalogs
    /// written before the 2026-05-31 user-facing rename still render
    /// cleanly in the File Journey timeline.
    nonisolated private static func parseRelocateLine(_ line: String) -> ParsedNoteEvent? {
        let prefix: String
        if line.hasPrefix("Migrate ") {
            prefix = "Migrate "
        } else if line.hasPrefix("Relocate ") {
            prefix = "Relocate "
        } else {
            return nil
        }
        let afterPrefix = line.dropFirst(prefix.count)
        guard let sepRange = afterPrefix.range(of: ": ") else { return nil }
        let stamp = String(afterPrefix[..<sepRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        let body = String(afterPrefix[sepRange.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return ParsedNoteEvent(
            timestamp: parseISO8601(stamp),
            kind: .relocate,
            icon: JourneyEventKind.relocate.defaultIcon,
            sentence: "Migrate hit a problem: \(body)"
        )
    }

    /// `Combined: <summary>` — produced by VideoScanModel+Combine. No
    /// stamp embedded in the note today, but the record's
    /// `dateCreatedRaw` is the combine time for newly-created merge
    /// records. We surface the summary; the journey builder fills in the
    /// timestamp from the record itself.
    nonisolated private static func parseCombineLine(_ line: String) -> ParsedNoteEvent? {
        guard line.hasPrefix("Combined: ") else { return nil }
        let body = String(line.dropFirst("Combined: ".count))
        return ParsedNoteEvent(
            timestamp: nil,
            kind: .combine,
            icon: JourneyEventKind.combine.defaultIcon,
            sentence: "Combined audio and video into one file (\(body))."
        )
    }

    /// Best-effort ISO8601 → Date. Returns nil rather than throwing so
    /// the journey timeline can still render the event with just its
    /// display string.
    nonisolated private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        // `withInternetDateTime` is the default option set — handles
        // both 2026-05-30T10:00:00Z and 2026-05-30T10:00:00+00:00.
        return f.date(from: s)
    }

    /// Extract `N` from `... totalWitnesses=N`. Returns 0 if missing /
    /// malformed.
    nonisolated private static func extractTotalWitnesses(_ body: String) -> Int {
        guard let range = body.range(of: "totalWitnesses=") else { return 0 }
        let tail = body[range.upperBound...]
        var digits = ""
        for ch in tail {
            if ch.isNumber { digits.append(ch) } else { break }
        }
        return Int(digits) ?? 0
    }

    // MARK: - Volume Provenance (View 1)

    /// Build the payload for "Where files from <vol> live now."
    /// Pure — takes the catalog snapshot + role/trust resolver and emits
    /// the value. The MainActor wrapper below grabs both off the model.
    nonisolated static func buildVolumeProvenance(
        sourceVolumeRootPath: String,
        sourceVolumeName: String,
        sourceIsRetired: Bool,
        sourceRetiredAt: Date?,
        sourceRetiredReason: String?,
        allRecords: [VideoRecord],
        resolveVolumeSafety: VolumeSafetyResolver
    ) -> VolumeProvenance {
        // Source records are EVERY record that began on this volume:
        //   - records currently still here (`fullPath` under the source root),
        //   - records that started here and were relocated elsewhere
        //     (`originalFullPath` under the source root OR `originVolume`
        //      matches the source's leaf name).
        let sourceLeaf = (sourceVolumeRootPath as NSString).lastPathComponent
        let srcPrefix = sourceVolumeRootPath.hasSuffix("/")
            ? sourceVolumeRootPath
            : sourceVolumeRootPath + "/"
        let sourceRecords = allRecords.filter { rec in
            if rec.fullPath.hasPrefix(srcPrefix) { return true }
            if let orig = rec.originalFullPath, orig.hasPrefix(srcPrefix) { return true }
            if let originVol = rec.originVolume, originVol == sourceLeaf { return true }
            return false
        }

        // Each source record may have copies at multiple destination
        // volumes. Group every known destination path (current `fullPath`
        // when not on the source, plus every parsed Bucket E witness path)
        // by host volume.
        //
        // We also track which source records have at least one safe
        // backup so the headline can say "all NN have a safe backup" vs
        // "M lack a safe backup."
        var byVolume: [String: VolumeAggregator] = [:]
        var recordsWithSafe = 0
        var atRisk: [String] = []

        for rec in sourceRecords {
            // Build the union of known destinations for this record.
            var destinations: [(path: String, volumePath: String)] = []

            // (a) Current location, if it's no longer on the source.
            if !rec.fullPath.hasPrefix(srcPrefix) && !rec.fullPath.isEmpty {
                let vp = volumeRootForPath(rec.fullPath)
                destinations.append((rec.fullPath, vp))
            }

            // (b) Witness paths parsed from the audit-trail notes.
            for w in parseWitnessesFromNote(rec.notes) {
                let vp = volumeRootForPath(w)
                // Skip witnesses that point back to the source — those
                // would just duplicate the original location.
                if vp == sourceVolumeRootPath { continue }
                destinations.append((w, vp))
            }

            // Dedup within this record so the same destination isn't
            // double-counted from both fullPath and a witness line.
            var seen = Set<String>()
            var hasSafeCopy = false
            for (path, vp) in destinations {
                if !seen.insert(path).inserted { continue }
                let (role, trust) = resolveVolumeSafety(path)
                let safe = role != .retired && trust != .unreliable
                if safe { hasSafeCopy = true }
                let key = vp.isEmpty ? "<unknown>" : vp
                byVolume[key, default: VolumeAggregator(volumeRootPath: vp,
                                                         role: role,
                                                         trust: trust)]
                    .add(path: path, bytes: rec.sizeBytes)
            }

            if hasSafeCopy {
                recordsWithSafe += 1
            } else if !destinations.isEmpty {
                // No safe witness anywhere. Surface the filename so the
                // headline can list the at-risk ones.
                atRisk.append(rec.filename.isEmpty
                              ? (rec.fullPath as NSString).lastPathComponent
                              : rec.filename)
            } else {
                // Still resident on source-only. If the source itself is
                // safe, count it as backed up; otherwise it's at-risk.
                let (role, trust) = resolveVolumeSafety(rec.fullPath)
                if role != .retired && trust != .unreliable {
                    recordsWithSafe += 1
                } else {
                    atRisk.append(rec.filename.isEmpty
                                  ? (rec.fullPath as NSString).lastPathComponent
                                  : rec.filename)
                }
            }
        }

        let groups = byVolume.values
            .map { $0.snapshot() }
            .sorted {
                // Primary: safety score descending. Secondary: name.
                if $0.safetyScore != $1.safetyScore {
                    return $0.safetyScore > $1.safetyScore
                }
                return $0.volumeName.localizedCaseInsensitiveCompare($1.volumeName)
                    == .orderedAscending
            }

        return VolumeProvenance(
            sourceVolumeName: sourceVolumeName,
            sourceVolumeRootPath: sourceVolumeRootPath,
            sourceIsRetired: sourceIsRetired,
            sourceRetiredAt: sourceRetiredAt,
            sourceRetiredReason: sourceRetiredReason,
            sourceRecordCount: sourceRecords.count,
            recordsWithSafeBackup: recordsWithSafe,
            atRiskFilenames: atRisk.sorted(),
            allDestinations: groups
        )
    }

    /// Mutable aggregator used internally by `buildVolumeProvenance`.
    private struct VolumeAggregator {
        let volumeRootPath: String
        var role: VolumeRole
        var trust: VolumeTrust
        var fileCount: Int = 0
        var totalBytes: Int64 = 0
        var paths: [String] = []

        mutating func add(path: String, bytes: Int64) {
            fileCount += 1
            totalBytes += bytes
            paths.append(path)
        }

        func snapshot() -> DestinationVolumeGroup {
            let sorted = paths.sorted()
            let sample = Array(sorted.prefix(5))
            let leaf = (volumeRootPath as NSString).lastPathComponent
            return DestinationVolumeGroup(
                volumeName: leaf.isEmpty
                    ? (volumeRootPath.isEmpty ? "Unknown volume" : volumeRootPath)
                    : leaf,
                volumeRootPath: volumeRootPath,
                role: role,
                trust: trust,
                fileCount: fileCount,
                totalBytes: totalBytes,
                samplePaths: sample,
                totalSampleAvailable: sorted.count
            )
        }
    }

    /// Compute the volume root for an arbitrary path. Used by the
    /// provenance grouping. Mirrors the rule the rest of the UI uses
    /// (first two components under /Volumes/; "/" otherwise).
    nonisolated private static func volumeRootForPath(_ path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Volumes/" + String(parts[1]) }
        }
        if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return "/Users/" + String(parts[1]) }
        }
        return "/"
    }

    // MARK: - File Journey (View 2)

    /// Build the payload for "Following <filename>". Pure — same MainActor
    /// wrapper pattern as `buildVolumeProvenance`.
    nonisolated static func buildFileJourney(
        for rec: VideoRecord,
        allRecords: [VideoRecord],
        resolveVolumeSafety: VolumeSafetyResolver
    ) -> FileJourney {

        // 1. Origin event — every record has one, even ones never
        //    relocated. We use `originVolume`/`originalFullPath` when
        //    present (post-relocate), else the current `fullPath` and
        //    `volumeName`. Date best-effort from `dateModifiedRaw` or
        //    `dateCreatedRaw`.
        var events: [JourneyEvent] = []
        let originVol = rec.originVolume ?? rec.volumeName
        let originPath = rec.originalFullPath ?? rec.fullPath
        let originDate = rec.dateModifiedRaw ?? rec.dateCreatedRaw
        let originSentence: String
        if !originVol.isEmpty {
            originSentence = "Scanned on \(originVol) at \(originPath)"
        } else {
            originSentence = "Scanned at \(originPath)"
        }
        events.append(JourneyEvent(
            timestamp: originDate,
            displayStamp: friendlyStamp(originDate),
            icon: JourneyEventKind.origin.defaultIcon,
            kind: .origin,
            sentence: originSentence
        ))

        // 2. Each parsed note event becomes a timeline event. Combines
        //    use the record's `dateCreatedRaw` as their best-known
        //    timestamp (combine writes a fresh record with that date).
        let parsed = parseRelocateEventsFromNotes(rec.notes)
        for evt in parsed {
            let ts = evt.timestamp ?? (evt.kind == .combine ? rec.dateCreatedRaw : nil)
            events.append(JourneyEvent(
                timestamp: ts,
                displayStamp: friendlyStamp(ts),
                icon: evt.icon,
                kind: evt.kind,
                sentence: evt.sentence
            ))
        }

        // Sort events: origin first (always), then by timestamp
        // ascending; nil-timestamp events get pinned to the end so the
        // current state is still last.
        let origin = events.first!
        let rest = events.dropFirst().sorted { lhs, rhs in
            switch (lhs.timestamp, rhs.timestamp) {
            case let (l?, r?): return l < r
            case (_?, nil):    return true
            case (nil, _?):    return false
            case (nil, nil):   return false
            }
        }
        var ordered: [JourneyEvent] = [origin] + Array(rest)

        // 3. Current state event — always last.
        let isMarkedDeleted = rec.archiveStage == .manuallyDeleted
        let witnessCount = parseWitnessesFromNote(rec.notes).count
        let currentSentence: String
        if isMarkedDeleted {
            currentSentence = witnessCount > 0
                ? "Marked deleted — \(witnessCount) backup copy reference(s) on file."
                : "Marked deleted from the catalog."
        } else {
            currentSentence = "Now at \(rec.fullPath)"
        }
        ordered.append(JourneyEvent(
            timestamp: Date(),
            displayStamp: friendlyStamp(Date()),
            icon: isMarkedDeleted
                ? JourneyEventKind.retire.defaultIcon
                : JourneyEventKind.currentState.defaultIcon,
            kind: .currentState,
            sentence: currentSentence
        ))

        // 4. Other known copies — every duplicate-group sibling AND every
        //    Bucket E witness path. Resolved through the safety resolver
        //    so the UI can badge each entry.
        var seenPaths = Set<String>()
        seenPaths.insert(rec.fullPath)
        var copies: [KnownCopy] = []

        if let dupID = rec.duplicateGroupID {
            for other in allRecords where other.duplicateGroupID == dupID
                                       && other.id != rec.id {
                guard seenPaths.insert(other.fullPath).inserted else { continue }
                let (role, trust) = resolveVolumeSafety(other.fullPath)
                copies.append(KnownCopy(
                    path: other.fullPath,
                    volumeName: volumeNameForPath(other.fullPath),
                    role: role,
                    trust: trust
                ))
            }
        }
        for w in parseWitnessesFromNote(rec.notes) {
            guard seenPaths.insert(w).inserted else { continue }
            let (role, trust) = resolveVolumeSafety(w)
            copies.append(KnownCopy(
                path: w,
                volumeName: volumeNameForPath(w),
                role: role,
                trust: trust
            ))
        }
        copies.sort { lhs, rhs in
            // Safe before degraded; within each group alphabetical.
            if lhs.isSafe != rhs.isSafe { return lhs.isSafe }
            return lhs.volumeName.localizedCaseInsensitiveCompare(rhs.volumeName)
                == .orderedAscending
        }

        // Hash status line — prefer "verified" when we know the partial
        // MD5 was checked recently (we can't tell from the catalog
        // today, so just label it "Hash on file"). The view treats this
        // as a passthrough string.
        let hashLine: String
        if rec.partialMD5.isEmpty {
            hashLine = "No hash recorded — re-scan to capture one."
        } else {
            let prefix = String(rec.partialMD5.prefix(8))
            hashLine = "partialMD5: \(prefix)…"
        }

        return FileJourney(
            recordID: rec.id,
            filename: rec.filename,
            hashStatusLine: hashLine,
            isMarkedDeleted: isMarkedDeleted,
            events: ordered,
            otherKnownCopies: copies
        )
    }

    /// "MyBook3Terabytes" — same volume-name rule as the rest of the UI.
    nonisolated private static func volumeNameForPath(_ path: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return String(parts[1]) }
        }
        if path.hasPrefix("/Users/") {
            let parts = path.split(separator: "/", maxSplits: 3)
            if parts.count >= 2 { return String(parts[1]) }
        }
        return "/"
    }

    /// Date → friendly display string. Returns "" on nil so the view
    /// can render a dash. ISO-like form keeps things sortable.
    nonisolated private static func friendlyStamp(_ d: Date?) -> String {
        guard let d else { return "" }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        fmt.timeZone = TimeZone.current
        return fmt.string(from: d)
    }

    // MARK: - Migration Overview (View 3)

    /// Build the payload for "From aging drives to safe homes." Pure —
    /// same MainActor wrapper pattern as the other builders.
    nonisolated static func buildMigrationOverview(
        allRecords: [VideoRecord],
        resolveVolumeSafety: VolumeSafetyResolver,
        now: Date = Date()
    ) -> MigrationOverview {
        // 1. Fleet snapshot — count records by current host volume's role.
        var roleCounts: [VolumeRole: Int] = [:]
        for rec in allRecords {
            let (role, _) = resolveVolumeSafety(rec.fullPath)
            roleCounts[role, default: 0] += 1
        }
        let slices = roleCounts
            .map { FleetRoleSlice(role: $0.key, recordCount: $0.value) }
            .filter { $0.recordCount > 0 }
            .sorted { $0.recordCount > $1.recordCount }

        // 2. Migration flow — bucket by (originRole, currentRole). Origin
        //    role is the role the record's `originalFullPath` resolves to,
        //    if set; otherwise it's the current role (record never moved).
        var flow: [VolumeRole: [VolumeRole: Int]] = [:]
        for rec in allRecords {
            let originPath = rec.originalFullPath ?? rec.fullPath
            let (originRole, _) = resolveVolumeSafety(originPath)
            let (currentRole, _) = resolveVolumeSafety(rec.fullPath)
            flow[originRole, default: [:]][currentRole, default: 0] += 1
        }
        let flowBars: [MigrationFlowBar] = flow
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .map { (sourceRole, dests) in
                let entries = dests
                    .sorted { $0.value > $1.value }
                    .map {
                        MigrationFlowEntry(
                            sourceRole: sourceRole,
                            destinationRole: $0.key,
                            recordCount: $0.value
                        )
                    }
                return MigrationFlowBar(
                    sourceRole: sourceRole,
                    totalRecords: entries.reduce(0) { $0 + $1.recordCount },
                    entries: entries
                )
            }
            .filter { $0.totalRecords > 0 }

        // 3. Triage funnel — Scanned → Triaged → Repaired/Combined →
        //    Archived. We derive these from `archiveStage` plus the
        //    sentinel `combinedFromPairID` so a strict mapping works.
        let scannedCount = allRecords.count
        let triagedCount = allRecords.filter {
            // "Triaged" = anything past .none. The Reviewed/Healthy/etc
            // stages all count as "user has touched this."
            switch $0.archiveStage {
            case .none: return false
            default:    return true
            }
        }.count
        let repairedCount = allRecords.filter { $0.combinedFromPairID != nil }.count
        let archivedCount = allRecords.filter { rec in
            if rec.archiveStage == .archived { return true }
            let (role, _) = resolveVolumeSafety(rec.fullPath)
            return role == .lta || role == .archive
        }.count
        let funnel: [TriageFunnelStage] = [
            TriageFunnelStage(label: "Scanned",
                              recordCount: scannedCount,
                              icon: "magnifyingglass"),
            TriageFunnelStage(label: "Triaged",
                              recordCount: triagedCount,
                              icon: "list.bullet.clipboard"),
            TriageFunnelStage(label: "Repaired / Combined",
                              recordCount: repairedCount,
                              icon: "link.circle"),
            TriageFunnelStage(label: "Archived",
                              recordCount: archivedCount,
                              icon: "archivebox.fill")
        ]

        // 4. Best stuff — Combined AND (archived OR lives on lta/archive).
        var bestStuffCount = 0
        var bestStuffBytes: Int64 = 0
        for rec in allRecords where rec.combinedFromPairID != nil {
            let isArchived = rec.archiveStage == .archived
            let (role, _) = resolveVolumeSafety(rec.fullPath)
            let onSafeHome = role == .lta || role == .archive
            if isArchived || onSafeHome {
                bestStuffCount += 1
                bestStuffBytes += rec.sizeBytes
            }
        }

        return MigrationOverview(
            generatedAt: now,
            totalRecords: allRecords.count,
            fleetSlices: slices,
            flowBars: flowBars,
            funnelStages: funnel,
            bestStuffCount: bestStuffCount,
            bestStuffBytes: bestStuffBytes
        )
    }

    // MARK: - MainActor wrappers (the views call these)

    /// MainActor wrapper around `buildVolumeProvenance`. Snapshots
    /// `records` + builds the safety resolver, then hands off to the
    /// pure builder.
    func makeVolumeProvenance(for target: CatalogScanTarget) -> VolumeProvenance {
        let name = (target.searchPath as NSString).lastPathComponent
        return Self.buildVolumeProvenance(
            sourceVolumeRootPath: target.searchPath,
            sourceVolumeName: name.isEmpty ? target.searchPath : name,
            sourceIsRetired: target.isRetired,
            sourceRetiredAt: target.retiredAt,
            sourceRetiredReason: target.retiredReason,
            allRecords: records,
            resolveVolumeSafety: makeVolumeSafetyResolver()
        )
    }

    /// MainActor wrapper around `buildFileJourney`.
    func makeFileJourney(for rec: VideoRecord) -> FileJourney {
        Self.buildFileJourney(
            for: rec,
            allRecords: records,
            resolveVolumeSafety: makeVolumeSafetyResolver()
        )
    }

    /// MainActor wrapper around `buildMigrationOverview`.
    func makeMigrationOverview() -> MigrationOverview {
        Self.buildMigrationOverview(
            allRecords: records,
            resolveVolumeSafety: makeVolumeSafetyResolver()
        )
    }
}
