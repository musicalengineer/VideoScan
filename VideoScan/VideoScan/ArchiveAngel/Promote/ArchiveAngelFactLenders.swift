// ArchiveAngelFactLenders.swift
// WHICH records may lend Rick's hand-entered facts to which (codex #1654,
// 2026-09-23). Identity for facts is not "the same family" (Show Copies'
// walk) and not a sampled signature — it is PROVEN equivalence, with
// direction:
//
//   EQUIVALENT (undirected — either may lend to the other)
//     • the same WHOLE-FILE digest (ContentFixity) on BOTH records, each
//       confirmed fresh NOW by a stat (`describesFileNow` — device, inode,
//       size, mtime, ctime; ArchiveAngelFixityCheck, off the main actor).
//       A copy rewritten since its digest was taken keeps its size but not
//       its stamp — codex #1659. `contentHash` is a SAMPLED head/middle/
//       tail signature (FileHasher.segmentedHash): two different 6 MiB
//       files can share it — codex #1654 P1-1. Never enough.
//     • an archive copy ↔ its promotion source (Promote verified the bytes
//       once) — only while BOTH ends are fresh (codex #1665) AND their
//       CURRENT whole-file digests are EQUAL (codex #1673 P1-1): a source
//       rewritten and legitimately re-hashed is fresh again, but it is not
//       the bytes that were promoted. The link alone never proves bytes.
//     • a WHOLE-FILE equivalent derivation ↔ its source: balanceAudio,
//       rebuildAudio or externalRepair, with no trim range and the same
//       length (±1 s / 1 %). Same footage, repaired. Bytes differ by
//       design, so no digest equality — but BOTH ends must be fresh
//       (codex #1673 P1-2): a repair rewritten since its fixity was taken,
//       or one with no fixity at all, lends nothing.
//   ANCESTRY (directed — the source lends DOWN to a derivative, never up)
//     • any other derivedFrom link: trims (a segment of the tape), and the
//       kind-less transcode / reformat / clean-up / hand-linked outputs.
//       A trim may take its tape's date; the tape never takes a trim's, and
//       two trims never date each other through the tape — P1-2. Each hop
//       needs BOTH ends fresh (codex #1673 P1-2); an archivePromotion hop
//       additionally needs equal current digests (it is the archive link).
//
//   lenders(T)    = equivalents(T) ∪ equivalents(a) for every ancestor a
//   sameBytes(T)  = the digest + archive-link equivalents only — backup
//                   attestations are claims about BYTES, so they travel
//                   only between byte-identical copies.
//
// ONE rule for every edge: `canCross` — both endpoints in the stat-verified
// fresh set, plus digest equality where the edge claims identical bytes. A
// non-fresh endpoint → "similar, not applied" (the Show Copies walk still
// shows it). `fresh == nil` is DISCOVERY: every edge is followed so
// ArchiveAngelFixityCheck learns which files to stat; never used to lend.
//
// Everything else in the Show Copies family is a HINT (shown in Review,
// never stamped). No full-content evidence → nothing is stamped.

import Foundation
import VideoScanCore

enum ArchiveAngelFactLenders {

    /// derivationKinds that repair a WHOLE file without cutting it.
    static let wholeFileKinds: Set<String> = ["balanceAudio", "rebuildAudio", "externalRepair"]

    /// Is `child` a whole-file equivalent of `parent` (see the header)?
    @MainActor
    static func isWholeFileEquivalent(_ child: VideoRecord, of parent: VideoRecord) -> Bool {
        guard child.derivedFrom == parent.id, let kind = child.derivationKind, wholeFileKinds.contains(kind),
              child.trimInSeconds == nil, child.trimOutSeconds == nil,
              child.durationSeconds > 0, parent.durationSeconds > 0 else { return false }
        return CopyFamilyAssessor.durationsMatch(child.durationSeconds, parent.durationSeconds)
    }

    /// Do `a` and `b` carry the same CURRENT whole-file digest? (The
    /// catalogue's ContentFixity — whether it still describes the file is
    /// the freshness half of `canCross`.)
    @MainActor
    static func sameCurrentDigest(_ a: VideoRecord, _ b: VideoRecord) -> Bool {
        let ka = ArchiveAngelCopyFamily.fullDigestKeys(a)
        return !ka.isEmpty && !Set(ka).isDisjoint(with: ArchiveAngelCopyFamily.fullDigestKeys(b))
    }

    /// May a lending edge between `a` and `b` be crossed? Both ends must be
    /// in `fresh` (stat-verified now); `byteIdentity` edges (the archive
    /// link) also need equal current digests. `fresh == nil` = discovery:
    /// always true. (≈ a single predicate every graph edge is filtered by.)
    @MainActor
    static func canCross(_ a: VideoRecord, _ b: VideoRecord, fresh: Set<UUID>?, byteIdentity: Bool) -> Bool {
        guard let fresh else { return true }
        guard fresh.contains(a.id), fresh.contains(b.id) else { return false }
        return !byteIdentity || sameCurrentDigest(a, b)
    }

    /// The equivalence class of `seed` (seed included). `derivations` =
    /// also follow whole-file equivalent derivations (false = bytes only).
    /// `fresh` = records whose ContentFixity a stat confirmed describes the
    /// file now; EVERY edge needs both ends in it. nil = DISCOVERY only
    /// (every edge followed — to learn which files to stat; never used to
    /// lend).
    @MainActor
    static func equivalents(of seed: VideoRecord, index: ArchiveAngelCopyFamily.Index,
                            catalog: any AngelCatalog, derivations: Bool,
                            fresh: Set<UUID>?) -> [UUID: VideoRecord] {
        var found: [UUID: VideoRecord] = [seed.id: seed]
        var queue = [seed]
        var hops = 0
        while let r = queue.popLast(), hops < 10_000 {
            hops += 1
            var next: [VideoRecord] = []
            // Same whole-file digest (the index key IS the digest, so
            // freshness of both ends is all that is left to check).
            for k in ArchiveAngelCopyFamily.fullDigestKeys(r) {
                next += (index.byDigest[k] ?? []).filter { canCross(r, $0, fresh: fresh, byteIdentity: false) }
            }
            // The archive link: Promote verified these bytes ONCE. It lends
            // only while both ends are fresh (codex #1665) AND their current
            // digests are equal (codex #1673 P1-1) — a rewritten-then-rehashed
            // source is fresh, but no longer the promoted bytes.
            let linked = [catalog.masterArchiveCopy(of: r), catalog.promotionSource(of: r)].compactMap { $0 }
            next += linked.filter { canCross(r, $0, fresh: fresh, byteIdentity: true) }
            // Whole-file repairs: by provenance, both ends fresh (codex #1673 P1-2).
            if derivations {
                if let d = r.derivedFrom, let parent = index.byID[d], isWholeFileEquivalent(r, of: parent),
                   canCross(r, parent, fresh: fresh, byteIdentity: false) {
                    next.append(parent)
                }
                next += (index.children[r.id] ?? []).filter {
                    isWholeFileEquivalent($0, of: r) && canCross(r, $0, fresh: fresh, byteIdentity: false)
                }
            }
            for x in next where found[x.id] == nil {
                found[x.id] = x
                queue.append(x)
            }
        }
        return found
    }

    /// Who may lend date / place to `target` (target excluded), and who may
    /// lend backup attestations (same bytes only). Both in path order.
    @MainActor
    static func lenders(for target: VideoRecord, index: ArchiveAngelCopyFamily.Index,
                        catalog: any AngelCatalog, fresh: Set<UUID>?) -> (facts: [VideoRecord], sameBytes: [VideoRecord]) {
        var facts = equivalents(of: target, index: index, catalog: catalog, derivations: true, fresh: fresh)
        // Ancestors lend DOWN (a derivative may take its source's facts).
        // Each hop needs both ends fresh (codex #1673 P1-2); an archive
        // copy's derivedFrom is its PROMOTION SOURCE — the archive link, not
        // ancestry — so that hop also needs equal current digests (#1665,
        // #1673 P1-1). A blocked hop ends the chain: everything above is
        // reachable only through it.
        var cursor = target
        var seen: Set<UUID> = [target.id]
        while let d = cursor.derivedFrom, let parent = index.byID[d], seen.insert(parent.id).inserted {
            let isArchiveLink = cursor.derivationKind == ArchivePromotion.derivationKind
            guard canCross(cursor, parent, fresh: fresh, byteIdentity: isArchiveLink) else { break }
            for (id, r) in equivalents(of: parent, index: index, catalog: catalog, derivations: true, fresh: fresh) where facts[id] == nil {
                facts[id] = r
            }
            cursor = parent
        }
        let bytes = equivalents(of: target, index: index, catalog: catalog, derivations: false, fresh: fresh)
        func ordered(_ m: [UUID: VideoRecord]) -> [VideoRecord] {
            m.values.filter { $0.id != target.id }.sorted { $0.fullPath < $1.fullPath }
        }
        return (ordered(facts), ordered(bytes))
    }
}
