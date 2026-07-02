import Foundation
import Combine

// MARK: - Dossier propagation across MD5-identical records
//
// Phase 0 (Rick 2026-06-15): the same physical file gets cataloged
// multiple times — once per volume it's been scanned on — and each
// record runs its OWN Whisper / VLM / OCR pass. Speech recognition is
// non-deterministic enough that the resulting transcripts diverge
// across copies: ~10% of duplicate-file groups in Rick's catalog had
// transcripts that differed between mirrored copies. Concretely, the
// elevator-clip CapeCod1997 file existed three times: the offline
// Seagate2TB / Maxtor750 transcripts said "elevator" verbatim, while
// the online LaCieWorkspace transcript said "elevated line of trees"
// (same audio, same MD5, different Whisper run). Searching "elevator"
// found the offline copies — useless because they're not mounted —
// and missed the connected copy.
//
// Fix: dossier results belong to FILE CONTENT, not to a particular
// catalog path. Group records by partialMD5; for each group, pick the
// "best" transcript / captions / OCR (heuristic: longest non-empty
// wins — proxy for "most words recognized" / "most scenes captured")
// and propagate to every member of the group. Going forward, every
// dossier writeback propagates to siblings too.
//
// Records with empty partialMD5 are treated as unique — propagation
// can't safely identify their siblings without content-hash evidence,
// so we leave them alone.

extension VideoScanModel {

    // MARK: - Public API

    /// Propagate the freshest / largest dossier across every catalog
    /// record sharing this record's `partialMD5`. Called after every
    /// transcript / caption / OCR writeback so duplicate copies stay
    /// in sync automatically. No-op when the record has no MD5 or no
    /// siblings.
    @MainActor
    func propagateDossierToMD5Duplicates(of record: VideoRecord) {
        guard !record.partialMD5.isEmpty else { return }
        let siblings = records.filter {
            $0.partialMD5 == record.partialMD5 && $0.id != record.id
        }
        guard !siblings.isEmpty else { return }

        let group = [record] + siblings
        propagateBestDossier(in: group)
    }

    /// One-shot backfill: scan the entire catalog, group by partialMD5,
    /// and propagate the best dossier within each multi-member group.
    /// Designed to run once on catalog load to harmonize legacy records
    /// whose dossiers diverged before per-writeback propagation existed.
    /// Returns the number of records that received a dossier update.
    @MainActor
    @discardableResult
    func backfillDossierAcrossDuplicates() -> Int {
        var byMD5: [String: [VideoRecord]] = [:]
        byMD5.reserveCapacity(records.count)
        for rec in records where !rec.partialMD5.isEmpty {
            byMD5[rec.partialMD5, default: []].append(rec)
        }

        var totalUpdated = 0
        for (_, members) in byMD5 where members.count >= 2 {
            totalUpdated += propagateBestDossier(in: members)
        }

        if totalUpdated > 0 {
            objectWillChange.send()
            saveCatalogDebounced()
            log("Dossier backfill: propagated best transcript/captions/OCR to \(totalUpdated) record(s) across duplicate-MD5 groups.")
        }
        return totalUpdated
    }

    // MARK: - Per-group propagation

    /// Pick the best dossier fields from a group of MD5-identical
    /// records and write them to every group member that's currently
    /// behind. Returns the number of records mutated.
    @MainActor
    @discardableResult
    func propagateBestDossier(in group: [VideoRecord]) -> Int {
        // Playability guard (regression fix 2026-06-30, smear introduced
        // 2026-06-15): a record that's `.ffprobeFailed` OR
        // `isLikelyUnanalyzable` is excluded as BOTH donor and recipient.
        // The direct dossier pipeline already skips these via the same
        // streamType / codec predicates; propagation must too, or a
        // junk/unreadable file that merely COLLIDES on partialMD5 with a
        // readable sibling inherits hallucinated transcript/captions it
        // never earned (and with no `dossierProcessedAt` stamp, since
        // propagation doesn't stamp). Filtering the group up front means
        // the "best" selectors only ever see readable donors, and only
        // readable records are written back.
        let eligible = group.filter { !Self.isExcludedFromPropagation($0) }
        guard eligible.count >= 2 else { return 0 }

        let bestTranscript = Self.bestAudioTranscript(in: eligible)
        let bestCaptions   = Self.bestSceneCaptions(in: eligible)
        let bestOCRText    = Self.bestOCRText(in: eligible)
        let bestOCRDates   = Self.bestOCRDateCandidates(in: eligible)

        var mutated = 0
        for rec in eligible {
            var changed = false
            if let best = bestTranscript,
               (rec.audioTranscript ?? "") != best.text {
                rec.audioTranscript = best.text
                rec.audioTranscriptModel = best.model
                rec.audioTranscriptDate = best.date
                changed = true
            }
            if let best = bestCaptions,
               rec.sceneCaptions != best.captions {
                rec.sceneCaptions = best.captions
                rec.sceneCaptionModel = best.model
                rec.sceneCaptionDate = best.date
                changed = true
            }
            if let best = bestOCRText,
               rec.ocrText != best.entries {
                rec.ocrText = best.entries
                changed = true
            }
            if let best = bestOCRDates,
               rec.ocrDateCandidates != best.entries {
                rec.ocrDateCandidates = best.entries
                changed = true
            }
            if changed { mutated += 1 }
        }
        return mutated
    }

    // MARK: - Playability / degeneracy guards (regression 2026-06-30)

    /// True when a record must be EXCLUDED from dossier propagation —
    /// both as a donor and as a recipient. Composes the two canonical
    /// readability predicates the rest of the app already uses:
    ///   • `streamType == .ffprobeFailed` — ffprobe couldn't classify it
    ///     (the exact filter the direct dossier pipeline applies).
    ///   • `isLikelyUnanalyzable` — known-bad legacy codec OR a prior VLM
    ///     run set `needsReformat`.
    /// No new domain predicate is invented here; this just ORs the two
    /// existing ones so the donor/recipient filter reads in one place.
    @MainActor static func isExcludedFromPropagation(_ rec: VideoRecord) -> Bool {
        rec.streamType == .ffprobeFailed || rec.isLikelyUnanalyzable
    }

    /// A dossier text is "degenerate" when, after trimming whitespace and
    /// newlines, it's empty OR every remaining character is identical
    /// (e.g. "!!!!", "----"). These are recognizer failure artifacts, not
    /// content — never worth propagating. `Set(trimmed).count == 1`
    /// captures the single-distinct-character case.
    static func isDegenerateDossierText(_ s: String) -> Bool {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        return Set(trimmed).count == 1
    }

    // MARK: - Provenance stamp for direct writebacks (fix 2026-07-01)

    /// Backfill the dossier provenance stamp after a direct per-channel
    /// writeback (audio transcript, scene captions). The smear-cleanup
    /// signature below treats "unreadable + has dossier content +
    /// dossierProcessedAt == nil" as corruption to blank — but a record
    /// with an unplayable legacy VIDEO codec (svq3/cinepak/... →
    /// `isLikelyUnanalyzable`) can still carry perfectly legitimate
    /// direct results: ffmpeg decodes the audio for Whisper, and the
    /// frame-rip path feeds the VLM, even when AVFoundation can't touch
    /// the video. Without the stamp such content matched the corruption
    /// signature and the one-shot cleanup destroyed it.
    ///
    /// Backfill-only: a record that already carries a FULL dossier stamp
    /// (VLM+Whisper stack, from `applyDossier`) keeps that attribution —
    /// the channel's own provenance is already carried by its
    /// model/date fields (audioTranscriptModel/Date, sceneCaptionModel/
    /// Date), so overwriting `dossierProcessedBy` with a single-channel
    /// id would erase the record of the full pass.
    /// Shared by VideoScanModel+AudioTranscript and
    /// VideoScanModel+SceneCaptions; lives here because this file owns
    /// the smear signature the stamp exists to satisfy.
    @MainActor
    func stampDossierProvenance(
        on record: VideoRecord,
        modelID: String,
        at date: Date
    ) {
        guard record.dossierProcessedAt == nil else { return }
        record.dossierProcessedAt = date
        record.dossierProcessedBy = modelID
    }

    // MARK: - One-shot cleanup of pre-fix smear corruption

    /// Pure, testable cleanup core (no gate, no file I/O): walk `records`
    /// and clear dossier content from every record matching the exact
    /// corruption signature left by the pre-2026-06-30 smear:
    ///   1. record is unreadable (`isExcludedFromPropagation`), AND
    ///   2. `dossierProcessedAt == nil` — never legitimately analyzed
    ///      (the direct pipeline ALWAYS stamps this; only propagation,
    ///      which never stamped, could populate content without it), AND
    ///   3. at least one dossier field is populated (the smeared content).
    /// Returns the cleared records (with their PRIOR content still intact
    /// on the returned snapshot copies) so the caller can quarantine them
    /// before the live records are blanked. Idempotent: a second run finds
    /// nothing because the content is gone.
    /// When `dryRun` is true, the corrupted records are identified and
    /// snapshotted (so the caller can quarantine/report them) but the live
    /// records are NOT blanked — used for the review-first pass.
    @MainActor
    @discardableResult
    func clearSmearedDossiers(dryRun: Bool = false) -> [VideoRecord] {
        var clearedSnapshots: [VideoRecord] = []
        for rec in records {
            guard Self.isExcludedFromPropagation(rec),
                  rec.dossierProcessedAt == nil else { continue }
            let hasContent = !(rec.audioTranscript ?? "").isEmpty
                || !rec.sceneCaptions.isEmpty
                || !rec.ocrText.isEmpty
                || !rec.ocrDateCandidates.isEmpty
            guard hasContent else { continue }

            clearedSnapshots.append(rec.snapshotClone())

            if dryRun { continue }

            rec.audioTranscript      = nil
            rec.audioTranscriptModel = nil
            rec.audioTranscriptDate  = nil
            rec.sceneCaptions        = []
            rec.sceneCaptionModel    = nil
            rec.sceneCaptionDate     = nil
            rec.ocrText              = []
            rec.ocrDateCandidates    = []
        }
        return clearedSnapshots
    }

    /// Gated one-shot wrapper, run once on catalog load. Quarantines the
    /// prior content to a JSON sidecar (reversible/auditable) BEFORE
    /// blanking the live records, then sets a UserDefaults flag so it
    /// never runs again. Mirrors the lifecycleStage backfill migration
    /// that runs alongside it.
    /// Review-first switch. While `true`, the one-shot cleanup runs in
    /// DRY-RUN: it writes the quarantine sidecar listing the corrupted
    /// records and logs the count, but mutates NOTHING. Flip to `false`
    /// (one-line change + rebuild) after Rick has reviewed the sidecar to
    /// perform the live clean. (Rick's call, 2026-06-30.)
    static let smearCleanupDryRun = true

    @MainActor
    @discardableResult
    func cleanupSmearedDossiersOnUnreadableRecords() -> Int {
        if Self.smearCleanupDryRun {
            // Dry-run: write the review list once, never mutate, never set
            // the live gate (so the eventual live pass still runs).
            let dryGateKey = "VideoScan.dossierSmearCleanup.v1.dryRunDone"
            if UserDefaults.standard.bool(forKey: dryGateKey) { return 0 }
            let candidates = clearSmearedDossiers(dryRun: true)
            UserDefaults.standard.set(true, forKey: dryGateKey)
            guard !candidates.isEmpty else { return 0 }
            Self.writeSmearQuarantine(candidates)
            log("Dossier smear cleanup [DRY-RUN]: identified \(candidates.count) unreadable record(s) carrying smeared dossier content (regression 2026-06-15). NOTHING mutated. Review list written under ~/Library/Logs/VideoScan/dossier_smear_quarantine_*.json. Flip smearCleanupDryRun=false to clean.")
            return candidates.count
        }

        let gateKey = "VideoScan.dossierSmearCleanup.v1.done"
        if UserDefaults.standard.bool(forKey: gateKey) { return 0 }

        let cleared = clearSmearedDossiers()
        UserDefaults.standard.set(true, forKey: gateKey)

        guard !cleared.isEmpty else { return 0 }

        Self.writeSmearQuarantine(cleared)
        objectWillChange.send()
        saveCatalogDebounced()
        log("Dossier smear cleanup: cleared hallucinated dossier content from \(cleared.count) unreadable record(s) (regression 2026-06-15). Prior content quarantined under ~/Library/Logs/VideoScan/ for audit/undo.")
        return cleared.count
    }

    /// Write the pre-clear dossier content of the corrupted records to a
    /// timestamped JSON sidecar so the destructive cleanup is reversible.
    /// Never throws to the caller — a failed write must not abort load.
    @MainActor
    private static func writeSmearQuarantine(_ records: [VideoRecord]) {
        let stampFmt = DateFormatter()
        stampFmt.dateFormat = "yyyyMMdd-HHmmss"
        stampFmt.timeZone = TimeZone(secondsFromGMT: 0)
        let url = PersistentLog.logDir
            .appendingPathComponent("dossier_smear_quarantine_\(stampFmt.string(from: Date())).json")

        if let data = try? smearQuarantinePayloadData(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Build the JSON payload for the quarantine sidecar. Extracted from
    /// `writeSmearQuarantine` so the schema is directly testable — the
    /// sidecar is the ONLY undo record for the destructive live pass, so
    /// a regression test must be able to prove the original dossier
    /// content round-trips out of it.
    ///
    /// Schema fix 2026-07-01: the original sidecar serialized full text
    /// ONLY for `audioTranscript`; captions and OCR were reduced to
    /// counts, so the live pass would have destroyed their content with
    /// no way back. Every field the cleanup blanks is now carried in
    /// full (content + model/date attribution); the counts stay as a
    /// review summary. A counts-only sidecar from the 2026-07-01 dry run
    /// exists on disk — it's superseded, not migrated, by the next run.
    @MainActor
    static func smearQuarantinePayloadData(_ records: [VideoRecord]) throws -> Data {
        struct Quarantined: Encodable {
            let id: String
            let fullPath: String
            let partialMD5: String
            // Full content of every field `clearSmearedDossiers` blanks —
            // this is the undo record.
            let audioTranscript: String?
            let audioTranscriptModel: String?
            let audioTranscriptDate: Date?
            let sceneCaptions: [SceneCaption]
            let sceneCaptionModel: String?
            let sceneCaptionDate: Date?
            let ocrText: [SceneCaption]
            let ocrDateCandidates: [SceneCaption]
            // Review-summary counts (redundant with the arrays above,
            // kept so the dry-run list stays skimmable).
            let sceneCaptionCount: Int
            let ocrTextCount: Int
            let ocrDateCount: Int
        }
        let payload = records.map {
            Quarantined(id: $0.id.uuidString,
                        fullPath: $0.fullPath,
                        partialMD5: $0.partialMD5,
                        audioTranscript: $0.audioTranscript,
                        audioTranscriptModel: $0.audioTranscriptModel,
                        audioTranscriptDate: $0.audioTranscriptDate,
                        sceneCaptions: $0.sceneCaptions,
                        sceneCaptionModel: $0.sceneCaptionModel,
                        sceneCaptionDate: $0.sceneCaptionDate,
                        ocrText: $0.ocrText,
                        ocrDateCandidates: $0.ocrDateCandidates,
                        sceneCaptionCount: $0.sceneCaptions.count,
                        ocrTextCount: $0.ocrText.count,
                        ocrDateCount: $0.ocrDateCandidates.count)
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Human-reviewable timestamps (the default numeric encoding is
        // unreadable in a review file).
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(payload)
    }

    // MARK: - Pure "best wins" selectors (testable)
    //
    // `@MainActor static`: stateless, but they read `VideoRecord` fields,
    // which is main-actor work. Callers (`propagateBestDossier`, the
    // MainActor test suite) already run on the main actor, so this is a
    // compile-time contract only — no runtime behavior change.

    struct BestTranscript: Equatable {
        let text: String
        let model: String?
        let date: Date?
    }

    struct BestCaptions: Equatable {
        let captions: [SceneCaption]
        let model: String?
        let date: Date?
    }

    struct BestOCREntries: Equatable {
        let entries: [SceneCaption]
    }

    /// Best transcript = the longest non-empty audioTranscript in the
    /// group. Carries forward the originating record's model + date so
    /// the propagated copy is honestly attributed to the run that made
    /// it. Returns nil when no member has a non-empty transcript
    /// (nothing worth propagating).
    @MainActor static func bestAudioTranscript(in group: [VideoRecord]) -> BestTranscript? {
        var best: BestTranscript?
        for rec in group {
            guard let tx = rec.audioTranscript, !tx.isEmpty else { continue }
            // Reject degenerate donor output: a transcript that collapses
            // to a single repeated character ("!!!!", "----") after
            // trimming is a Whisper failure artifact, never real speech.
            // Without this guard the smear bug propagated a literal "!!!!"
            // transcript across a whole MD5 group (Rick 2026-06-30).
            if Self.isDegenerateDossierText(tx) { continue }
            if best == nil || tx.count > (best?.text.count ?? 0) {
                best = BestTranscript(
                    text: tx,
                    model: rec.audioTranscriptModel,
                    date: rec.audioTranscriptDate
                )
            }
        }
        return best
    }

    /// Best scene captions = largest count of captions, tiebreak on
    /// total text length. More scenes captured + more text per scene =
    /// more search signal. Nil when nobody has captions.
    @MainActor static func bestSceneCaptions(in group: [VideoRecord]) -> BestCaptions? {
        var best: BestCaptions?
        var bestScore = -1
        for rec in group {
            guard !rec.sceneCaptions.isEmpty else { continue }
            let textLen = rec.sceneCaptions.reduce(0) { $0 + $1.text.count }
            // Score: count × 1000 + total text length. Caps total text
            // contribution so a 50-caption record beats a 1-caption
            // 50KB record. Real-world counts are < 100 so the 1000x
            // weight is safe.
            let score = rec.sceneCaptions.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestCaptions(
                    captions: rec.sceneCaptions,
                    model: rec.sceneCaptionModel,
                    date: rec.sceneCaptionDate
                )
            }
        }
        return best
    }

    /// Best OCR text = largest count, tiebreak on total text length.
    /// Same shape as scene captions. Nil when nobody has OCR text.
    @MainActor static func bestOCRText(in group: [VideoRecord]) -> BestOCREntries? {
        var best: BestOCREntries?
        var bestScore = -1
        for rec in group {
            guard !rec.ocrText.isEmpty else { continue }
            let textLen = rec.ocrText.reduce(0) { $0 + $1.text.count }
            let score = rec.ocrText.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestOCREntries(entries: rec.ocrText)
            }
        }
        return best
    }

    /// Best OCR date candidates = largest count, tiebreak on total
    /// text length. Same shape as OCR text. Nil when nobody has
    /// OCR date candidates.
    @MainActor static func bestOCRDateCandidates(in group: [VideoRecord]) -> BestOCREntries? {
        var best: BestOCREntries?
        var bestScore = -1
        for rec in group {
            guard !rec.ocrDateCandidates.isEmpty else { continue }
            let textLen = rec.ocrDateCandidates.reduce(0) { $0 + $1.text.count }
            let score = rec.ocrDateCandidates.count * 1000 + textLen
            if score > bestScore {
                bestScore = score
                best = BestOCREntries(entries: rec.ocrDateCandidates)
            }
        }
        return best
    }
}
