// PromoteToArchiveJob+Guards.swift
// The guards Promote runs BEFORE the journal intent (ARCH-7): the date
// refusals (filing year, GH #219 agreement), the GH #190 duplicate claim,
// and the source-digest proof (codex 2026-10-02 #1). Moved verbatim out of
// PromoteToArchiveJob+Steps.swift (file length); see that file for the
// per-file flow that calls them.

import Foundation
import os
import VideoScanCore

extension PromoteToArchiveJob {

    // MARK: GH #190 / #219 guards

    /// The two date refusals that run before a byte moves, each logged:
    /// - the filing-year guard (Rick 2026-09-27): no video under a year
    ///   before 1900 or after next year (the same function guards Refile);
    /// - GH #219: when Promote will not write the chosen date on the
    ///   archived record (a decade, or a machine proposal), registration
    ///   keeps the SOURCE's own userDate — refused if that disagrees with
    ///   the placement (ARCH-6, ARCH-7).
    func dateRefusal(source: VideoRecord, entry: ArchivePromotePlan.Entry,
                     facts: ArchivePathResolver.RecordFacts, model: VideoScanModel) -> Refusal? {
        if let refusal = ArchivePathResolver.filingYearRefusal(facts: facts) {
            return Refusal(code: .filingYear, kind: .failed, detail: refusal,
                           logFacts: "the filing year is outside the allowed range; nothing written")
        }
        if let refusal = recordDateRefusal(source: source, placement: facts.dateHint) {
            return Refusal(code: .dateAgreement, kind: .failed, detail: refusal,
                           logFacts: "the date it would be filed under disagrees with the file's own date; nothing written")
        }
        return nil
    }

    /// What the duplicate check decided for one source.
    enum DigestClaim {
        /// Not in the archive; this digest is now claimed for `provisional`.
        /// `proven` = the digest was READ from the source in this run; false =
        /// it came from a stored fixity and must be proven before any write.
        case claimed(String, proven: Bool)
        /// The archive (or a file landing right now) already holds these bytes.
        case alreadyArchived(Refusal)
        case cancelled

        /// The per-file result when nothing was claimed.
        var notClaimedResult: FileResult {
            switch self {
            case .alreadyArchived(let refusal): return .refused(refusal)
            case .cancelled, .claimed: return .cancelled
            }
        }
    }

    /// GH #190: the source's whole-file digest (a stamp-bound fixity that
    /// still describes the file, else one full read — logged before it
    /// starts, it can take minutes), then look up and claim it in ONE
    /// main-actor turn, so a second identical file (this batch, or another
    /// Promote job) cannot pass between. The caller releases the claim if
    /// nothing gets published.
    func claimSourceDigest(source: VideoRecord, entry: ArchivePromotePlan.Entry, provisional: String,
                           model: VideoScanModel, ctx: RunContext) async throws -> DigestClaim {
        let digest: String
        let proven: Bool
        if let trusted = await Self.trustedSourceDigestOffMain(path: source.fullPath, fixity: source.contentFixity) {
            digest = trusted
            proven = false
        } else {
            proven = true
            // Persistent lines name the operation, not the file (codex
            // 2026-10-02 #7); the window's subtitle names it.
            model.log("Promote: \(currentOpLabel) — checking the source (\(Self.promoteByteText(max(1, source.sizeBytes)))) against the archive before copying…")
            promoteLog.notice("promote CHECK \(self.currentOpLabel, privacy: .public) (\(source.sizeBytes, privacy: .public) bytes) — hashing the source for the duplicate check")
            let reporter = PromoteProgressReporter()
            let fileBytes = max(1, source.sizeBytes)
            let filename = source.filename
            let checkProgress: @Sendable (Int64) -> Void = { [weak self] done in
                guard let tick = reporter.tick(phase: .verifying, done: done, fileBytes: fileBytes) else { return }
                let sub = "Checking \(filename) against the archive · \(tick.doneText) of \(tick.totalText) · \(tick.rateText)\(tick.etaText)"
                Task { @MainActor [weak self] in self?.applyPhaseSubtitle(sub) }
            }
            guard let read = try await Self.hashSourceOffMain(path: source.fullPath, progress: checkProgress) else {
                return .cancelled
            }
            digest = read
        }
        if Task.isCancelled { return .cancelled }
        if let held = archiveDigests.relPath(forDigest: digest)
            ?? model.claimPromoteDigest(digest, relPath: provisional, root: ctx.root) {
            return .alreadyArchived(Refusal(
                code: .duplicate, kind: .skipped,
                detail: Self.duplicateRefusal(existingRelPath: held, digest: digest),
                logFacts: "identical bytes (sha256 \(digest.prefix(12))…) are already in the archive; nothing copied"))
        }
        return .claimed(digest, proven: proven)
    }

    // MARK: The guards on the proven bytes

    enum ProvenBytesStep {
        case passed(SoundGateResult)
        case refused(Refusal)
        case cancelled
    }

    /// The two guards that judge the source's CURRENT bytes, in order, both
    /// before the journal intent: (1) the digest proof — a stored fingerprint
    /// is read back and refused on any difference (codex 2026-10-02 #1);
    /// (2) the sound gate, on exactly the bytes just proven. `proven` false =
    /// the digest came from a stored fingerprint and is read back first.
    ///
    /// `stampBeforeDigest`: the source's stat stamp taken BEFORE its digest
    /// was read or trusted. The sound gate requires the file to still carry
    /// it (Codex #280 F2): a file replaced after the proof is no longer the
    /// proven one, however stable it then is while it is measured.
    func provenBytesGuards(source: VideoRecord, entry: ArchivePromotePlan.Entry, digest: String,
                           proven: Bool, stampBeforeDigest: FileIdentityStamp?,
                           model: VideoScanModel) async throws -> ProvenBytesStep {
        if !proven {
            guard let actual = try await proveSourceDigest(source: source, entry: entry) else { return .cancelled }
            if actual != digest {
                return .refused(Refusal(
                    code: .storedDigestMismatch, kind: .failed,
                    detail: Self.storedDigestMismatch(recorded: digest, actual: actual),
                    logFacts: "stored sha256 \(digest.prefix(12))… ≠ current sha256 \(actual.prefix(12))…; nothing written"))
            }
        }
        testHookBeforeSoundCheck?(source)
        if Task.isCancelled { return .cancelled }
        let sound = try await soundGate(source: source, entry: entry, digest: digest,
                                        stampBeforeDigest: stampBeforeDigest, model: model)
        if let refusal = sound.refusal { return .refused(refusal) }
        // After BOTH guards, still before the destination and the journal
        // intent: a change made here is the copy engine's to catch.
        testHookAfterSourceProof?(source)
        return Task.isCancelled ? .cancelled : .passed(sound)
    }

    // MARK: Sound gate (Rick 2026-11-10)

    /// What the sound gate decided for one file: a refusal, or go on with a
    /// note (one-sided, or accepted by the owner's tag) that rides the
    /// outcome row and the landed line.
    struct SoundGateResult {
        var note: String?
        var refusal: Refusal?

        static func pass(note: String?) -> SoundGateResult { SoundGateResult(note: note, refusal: nil) }
        static func refused(_ refusal: Refusal) -> SoundGateResult { SoundGateResult(note: nil, refusal: refusal) }

        /// " · sound on the left side only", or "".
        var landedSuffix: String { note.map { " · \($0)" } ?? "" }
    }

    /// THE one call of PromoteSoundGate (the rule and its words live there).
    /// Runs after the source's digest is proven and before the destination
    /// is chosen, so a refusal has written nothing to the archive.
    ///
    /// The sound is MEASURED here, every time — `soundMeasure` (ffprobe + the
    /// levels pass), run directly, not as a nested MFO job: this job already
    /// holds the source volume's gate. Nothing stored about the file's sound
    /// is read, and nothing is stored (Codex #280 / #281: a stored verdict
    /// has no digest and no completeness mark). The record is the SOUND
    /// OUTCOME line. The file must still carry the stamp it had before its
    /// digest was read, and the same stamp after the measurement, or the
    /// answer is "could not check".
    ///
    /// Memory: the diagnosis is a few small structs; the probe streams and
    /// keeps at most ~1 MB of ffprobe output. Nothing is retained per file
    /// but a one-line note.
    func soundGate(source: VideoRecord, entry: ArchivePromotePlan.Entry, digest: String,
                   stampBeforeDigest: FileIdentityStamp?, model: VideoScanModel) async throws -> SoundGateResult {
        let op = currentOpLabel
        func say(_ line: String) {
            model.log("Promote: \(line)")
            appLog.write("promote \(line)")
            promoteLog.notice("promote \(line, privacy: .public)")
        }
        let path = source.fullPath
        let before = await Self.stampOffMain(path: path)
        let finding: PromoteSoundGate.Finding
        if before == nil {
            finding = .unchecked("the file is not reachable")
        } else if before != stampBeforeDigest {
            // Not the file whose digest was proven (Codex #280 F2): it is
            // not measured.
            finding = .unchecked("the file changed after its bytes were proven")
        } else {
            say("SOUND START \(op): measuring (\(source.sizeBytes) bytes)")
            applyPhaseSubtitle("Checking the sound of \(source.filename)…")
            finding = try await measureSound(path: path, before: before)
        }

        // The owner's word is read NOW, from the catalog's CURRENT record for
        // this id (Codex #280 F4): a rescan may have replaced the object
        // while the sound was measured, and the tag may have been taken back.
        let current = model.record(forID: source.id) ?? source
        let facts = current.soundPresenceContext
        let mark = PromoteSoundGate.mark(tags: current.tags, storedFixity: current.contentFixity,
                                         provenDigest: digest, recordSizeBytes: current.sizeBytes,
                                         provenSizeBytes: before?.size ?? 0)
        let decision = PromoteSoundGate.decide(finding: finding, mark: mark,
                                               soundPartnerName: facts.soundPartnerName,
                                               recordedYear: facts.recordedYear,
                                               digestPrefix: String(digest.prefix(12)))
        switch decision {
        case .promote(let rowNote, let logFacts):
            say("SOUND OUTCOME \(op): \(logFacts)")
            soundNotes[source.id] = rowNote
            return .pass(note: rowNote)
        case .refuse(let code, let detail, let logFacts):
            // `noteRefusal` writes the one persistent REFUSED line.
            let refusalCode = Refusal.Code(rawValue: code.rawValue) ?? .soundUnchecked
            return .refused(Refusal(code: refusalCode, kind: .failed, detail: detail, logFacts: logFacts))
        }
    }

    /// Measure now. A thrown probe error, a levels pass that did not cover
    /// every channel, or a file whose stamp moved during the read is
    /// "could not check" — never a pass. Nothing is written anywhere.
    private func measureSound(path: String, before: FileIdentityStamp?) async throws -> PromoteSoundGate.Finding {
        let diagnosis: AudioVerifyDiagnosis
        do {
            diagnosis = try await soundMeasure.diagnose(path)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled || state == .cancelling { throw CancellationError() }
            return .unchecked(PromoteSoundGate.uncheckedReason(error))
        }
        if Task.isCancelled || state == .cancelling { throw CancellationError() }
        let after = await Self.stampOffMain(path: path)
        guard let before, let after, before == after else {
            return .unchecked("the file changed while its sound was being checked")
        }
        return PromoteSoundGate.finding(from: diagnosis)
    }

    /// One stat of the source, off the UI thread (a sleeping drive can make
    /// a stat take seconds).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func stampOffMain(path: String) async -> FileIdentityStamp? {
        FileIdentityStamp.capture(path: path)
    }

    /// Codex 2026-10-02 #1: one full read of the source, BEFORE the journal
    /// intent, when its digest came from a stored fixity. nil = cancelled.
    /// Logged before it starts (it can take minutes on a long tape).
    func proveSourceDigest(source: VideoRecord, entry: ArchivePromotePlan.Entry) async throws -> String? {
        model?.log("Promote: \(currentOpLabel) — proving the source's current bytes (\(Self.promoteByteText(max(1, source.sizeBytes)))) before anything is written; a stored fingerprint is not evidence…")
        let reporter = PromoteProgressReporter()
        let fileBytes = max(1, source.sizeBytes)
        let filename = source.filename
        let proofProgress: @Sendable (Int64) -> Void = { [weak self] done in
            guard let tick = reporter.tick(phase: .verifying, done: done, fileBytes: fileBytes) else { return }
            let sub = "Reading \(filename) before copying · \(tick.doneText) of \(tick.totalText) · \(tick.rateText)\(tick.etaText)"
            Task { @MainActor [weak self] in self?.applyPhaseSubtitle(sub) }
        }
        return try await Self.hashSourceOffMain(path: source.fullPath, progress: proofProgress)
    }

    /// The refusal when a stored fixity does not describe the bytes it is
    /// stamped to (codex 2026-10-02 #1). Pure. Digest prefixes only.
    nonisolated static func storedDigestMismatch(recorded: String, actual: String) -> String {
        "the source changed since it was fingerprinted — its stored fingerprint (sha256 \(recorded.prefix(12))…) does not match its bytes now (sha256 \(actual.prefix(12))…) although the file's stamp is unchanged (a wrong fingerprint, or silent corruption). Nothing was written. Check the source file and re-fingerprint it before promoting"
    }

    /// GH #219: the date-agreement refusal for this source at `placement`,
    /// or nil. Promote writes the chosen date on the archived record only
    /// when it is Rick's (typed / Review / a copy's) AND has a user-date
    /// form; otherwise the record keeps the source's own `userDate`, which
    /// must then agree with the placement.
    func recordDateRefusal(source: VideoRecord, placement: ArchiveDateHint) -> String? {
        let override = plan.archiveDateOverrides[source.id]
        let whose = plan.archiveDateSources[source.id]
        let writes = override != nil && whose != nil && ArchiveRefile.userDate(for: placement) != nil
        return ArchiveDateAgreement.promoteRefusal(placement: placement,
                                                   writesChosenDate: writes,
                                                   sourceUserDate: source.userDate,
                                                   sourceKnown: source.userDateStatus == .known,
                                                   isMachineProposal: override != nil && whose == nil)
    }

    /// GH #190: the per-file refusal line naming the archived file. Pure.
    nonisolated static func duplicateRefusal(existingRelPath: String, digest: String) -> String {
        "already in the Master Archive as \(existingRelPath) — identical bytes (sha256 \(digest.prefix(12))…), so no second copy was made. To change that file's name or date, use Update… on it"
    }

    /// The source's digest WITHOUT reading it, when its stored fixity is
    /// stamp-bound and still describes the file (the persistent digest
    /// policy, `ContentFixity.describesFileNow`). nil = read it. The
    /// engine's `expectedSourceSHA` re-proves it against the bytes copied.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func trustedSourceDigestOffMain(path: String, fixity: ContentFixity?) async -> String? {
        guard let fixity, fixity.describesFileNow(FileIdentityStamp.capture(path: path)),
              ArchiveDigestIndex.isSHA256(fixity.digest) else { return nil }
        return fixity.digest.lowercased()
    }

    /// One full read of the source (symlink chain followed, regular file
    /// only — the same open the copy uses), with progress. nil = cancelled.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func hashSourceOffMain(path: String,
                                              progress: @escaping @Sendable (Int64) -> Void) async throws -> String? {
        let h = try ArchivePromoteEngine.openSource(path: path)
        defer { h.close() }
        return try ArchivePromoteEngine.sha256(fd: h.fd, shouldCancel: { Task.isCancelled }, progress: progress)
    }
}
