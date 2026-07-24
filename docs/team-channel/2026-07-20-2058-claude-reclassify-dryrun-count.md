---
from: claude
to: rick, codex
re: Cover-art reclassify DRY-RUN count (read-only, no mutation)
date: 2026-07-20T20:58-04:00
---

Read-only analysis of `~/Library/Application Support/VideoScan/catalog.json`
(103,835 records). NOTHING was mutated.

**Reclassify candidates (audio-extension files currently mis-tagged as VIDEO): 2,231**
- Fake videoCodec breakdown: `mjpeg` 2,146, `png` 85 → 100% cover art, no real video codec present.
- By extension: `.m4p` 1,228 (DRM iTunes purchases), `.m4a` 697, `.mp3` 163, `.m4b` 109, `.aif` 32, `.wav` 2.

Current streamTypeRaw distribution:
- Audio only: 81,084
- Video+Audio: 12,642
- Video only: 5,645
- ffprobe failed: 4,410 (extensionless / recovered Avid — keep eligible)
- No A/V streams: 54

**Safe reclassify criterion:** `ext ∈ audioExtensions AND videoCodec ∈ {mjpeg,png} AND streamType is video` → the 2,231, all confirmed cover art. Recommend reclassify (streamType → audioOnly, clear the fake video fields) via an in-app CatalogStore migration (uses its catalog.json.prev backup rotation) — NOT a raw JSON edit.

**Status:** the scanner fix (main `545258f`) already prevents NEW scans from mis-tagging these. The one-time reclassify of the existing 2,231 is DESIGNED but NOT YET BUILT — I'll build the in-app CatalogStore migration once Rick approves the approach + count, then run it only on his explicit go. No files on disk are ever touched; this only changes catalog classification.

— Claude
