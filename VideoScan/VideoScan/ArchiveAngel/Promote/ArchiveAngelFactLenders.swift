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
//     • an archive copy ↔ its promotion source (Promote verified the bytes).
//     • a WHOLE-FILE equivalent derivation ↔ its source: balanceAudio,
//       rebuildAudio or externalRepair, with no trim range and the same
//       length (±1 s / 1 %). Same footage, repaired.
//   ANCESTRY (directed — the source lends DOWN to a derivative, never up)
//     • any other derivedFrom link: trims (a segment of the tape), and the
//       kind-less transcode / reformat / clean-up / hand-linked outputs.
//       A trim may take its tape's date; the tape never takes a trim's, and
//       two trims never date each other through the tape — P1-2.
//
//   lenders(T)    = equivalents(T) ∪ equivalents(a) for every ancestor a
//   sameBytes(T)  = the digest + archive-link equivalents only — backup
//                   attestations are claims about BYTES, so they travel
//                   only between byte-identical copies.
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

    /// The equivalence class of `seed` (seed included). `derivations` =
    /// also follow whole-file equivalent derivations (false = bytes only).
    /// `fresh` = records whose ContentFixity a stat confirmed describes the
    /// file now; a digest edge needs BOTH ends in it. nil = DISCOVERY only
    /// (every claimed digest followed — to learn which files to stat;
    /// never used to lend).
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
            if fresh?.contains(r.id) ?? true {
                for k in ArchiveAngelCopyFamily.fullDigestKeys(r) {
                    next += (index.byDigest[k] ?? []).filter { fresh?.contains($0.id) ?? true }
                }
            }
            if let copy = catalog.masterArchiveCopy(of: r) { next.append(copy) }
            if let src = catalog.promotionSource(of: r) { next.append(src) }
            if derivations {
                if let d = r.derivedFrom, let parent = index.byID[d], isWholeFileEquivalent(r, of: parent) {
                    next.append(parent)
                }
                next += (index.children[r.id] ?? []).filter { isWholeFileEquivalent($0, of: r) }
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
        var cursor = target
        var seen: Set<UUID> = [target.id]
        while let d = cursor.derivedFrom, let parent = index.byID[d], seen.insert(parent.id).inserted {
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
