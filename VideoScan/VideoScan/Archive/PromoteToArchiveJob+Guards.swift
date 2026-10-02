// PromoteToArchiveJob+Guards.swift
// The guards Promote runs BEFORE the journal intent (ARCH-7): the date
// refusals (filing year, GH #219 agreement), the GH #190 duplicate claim,
// and the source-digest proof (codex 2026-10-02 #1). Moved verbatim out of
// PromoteToArchiveJob+Steps.swift (file length); see that file for the
// per-file flow that calls them.

import Foundation
import os

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
