# Video Classification — Media-Kind Detection (Slideshow/Presentation Pollution)

*Rick's request 2026-07-16: searches for real footage are polluted by photo
slideshows, collages, and presentations exported as `.MOV`/`.mp4`. Focus is
"original video or converted video from tape or DV stream" (1980s–early 2000s).
Detect the fakes and let searches exclude them. Idea captured from the
2026-07-16 discussion; not yet implemented.*

## Proposed feature: media-kind classifier

Classify every catalog record: `cameraVideo / tapeTransfer / slideshow /
screenRecording / unknown` — **scored, filterable, reversible**. Never
delete/skip destructively; integrates with the AnalysisScope / set-aside
machinery (2026-07-15) as a search & scope filter ("original footage only").

## Tier 1 — metadata scorecard (fields already in the catalog; zero disk I/O)

Ranked by reliability:

1. **Audio sample rate 44.1 kHz** → slideshow music bed. Cameras/tape record
   48 kHz (DV: 32/48). No audio track at all is also slideshow-ish — cameras
   always record sound.
2. **Bits-per-pixel-per-frame** = `bitrate / (width × height × fps)`. Stills
   with Ken Burns pans compress 5–10× better than real footage (tape noise is
   an entropy firehose). 1080p @ ~3 Mbps ⇒ slideshow; camera 1080p runs
   17–28 Mbps. Sharpest single scalar — the two populations barely overlap.
3. **Exact round frame rates** — `30/1`, 15, 12, 10 ⇒ export tool. Cameras
   say 29.97 (`30000/1001`), 25, 23.976, 59.94.
4. **Codec photo-jpeg or qtrle (Animation)** ⇒ iPhoto-era slideshow export,
   conclusive when present.
5. **Presentation resolutions** — 1024×768, 800×600, 1280×800: screen
   geometries no camera ever shot.
6. **Writer/handler metadata tags** (encoder = iPhoto/iMovie/Photos/Keynote/
   FotoMagico vs camera handlers) — the confession, when present. NOTE: verify
   the scanner captures these ffprobe tags; add capture if missing.

Positive class identifies itself: dvvideo/mpeg2/hdv/ffv1 codecs, 48 kHz audio,
broadcast frame rates, SD/HD camera geometries.

## Tier 2 — free refinement from existing analysis outputs

- **Scene cadence** from `sceneCaptions`: metronomic cuts every 4–6 s ⇒
  slideshow; real home video has no rhythm.
- **Whisper transcript "no speech" + audio present** ⇒ music-only bed.
- **VLM captions confess**: "a photograph of…", "a collage of…" — string
  signal minable today on every analyzed record.

## Implementation sketch

- Pure-logic scorer over existing `VideoRecord` fields (table-driven tests),
  sibling of `CatalogScopePolicy`/`AnalysisScope`.
- New additive field (e.g. `mediaKindScore`/`mediaKind`), search filter
  "Original footage only", misclassification fixable per-record by click.
- Five-dimension test bar; scale test over 100k records; sensors pinning the
  scorecard thresholds.

## Related

- `docs/media_longterm_plan.md` (dispositions), AnalysisScope / Tidy Catalog
  (2026-07-15), junk-triage goals, person belief-vector design (slideshows are
  also a person-evidence trap: faces in *photos inside videos* are not the
  person being present in footage).
