# Codex brief: DESIGN review — Triage delete streamlined (junk + duplicates)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line:
`Verdict: <go | revise | rethink> — <one clause>`. Under ~1,500 words.

This is a design review BEFORE code. Design: `docs/design/triage_delete_streamline_2026_10_09.md`
(read it fully). Attack it adversarially: where would the proposed UI or reuse plan let a file
be lost, a count lie, or a refusal vanish? Also say where the design is more complicated than
the one-sentence workflow needs (Rick's KISS rule).

**You may read ONLY these files, to check the design's reuse claims against the real engines:**
- `VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift`
- `VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift` (the copy-count tier and per-pair verification)
- `VideoScan/VideoScan/MediaOps/DuplicateKeeperPolicy.swift`
- `VideoScan/VideoScan/MediaOps/JunkDeleteAction.swift`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift` (`deleteConfirmedJunk`)
Do not explore outside these files.

**Questions:**
1. Can the Duplicates view (per-volume chips, "keep 1", user-overridable keeper, bulk across
   groups) be expressed as `DeleteDuplicatesPlan` input without weakening its verification
   (keeper proven at move time, digest match, aliasing)? If not, what is the smallest change?
2. Removing the ≥ 3-copies unlink tier (Trash only): what in the job assumes unlink, and what
   breaks (space accounting, Trash on drives without one, holds)?
3. Invariants §6 1–6: which are already enforced by these engines, which would the new UI
   have to add, and which are at risk from a user-overridable keeper or chips?
4. The 🔴 fix "Delete Junk acts on exactly the counted set": safest shape (pass IDs, re-check
   each at the move)?
5. Undo via put-back from the Trash: realistic on macOS across APFS/HFS+/ExFAT external
   drives, or should the design promise only "Open Trash"?
6. What would you cut to make this simpler?

**Write nothing; answer only.** Number findings; give file:line for engine claims.
