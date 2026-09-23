// ArchiveAngelFixityCheck.swift
// Is a record's stored whole-file digest still true of the file ON DISK
// NOW? (codex #1659, 2026-09-23.) A ContentFixity is bound to the stat
// stamp of the file it was read from; `describesFileNow` — device, inode,
// size, mtime AND kernel ctime — is the verification-grade check the rest
// of the app uses to let a stored digest stand in for a read. The Archive
// Angel lends Rick's hand-entered facts across a digest match only when
// BOTH the donor's and the target's fixity pass it: a donor rewritten at
// the same size keeps its size but not its stamp.
//
// Stat only — never a read of the file's contents (the fixity design:
// stat-level identity, the digest stands in for the read). Runs OFF the
// main actor (`@concurrent`): a sleeping or network volume can take
// seconds to answer a stat. An offline or unstat-able file is simply not
// fresh — its copies become "similar, not applied".
//
// Called at plan build (ArchiveAngelJob) and just before Promote stamps
// (ArchiveAngelPromoter.verifiedFixity → promote(freshFixity:)).

import Foundation
import VideoScanCore

enum ArchiveAngelFixityCheck {

    /// What one stat needs — a value, so it can cross to the off-main hop.
    struct Probe: Sendable {
        let id: UUID
        let path: String
        let fixity: ContentFixity
    }

    /// The records worth a stat: a usable ContentFixity whose digest the
    /// catalogue could match (ArchiveAngelCopyFamily.fullDigestKeys).
    @MainActor
    static func probes(for records: [VideoRecord]) -> [Probe] {
        var seen = Set<UUID>()
        return records.compactMap { r in
            guard seen.insert(r.id).inserted, !ArchiveAngelCopyFamily.fullDigestKeys(r).isEmpty,
                  let f = r.contentFixity else { return nil }
            return Probe(id: r.id, path: r.fullPath, fixity: f)
        }
    }

    /// Every record a digest could join to `targets` (DISCOVERY walk — no
    /// freshness yet), the targets included: the set to stat.
    @MainActor
    static func candidates(for targets: [VideoRecord], index: ArchiveAngelCopyFamily.Index,
                           catalog: any AngelCatalog) -> [VideoRecord] {
        var out: [UUID: VideoRecord] = [:]
        for t in targets {
            out[t.id] = t
            for r in ArchiveAngelFactLenders.lenders(for: t, index: index, catalog: catalog, fresh: nil).facts {
                out[r.id] = r
            }
        }
        return out.values.sorted { $0.fullPath < $1.fullPath }
    }

    /// The ids whose stored fixity describes the file now. Stat only.
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func fresh(_ probes: [Probe]) async -> Set<UUID> {
        var ok = Set<UUID>()
        for p in probes where p.fixity.describesFileNow(FileIdentityStamp.capture(path: p.path)) {
            ok.insert(p.id)
        }
        return ok
    }

    /// Candidates → probes → stat off-main. The main-actor parts are O(the
    /// families of `targets`) plus the index already built by the caller.
    @MainActor
    static func verify(targets: [VideoRecord], index: ArchiveAngelCopyFamily.Index,
                       catalog: any AngelCatalog) async -> Set<UUID> {
        let list = Self.probes(for: Self.candidates(for: targets, index: index, catalog: catalog))
        guard !list.isEmpty else { return [] }
        return await Self.fresh(list)
    }
}
