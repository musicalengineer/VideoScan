# VideoScan

A personal macOS app for cataloging, searching, and recovering family media —
built to find people across decades of home videos and to keep an irreplaceable
family archive organized and safe.

VideoScan is a Swift/SwiftUI app (macOS 13+) with three parts:

- **Catalog** — scans volumes for video files, extracts metadata via ffprobe,
  correlates and combines orphaned audio/video-only MXF files, exports CSV.
- **Person Finder** — frame-by-frame face recognition (Apple Vision / ArcFace),
  clip extraction, and per-person / per-decade compilation.
- **CLI + Python tools** — standalone scanners and face-recognition utilities.

## Authorship

VideoScan was **written by Claude (Anthropic) under the design and direction of
Rick Breen.** The architecture, the audio/video domain expertise, the
priorities — above all, preserving family media without ever losing or
corrupting it — and the project's purpose are Rick's. The code authorship is
Claude's. It is, genuinely, a collaboration.

## License

Hobby project — **not for sale.** Source is under the **PolyForm Noncommercial
License 1.0.0** ([`LICENSE`](LICENSE)): free for any noncommercial use, just keep
the credit. A thanks is all that's asked.

One caveat: the face-recognition **model weights are not covered by this license**
and must not be redistributed — ship source, let users supply the model.
