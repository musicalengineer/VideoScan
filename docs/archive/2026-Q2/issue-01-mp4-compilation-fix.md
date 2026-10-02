# Issue #1: Compiled MP4 Corruption with Mixed Codecs

## Problem

The compiled MP4 (concatenation of person-finder clips) was corrupted/unplayable when clips had different codecs, resolutions, or audio formats.

## Root Causes (Both Fixed)

### 1. Stderr pipe deadlock (fixed in 600119d)

ffmpeg writes warnings to stderr. With mixed-format inputs, it can emit thousands of lines. The default pipe buffer is 64KB — when it fills, ffmpeg blocks on write, the parent blocks waiting for ffmpeg, and the output file is truncated.

**Fix:** Drain stderr asynchronously via `readabilityHandler` instead of leaving pipes unread.

### 2. Codec mismatch in concat demuxer (fixed in PersonFinderModel.swift)

The ffmpeg concat demuxer (`-f concat`) requires all inputs to have identical stream parameters. When clips from different sources (DV, AVCHD, H.264, HEVC) are concatenated, the demuxer produces corrupt timestamps and dropped streams.

**Fix in PersonFinderModel.swift:** CompatKey-based bucketing. Each clip is probed via ffprobe to extract a CompatKey (codec, profile, pixel format, resolution, SAR, fps, colorspace, audio codec/rate/channels). Consecutive clips with identical keys are grouped into buckets and stream-copied losslessly. Different-format clips produce separate output files rather than a single corrupt one.

**Fix in swift_cli/PersonFinder.swift:** The CLI still uses a single-output re-encode approach (scale to 1280x720, H.264/AAC) which avoids the mismatch by normalizing everything, but the stderr deadlock was still present. Now fixed with async stderr draining.

## What Changed

### PersonFinderModel.swift (app) — already fixed
- `CompatKey` struct for format fingerprinting
- `pfProbeCompatKey()` to probe each clip
- `pfBucketClips()` to group consecutive compatible clips
- Per-bucket concat with `-c copy` (lossless)
- Async stderr drain via `pfStderrBox`

### swift_cli/PersonFinder.swift (CLI) — fixed in this pass
- `concatenateClips()`: Added stderr drain, `-movflags +faststart`, error reporting with last 10 stderr lines
- `concatenateWithDecadeChapters()`: Same stderr drain fix
- Added `StderrBox` helper class for thread-safe stderr capture

## Status

Both the app and CLI paths are now fixed. The app path is more sophisticated (lossless bucketing) while the CLI path re-encodes to a uniform format (simpler but lossy).
