---
from: claude
to: rick, codex
re: Search beachball — full diagnosis + ranked fix (profiled at real 103k scale)
date: 2026-07-21T15:20-04:00
---

Two analyses (perf-agent benchmark on a real-catalog copy + a catalog-composition
pass) fully explain the prefix-search beachball. Read-only; no production changes.

## Why it beachballs (three compounding causes)
1. **The corpus is 76% music-production junk.** Of 101,604 records (post-purge),
   81,084 are audio-only — and **77,293 are unrelated to any video** (no co-located
   video / no matching stem / no shared UMID). Overwhelmingly Logic Pro sample
   libraries + Apple Loops (~63k), Omnisphere/Pro Tools samples, old sessions.
   Only 3,791 audio-only records are repair-related to videos.
2. **Every keystroke is a full O(N) linear `memmem` scan of ~94k haystacks
   (63.7 MB) on the MAIN THREAD.** #123's inverted index is INERT for real queries:
   prefixes aren't complete words, and complete words ("donna") fail the infix gate
   (infix of "madonna"). Measured: `donna` costs the same ~60 ms as `don`/`christmas`
   — proof the fast path never fires. + up to 176 ms reachability = ~240 ms
   main-thread block per settled keystroke.
3. **Short prefixes dump the result set into SwiftUI Table on the main thread:**
   `d`→92,916 rows, `the`→14,660. That's the visible freeze on short/prefix typing.

(The historical multi-SECOND freeze was index poisoning → 2.3 s/keystroke inline
rebuild; #123's defenses hold today at an 80 MB healthy index. Keep a sensor.)

## The fix (layered; measured)
- **#1 Shrink the searched set — biggest win, mostly already built.** Default to
  video-bearing + reachable-FIRST: 94k→~18-24k. Measured filter 60ms→24ms (2.5x)
  and `d` rows 92,916→17,203 (5.4x fewer to Table). The junk lives in identifiable
  trees, so exclude them wholesale (scan-skip `Logic Pro Library.bundle`,
  `Apple Loops`, `*/Samples`, Omnisphere, `Old PT sessions`) + purge existing.
  Corpus 101,604 → ~24,311.
- **#2 Run filter + reachability OFF the main thread** (query-generation staleness
  guard). Kills the input-thread block regardless of corpus.
- **#3 Replace the dead inverted index with a real token-PREFIX trie** — short
  prefixes go O(matches) instead of O(94k). The durable algorithmic fix.
- **#4 Cap rows to Table for broad prefixes** (or 2-char minimum) — low effort,
  high perceived-latency win.
- #5 drop transcripts from the fast-path haystack (opt-in transcript search);
  #6 poison-regression sensor.

## Decisions needed from Rick (before any implementation)
1. When it beachballs, which media-kind facet is selected — **All Kinds or Videos**?
   (Determines whether #1 already helps or must become the search default.)
2. **Token-prefix semantics OK** (type-ahead style; enables the fast trie), or must
   pure-substring be preserved (needs a heavier n-gram index)?
3. OK to run search **off the main thread** and **cap displayed rows** for 1-2 char
   prefixes?
4. Sign-off on the **junk-tree exclusion + purge** (which trees; bigger cut than the
   cover-art purge — ~77k records, media files untouched).

Recommendation: #1 (video+reachable-first, backed by the junk-tree exclusion) is the
single highest-leverage move and aligns with the video-centric north star; pair with
#4 immediately for the short-prefix freeze; #2 and #3 are the durable follow-ups.
Nothing implemented pending Rick's calls above.

— Claude
