# Find Original / Find Related — design (DRAFT for Rick, 2026-09-22)

*Read-only study of the codebase. Numbers marked "verified" were read from the live catalog/files on 2026-09-22; "estimate" means to be measured.*

## 0. The problem, on the guitar case

Right-click `RickGuitarGravity_etc_2024.mov` (LaCieWorkspace, fcpbundle `Transcoded Media`) → you want: where did this come from, what else came from the same source, and when was it really shot.

What the catalog **already knows** (verified):

| Record | Evidence we already hold |
|---|---|
| `RicksGuitars2024.mov` on /Volumes/Projects | **Same `contentHash`** (`v1:d4f1d9de…`) as the LaCie file — byte-identical, different name |
| `RicksGuitars2024.mp4` on CrucialX9 + Cheesegrater archive | duration 951.784 s vs 951.751 s → **1 frame apart at 29.97**; stem = the Projects twin's name; H.264, no make/model, embedded 2025-02-02. The CrucialX9 copy has **no contentHash yet** |
| LaCie ProRes | `com.apple.proapps.mediaIdentifier=E2D2E261…`, `encoder=Apple ProRes 422`; GuitarJams event has **no `Original Media`** (FCP imported the source by reference) |

Chain: *2024 camera clips (not found)* → `RicksGuitars2024.mp4` (edit export, 2025-02-02) → FCP ProRes transcode (2026-03-11), existing as 2 byte-identical copies with 2 names. Metadata alone (Phase 1) reaches the mp4; finding the camera clips *inside* a 15-min compilation needs content fingerprints (Phase 2/3).

**On "train itself overnight":** nothing can be learned until every file has a fingerprint, so the overnight compute is **indexing** first. Learning is small and comes later: your Confirm / Not related clicks re-weight how much each evidence tier counts. No neural training.

**Scale (verified):** 13,881 records; 7,356 active video > 5 s; 652 h / 9.6 TB across 8 volumes. 5,389 have no embedded creation date; 3,311 have no date of any kind. 810 groups share a duration within 0.1 s, 604 of them with *different* bytes — raw material for Find Related (and coincidences).

## 1. Evidence tiers (strongest first)

| Tier | Catches | Cost / file | Failure modes |
|---|---|---|---|
| **T0 Known lineage** | `contentHash` / `partialMD5+size` identity (same keys `OnlineCopyFinder` uses); `derivedFrom`+`derivationKind` (trim, balanceAudio, cleanup); `combinedFromPairID`, `pairGroupID`, `materialPackageUMID`; FCP structure `<event>/Transcoded Media/High Quality Media/X.mov` ↔ `<event>/Original Media/X.*` (verified on `12-27-23/MA5A3201.mov`: same stem, same duration to the µs, transcode stamped 36 s after original); `com.apple.proapps.mediaIdentifier` equality links **transcodes to each other** across copied libraries (the original doesn't carry it) | 0 — one new ffprobe tag captured by the existing embedded-date refresh | FCP "leave in place" imports (the guitar case) have no Original Media, so T0 stops at the transcode. `duplicateGroupID` is heuristic and **must not** count as identity (the 2026-09-12 date-propagation lesson) |
| **T1 Duration + name** | Exports, transcodes, renamed copies. Duration within ±2 frames at the record's own frame rate (fallback 0.1 s); stem normalized with the existing `ArchiveAngelNaming.derivativeBaseStem` (`.vs.*`, `_trimmed`, `_balanced`, `_converted`, `copy 2`…), extended to strip `_02`, `_combined`, date tokens, case/punctuation | 0 I/O; one in-memory index, < 50 ms (estimate) | Trims/compilations change duration → miss. Unrelated equal-length clips → collisions, so **duration alone never scores above "possible"** |
| **T2 Audio fingerprint** | Same recording through any re-encode/gain/container change; **sub-clip alignment** ("this clip is 03:12–04:40 of that compilation") | Bytes-bound: whole container read, ~150–200 MB/s on spinning disks (estimate); CPU negligible | Silent/muted footage; music bed laid over camera audio; heavy denoise; **two cameras at one event share room audio** → audio-only match means "same event", not "same footage" |
| **T3 Visual fingerprint** | Trims, compilations, re-crops, transcodes without usable audio. Shot cuts via ffmpeg `scdet` (already in the installed ffmpeg); per shot a 64-bit dHash (reuse `PerceptualHash.swift`, already on main) + Vision `VNGenerateImageFeaturePrintRequest` vector (ANE); shot sequences aligned Smith-Waterman style. The installed ffmpeg also has the MPEG-7 `signature` filter — a zero-dependency near-duplicate detector worth a spike | Keyframe-only decode for long-GOP; ~2 fps for all-intra (ProRes/DV/FFV1); ~1–3 min compute per hour of footage on M4 Max (estimate) | Letterbox vs crop defeats dHash (documented in `PerceptualHash.swift`); black leaders/title cards (existing 5% trim rule helps); static tripod shots look alike |
| **T4 People/faces** | Tiebreaker only | Reuses ArcFace / Person Finder results | "Man playing guitar who looks like Rick" matches **every** guitar video of Rick — face identity says who, not which shot. May rank ties among T2/T3 candidates; never nominates one |

**Relationship verdicts shown:** Identical (T0 bytes) · Same footage, re-encoded (T1+T3 or T2+T3 full length) · Contained in / Contains (T2/T3 partial alignment) · Same event, other camera (T2 without T3) · Similar (T4 only, hidden by default).

## 2. Which one is the original?

A versioned, reason-printing scorer in the style of `DuplicateDetector.keeperScore`:

- **For:** `originMake`/`originModel` present; `com.apple.quicktime.creationdate` present; camera-native codec/container (DV, AVCHD `.MTS`, iPhone HEVC, GoPro/DJI handler); camera filename pattern (`MA5A####`, `MVI_`, `IMG_`, `GX01…`); earliest *sanity-filtered* embedded date; being **contained in** a longer file (camera clips are the parts, compilations the whole); highest resolution/bitrate **within one codec family only** (a ProRes transcode always wins on raw bitrate).
- **Against:** transcoder `originEncoder` (`Apple ProRes 422` from an FCP path, HandBrake, `Lavf…`); path contains `Transcoded Media`/`Proxy Media`/`Render Files`; `mediaIdentifier` tag present; non-nil `derivativeBaseStem`; `derivedFrom` set; embedded date equal to a known transcode/export time.

**Output:** a chain (original → export → transcode) with each link labelled, plus **the capture date to propagate**, taken from the earliest node with camera evidence. If none has camera evidence, the sheet says so. For the guitar case: *"Original not in catalog. Best available: RicksGuitars2024.mp4 — export 2025-02-02, no camera tags; its date is an upper bound, not a shooting date. Filename suggests 2024 (year precision)."*

## 3. Fingerprint index

- **Storage:** `~/Library/Application Support/VideoScan/fingerprints.sqlite`, following the `MetadataCache` / `PersonFinderCache` pattern (SQLite3 C API, `NSLock`, per-process scratch DB under test hosts). Rows keyed by **content key** (`h:v1:…`, else `p:<md5>:<size>`, the existing `MediaLedgerEvent.contentKey`), so every copy shares one fingerprint and **offline files still match**. Rows with an empty key are content-hashed first via the existing backfill; nothing is keyed on path alone.
- **Tables:** `files` (contentKey, last path, volume, size, mtime, duration, per-tier algorithm version, indexedAt, error); `audio_fp` (blob + algorithm version); `shots` (start, duration, dHash, float16 feature print). The query-time inverted index is built in memory from the blobs on first use (~1–2 s, estimate) and cached, not stored.
- **Sizes (estimate):** audio ~115 KB/h → ~75 MB for 652 h; visual ~1.5 KB/shot at ~10 shots/min → ~0.9 MB/h → ~600 MB. **< 1 GB total**; disposable, always rebuildable (see `media-archive.md`).
- **The job:** "Build Fingerprints" as a `MediaFileOperationJob` (pause/resume, MFO window). **One reader per physical disk**, never two on one spindle; disks in parallel. Mounted volumes only — **never wakes or spins up drives**; backs off when Drive Health flags a disk. Checkpoints every file into SQLite; resume skips rows at the current algorithm version. Honest progress: files and bytes per volume, measured MB/s, ETA from that rate; every file logged (Logger + job log). Runs on whichever Mac the drives are on (M4 Max now; M5 Ultra from late October); rows are content-keyed, so indexes from the M5 Pro/M1 Max merge without conflict.
- **Priority:** (1) the 3,311 undated records + the 141 files inside FCP `Original Media`/`Transcoded Media`; (2) archive + Archive Angel candidates; (3) everything else, mounted volumes first.
- **Throughput (estimate):** 9.6 TB at ~180 MB/s ≈ 15 disk-hours; across 8 volumes in parallel, **1–2 nights** for T2. T3 adds a second read pass plus ~11–33 compute-hours on M4 Max; a combined single pass is not v1.

## 4. The verb and the sheet

**Right-click → "Find Original…"** (next to the existing "Find Online Version") opens a sheet:

- **Header:** the chain diagram and the "date to propagate" line with its honesty caveat.
- **Ranked list:** thumbnail, name, volume (online/offline), codec, resolution, duration, embedded date, origin (`Canon EOS R6` / `HandBrake`); **evidence chips per tier** (`T0 identical`, `T1 Δ1 frame · stem`, `T2 audio 97% @03:12`, `T3 41/44 shots`, `T4 same people`); verdict; confidence (Certain / Likely / Possible); a "Why" popover with per-tier scores and current weights.
- **Play side by side** (both online), synced at the aligned offset.
- **Actions:**
  - **This is the original** — records `derivedFrom`-style lineage with provenance.
  - **Not related** — suppresses the pair for good.
  - **Use its date for this file** — writes the date as *your* decision, provenance `"from original <id>, confirmed by Rick (Find Original)"`, Media Ledger `dateSet` (`by: .rick`). Offered to other chain members by checkbox, never auto-propagated (respects the 2026-09-12 rule: machine dates travel only between byte-verified copies).
- **Learning:** each Confirm / Not related writes a ledger event (`lineageConfirmed` / `lineageRejected`) with the per-tier score vector. A nightly **logistic regression** refit over ~6 features (T0, T1 name, T1 duration, T2, T3, T4), L2-regularized, ~50 lines of Swift, no dependency. Hand-set weights until 30 answers; each weight set versioned ("weights v3 · 47 answers") and revertible. Learning only re-weights ranking; it never changes the index.

## 5. Payoffs

- **Transcode-date misfiling:** FCP transcodes/exports currently file under their render day; with confirmed lineage the whole family files under the original's capture date.
- **Archive item versions:** the chain *is* the version set (original · preservation · access · editable · restored) — replaces filename guessing.
- **Archive Angel:** real event families and a uniqueness score (the long-planned T11 in `archive_angel_curation_direction.md`), so "one Thanksgiving variant per batch" stops depending on names. Duplicate analysis gains "same footage, different encoding" — evidence can only **add**; deletion still requires `SignatureVerification` (per `media-archive.md`).

## 6. Phasing and tests

| Phase | Scope | Rough size |
|---|---|---|
| **1** | T0 (+ capture `mediaIdentifier` in `EmbeddedOriginTags`) + T1, originality scorer, sheet, date write. Instant, no index | ~1 week |
| **2** | Audio fingerprints (T2) + Build Fingerprints job + sub-clip alignment; starts with a 1-day engine spike on the guitar case | ~1–2 weeks + nights |
| **3** | Shot-level visual fingerprints (T3) + alignment; T4 as tiebreaker | ~2 weeks + nights |
| **4** | Ledger events, nightly weight refit, "Why" popover | ~3 days |

**Tests (5-dimension checklist):**
1. **Logic** — table tests: stem normalizer; frame-rate-aware duration tolerance; originality reasons; chain building (ties, cycles, missing original); logistic fit on synthetic labels.
2. **Scale** — 100k synthetic records: T1 index build < 1 s; one query < 50 ms; query against a synthetic 1,000-hour audio index < 1 s.
3. **Media matrix** — ffmpeg `test_*` fixtures: one source rendered as mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv, plus a trimmed sub-clip, a 3-clip compilation, and a **same audio, different picture** negative. Every pair found with the right verdict; offsets within ±0.5 s; the negative says "same event", never "same footage".
4. **Isolation** — a poisoned `fingerprints.sqlite` at the production path is never read under a test host.
5. **Sensors** — the guitar case as a metadata-only replica pins the ranking and the "original not in catalog" message; a false-positive sensor: across 100k random-duration records, zero T1-only candidates rank above "Possible".

## 7. Risks

- **False positives** — same event/different camera (shared audio), tripod repeats, stock intros. *Mitigation:* verdict classes, T4 tiebreaker only, no automatic writes (every date/lineage write is your click).
- **Compute and disk wear** — reading 9.6 TB wakes drives and seeks for hours. *Mitigation:* mounted volumes only, one reader per spindle, Drive Health back-off, overnight window, pause/resume.
- **Privacy** — all on-device: Vision on the ANE, local SQLite, no network.
- **New dependency** — `fpcalc` is not installed and Homebrew ffmpeg has no chromaprint muxer (both verified). Chromaprint (`brew "chromaprint"`, LGPL-2.1) would be a new external tool. *Alternative, no new dependency:* ShazamKit (`SHSignatureGenerator` + `SHCustomCatalog` works offline and reports match offsets; CLAUDE.md prefers macOS-native). *Unknown:* its behaviour on room audio and all-pairs queries.
- **Index staleness** — rows carry an algorithm version; a changed file gets a new content key and is re-indexed.

## Decisions for Rick

1. **Audio engine: Chromaprint (new Homebrew dependency) or Apple ShazamKit?** *Recommend:* a 1-day spike of both on the guitar case; ship ShazamKit if its sub-clip offsets are reliable, else approve `chromaprint` in the Brewfile.
2. **"Use its date" — your own date (`userDate`, ledger `dateSet by: rick`) or a high-confidence machine date?** *Recommend:* your date, full provenance string, offered to chain members by checkbox, never auto-propagated.
3. **May the overnight index wake sleeping or unmounted drives?** *Recommend:* no — mounted only, one reader per disk, stop at a set morning hour.
4. **Ship Phase 1 (metadata only, no index) before any overnight work?** *Recommend:* yes — it reaches the mp4 in the guitar case in ~1 week and gives you the sheet to judge Phases 2–3.
5. **Learned weights: update nightly on their own, or wait for your approval?** *Recommend:* automatic once ≥ 30 answers, versioned and revertible, current weights visible in the "Why" popover.

### Critical files for implementation
- `VideoScan/VideoScanCore/Sources/VideoScanCore/VideoRecord.swift` — lineage, identity, `originMake/Model/Encoder`, `embeddedCreationDate`
- `VideoScan/VideoScanCore/Sources/VideoScanCore/EmbeddedCreationDate.swift` — `EmbeddedOriginTags`: add `com.apple.proapps.mediaIdentifier`
- `VideoScan/VideoScan/ArchiveAngelCandidate+Record.swift` — `ArchiveAngelNaming.derivativeBaseStem` (T1 normalizer to extend)
- `VideoScan/VideoScan/OnlineCopyFinder.swift`, `CatalogContent+Table.swift` — pure same-content finder pattern + right-click verb
- `VideoScan/VideoScan/PerceptualHash.swift`, `PerceptualFingerprinter.swift`, `MetadataCache.swift`, `MediaFileOperations.swift` — T3 base, SQLite sidecar pattern, MFO job protocol
