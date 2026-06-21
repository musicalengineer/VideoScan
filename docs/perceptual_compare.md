# Perceptual Compare — branch notes

> Parked branch: **`feature/perceptual-compare`** (local + on the worktree below).
> Captured 2026-06-20 so the context survives a Claude reboot.

## Where it lives
- **Branch:** `feature/perceptual-compare` — HEAD `ee12464` (2026-06-11), 10 commits ahead of where it branched.
- **Worktree:** checked out (locked) at
  `/Users/rickb/dev/VideoScan/.claude/worktrees/agent-a4988cb217d50eed0`
- Local-only (not on `origin`). Recovery is via the branch ref / reflog.
- ~9 days stale relative to `main` as of this note.

## What it is — "is this the same video, re-encoded?"
A **perceptual A/V comparison tier** that decides whether two media files are the
*same content* even when they are **different encodings** — e.g. a ProRes master
vs an H.264 copy, or a Topaz-upscaled version vs the original. The headline
verdict it produces is **"Same content (re-encoded)."**

This is **Tier-3** of the media-pair compare pipeline (Tiers 0–2 are the
exact/metadata/stream checks that already exist); Tier-3 only runs after those.

## How it works
- One `ffmpeg` pass per file decodes **32 frames** at evenly-spaced *interior*
  positions, skipping the first/last **5%** of duration (home-video black leader
  / bars hash identically across unrelated tapes and would poison the stats).
- Inside the trimmed span, an `fps` filter emits one frame per 1/32 of the span,
  so **both files of a pair are sampled at the same normalized positions** →
  index-aligned comparison is meaningful.
- Each frame → `scale=9:8:flags=area` + `format=gray` → a **64-bit dHash**
  (perceptual hash). Per-frame hashes are compared index-aligned to yield a
  similarity verdict that survives re-encoding.
- Output transport: ffmpeg writes raw frames to a **temp file** (not `pipe:1`,
  which `ProcessRunner` would mangle as UTF-8). Footprint is tiny — ≤ ~2.3 KB of
  frame bytes + a 256-byte fingerprint; nothing scales with media size.
- Cost (accepted for v1): the `fps` filter decodes every frame in the trimmed
  span, so a compare roughly doubles in runtime vs Tiers 0–2 (which already read
  both files end-to-end). One pass was chosen over 32 `-ss` seeks to avoid 32
  process launches + keyframe-snap misalignment between differently-encoded copies.

## What's in the branch
Core feature (unique to the branch, mostly new files):
- `VideoScan/VideoScan/PerceptualHash.swift` — pure dHash math (336 lines)
- `VideoScan/VideoScan/PerceptualFingerprinter.swift` — the ffmpeg runner (210 lines)
- `VideoScan/VideoScan/MediaPairComparator.swift` — Tier-3 verdict integration (+130 lines)
- Tests: `PerceptualHashTests.swift` (427 lines), `PerceptualFingerprinterTests.swift` (179 lines)

Bundled extras on the same branch:
- **All-Frames ripper** — `AllFramesRipper.swift`, `RipAllFramesJob.swift`,
  `RipAllFramesSheet.swift` (+ `AllFramesRipPlannerTests.swift`)
- `VolumeMigrationSheet.swift`
- `.claude/agents/refactor.md` (the refactor sub-agent definition)

### Full unique commit list (main..branch, all 2026-06-11)
```
ee12464 fix(compare): QA follow-ups — progress generation token, stderr filter, constant pinning
6d48dd3 feat(compare): Tier-3 perceptual verdict — "Same content (re-encoded)"
f9885bf feat(compare): perceptual dHash core + ffmpeg frame fingerprinter
6581613 fix(dossier): exclude retired volumes from sweep + rename buttons
ce75f2e chore(agents): add refactor agent — behavior-preserving changes, codex-findings triage
1f3ca04 chore(lint): replace force-unwrap with reduce in dup-group index build
9d24781 feat(catalog): Find Online Version + per-volume Show Migrated report
8d5922a ui(fileops): uniform verb-badge width so job-list capsules align
c21796d feat(fileops): split Extract Frames into facial (Vision) and ffmpeg-only verbs
a245d7e chore(scripts): default XcodeRAM to 8GB — 4GB fills and fakes codesign errors
```

## Why it matters
Directly serves the dedup / triage goal: confidently identifying that two copies
of the same family footage across volumes are the **same scene** despite
different codecs/bitrates — the missing piece for collapsing re-encoded
duplicates. Pairs naturally with Correlate/Combine and the cleanup pipeline.

## Merge plan (when ready)
The branch is stale and **some of its commits already landed on `main` separately**:
- `9d24781` "Find Online Version" — `OnlineCopyFinder.swift` is **byte-identical**
  on `main` already (landed via different commits). Drop it on rebase.
- The Extract-Frames-split / verb-badge / XcodeRAM-8GB commits also overlap with
  the (kept) `feature/extract-frames-split` branch.

Recommended: **rebase `feature/perceptual-compare` onto current `main`**, keeping
the perceptual-compare + All-Frames pieces and dropping the already-landed ones,
then build + run the suite. The core perceptual files are mostly new, so
conflicts should be modest. Re-assess the All-Frames ripper and
`VolumeMigrationSheet` separately — confirm they aren't already superseded on main.

## Status
Parked / not started. Substantial, well-tested work (QA-follow-ups commit present),
worth revisiting after the current migrate/triage work settles.
