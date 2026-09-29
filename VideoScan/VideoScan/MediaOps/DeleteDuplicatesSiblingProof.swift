// DeleteDuplicatesSiblingProof.swift
// Delete Duplicates — PROVE SIBLINGS (Rick's SanDisk run, 2026-09-21:
// 2,898 working copies, 1.5 hours, ZERO deleted).
//
// What happened: every row's family had other copies — often two or
// three, on LaCieWorkspace and SanDisk itself — but the copy-count tier
// counts only copies with CURRENT evidence (a stamp-bound whole-file
// fixity whose stat, ctime included, still reproduces). The keeper gets
// one the first time it is read; a sibling never did, because nothing
// ever read a sibling. So "only 1 verified copy would remain — left
// alone" was the answer 1,702 times while the named siblings sat right
// there.
//
// The fix ADDS evidence; it does not relax a rule. When a row's count
// falls short and a named sibling lacks current evidence, the job reads
// that sibling IN FULL, once, on its own drive, exactly the way a
// keeper's fixity is produced (`SignatureVerification.wholeFileFixity`:
// stat, stream every byte, stat again, the two stamps identical). The
// digest + stamp go onto the sibling's record — the same field and the
// same store call as the keeper's — so the next row naming it, or the
// next run, only stats it. A sibling whose digest is the duplicate's
// then counts through the ORDINARY path (`DeletionTierFacts.gather`),
// rides on the row as a `CountedCopy`, and is re-stat'ed at the removal
// boundary by `DeletionTierFacts.recheck` — still the last word.
//
// Rules that stand, unchanged: ≥ 3 verified copies remaining → permanent;
// exactly 2 → the Trash; < 2 → left alone. A sibling offline is not
// counted (unavailable ≠ absent). A sibling that is the same inode as the
// keeper or as the duplicate (a hard link, two spellings of one name) is
// never read and never counted. A sibling that is itself a row of this
// run still to be decided is never read (it may go too). A mismatch is
// noted: that sibling is not a copy.
//
// Reads stop as soon as the goal is reached (3, or 2 with "Prefer the
// Trash"), and none are made when even every readable sibling could not
// lift the count to two. The job reserves the sibling drives' slots at
// dispatch (`readablePaths`); a sibling whose drive was not reserved is
// not read on this pass.
//
// Memory: one 1 MiB hash buffer per read, reads one at a time per pair
// (at most two pairs in flight) — worst case 2 MiB regardless of file
// size.
//
// (For Rick: an `enum` with no cases ≈ a C++ namespace of static
// functions; `inout` ≈ pass by non-const reference.)

import Foundation
import VideoScanCore

/// One sibling the job read in full, and what it found.
struct SiblingRead: Sendable, Equatable {
    enum Result: String, Sendable, Equatable {
        /// Same digest as the duplicate — the sibling is a verified copy.
        case matches
        /// Different bytes — not a copy of this file.
        case differs
        /// Could not be stat'ed at read time (drive gone).
        case offline
        /// Opened but could not be read to the end.
        case unreadable
        /// Its stat changed while it was being read.
        case changedDuringRead
        /// The run was stopped mid-read.
        case cancelled

        /// "matches" / "differs" / … — the log's word.
        var word: String {
            switch self {
            case .matches: return "matches"
            case .differs: return "differs"
            case .offline: return "offline — not counted"
            case .unreadable: return "could not be read — not counted"
            case .changedDuringRead: return "changed while it was read — not counted"
            case .cancelled: return "stopped mid-read — not counted"
            }
        }
    }

    let recordID: UUID?
    let path: String
    /// "sibling b.mov on LaCieWorkspace".
    let label: String
    /// Bytes read (the file's size at the read); 0 when nothing was read.
    let bytes: Int64
    let result: Result
    /// The fresh stamp-bound fixity (matches / differs) — stored on the
    /// sibling's record whatever it says.
    let fixity: ContentFixity?
}

enum SiblingProver {

    /// What the job lets the disk worker read for one row, decided on the
    /// main actor at dispatch.
    struct Allowance: Sendable, Equatable {
        /// Stop reading once this many verified copies would remain:
        /// 3 (permanent), or 2 with "Prefer the Trash for every duplicate".
        var goal: Int
        /// Only these sibling paths may be read — the drives whose slots
        /// the pair reserved (the SSD/HDD gate).
        var readablePaths: Set<String>

        static let none = Allowance(goal: 0, readablePaths: [])

        static func goal(preferTrash: Bool) -> Int {
            preferTrash ? DeletionTierDecision.minimumForTrash : DeletionTierDecision.minimumForPermanent
        }
    }

    /// A sibling a read could prove: its index in `otherCopies` and the
    /// stamp it has now.
    struct Readable: Sendable, Equatable {
        let index: Int
        let stamp: FileIdentityStamp
    }

    /// Stat only. Which of `otherCopies` a read could turn into evidence:
    /// allowed by `allowance`, online, WITHOUT current evidence (no
    /// usable fixity, or one whose stamp no longer reproduces), and not
    /// the same inode as the keeper, the duplicate or another readable
    /// sibling. `offline` lists every sibling that could not be stat'ed
    /// (for the row's words — an offline copy is unavailable, not
    /// absent, and never counted). Off the main actor.
    nonisolated static func readableSiblings(_ candidates: DeletionTierCandidates, allowance: Allowance)
        -> (readable: [Readable], offline: [Int]) {
        func key(_ s: FileIdentityStamp) -> String { "\(s.device):\(s.inode)" }
        var excluded: Set<String> = []
        if !candidates.keeperPath.isEmpty, let k = FileIdentityStamp.capture(path: candidates.keeperPath) {
            excluded.insert(key(k))
        }
        if let d = candidates.duplicateIdentity { excluded.insert(key(d)) }
        var readable: [Readable] = []
        var offline: [Int] = []
        for (i, copy) in candidates.otherCopies.enumerated() {
            guard let now = FileIdentityStamp.capture(path: copy.path) else { offline.append(i); continue }
            guard allowance.readablePaths.contains(copy.path) else { continue }
            if let f = copy.fixity, f.isUsableForVerification, f.describesFileNow(now) { continue }   // evidence is current
            guard !excluded.contains(key(now)) else { continue }                                     // hard link
            excluded.insert(key(now))
            readable.append(Readable(index: i, stamp: now))
        }
        return (readable, offline)
    }

    /// Read siblings until the goal is reached. Each read sibling's fresh
    /// fixity replaces the candidate's (`otherCopies[i].fixity`), so the
    /// caller's next `gather` counts a matching one through the ordinary
    /// stamp-bound path — and names a mismatching one "holds different
    /// bytes". Offline siblings get the note "offline — not counted".
    /// Returns every read made, in order. Off the main actor.
    nonisolated static func prove(_ candidates: inout DeletionTierCandidates, digest: String,
                                  allowance: Allowance, hooks: SignatureVerification.Hooks) -> [SiblingRead] {
        let wanted = digest.lowercased()
        let start = DeletionTierFacts.gather(candidates, digest: wanted).remainingVerifiedCopies
        guard start < allowance.goal else { return [] }
        let (readable, offline) = readableSiblings(candidates, allowance: allowance)
        for i in offline { candidates.otherCopies[i].unverifiedNote = "offline — not counted" }
        // Reading cannot help when even every readable sibling would not
        // lift the count to two: spend no reads.
        guard start + readable.count >= DeletionTierDecision.minimumForTrash else { return [] }
        var reads: [SiblingRead] = []
        var matched = 0
        for candidate in readable where start + matched < allowance.goal {
            let copy = candidates.otherCopies[candidate.index]
            let outcome = SignatureVerification.wholeFileFixity(path: copy.path, label: "sibling", hooks: hooks)
            switch outcome {
            case .fixity(let fixity):
                candidates.otherCopies[candidate.index].fixity = fixity
                let same = fixity.digest == wanted
                if same { matched += 1 }
                reads.append(SiblingRead(recordID: copy.recordID, path: copy.path, label: copy.label,
                                         bytes: fixity.byteCount, result: same ? .matches : .differs, fixity: fixity))
            case .unavailable:
                candidates.otherCopies[candidate.index].unverifiedNote = "offline — not counted"
                reads.append(SiblingRead(recordID: copy.recordID, path: copy.path, label: copy.label,
                                         bytes: 0, result: .offline, fixity: nil))
            case .unreadable:
                candidates.otherCopies[candidate.index].unverifiedNote = "could not be read — not counted"
                reads.append(SiblingRead(recordID: copy.recordID, path: copy.path, label: copy.label,
                                         bytes: candidate.stamp.size, result: .unreadable, fixity: nil))
            case .changedDuringRead:
                candidates.otherCopies[candidate.index].unverifiedNote = "changed while it was read — not counted"
                reads.append(SiblingRead(recordID: copy.recordID, path: copy.path, label: copy.label,
                                         bytes: candidate.stamp.size, result: .changedDuringRead, fixity: nil))
            case .cancelled:
                reads.append(SiblingRead(recordID: copy.recordID, path: copy.path, label: copy.label,
                                         bytes: 0, result: .cancelled, fixity: nil))
            }
            if outcome == .cancelled { break }
        }
        return reads
    }
}
