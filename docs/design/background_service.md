# VideoScan Background Service — Automated Intelligence Gathering for Legacy Family Media

Status: in flight — 2026-11-04 evening: **Part A (§1–§7) is the dossier deep dive** Rick asked for ("what are all possible data items and patterns I can get from a media file … I want a DEEP dive"): his draft of 2026-11-04 (Parts 1–4, kept in substance and voice), made accurate against the code and the rulings, with the analyzers spelled out as chains, the corpus layer graded, worked examples, and how Rick sees the results. **Part B (§8–§19) is the service design as built**, unchanged in substance; it was §0–§8 until tonight. Old → new numbers, for comments written before 11/04: §0 → §8 · §0.5 → §9 · §0.6 → §10 · §0.7 → §11 · §1 → §12 · §2 → §13 · §3.x → §14.x · §4 → §15 · §5 → §16 · §6 → §17 · §7 → §18 · §8 → §19. Earlier status: 2026-11-04 the helper owns its schedule (DECISIONS 2026-11-04; §14.2, §14.5). Step 0 is built (the helper, its launchd job, XPC control). Step 1 merged on 2026-11-01 (`0656aee6`): the seated 8B era/OCR job, the observation journal, `JournalApplier` through the commit door, schema v14 `provenance_assertions` (DECISIONS 2026-10-31, 2026-11-01). The corpus run proceeds on the Ultra (STATUS). Step 2, captions on the 8B, is §15.

VideoScan Background is the helper process that keeps analysing after the app quits: a login-item launchd job the app registers, controlled over XPC, with its durable state in files under `App Support/VideoScan/background/`, taking one engine at a time out of the app so the app is never down for a rewrite. What it may run is listed in §14.6; it never touches media. §10 (Rick, 10/31) says what goes in and what comes out; §11 names the outputs **observations**, says where they live (the three homes) and in what order they are produced (1960–2010, oldest first). An observation reaches the catalog only through the app's one commit door, and is never shown as a date (DECISIONS 2026-11-01). The first job it hosts is the video-model work in `docs/design/machine_intelligence.md`.

*Part B is the design as written on 2026-10-30, with §9–§11 added 10/30–10/31 (Rick said "design it"); its original preface is the italic note at §8. Part A was written 2026-11-04/05 from Rick's draft; where the draft and a ruling disagreed, the idea is kept, the mechanism corrected, and the ruling cited.*

---

# Part A — The dossier: everything that can be known about a media file

**The question (Rick, 2026-11-04):** "What are all possible data items and/or patterns I can get from a media file? (1) technical data; (2) patterns we can find using LLMs and various analyzers; (3) extrapolation or triangulation by traversing the corpus over and over — once we have looked at every media file, we see patterns at a corpus-wide level. I do not know what is possible, but I want to dig deep and see what might be possible." The word from earlier in the project is **dossier**: for every media file, everything that can be known about it, each item saying where it came from.

**Three layers, one rule.** Layer 1 is read from the bytes and is deterministic. Layer 2 is extracted from the decoded pictures and sound by signal processing and models. Layer 3 is what the corpus says when every file has been through layers 1 and 2. Every item in every layer is an **observation** (§11): it carries who made it (`by = engine@version`), when, and its evidence; a decision Rick made outranks it; it never supports the inference that produced it; and it is never shown as a fact it has not earned (CLAUDE.md rule 1; DECISIONS 2026-11-01). The machine proposes with a written reason; Rick confirms.

**How to read the tables.** *Tells us* — what the item says about a family video (a date bound, the carrier, the device chain, who, where, what occasion). *Analyzer* — the concrete tool, library or model that yields it, all local on Apple Silicon. *Status* — ✓ built (file cited) · ◐ partial · ○ idea. *Cost* — per file, on the Ultra: **D** deterministic, well under a second unless marked; **D-decode** deterministic but decodes the whole file (minutes per hour of footage, see `provenance.md` Phase B's table); **M** a model, seconds per file. Counts quoted are from the docs named; the catalog is the source of truth, not this page.

## 1. Structural and technical facts (the computational layer)

These are parsed without guessing from the container, the stream headers and the raw stream layout. Rick's draft (1.1–1.4) is kept; 1.5–1.6 are what it missed. One standing caveat from the forensics reading (§10): **a transfer is not a recording** — every date in this layer dates the file or the carrier it was captured from, and the output must say which (DECISIONS 2026-11-01, "the DV datecode dates the DV stream, not necessarily the content").

### 1.1 File and container

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Container / wrapper (mov, avi, mkv, mxf, mp4, mpg, 3gp, wmv, dv) | an upper bound on the era of the *file* (what encoders existed), never of the footage; the capture or edit tool's family | ffprobe → `metadata_cache.sqlite` | ✓ Core `FFmpeg*`, `Media/` (ARCHITECTURE §4) | D |
| Size, duration, overall bit rate, VBR vs CBR | master-capture (high, constant) vs distribution copy (low, variable); a 4 GB DVD rip vs a 13 GB/h DV capture | ffprobe | ✓ | D |
| Muxer / encoder / software strings (`Lavf61.7.100`, `HandBrake 1.7.3`, Sony Vegas, iMovie, Avid) | the transfer or edit tool and so the **capture setup** (one device chain, many tapes); a July 2026 ClearClick batch is one encoder + one frame size | ffprobe format/stream tags → `EmbeddedOriginTags` | ✓ `Core/EmbeddedCreationDate.swift`; `probe_extra` | D |
| File-system dates (birth, mtime) | the **transfer history** only (a bulk copy resets them); equal to an embedded date = unset, not evidence | `stat` | ✓; the plausibility gate is BACKLOG #118 | D |
| Embedded creation dates: QuickTime `creation_time` (mvhd, UTC, 1904 epoch trap), `com.apple.quicktime.creationdate` (wall clock + offset, the best phone field), Matroska `DateUTC`, EXIF `DateTimeOriginal` | the recording date on camera-native files (phones, digicams); the **capture** date on transfer files (ProRes, FFV1, DNxHD stamps are transfers, `video_llm_benchmarks.md` truth rule) | ffprobe tags → `EmbeddedDateParser` + `EmbeddedDateSanity` (rejects 1904, 1970, 2000-01-01, the future, pre-1980) | ✓ `Core/EmbeddedCreationDate.swift`; 5,635 camera-dated files (`machine_intelligence.md` §0) | D |
| ExifTool's long tail (`Keys:CreationDate`, `TrackCreateDate`, MakerNotes, GPS, orientation, lens, exposure) | the few fields ffprobe normalises away; MakerNotes name the exact camera body | `exiftool -api QuickTimeUTC=1 -j` | ○ a one-day probe pass (§10 says so); not read today | D |
| Timecode track, chapters, edit lists | project-relative time; an edit list or chapter marks = an NLE export, not a capture | ffprobe `-show_streams` (tmcd), `-show_chapters` | ◐ shown by ffprobe, not stored as an observation | D |
| **Reference movies and essence-less MXF** (a QuickTime that points at media elsewhere; an Avid MXF with only a descriptor) | the row describes *nothing playable*; its media may be in the corpus under another row | ffprobe (`nb_frames` 0, no video packets) + the MXF/Avid bin parsers | ◐ found: 190 "DV" mov/mxf rows hold no frames; what the catalog should say is BACKLOG "To file (dv_datecode run)" | D |
| **Avid MXF descriptor vs stream** | the codec label on 25 MXF rows comes from the descriptor, not the bytes (they are MPEG-2, labelled "DV 25") — rule 1: a shown fact comes from the stream | ffprobe on the essence, not the wrapper | ◐ measured 2026-11-01; BACKLOG "To file" | D |
| **Avid bins and NLE projects** (tape name, clip name, source timecode in `.avb`; FCPXML `media-rep`; iMovie event names) | the **human organisation that already happened**: which tape a clip came from, the editor's name for the event | the MXF and Avid bin parsers (ARCHITECTURE §4 "Media reading"); FCPXML parse | ◐ parsers exist for pairing; as provenance evidence they are `provenance.md` Phase D ("recover existing human organization", BACKLOG) | D |

### 1.2 Video stream

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Codec / FourCC / profile (dvvideo, mjpeg, svq3, h263, mpeg4/DivX/XviD, h264, hevc, prores, ffv1, dnxhd) | a **carrier or generation floor**: dvvideo = DV/Digital8 1995+ or an analog tape through a DV bridge; mjpeg 640×480 = 2000s digicam; svq3 = early QuickTime export; ffv1/prores/dnxhd = a *transfer*, which says nothing about when the footage was shot | ffprobe | ✓ (codec class per stratum in `bench.py codec_class`) | D |
| Frame size (720×480/576 SD, 352×240 VCD, 640×480, 1280×720, 1920×1080, 3840×2160) | SD interlaced = analog or DV era; a 1280×720 FFV1 of a 4:3 image = an upscaled tape transfer (the July setup) | ffprobe | ✓ | D |
| PAR / DAR, 4:3 vs 16:9 | pre-2010 non-square pixels; 16:9 SD = late DV/DVD era; letterboxed 4:3 inside 16:9 = a later re-wrap | ffprobe; `cropdetect` for letterbox geometry | ✓ ratios; ○ measured letterbox (Phase B uses `cropdetect` for hashing) | D / D-decode |
| Scan type and field order as **flagged** (TFF, BFF, progressive) | analog or DV = interlaced; progressive-flagged H.264 that is interlaced underneath = "later-generation re-encode of an analog transfer" | ffprobe `field_order` | ✓ flag | D |
| Scan type as **measured** (comb artefacts in the pixels) | the truth under the flag (flags lie after re-encodes) | `ffmpeg -vf idet` (per-frame TFF/BFF/progressive counts; [ffmpeg idet](https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Video/idet.html)) | ○ named in Phase D; a cheap pass, minutes per hour | D-decode |
| **Film cadence / telecine (3:2 pulldown)** | the footage is **film** (8 mm, Super 8, 16 mm) transferred to video: a hard carrier fact and a pre-video era hint; one repeated field in five at 29.97 = NTSC pulldown | `idet`'s repeated-field counts (`rep_thres`); its 2014 commit notes it "can be useful for determining telecine" ([ffmpeg-cvslog](https://lists.ffmpeg.org/pipermail/ffmpeg-cvslog/2014-November/082874.html)); weak on soft telecine (RFF flags) | ○ "untested, still worth a day" (§10); DECISIONS 2026-10-26: film scans are one more carrier, no special pipeline until Rick says where the scans are | D-decode |
| Frame rate (29.97, 25, 24, 15, 10, variable) | 25 = PAL country; 15/10 fps = early webcam or phone; 24 = a film scan or a modern cinema mode; VFR = phone | ffprobe `r_frame_rate` vs `avg_frame_rate` | ✓ | D |
| Colour primaries / matrix / transfer (BT.601 vs 709 vs 2020), bit depth, chroma subsampling | SD/601 = analog or DV era; 4:2:2 10-bit = a modern capture card; 2020/HDR = a 2020s phone | ffprobe | ✓ | D |
| GOP layout, I/P/B pattern, keyframe interval | long GOP = distribution copy; all-I (DV, MJPEG, ProRes, FFV1) = capture or master | `ffprobe -show_frames` on a window | ◐ not stored; cheap to add to the probe | D |
| Grain / noise statistics, exposure, white balance, colour cast per frame | film grain vs tape noise vs sensor noise; a purple cast = faded dye in a film transfer; a yellow cast = incandescent indoors | `ffmpeg -vf signalstats` (YAVG, SATAVG, HUEAVG, YDIF per frame) | ○ | D-decode |
| **Analog tape signatures**: dropouts, head clogs, tracking errors; dropout-compensator concealment; the head-switching band in the bottom lines | the file is a **tape capture** (VHS / 8 mm / Hi8), and how rough the deck was; two captures of one tape share dropout positions (same-carrier evidence) | `signalstats` TOUT ("video dropouts, head clogs, or tape tracking issues") and VREP ("concealment from a dropout compensator") ([ffmpeg signalstats](https://ayosec.github.io/ffmpeg-filters-docs/8.0/Filters/Video/signalstats.html)); QCTools (MediaArea) wraps the same filters for archivists | ○; BACKLOG "QCTools/MediaConch post-capture QC" | D-decode |
| Film gate weave, splice flashes, sprocket-hole shadow, frame-line bob | film again, and the scanner's quality | research code; no off-the-shelf detector found | ○ research | — |
| Scene cuts, shot length, camera motion (pan/zoom speed) | a one-shot home video vs an edited compilation (DECISIONS 2026-09-23: a compilation has no single date); the sampler's window boundaries | `ffmpeg select='gt(scene,0.3)'` (in use for windows) or PySceneDetect | ◐ used by the window sampler, not stored | D-decode |

### 1.3 Audio stream

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Codec (PCM, MP3, AC-3, AAC, WMA) | PCM = capture or DV; AC-3 = DVD; AAC = phone or export | ffprobe | ✓ | D |
| Sample rate: **32 kHz = DV 12-bit 4-channel mode** (consumer camcorders in LP or 4-ch), 48 kHz = DV 16-bit or any modern capture, 44.1 kHz = CD-era capture card, 22.05/11.025 kHz = web export | a carrier and camera-setting fingerprint; 32 kHz alone narrows to consumer DV/Digital8 | ffprobe | ✓ | D |
| Bit depth (8, 12 non-linear, 16, 24), channels, layout | as above; 4 tracks = DV 12-bit | ffprobe | ✓ | D |
| **Dual-mono vs true stereo; silence measured** | a tape captured with one cable; a silent file is a *fact about the file*, not a defect (DECISIONS 2026-11-02 "silent (measured)") | `AudioPCMDecoder` → the sound-print pass (8 kHz mono) | ✓ silence measured (19 files); ○ dual-mono detection (L−R energy) | D-decode |
| Loudness, hiss floor, dropouts | AGC camcorder vs line capture; a hiss floor is a tape signature; audio dropouts align with video dropouts | `ffmpeg -af ebur128,astats` | ○ | D-decode |
| Mains hum (ENF) | **dropped** (§10): no public US 60 Hz reference for 1985–2010; battery camcorders with AGC rarely carry it | — | dropped | — |

### 1.4 Embedded tags written by the device

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Camera make / model (QuickTime `udta`, `com.apple.quicktime.make/model`, AVCHD MDPM, EXIF MakerNotes) | the **physical camera**, so a hardware lineage across years (§3.4) | ffprobe tags → `EmbeddedOriginTags`; exiftool for MakerNotes | ✓ QuickTime/MP4 (`EmbeddedCreationDate.swift`); ○ exiftool | D |
| Camera serial number | the one camera among several of a model | EXIF MakerNotes (some stills); **rare in consumer video** — not in DV, not in most AVCHD | ○; expect few hits | D |
| **DV / HDV datecode** (recording date and time in every DV frame's VAUX pack; HDV carries a similar pack in its transport stream — not measured here) | the **camcorder clock at the moment of recording**: frame-accurate, immune to file-system dates, survives a stream copy into .mov/.mkv, lost by any re-encode; an upper bound on the content ("no later than") and the recording date when nothing says the content is older (DECISIONS 2026-11-01 ×2) | `dvrescue` (MediaArea) per frame → `rdt`, `rdt_r`, `rdt_nc` ([DVRescue schema](https://mipops.github.io/dvrescue/sections/dvrescue_documents.html)); `scripts/dv_datecode.py` reads the head windows | ◐ **measured 2026-11-01**: 707 DV contents, 262 raw + 35 wrapped carry a date; on 231 of 297 the recording precedes the file's own date (`machine_intelligence.md` §11). Not in the catalog yet (`MachineEraStore.swift` says so); the reader → `inferred_dates` source `dv-datecode` is BACKLOG "DV rdt as a deterministic date bound" (needs Rick's ranking) | D, head-only; 159 s for 720 GB |
| DV record-start flags, timecode discontinuities | **take boundaries**: each press of Record is one take; a tape is a sequence of takes, each with its own rdt | `dvrescue` `rec_start`, `tc` jumps | ○ (Phase D names it) | D |
| SMPTE timecode track (tmcd) | the deck's or NLE's reel position; two files whose timecodes abut came from one capture session | ffprobe | ◐ shown, not stored | D |
| GPS, orientation, altitude (phones) | where, which way up | ffprobe `location` tags; exiftool | ◐ read by ffprobe; place is not an observation yet | D |

### 1.5 Identity, copies and lineage (what makes two files the same thing)

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Whole-file SHA-256 | identity; byte copies | `ContentFixity` | ✓ (rule 6) | D-decode (reads every byte) |
| Audio landmark fingerprint (Shazam-style constellation on 8 kHz mono) | **same recording** across containers, re-encodes and trims, with the offset: "this 90 s clip is cut from that 16-minute master" | `AudioFingerprint`, `AudioFingerprintMatcher`; `audio-fingerprints.sqlite` | ✓ (`people_events.md` "Audio fingerprint engine"; Find Master Phase A) | D-decode; 2.5 s per hour of audio |
| Picture prints: 32 frames → 9×8 dHash | same footage for a pair compare, silent footage included | `PerceptualFingerprinter`, `PerceptualHash` | ✓ (`Media/PerceptualFingerprinter.swift`) | D-decode |
| Picture timeline: one 256-bit PDQ-class hash per second, with a quality score | the audio matcher's algorithm on pictures: clip-of, offset, coverage, for silent film and tape | `PictureTimeline` (Phase B, designed) | ○ designed (`provenance.md` Phase B) | D-decode |
| TMK+PDQF / vPDQ (Meta's open video hashes) | an off-the-shelf alternative to Phase B; vPDQ's variable-length hash suits clip-in-longer-video | ThreatExchange repo ([PDQ/TMK test drive](https://ar5iv.labs.arxiv.org/html/1912.07745)) | ○ alternative, not chosen | D-decode |
| **PRNU sensor noise** (the physical sensor's fixed-pattern noise) | groups files from **one camera body**; never a date | research code; survey of limits: compression, stabilisation and scaling weaken it; electronic stabilisation is "the most damaging pipeline step" ([Altinisik et al.](https://ar5iv.labs.arxiv.org/html/1905.09611); [survey](https://qspace.qu.edu.qa/handle/10576/40327)); analog transfers carry the capture card's pattern, not the camera's | ○ research; "grouping only, later" (§10); uncropped phone clips are the one plausible use | D-decode, heavy |
| Encoder chains and edit signatures (a GOP break, a second encoder string, a frame-size change) | a derivative, and of what generation | `probe_extra` signatures; Phase D "encoder chains" | ◐ | D |

## 2. Extracted patterns in the pictures and the sound (the perceptual layer)

Nothing here is in a header; it is read from decoded frames and audio by signal processing and models. The status column names the model that holds the seat today (`machine_intelligence.md` Part II). Rules that bind every row: pixels only, a model never sees the file's facts as prompt text (DECISIONS 2026-10-31: the codec anchored the model on the carrier's era); a schema-invalid answer is no answer; the model's own confidence is stored, never shown; a model never assigns a name (DECISIONS 2026-10-10).

### 2.1 Picture

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| **Burned-in date/time stamp** (camcorder OSD, orange/white digits, a corner) | an exact day, the strongest machine date on camcorder footage; ranked by the stamp-fusion rule (a stamp outranks the DV clock) | Qwen3-VL-8B-4bit, `date` prompt on 5 stills (`ocr.date`) | ✓ seated: any-frame exact 95 % on 63 clips (`video_llm_benchmarks.md` A2); earlier the 3B's 1,448 candidates; junk "!!!!" refused (#402) | M, 0.2 s per still |
| On-screen text (signs, banners, a cake's "Happy 7th", a T-shirt, a licence plate) | event, place, an age, a year; search words | the same 8B, `text` prompt (`ocrText`) | ✓ 3B today; moves to the 8B in step 2 (§15) | M |
| Scene caption (free text per window) | search fodder, never a fact | 8B `scene` prompt | ✓ 3B today, 4,518 contents; 8B in step 2 | M |
| **Era cues** (clothing, hair, cars, CRT televisions, consoles, wallpaper, the camcorder's own look) → a year range with cues and a rationale | a **decade-class bound** from the content itself, independent of the carrier: the re-recording detector's other witness | 8B, `era` contract, 3 windows × 8 frames (`era.yearRange` per window, `era.fused` per file) | ✓ seated (DECISIONS 2026-10-31): Rick-dated MAE 3.6 y, truth inside the range 86 %, 7 s per clip; the 32B was worse at 5× the cost | M, 1.5 s per window |
| Room features and setting (indoor/outdoor, "green shag carpet", "brick fireplace", "wood-paneled walls") | **place as context**: the same room across years is one house (§3.5); never identity | 8B `roomFeatures` contract | ◐ emitted on every window (100 % schema-valid, 889 distinct features over 327 clips); **no ground truth, sidecar only** until Rick's ~50 place labels (lab §9 ruling 2) | M (same window) |
| Occasion kind (birthday, christmas, thanksgiving, easter, halloween, wedding, beachVacation, musicPerformance, graduation, mixed, unknown) | an **event category** vote per window, for the rulings to combine (§3.2) | 8B, `OccasionKindContract` | ◐ the contract exists (`ModelLab/ApproachOutputContracts.swift`); not run, not promoted; gate precision@5 ≥ 0.8 on the 18 confirmed events | M |
| Faces: detection, tracks, feature prints | **how many people**, where in the frame, for how long; the within-occasion continuity signal (same clothes for an afternoon) | Apple Vision (`VNDetectFaceRectanglesRequest`, feature prints); AdaFace IR-50 / ArcFace embeddings on Core ML | ✓ built; **recognition frozen 2026-10-23** (POI search is not the strategy; faces are a weak signal, DECISIONS 2026-10-03/10) | M, local, fast |
| Face attributes: adult/child, age band, sex, infant present | the **Household Roster filter** (A7): date window × tree × attributes → one or two named candidates, proposed with a reason, never written | MiVOLO (open weights; MAE ≈ 4 y on adult benchmarks, [arXiv 2307.04616](https://arxiv.org/abs/2307.04616)) or the 8B asked for attributes only | ○ A7's next rung (`docs/reviews/household_roster_feasibility.md`); calibrate on Rick's tagged clips before any number is shown | M |
| Objects and materials (cake, candles, tree, wrapped boxes, pool, car, CRT, beige tower) | occasion and era votes; search words | Apple Vision `VNClassifyImageRequest` (on-device taxonomy, `knownClassifications`) for a cheap first pass; the 8B's cues for the rest | ○; the 8B already returns such cues inside `era` | M, cheap (Vision) |
| Season, weather, time of day, indoors/outdoors | a month-class bound (snow, leaves, a pool); a Christmas tree is December-ish, not a date | 8B cues; `roomFeatures.setting` | ◐ setting is emitted; season is not a contract field yet | M |
| Scene composition: cuts, pans, zoom, handheld shake | one-shot home video vs edit; which camera (a tripod wedding vs a handheld birthday) | `select=scene`, optical-flow stats | ◐ cuts used by the sampler | D-decode |
| Measured interlace, compression artefacts (macroblocking, mosquito noise), tape noise | generation and carrier evidence from the pixels (layer 1 rows, measured) | `idet`, `signalstats`, blockiness metrics | ○ | D-decode |
| Picture embeddings per window (a vector) | **retrieval by example**: "windows like this one" for room/occasion suggestions, distance shown | MobileCLIP2-S2 (Core ML, ANE) or SigLIP 2 / Qwen3-VL-Embedding-2B | ○ lab A4; gated on precision@k ≥ 0.8 | M, cheap |

### 2.2 Sound

| Item | Tells us | Analyzer | Status | Cost |
|---|---|---|---|---|
| Transcript | what was said: names, years ("your seventh birthday"), places ("down the Cape"), occasions ("make a wish"); search words | Whisper medium (MLX, q4) through the long-lived worker (`scripts/whisper_worker.py`, JSONL) | ✓ in production (`Media/WhisperWorkerTranscriber.swift`); **segment timing discarded** (BACKLOG) | M, ≈ real-time ÷ 10 |
| Timed segments (start, end, text) | *when* a thing was said, so it can be aligned with a face in frame or a cake on the table | the same worker returning `segments` (a one-line change, lab §3.2); Apple's `SpeechAnalyzer` (macOS 26, on-device, `.audioTimeRange`) as a second engine ([WWDC25 277](https://developer.apple.com/videos/play/wwdc2025/277/)) | ◐ designed; not kept yet | M |
| Language | an English/other split; nothing more here | Whisper language detection | ✓ | M |
| Speaker diarization (who-speaks-when, as anonymous speaker A/B/C) | how many voices; **the one voice that is always near the microphone** is the operator (§3.3); a child's voice vs an adult's | pyannote 3.1 on MPS (≈ 3 min for 45 min on a Mac, [pyannote #1626](https://www.github.com/pyannote/pyannote-audio/issues/1626)); Swift/Core ML ports exist (speakrs reports ≈ 7 % DER on VoxConverse on an M4 Pro, [speakrs](https://docs.rs/crate/speakrs/latest/source/src/lib.rs)) | ○ "speaker similarity" is BACKLOG; never a name (DECISIONS 2026-10-10) | M, ≈ real-time ÷ 15 |
| Spoken name beside a visible child (`spokenNamePresence`) | within-occasion continuity: "Jimmy" said at 02:14 while one child is in frame | timed transcript × face tracks; a declared `FieldFamily` | ○ needs timed segments first | D over M outputs |
| **Sound events** (singing, applause, laughter, crying, fireworks, water, wind, engine; the exact label list is read from `knownClassifications` first, not assumed) | **acoustic anchors** for occasion rulings: a chorus + candles = birthday; fireworks = July; waves = the Cape | Apple `SoundAnalysis` built-in classifier (`SNClassifySoundRequest`, `.version1`; ≈ 300 labels, multi-label, on-device; [overview](https://swiftjectivec.com/Sound-Analysis-Framework-Built-In-Model/)) | ○ **the cheapest unbuilt analyzer**: Apple framework, no weights to manage, native Swift | M, cheap |
| Music present; song identified | a song's release year is a **lower bound** on the date ("no earlier than"); music = a party or a TV in the room | presence: SoundAnalysis "music". Identification: Chromaprint → AcoustID or `ShazamKit` — **both send a fingerprint of the audio to a server** ([AcoustID](https://oxygene.sk/2010/08/acoustid/); [ShazamKit signature](https://yaacoub.github.io/articles/swift-tip/shazamkit-a-first-look)) | ○ presence is free; identification **needs a ruling** (rule 13: a fingerprint of audio that carries family voices is derived from living-family audio) | M |
| Hum, hiss floor, AGC pumping, wow and flutter | tape and camcorder signatures (layer 1 rows, measured) | `astats`, spectral stats | ○ | D-decode |
| Voice similarity across the corpus (anonymous clusters) | the same adult voice in 1988 and 1996 — a weak within-family signal, like faces | speaker embeddings (pyannote / WeSpeaker) | ○ research; family voices are as alike as family faces | M |

## 3. Algorithmic triangulation and corpus-wide extrapolation (the intelligence layer)

The apex, in Rick's words: "once we have looked at every media file, we see patterns at a corpus-wide level." Each sub-section gives the method, the evidence it needs, what goes wrong, how it stays truthful under the rules, and a feasibility grade: **now** (the evidence is in the catalog or a sidecar today) · **one analyzer** (needs one row of §1–§2 built first) · **research** (no measured method yet; try it as a lab experiment with a number before it may suggest anything).

Four rules, applied everywhere below:
1. **Conflation is deterministic.** Rulings and the triangulator combine observations; a model is a witness per file, never the organiser (§10; DECISIONS 2026-10-12 "models say what kind of event, capture adjacency says which").
2. **No circular corroboration.** A derived fact never supports the inference that produced it; a machine fact never outranks a human one (§11). In practice: every propagated bound carries its *chain* (which files, which observations) and a chain that loops is refused.
3. **Propose, never write.** The output of every corpus method is a `provenance_assertions` row in state `inferred` with its reason, shown as its own labelled line, confirmed or rejected by Rick; a rejected value is never re-proposed (the v14 veto trigger). A machine era is never a date (DECISIONS 2026-11-01); only Rick changes an archived date (rule 3).
4. **Calibrated, not confident.** No percentage without a measured hit rate on Rick's confirmed set (the convergence line in Catalog Status is the model: "within 5 y of your confirmed date: N of M").

### 3.1 Chronological pinpointing and age-trajectory interpolation

**Rick's logic, kept.** Face cluster C is a toddler in Video X and six-ish in Video Y; Video Y carries a DV datecode of 1996-12-25; so C's birth year is about 1992 and Video X is about 1994 — a date bound for X that no header holds.

**Corrected mechanism.** Video X is not "instantly back-dated, overriding the file-system date" (the draft's wording). It receives an *inferred* line — "Child A appears about 2 (machine age band); Child A was born 1992 (People tab) → likely 1993–1995" — under its confirmed date if it has one, beside the DV clock if it has one, with the chain written out. The strongest version of this needs no face recognition at all: **the birth dates in the People tab are already constraints** (§11; Charter §3 Claude Feedback "tree facts constrain media facts"). An apparent-age band on an *anonymous* child plus the roster of children alive in the date window narrows both who and when; this is A7's constraint solver (`docs/reviews/household_roster_feasibility.md`).

| | |
|---|---|
| Method | per file: face tracks → age band per track (MiVOLO or the 8B, attributes only). Per cluster across files: fit one birth year that minimises the disagreement between apparent ages and the files' best date bounds; propagate a window to every file in the cluster whose own bound is weaker. |
| Evidence needed | face tracks (✓ Vision), an age-band estimator (○), a within-corpus cluster (✓ AdaFace embeddings, frozen but usable for *clustering without naming*), at least a few anchor files per cluster with a strong date (✓ DV datecode, OCR stamp, Rick's date). |
| What goes wrong | age estimators are worst on children and the very old; siblings two years apart cluster together; a child's apparent age in a dim VHS frame is ± 3 years at best; **circularity**: a file dated *by* the cluster must never be an anchor *for* the cluster. NIST's age-estimation track reports MAE mostly for adults plus a 13–16 track; younger children are thinly measured ([NIST FATE AEV](https://pages.nist.gov/frvt/html/frvt_age_estimation.html)). |
| Stays truthful | anchors are only decisions and layer-1 dates; propagated windows are `inferred` with the chain; the convergence line reports the hit rate per method before any window is shown as more than "unconfirmed". |
| Grade | **one analyzer** (an age-band estimator, calibrated on Rick's tagged clips); the propagation itself is a deterministic job. The faces-as-identity half stays frozen; this uses faces as *age-bearing anonymous tracks* only. |

### 3.2 Event synthesis (the birthday and Christmas matrices)

**Rick's logic, kept.** Transcript says "make a wish"; the chorus sings "Happy Birthday"; candles, a round frosted cake, faces looking down at a table; the child behind the cake is cluster C → "Child B's 7th birthday". Red/green ratios, a conifer with reflective points, wrapped boxes on the floor, paper tearing, holiday music → late December.

**Corrected mechanism.** Events v1 already does the deterministic half (nine phrase-rule categories with negative cues, folder/date adjacency; 18 confirmed events, 42 members) and DECISIONS 2026-10-12 fixes the shape: *models say what kind, capture adjacency says which*; two levels (category, instance); "mixed" and "unknown" are valid answers; exact days are never invented; suggestions are confirmed with decisions stored apart from model output. What the corpus layer adds is **more witnesses per file** feeding the same rulings: the 8B's `occasionKind` vote per window, the 8B's object cues, SoundAnalysis classes (singing, applause, fireworks), transcript phrases, and §3.1's age band for the ordinal ("7th" needs an age, and the age needs a birth year — from the People tab, never from the model).

| | |
|---|---|
| Method | per file: a category vote with its witnesses (words, classes, cues, each cited at a time). Across the corpus: group by capture adjacency (same tape take sequence, same folder, same day by any date bound) into instances; an instance inherits the strongest date bound of its members with the chain; "Child B's 7th" is proposed only when a confirmed person tag + the People-tab birth date + the instance's date agree. |
| Evidence needed | transcripts (✓), occasion votes (◐ contract exists), sound events (○ SoundAnalysis), take boundaries (○ dvrescue `rec_start`), People-tab birth dates (✓), confirmed person tags (✓ Rick's). |
| What goes wrong | the same table every Christmas is an adversarial dataset for a model (the 10/16 review); a birthday song at a restaurant is someone else's birthday; "Happy Birthday" plays on a TV; a compilation tape holds three Christmases (a compilation has no single date, DECISIONS 2026-09-23). |
| Stays truthful | Events v2 gates: zero false equivalences, zero invented precise dates, ≥ 90 % category precision on the frozen set (DECISIONS 2026-10-12); membership never proves "covered"; the ordinal is shown only with all three witnesses named. |
| Grade | **now** for category and instance (more witnesses sharpen what exists); **one analyzer** (SoundAnalysis) for the acoustic anchors; the ordinal birthday is **one analyzer** (§3.1's age band) on top. |

### 3.3 Who filmed it — operator identification

**Rick's logic, kept.** Person Y is on screen in 5 % of a tape's clips but is heard continuously from zero distance (highest amplitude, least reverberation) → Y is the videographer.

**Corrected mechanism.** Rick already answers "videographer" once per tape in the provenance workflow (DECISIONS 2026-10-22). The corpus layer can *pre-answer* it: on a tape, the **near-microphone voice** (direct-to-reverberant ratio, amplitude, speech while the camera pans) is one anonymous speaker cluster; the people in frame are face tracks; the adult who is heard most and seen least is the proposal, named only through the roster (who was an adult in that year, who is known to have owned the camera — a tree fact), never through voice or face identity.

| | |
|---|---|
| Method | diarize (anonymous), compute per-speaker near-field score, cross with per-tape face-track presence; propose one operator per tape with "heard N min, seen M s, camera operator by exclusion". |
| Evidence needed | diarization (○), face presence per file (✓ detection), tape grouping (◐ Phase D `sameCarrier` from rdt ranges / folders), the roster (✓). |
| What goes wrong | a camcorder on a tripod has no near voice; two adults pass the camera; the near voice is a child holding it; wind. No published method does this for home video; it is a heuristic to measure on Rick's answered tapes first. |
| Stays truthful | it is one `inferred` `videographer` assertion per tape with the numbers; Rick's once-per-tape answer is the decision; the hit rate on already-answered tapes is reported before it is shown on unanswered ones. |
| Grade | **research** (needs diarization plus a measured near-field heuristic). |

### 3.4 Hardware lineage — which camera, which setup, over the decades

**Rick's logic, kept.** Cluster files by technical commonalities: Archetype 1 = 4:3, NTSC interlaced, 60 Hz hum, tape hiss (the 1990s camcorder); Archetype 2 = 640×480 progressive MJPEG AVI with Canon PowerShot MakerNotes (the early-2000s pocket camera). Cross with operators and years → the family's technology ownership over time.

**Corrected mechanism.** Most of this is deterministic and nearly free: the layer-1 vector (codec, frame size, PAR, scan, fps, audio rate/depth/channels, encoder string, make/model, DV flags) partitions the corpus into **capture setups** — exactly the `capture_setups` table of the provenance design ("one device chain, many tapes", ARCHITECTURE §10.5). PRNU would tie born-digital clips to one sensor but is marginal after compression and stabilisation (§1.5); for tape captures the "camera" signature belongs to the capture card, so the right word is *setup*, not camera.

| | |
|---|---|
| Method | group by the layer-1 vector (exact for born-digital, with tolerances for tape captures: same frame size + rate + scan + audio rate + encoder); order groups by their members' date bounds; name each group by its make/model when present, else by its signature ("DV 32 kHz 4-ch, 1996–1999"). |
| Evidence needed | all ✓ today (ffprobe cache, embedded origin tags); dvrescue flags (○) sharpen DV sub-groups; PRNU (○ research) for phones only. |
| What goes wrong | a transfer setup masks the camera (every July 2026 tape looks like the ClearClick); one camera in two modes (SP/LP, 12/16-bit) looks like two; an NLE export looks like a camera. |
| Stays truthful | a group is a `captureSetup` draft with its signature as evidence; the sheet shows the files; "camera" is said only with a make/model tag, otherwise "setup". |
| Grade | **now** (a deterministic job over the probe cache; the table it feeds is a designed migration that needs Rick's approval). |

### 3.5 Same room, same house — place as context

**Method.** The 8B's `roomFeatures` strings and a picture embedding per window; cluster windows across the corpus; a cluster that recurs over years is one place ("the house with the green shag carpet, 1988–1997"). Rick names it once; every member inherits the place label as `inferred`. Retrieval by example ("find windows like this one") is the lab's A4; the Related ladder may show it as a suggestion with a distance, never as lineage or a date (DECISIONS 2026-09-23).

**What goes wrong.** Two houses with the same beige carpet; a feature list that says "furniture, floor, wall" (the 3B's vocabulary was exactly that; the 8B's is specific); a rented cottage every summer is one place with no address.

**Grade: one analyzer** (the embedding, A4) plus **one hour of Rick** (≈ 50 place labels, lab §9 ruling 2) to measure precision@k ≥ 0.8 before it may suggest.

### 3.6 Re-recording detection — carrier newer than content

**Method.** Three independent witnesses per file: the *carrier floor* from layer 1 (DV = 1995+, HDV = 2003+, a phone container = 2007+), the *DV clock* (§1.4), and the *content era* from the pixels (the 8B, pixels only). When the content era is 10+ years older than the carrier or the clock, the file is a transfer of older footage: "re-recorded: content older than the carrier (DV clock 2001)" — DECISIONS 2026-11-01 says exactly this after Rick's review found both "wrong" DV dates were a 1965 film and a 1984 tape through a 2001 camcorder. Film cadence (§1.2) is a fourth witness for film.

**Grade: now** for the DV cases (the clock is measured, the era is in `provenance_assertions`); the rule is a deterministic join the catalog does not hold yet because the DV datecode is not in it (BACKLOG "DV rdt as a deterministic date bound").

### 3.7 Duplicate, excerpt and lineage graphs

**Method.** Identity by SHA-256 (✓); same recording by audio landmarks with offset (✓ Find Master, sound); picture timeline for silent footage (○ Phase B); `content_excerpts` rows per non-`different` verdict (○ Phase C1); the typed relations (copy, clip-of, re-encode, supersedes) with containment never giving direction (DECISIONS 2026-09-23). Over the corpus: a graph whose roots are the files nothing contains — the candidates for **Master** — which only Rick confirms (DECISIONS 2026-10-26: no file is a designated master yet). The 2026-11-01 finding that an archive `.vs.archive.mov` has no lineage row to its source `.dv` is the gap this closes (BACKLOG "To file (11/01)").

**Grade: now** for sounded footage; **one analyzer** (Phase B) for silent footage.

### 3.8 Continuous re-traversal — each pass sharpens the priors

**Rick's intuition, kept.** Loop over the corpus again and again; what the last pass learned narrows the next.

**Mechanism.** The helper already re-plans every 10 minutes and on every catalog generation change (§14.2), and every job skips digests its signer has already answered (§11). Re-traversal is therefore not "re-run the model"; it is **a deterministic propagation job** that runs after any commit: take every confirmed decision and every strong layer-1 bound, walk the relations (same recording, same tape, same take sequence, same cluster, same instance) and write tighter `inferred` windows where the chain allows, with the chain as evidence. It converges because each propagated window is at most as wide as its weakest source and a bound never widens. A new confirmation from Rick is what moves it; a new model is a new signer, whose rows sit beside the old ones (§4.4).

**What goes wrong.** Two machine guesses corroborating each other through a third (the circularity rule 2 above is the guard: a chain must bottom out in a decision or a layer-1 fact, or it is refused); priors that drift because a wrong confirmation propagates (every chain is reversible: reject the root and the derived rows go with it — the same shape as the purge relation, ARCHITECTURE §10.1).

**Grade: now** (the relations and bounds that exist today give a first propagation job; every §1–§2 row that lands adds an edge type).

### 3.9 Feasibility, in one table

| Corpus method | Grade | The one thing it needs first |
|---|---|---|
| 3.4 Hardware lineage / capture setups | now | nothing (deterministic over the probe cache); the `capture_setups` migration to store it |
| 3.6 Re-recording detection | now | the DV datecode in the catalog (reader + ranking ruling) |
| 3.7 Lineage graph, sounded footage | now | Phase C1 `content_excerpts` |
| 3.8 Propagation / re-traversal | now | the chain-carrying assertion job |
| 3.2 Event category and instance | now; ordinal needs 3.1 | SoundAnalysis for acoustic anchors; `occasionKind` run and judged |
| 3.5 Same place | one analyzer | the A4 embedding + 50 place labels |
| 3.1 Age trajectory | one analyzer | an age-band estimator calibrated on Rick's clips |
| 3.7 Lineage graph, silent footage | one analyzer | Phase B picture timeline |
| 3.3 Operator identification | research | diarization + a measured near-field heuristic |
| PRNU camera grouping | research | only for uncropped phone clips; never a date |

## 4. Analyzers as plugins and chains (the engineering execution matrix)

Rick's Part 4 asked for a tiered, asymmetric pipeline: cheap deterministic work on every file, expensive model work only where it pays, the model as the final "narrative engine". The tiers are right; two corrections, both rulings: the model is a **witness per file, not the narrator** (§10) — the narrative is the deterministic rulings and the propagation job (§3.8), and a text model may only *phrase* what Swift already proved (DECISIONS 2026-08-14, Hallie's rule); and the vision model is **never handed the technical summary** (DECISIONS 2026-10-31: told the codec, the 8B moved a 1965 film in DV to 1975–1985). The file's facts enter as deterministic *bounds* in the fusion step, after the model has answered. The tool names in the draft are replaced by the ones that hold the seats (Qwen3-VL-8B for era and OCR, not Qwen2.5-VL or Tesseract; Apple Vision + AdaFace for faces, frozen, not InsightFace).

### 4.1 What an analyzer is

One descriptor, the same shape for a model and for a deterministic engine:

| Field | Meaning | Today in code |
|---|---|---|
| `id` | `model/promptFamily/sampler` for a model (`qwen3-vl-8b-4bit/era-v1/window-60s`); `engine/recipe/sampler` for a deterministic one (`ffprobe/technical-v1/container`, `dvrescue/datecode-v1/head-120mb`, `soundanalysis/v1/whole-file`) | `ApproachID` (`ModelLab/ApproachRegistry.swift`) |
| `revision` | bumped on any prompt, parameter or recipe change; the prompt text is hashed into every run record | `ApproachDescriptor.revision`, `promptHash` |
| `host` | where it runs: in-process Swift (`.mlxSwift`, and a `.native` for Vision/SoundAnalysis/ffmpeg), a Python child (`.pythonWorker`), a local Ollama; `.remoteTextOnly` is the disabled cloud slot | `ApproachHost` |
| `accepts` | the payload classes it may be sent: `pixels`, `audio`, `derivedText`; rule 13 is the gate (`PayloadGate.check` throws before a byte reaches a transport) | `PayloadClass`, `PayloadGate` |
| `emits` | the field families it produces — `era, scene, ocrDate, ocrText, occasionKind, roomFeatures, carrierClues, spokenNamePresence` today; deterministic families to add: `technical, datecode, soundEvent, faces, prints, cuts` | `FieldFamily` |
| `resources` | peak RAM, needs the one resident model, seconds per unit | `ResourceProfile`; the helper refuses a job the Mac cannot hold (§14.2) |
| `signer` | `machine:<id>@r<revision>` — the `by` on every observation it writes | `ApproachDescriptor.signer`; the era job takes it from the worker's own load reply (`PythonClipWorker.LoadInfo.signer`) so the row says what actually ran |

**Inputs** are a *sampler plan* (which seconds, which frames, which audio range — `EvidenceSampler`, pure) plus the decoded material the job rips through the existing extractors; **outputs** are observations: `(subject digest, range, field, value, by, evidence JSON)` — `EvidenceAssertion`, pure and byte-stable. A deterministic analyzer's "contract" is its typed result; a model's is a fixed JSON schema per family that fails closed (`ContractDecoder`). **Swapping a model creates a new signer; old rows stay.** Two signers' rows for one file sit side by side in `provenance_assertions` and in the sidecar; the display rule picks the newest promoted signer per field (`MachineEraResolver` shows the newest era, others in the help); nothing is overwritten or deleted (the table refuses UPDATE and DELETE).

### 4.2 The chain notation

```
MEDIA_FILE → <analyzer 1 → analyzer 2 → … → analyzer N> → OBSERVATIONS → catalog (search · inspector · sheet)
```

An arrow between analyzers means "the left one's output is the right one's input". The seams are: a **sampler** (file → plan), a **decoder** (plan → frames / PCM; ffmpeg or AVFoundation, shared), a **witness** (frames or PCM → a contract-typed answer; a model or a native framework), a **fusion step** (answers + layer-1 bounds → one file-level observation; deterministic, in Swift), and the **journal → applier → catalog** road (§14.4). Rick's worked chain, as it runs tonight:

```
Christmas_1990.mov
  → ffprobe (technical-v1)                      → technical facts; a carrier floor "DV: 1995+" (a bound, not prompt text)
  → ffmpeg (rip 3 windows × 8 frames, 5 stills) → PNG frames in a temp dir
  → Qwen3-VL-8B-4bit (era-v1 r3, pixels only)   → era.yearRange per window with cues; ocr.date per still
  → Swift fusion (bench.py fuse_range today)    → era.fused "1989–1992" (a cited stamp year collapses the range)
  → journal (ObservationJournal) → JournalApplier → provenance_assertions (state inferred)
  → MachineEraStore → inspector "Machine era: 1989–1992 · 8B, unconfirmed" · Catalog Status convergence · search "1990s / early 90s"
```

And the sound chain the design names for step 4:

```
Christmas_1990.mov
  → ffmpeg (audio → 16 kHz mono PCM)
  → Whisper medium (MLX worker)                  → transcript; timed segments (once kept)
  → SoundAnalysis (.version1)                     → sound events with times: singing, applause, laughter
  → Events rules (deterministic)                  → occasion vote "christmas" with its cited witnesses
  → text model, local Ollama (derivedText only)   → the one-line wording of the proposal, verified against the witnesses (Hallie's composer rule)
  → journal → applier → provenance_assertions (occasion.kind, inferred) → Events (Triage) as a suggestion
```

### 4.3 The analyzers, as the registry would list them

| Analyzer (id) | Host | Accepts | Emits | Status | s/file (Ultra) |
|---|---|---|---|---|---|
| `ffprobe/technical-v1/container` | native | file | technical | ✓ (`metadata_cache.sqlite`), not yet a registered descriptor | < 0.1 |
| `sha256/fixity-v1/whole-file` | native | file | identity | ✓ Full Hashes cycler | read-bound |
| `audio-landmarks/v1/8khz-mono` | native | audio | prints | ✓ Sound Prints cycler (`AudioFingerprint`) | 2.5 per hour |
| `dhash/v1/32-frames` | native | pixels | prints | ✓ Picture prints (`PerceptualFingerprinter`) | decode-bound |
| `embedded-dates/v1/tags` | native | file | technical | ✓ Embedded Dates cycler | < 0.1 |
| `dvrescue/datecode-v1/head-120mb` | child process | file | datecode | ◐ script only (`scripts/dv_datecode.py`); not a cycler, not in the catalog | 0.2 |
| `qwen2.5-vl-3b-4bit/captions-v1/stills-5` | mlxSwift | pixels | scene, ocrText, ocrDate | ✓ in-app captioner (`CaptionRunner`); retires at step 2 | 5.2 |
| `qwen3-vl-8b-4bit/era-v1/window-60s` @r3 | pythonWorker | pixels | era, ocrDate (+ roomFeatures to the sidecar) | ✓ **seated**, the helper's era job | 7.0 |
| `whisper-medium-mlx-q4/transcribe-v1/whole-file` | pythonWorker | audio | transcript | ✓ Transcribe cycler | ≈ duration ÷ 10 |
| `vision/faces-v1/stills` + `adaface-ir50/embed-v1` | native (Core ML) | pixels | faces | ✓ built, recognition frozen | fast |
| `ffmpeg/idet-signalstats-v1/sampled` | native | pixels | carrierClues (measured scan, cadence, tape noise) | ○ | decode-bound, sampled |
| `soundanalysis/v1/whole-file` | native | audio | soundEvent | ○ | fast |
| `pyannote/diarize-v1/whole-file` | pythonWorker | audio | speakers (anonymous) | ○ | ≈ duration ÷ 15 |
| `mivolo/age-band-v1/face-tracks` | pythonWorker | pixels | faceAttributes | ○ | fast |
| `mobileclip2-s2/embed-v1/window-10s` | native (ANE) | pixels | vectors (sidecar) | ○ lab A4 | fast |
| `qwen3-vl-8b-4bit/occasion-v1/window-60s` | pythonWorker | pixels | occasionKind | ◐ contract exists; not run | 1.5 per window |
| `propagate/bounds-v1/catalog` | native | derived (catalog) | inferred windows with chains | ○ §3.8 | seconds per pass |

### 4.4 Adding one, swapping one

**Add.** Write the descriptor (id, revision 1, host, accepts, emits, resources, prompt or recipe hash) and register it; write the contract type and its fail-closed decoder (or the typed result for a native engine); give it a planner (which digests still need it — "no line by this signer yet", the caching rule of §11); declare it in the helper's schedule or as an Analyze cycler. The payload gate, the journal, the applier, the stamps, Catalog Status's counts and the search-word rule need no change: they read `by`, `field` and `value`. Rule 8's five test dimensions apply (logic · scale · media matrix · isolation · sensor) plus a truth test for whatever it shows, and the Judge's table in `docs/reviews/video_llm_benchmarks.md` if it is a model.

**Swap (8B → 32B, or r3 → r4).** Register the new descriptor; the planner sees every file as unanswered *by the new signer* and runs it oldest-first; the old signer's rows remain; promotion is one Judge verdict and one DECISIONS line (the 32B was benchmarked and parked this way, `machine_intelligence.md` Part II). Nothing is re-written; the inspector shows the newest promoted signer and names the others in its help.

**Recommendation on the classic analyzers.** Yes, put them in the same registry — as **descriptors first, engines later**. A descriptor costs tens of bytes and gives every analyzer one id, one revision, one signer and one `accepts` line, which is what the results sheet (§6) and the per-file dossier view need to list them uniformly. Do **not** refactor the cyclers or their stamps to do it: an engine moves into the helper and onto the journal road only as its step comes (§15), exactly as the era job did. KISS: one table, no new machinery; the `JobResourceProfile` / `ResourceProfile` unification already in BACKLOG is the one type merge this needs.

### 4.5 The tiers, corrected

```
[every live, readable file, oldest first]
   │
   ▼  Tier 1 — deterministic, every file, seconds      ffprobe · stat · embedded tags · SHA-256 · dvrescue · exiftool (probe pass)
   │                                                   → technical facts, carrier floor, DV clock, identity, capture-setup vector
   ▼  Tier 2 — decode once, cheap witnesses             ffmpeg rip (windows, stills, 8 kHz PCM) · sound prints · picture prints
   │                                                   · idet/signalstats (sampled) · SoundAnalysis · Whisper (timed) · Vision faces
   ▼  Tier 3 — the vision model, pixels only            Qwen3-VL-8B: era · ocr.date · ocr.text · scene · roomFeatures · occasionKind
   │                                                   (never told the codec; never a name)
   ▼  Tier 4 — deterministic fusion and propagation     Swift: stamp-fusion, carrier bounds, People-tab constraints, Events rules,
   │                                                   the chain-carrying propagation job (§3.8); a local text model phrases, never decides
   ▼  journal → JournalApplier → catalog                provenance_assertions (inferred) · captions · transcripts · sidecars
   ▼  Rick                                              inspector line · results sheet · Provenance sheet: confirm / correct / reject
```

Ninety percent of the work is tiers 1–2 and 4, deterministic; tier 3 is the only expensive step and runs once per file per signer.

## 5. Worked examples, end to end

Synthetic names; roles, never family names. Each line is `file → analyzers → observations → where Rick sees it`.

**5.1 `Christmas_1990.mov`** — a QuickTime-wrapped DV capture of a camcorder tape, 720×480 4:3, 32 kHz 4-ch audio, mtime 2003-02-11.

| Step | Analyzer | Observation (by) | Where it shows |
|---|---|---|---|
| 1 | ffprobe | dvvideo / 720×480 / 29.97 TFF / 32 kHz 12-bit; carrier floor "DV: 1995+"; mtime = transfer | inspector technical block; the bound feeds step 5 |
| 2 | dvrescue (○ today) | DV clock 1997-12-25 14:02 → 14:31, one take; rdt earlier than mtime by 6 y | "Recorded 1997-12-25 (camcorder clock)" once the reader lands; indexed as 1997 / 1990s |
| 3 | 8B, 5 stills | ocr.date "DEC 25 1997" on 4 of 5 stills | inspector Machine era help (frames, times) |
| 4 | 8B, 3 windows | era.yearRange 1994–1999 (cues: wood panelling, a CRT, a boxy camcorder look); roomFeatures "wood-paneled walls, patterned sofa" (sidecar) | — |
| 5 | Swift fusion | era.fused 1997–1997 (the stamp is cited in ≥ 2 windows and inside the range) | "Machine era: 1997 · 8B, unconfirmed"; Catalog Status convergence; search "1997", "90s" |
| 6 | Whisper + SoundAnalysis (○) | transcript "…open the big one first…"; sound events singing, laughter (whatever the built-in labels actually cover) | search by what was said |
| 7 | Events rules | occasion christmas, instance "1997-12-25", witnesses cited; the file name agrees (a weak witness) | Triage ▸ Events suggestion |
| 8 | propagation (○) | the DV clock agrees with the stamp and the era: the file is a recording, not a re-recording; its three siblings on the same tape take sequence get "1997-12-25 ± 1 day" as inferred | Provenance sheet, grouped by tape |

Rick confirms the date once; the archive filing by decade follows his decision, never the machine's.

**5.2 `tape07_capture.mxf`** — an Avid DNxHD MXF essence captured from a VHS in 2016, video-only; its audio half is the Avid op-atom sibling `tape07_captureA01.mxf`; the tape holds a 1984 birthday.

| Step | Analyzer | Observation | Where |
|---|---|---|---|
| 1 | ffprobe + the MXF parser | dnxhd 1920×1080 (a transfer codec: no era from it); the descriptor's label checked against the stream; A/V pair found by the Correlate cycler | pair shown; "DV 25" mislabels of this class are the BACKLOG item |
| 2 | Avid bin parser (◐) | tape name "VHS-07", clip name "bday 84?" — the editor's own words, a human organisation recovered | Provenance sheet: carrier draft "VHS-07", inferred |
| 3 | idet + signalstats (○) | interlaced underneath a progressive flag; TOUT/VREP bursts at 00:12 and 03:40 (dropouts) → "tape capture" | technical block: "analog tape capture (measured)" |
| 4 | 8B, pixels | era 1982–1988 (cues: hairstyles, a console TV); ocr.date none | "Machine era: 1982–1988 · 8B, unconfirmed" |
| 5 | re-recording rule (§3.6) | content era 30 y older than the container's 2016 → "transfer of older footage; carrier VHS (bin), capture 2016" | Provenance sheet |
| 6 | Whisper on the A01 half + SoundAnalysis (○) | "Happy Birthday" chorus (singing), "how old are you now — five!" | search; Events witness |
| 7 | Events + People tab | birthday; a child of five in 1984 → the roster yields one candidate; proposed as "Child A's 5th birthday (1984)?" with the three witnesses | Events suggestion; never a tag until Rick confirms |

**5.3 `IMG_0810.MOV`** — an iPhone HEVC clip, born digital, 2019-07-04, GPS present.

| Step | Analyzer | Observation | Where |
|---|---|---|---|
| 1 | ffprobe tags | `com.apple.quicktime.creationdate` 2019-07-04T21:14-04:00; make/model Apple iPhone XS; GPS; role born digital | inspector; embedded date; this file is analysed **last** (phone footage dates itself, §11) |
| 2 | SoundAnalysis (○) | fireworks, crowd | Events witness ("July 4th", with the date agreeing) |
| 3 | 8B | era 2015–2020 (agrees; the convergence line counts it) | Machine era line |
| 4 | hardware lineage (§3.4) | capture setup "iPhone XS, 2018–2020", 212 files | Provenance sheet, setups |
| 5 | lineage graph | an identical SHA-256 on the RAID and a re-encoded H.264 copy in a Messages export (audio landmarks match at offset 0) | Find Master / Cleanup: the copy may go, proven at the move |

**5.4 `reel3_super8.mkv`** — an FFV1 scan of a Super 8 reel, 1280×720, silent, 2024.

| Step | Analyzer | Observation | Where |
|---|---|---|---|
| 1 | ffprobe | ffv1 (transfer), no audio, 24 fps progressive | technical block |
| 2 | idet (○) | no pulldown (a native 24 fps scan): film cadence consistent with a frame-by-frame scan; **not** a telecine | "film scan (measured cadence)" |
| 3 | 8B | era 1966–1974 (cues: film grain, colour shift, cars) | Machine era line |
| 4 | picture timeline (○ Phase B) | 02:10–04:55 of this reel matches a 1998 VHS compilation's 11:30–14:15 at 1 s precision → the VHS is a *copy* of the film, not the other way (containment gives no direction; the carrier floor does: film < VHS) | Find Master (picture); lineage |
| 5 | propagation | the VHS compilation's segment inherits the reel's era as a bound; the compilation itself gets no single date (DECISIONS 2026-09-23) | Provenance sheet |

## 6. How Rick sees the machine intelligence

**Today's surfaces (all built, all read-only):**

| Surface | Shows | Source |
|---|---|---|
| Inspector, date block | "Machine era: 1991–1995 · 8B, unconfirmed", "disagrees with your date" when it does; help lists windows, frames, `by` | `Catalog/InspectorDateView.swift` (`InspectorMachineEraLine`), `MachineEraStore.shown` |
| Catalog Status | "Machine era agrees with your confirmed date within 5 y: N of M (p %)"; journal lines waiting / refused | `MachineEraStore.convergence`; `JournalApplier` counts |
| Search bar | the era's human words ("1990s", "90s", "early 90s", its years), never the range or signer (DECISIONS 2026-11-01) | `CatalogSearchIndex.ObservationLayer` |
| Totals strip | `● Content: 1,190 left to analyze` / `Analyzing N of M` (grey/blue, never yellow; DECISIONS 2026-11-03) | `CatalogStatusChip`, `AnalyzeCoverage` |
| Content Analysis / Settings ▸ Background | the checkbox, launchd's line, the helper's job line (kind, N of M, hold reason) | `ContentAnalysisSettingsRows.swift` |
| Menu bar item | Pause / Resume; why a kind is held | `BackgroundMenuPresentation` |
| `background.log` | START / OUTCOME per job, one line per try and per give-up with ffmpeg's own words | `BackgroundLogSink` |
| Hallie | nothing yet: "from the 90s" does not count machine eras (BACKLOG) | — |

**What is missing (and why it matters):**
- `era.none` and the three-try give-ups show **nowhere** in the UI; only the log has them (STATUS 11/04; BACKLOG 11/04 "results sheet"). Rick cannot answer "what did the helper do last night, and what did it fail on?" without reading a log.
- `roomFeatures` is produced on every window and lives in the sidecar only; nothing shows it.
- There is no **per-file dossier view**: every observation about one file, by signer, with its evidence, in one place. The inspector has one line (era); captions and transcripts have their own panes; prints and faces are invisible.
- There is no **inbox** for proposals (§3): the Provenance sheet (Phase C2) is designed for exactly this and not built.

**The smallest set of views (proposal; Rick decides the workflow and the look):**
1. **Content Analysis ▸ Results sheet** (BACKLOG 2026-11-04, Rick's words): per analyzer, counts by outcome — found · none · gave up (with the reason) · still to do · agrees with your date within 5 y — and a clickable file list per outcome. Read-only; built from `provenance_assertions`, `EraAttemptStore` and the journal's refused count. This is the "what did it do" view.
2. **Inspector ▸ Observations** disclosure group: one line per observation on the selected file, grouped by family, each with its signer and an evidence pop-over (windows, frames, cues, chain) — the Machine era line generalised; `roomFeatures`, sound events and DV clock appear here the day they exist. This is the per-file dossier.
3. **Provenance sheet** (Phase C2, designed): the inbox — every `inferred` row grouped by tape or by file, confirm / correct / reject in one click, the veto remembered. This is where §3's proposals go and where Rick's attention, the scarce resource, is spent.

Not proposed: a dashboard of model metrics (the convergence line and the benchmark page are enough), a machine-date filter (ruled out until the convergence number has been read, DECISIONS 2026-11-01), per-file confidence percentages (no calibration, no number).

## 7. Recommended next three steps, and open questions

**Next three (in order of proof per hour; each is one branch with the five test dimensions):**
1. **Results sheet** (§6 view 1). It makes everything the helper does visible, including `era.none` and the give-ups, before any new analyzer is added. No schema change.
2. **DV datecode into the catalog** (§1.4; BACKLOG "DV rdt as a deterministic date bound"): a `dvrescue` analyzer in the helper, `datecode` observations through the journal, shown as "Recorded <date> (camcorder clock)", the re-recording rule (§3.6) as a deterministic join. The biggest free dating win (297 dated files measured; 231 earlier than their mtime). Needs Rick's ranking ruling (already stated in DECISIONS 2026-11-01; the `inferred_dates` seat is the open part).
3. **SoundAnalysis + timed Whisper segments** (§2.2): two cheap, native, local analyzers that give Events its acoustic anchors and the `spokenNamePresence` family its clock, and register the first two deterministic descriptors in the registry (§4.4). Then the propagation job (§3.8) over what exists.

**Open questions for Rick (one line each; workflow, UI and policy are his):**
1. May a machine era, DV clock or propagated window ever enter `inferred_dates` / the triangulator / a filter, and when (DECISIONS 2026-11-01 defers this to "after a few weeks of the convergence number")?
2. Song identification sends an audio fingerprint to AcoustID or Shazam: allowed under rule 13 (it is derived from audio that carries family voices), or local-only (presence of music, no title)?
3. Diarization and face-attribute estimation produce anonymous clusters and age bands: is "anonymous clustering, never a name" an acceptable use of the frozen recognition machinery, or does the freeze cover clustering too?
4. The 50 place labels for same-room retrieval (lab §9 ruling 2): an hour of your time now, or after the results sheet?
5. Where does the per-file dossier live — the inspector (view 2), a separate Dossier window, or the Provenance sheet alone?
6. The `capture_setups` / carrier migration (§3.4 needs it to store setups): approve it next, or keep setups as sidecar drafts until the Provenance sheet exists?
7. The ~40 code comments in `Core/Background` that cite the old section numbers ("design §3.4"): sweep them in one code commit (sensor lane), or keep the old → new map at the top of this file?

---

# Part B — The service: VideoScan Background, the design as built

*The design as written on 2026-10-30, with §9–§11 added 10/30–10/31 (Rick said "design it"); the italic note below is its original preface.*

*Rick said "design it" on 2026-10-30: "The app is essentially the UI/UX… peel off services into a BG process that
can keep running, persist after we quit the app… I don't like the idea of having an option to launch the app in the BG but I am open to these trade-offs… we can't
lose the app for 2 weeks while we completely refactor it into a front-end backend." This is the VideoScan answer.
It builds on `docs/design/machine_intelligence.md` (the first job the service hosts) and ARCHITECTURE §4 (MFO,
Analyze cyclers, the one commit door). Steps 0 and 1 are built (§15).*

## 8. In one page

### Responsibilities of the Background Service (Rick, 2026-10-30)
The VS BG Service is responsible for continuous Content Analysis of the media. The service is constantly analyzing the media, 
metadata, dates, times, and gleaning as much as it can from the media, the metadata, and the catalog so it can
populate "observations" or "derived machine-generated" information into the app to help the user so when the user searches for
something, the app has this information. It is like a family archivist working 24x7 to understand patterns, connections, and what is where.

INPUTS: all media files + catalog database + all metadata + any new machine generated observations (provisionally within reason)
OUTPUTS: machine generated intelligence all about the media
GOAL: Anything in the content analysis window, audio transcripts, Sound fingerprints, Date Inference, Provenance Estimation, Scene Captions, etc.

Question for Claude: clarify where the observations and machine generated intelligence is stored, since you said the catalog is open read-only, 
how does machine generated intelligence get into the app and persist and be searchable?

**Claude's answer (2026-10-30).** Two stores, one road into the catalog:
- **Bulk observations** — sound prints, picture prints, every raw model output, embeddings, timed transcript segments — live in
  **sidecar SQLite files the service owns** (`model-lab.sqlite`, `audio-fingerprints.sqlite`, `picture-prints.sqlite`), exactly as
  the audio fingerprints do today. The app reads them directly (Find Master, Related, the model lab); they never pass through the catalog.
- **Catalog-bound facts** — a scene caption, a transcript, an inferred date, an era claim, a provenance assertion — are written by the
  service to an **append-only journal** (`background/journal/*.jsonl`, one line per fact, keyed by content digest). The app's one
  committer **applies** the journal into the real catalog tables (`captions`, `transcripts`, `inferred_dates`, `provenance_assertions`)
  at launch and every few minutes while open, through the same commit door as every other write. From then on they are ordinary rows:
  search, Hallie, Catalog Status and the Provenance sheet all see them, with `by = background:<job>@<version>` and their evidence.
- **Lag and visibility.** A fact the service produced while the app was closed is searchable the next time the app opens; Catalog
  Status shows "N journal lines waiting / M refused" so nothing is invisible. Refused lines (an archived row's name or date — rule 3;
  a value Rick already rejected — the veto trigger) are kept with the reason, never dropped. Rejected: the service writing the catalog
  itself when the app is closed — two writers on one catalog is the bug class that cost us twice (`fix/committer-lost-writes`); the
  journal keeps one committer. Revisit only if the lag is felt.
- **Observations as inputs.** Yes: once applied, an era claim feeds `DateTriangulator`, a confirmed event feeds example memory, a
  place signature feeds retrieval — with one standing rule: **no circular corroboration** — a derived fact never supports the inference
  that produced it (`events_design.md` §1 rule 6), and a machine fact never outranks a human one.
- **"Constantly analyzing."** The Analyze cyclers — the staleness rule that decides which file needs captions, transcript, prints or a
  date pass next — move into the service (§15 step 4) and run continuously under backoff; the service keeps itself busy without being
  told, and the app or the nightly may still enqueue specific jobs. §9 below is amended to say so.

1. **One helper app inside the app bundle, registered as a launchd agent** through Apple's `SMAppService`:
   `VideoScan.app/Contents/Library/LoginItems/VideoScan Background.app`. Its own name and badged icon in Activity
   Monitor and in System Settings ▸ Login Items; launchd starts it, restarts it if it dies, keeps it alive after the
   app quits and across reboots. This is the macOS best practice for "work that outlives the window" (Apple's
   "Updating helper executables from earlier versions of macOS", `SMAppService.agent(plistName:)`). It is **not** a
   copy of VideoScan launched in the background; Rick ruled that out.
2. **The service never writes the catalog.** It reads it read-only (the schema-13 read-only door), writes its
   results to **sidecar SQLite files and an append-only journal**, and the app's one committer applies the journal
   when the app is next open. The one-committer rule (hard rule 6) is untouched; there is still exactly one process
   that can write `catalog.sqlite`.
3. **One engine per action is kept by moving engines, not copying them.** An engine lives in the app *or* in the
   service, never both. The order of the move is the order of value: the model lab (new, so it is born in the
   service) → Scene Captions → sound and picture fingerprints → the rest of Content Analysis → Event Analysis.
   The app keeps working at every step; a job that has not moved yet still runs in-app as today.
4. **The app is the window onto the service.** Jobs in the service appear in the same MFO list as in-app jobs, with
   the same row (verb, N of M, current file, Pause/Stop). Control and progress go over **XPC**; durable state (queue,
   checkpoints, journal) is on disk so a crash of either side loses nothing. With the app closed, Activity Monitor
   and a one-line CLI (`videoscan-bg status|pause|stop`) are the window.
5. **It runs whenever there is work (2026-11-04, replacing "it backs off while Rick works").** No keyboard or
   trickle backoff: the worker child runs at utility QoS, so interactive apps win the CPU and the performance cores
   stay reachable. Only the Mac's own thermal and memory pauses, Pause in the menu bar, or a hold after a failure stop
   it. A Speed control is deferred until Rick sees interference. Every job declares its RAM and whether it needs the
   one resident model; the service refuses to start a job the Mac cannot hold.
6. **Cost Rick pays once:** the helper is its own bundle, so macOS asks for Full Disk Access (and removable-volume
   access) for it once; signed with Rick's Apple Development identity (DECISIONS 2026-11-03, replacing "VideoScan Local" of 10-28) so the grant and the launch constraint survive rebuilds. One
   grant, one time, is the price of its own name and lifecycle; the single-binary alternative (§13 option B) shares
   grants but is the design Rick does not want.

## 9. Statement of responsibility (Rick, 2026-10-30: "good SW design requires clear responsibilities")

**`VideoScan Background` is a persistent container.** It keeps analysis engines running when the VideoScan window is
not open. It owns no analysis logic of its own.

| It is responsible for | It is not responsible for |
|---|---|
| Staying alive across app quit and reboot while registered (launchd KeepAlive; no idle exit since 2026-11-04) | Any user interface; it has no windows and draws nothing |
| **Its own schedule** (2026-11-04): planning each scheduled kind at launch, every 10 minutes and when the catalog generation changes; running jobs one per lane with checkpoints; holding a kind whose job failed | Owning the *rule* that decides what is stale (that is the job's planner, in the engine library). The app enqueues nothing; the CLI may still `--enqueue` / `--run` by hand |
| Hosting engines from the libraries (`VideoScanCore`, `VideoScanEngine`) and loading at most one resident model | Containing an engine's logic; an engine that needs the service must first live in a library with its own tests |
| Thermal and memory pressure (pause); utility QoS for the worker | Energy backoff while Rick works (removed 2026-11-04) |
| Writing results to sidecar stores and the append-only journal, with START/OUTCOME in `background.log` | **Writing the catalog**, ever; the app's one committer applies the journal |
| Reading media and the catalog read-only | Moving, renaming, deleting, trashing, re-encoding or promoting media (data-risk verbs stay in the app, with Rick present) |
| Answering XPC `status/enqueue/pause/resume/stop` from a signed VideoScan client | Trusting any other client; and it never initiates contact with the app |
| Refusing in words what it cannot do (RAM, missing weights, newer sidecar schema, unsigned caller) | Guessing, repairing, or coercing |

C++ reading: a daemon that owns a thread pool and a work queue and dynamically hosts plug-in libraries behind one
interface; the plug-ins carry the knowledge, the daemon carries the lifetime.

### The direction this sets: libraries, not folders

Today VideoScan is one app target (~700K lines organised by folder) plus one library (`VideoScanCore`). Folders are
not modules: the compiler sees one module and anything may call anything; `VideoScanModel` (one object, ~90
published properties, ~133 extending files) is the hub of the coupling. The target is **the UI/UX app plus a library
per functional group** — in C++ terms, static libraries with narrow headers:

| Library | Holds | Status |
|---|---|---|
| `VideoScanCore` | pure types, catalog store and commit door, fingerprints, date triangulation, GEDCOM graph | exists |
| `VideoScanEngine` | media reading (ffmpeg/AVFoundation wrappers), captioning, transcription, model-lab approaches, sidecar stores, `LogSink` | new; filled one engine at a time as each moves into the service |
| `VideoScanBackground` | the container of this design | new |
| later: `VideoScanEvents`, `VideoScanProvenance`, `VideoScanFamilyTree` | the domain engines behind those tabs, each with its own tests | as #337 splits `VideoScanModel` |
| `VideoScan` (app) | SwiftUI, feature stores, the one committer, the data-risk verbs | shrinks |

The service is the lever: an engine can only move into the container if it imports no SwiftUI and touches no
`VideoScanModel`, so every move extracts a library first. Not everything at once ("no way"); every increment in
this direction, each one compile-proven, test-proven and merged.

**What this does to the grades (honestly).** CCN is per function: extraction alone does not lower it. What
modularization lowers directly is coupling (the `extension VideoScanModel` count, imports per file, fan-in/out) and
build time, and it raises testability. CCN falls when the untangling that extraction forces splits long functions —
a consequence to measure, not assume. The metrics page should carry a coupling figure beside CCN so the refactor
shows in the number it actually moves (BACKLOG).

## 10. What goes in, what comes out, and why (Rick, 2026-10-31, after the first review session)

**The goal, in Rick's words:** make the corpus easier to search and organize. Estimate dates over the whole corpus; a date within
2–3 years is valuable; "find all the videos down the Cape from 1990–1995" answered 90 % right is a win. Then the same for places,
events, people. The service's job is to produce that intelligence in bulk, file after file, so Rick never dates by hand again.

**On confidence.** A 95 % percentile per file is overkill and would be invented: the model's own confidence number is not calibrated.
What we need is a **calibrated claim**: a range (or a year ± n) plus the *measured* hit rate of that kind of claim on the confirmed
set. "Era 1990–1995, kind of claim right 80 % of the time on Rick-dated files" is honest and is enough for a 90 %-right search when
the search also uses the file's own facts. The Catalog Status line "machine era within 5 y of your confirmed date: N of 73 (p %)" is
that calibration, read week over week. Today (25 Rick-dated clips, 8B, pixels only): midpoint within 5 y on 20 of 25; the model's
ranges are padded (15–20 y wide on 9 of the 13 misses) — a prompt/contract problem, not a model problem; midpoint ± 5 is the usable claim.

### Inputs — what the machine can look at

| Layer | Facts | Have / not yet |
|---|---|---|
| Container & metadata | container, duration, size, creation vs modification dates (file system, `mvhd` creation time since 1904, EXIF `DateTimeOriginal`), encoder string, device make/model, GPS, orientation, timecode track, chapters, **DV datecode** (per-frame recording date/time on DV) | most read; `exiftool` fields and the DV datecode **not yet** |
| Video technical | codec, profile, bit depth, chroma, color primaries/transfer, frame size, PAR/DAR, frame rate, scan + field order, **3:2 pulldown (film detector)**, GOP, bitrate, grain/noise, letterbox geometry, VHS head-switching noise, film gate weave | first group read; signal-level ones **not yet** |
| Audio technical | codec, channels, sample rate, bit depth, loudness, dual-mono vs stereo, **mains hum (ENF)**, hiss floor, dropouts | first group read; ENF **not yet** |
| Picture content | scene cuts, shot length, camera motion, exposure/white balance, color cast, camcorder OSD date/time, on-screen text, faces, people, clothing, objects, cars, signage, room features, weather, season, time of day | OCR, captions, faces, era (8B); cuts and signal stats **not yet** |
| Audio content | transcript, speaker identity, spoken names, music (a song = a lower bound on the date), ambient sound, language | transcripts; speaker similarity in BACKLOG |
| Identity & provenance | whole-file SHA-256, perceptual video hash, audio fingerprint, **PRNU sensor noise (the physical camera)**, edit signatures | hash + audio fingerprint; perceptual hash and PRNU **not yet** |
| The catalog and Rick | confirmed dates, people tags, places, occasions, archive decisions; earlier machine observations | read; **no circular corroboration** (a derived fact never supports the inference that produced it; a machine fact never outranks a human one) |

### Outputs — machine-generated intelligence, where it lives, what it unlocks

| Output | How it is made | Store | Unlocks |
|---|---|---|---|
| **Era / date claim** | 8B vision model, windows + contract (A2); fused with the file's facts as bounds (codec/carrier floor, stamp read, DV datecode, metadata on camera-native files) | journal → `provenance_assertions` (v14) only — never `inferred_dates`, the triangulator or a filter (DECISIONS 2026-11-01) | its own inspector line; the convergence count; search by era words ("90s"); a date only if Rick later rules |
| Burned-in date (OCR) | 8B `date` prompt on 5 stills | journal → `provenance_assertions` (`ocr.date`, step 1) | exact dates on camcorder footage, once Rick rules how they rank |
| Scene captions, on-screen text | 8B `scene` / `text` prompts (the captioner moves to the 8B) | journal → `captions` | free-text search |
| Transcript, spoken names | Whisper; name presence | journal → `transcripts` | search by what was said; people |
| Room / place signature | `roomFeatures` contract → signature over the corpus | sidecar (vectors) + journal (place label once ruled) | "find the Cape house"; events |
| People presence | face pipeline + Household Roster filter + Rick's confirmations | `people` stores (separate by design) | "find Donna" |
| Events / occasions | **rulings over the above** (same date window + same place + same people + same audio print), never a model | `events` | "Thanksgiving 1984" as a folder |
| Duplicates / same footage | SHA-256, audio fingerprint, perceptual hash | catalog + `audio-fingerprints.sqlite` | let copies go safely; link transfers |
| Provenance | carrier, device chain (PRNU, encoder strings), transfer chain | `provenance_assertions` | which file is the master; what a date means |

The service produces the per-file rows; **conflation is deterministic**, in the rulings and the triangulator, auditable and tested.
The model is a witness per file, not the organizer.

### Forensics, read for our scale (Rick's guide, 2026-10-31)

Rick's guide (`audio_video_digital_forensics_guide.pdf`) is court-oriented and single-file. What transfers to hundreds of files:
- **The checklist is our rule set:** never one timestamp (the triangulator weighs every source); map to UTC (every stored date carries
  its zone); audit for "timestomping" — for us the benign version, **transfer versus content**: a 2003 file holding 1984 footage is
  the normal case, not an attack, and the output must say which date is which.
- **ExifTool** beside ffprobe for `DateTimeOriginal`, `mvhd` creation time (seconds since 1904, a classic off-by-66-years trap),
  encoder signatures: cheap in bulk, worth a probe pass over the corpus. **DCode-style epoch decoding** matters only for odd containers;
  ffprobe already normalises the common ones.
- **Amped / Axon / Magnet / Belkasoft** reconstruct one timeline from one file for a courtroom; nothing in them beats ffmpeg + Python
  for bulk, and their proprietary-DVR strengths do not apply. **VideoCleaner**'s tamper checks do not apply.
- **Beyond the guide, the cheap date sources, checked the same evening** (lab design §11; research pass + a probe over the corpus):
  - **ExifTool / container dates — first, hours.** `QuickTime:CreateDate` / `MediaCreateDate` / `TrackCreateDate`, iPhone's
    `Keys:CreationDate` (local time with offset, the best phone field), `Matroska:DateUTC`; always `-api QuickTimeUTC=1`; a 1904 or
    zero value is unset; a date equal to the file's mtime is the transfer, not the recording. One-day test: tabulate every date field
    against mtime over the corpus and count the files with real evidence.
  - **DV datecode — yes, a day.** It lives in the DV frames (VAUX/SSYB), survives a stream copy into .mov/.mkv, and is lost by any
    re-encode (FFV1, ProRes, H.264). ffprobe does not read it (a raw .dv shows only the timecode). **Probe tonight:** MediaInfo finds a
    `Recorded_Date` on 5 of the 51 DV clips, all 2000s camcorder captures wrapped in QuickTime, and the year matches the file's own
    date 4 of 5 (one Dec 21 vs a Jan label — the boundary case); the ten raw `.dv` captures from the 1990s show a subcode timecode
    but no date in the frames MediaInfo reads — either the camcorder clock was unset or the date appears later in the tape. Next:
    `dvrescue` (MediaArea; needs a Brewfile entry and Rick's install) reads the datecode per frame and would settle it.
  - **Mains hum (ENF) — dropped.** No public US 60 Hz reference exists for 1985–2010 (FNET/GridEye starts ~2004 and is not open in
    bulk); battery camcorders with AGC, music and speech rarely carry a usable hum; tape transfers add wow and flutter.
  - **PRNU camera fingerprint — grouping only, later.** Compression, stabilization and scaling weaken it; interlaced SD DV is marginal;
    analog transfers carry the capture card's pattern, not the camera's. It yields a cluster, never a date; worth a try only for
    grouping uncropped phone clips from one phone.
  - **3:2 pulldown as a film detector — untested**, still worth a day.

**Step 1, as built (DECISIONS 2026-10-31; merged 2026-11-01):** the 8B era/OCR job first, with schema v14; captions second (§15).
§18 ruling 4 answered; 2 and 3 take the defaults unless Rick says otherwise.

## 11. Where the machine intelligence lives, and what to call it (Rick, 2026-10-31 evening)

**Name: observations** (glossary: `docs/ARCHITECTURE.md` "Terms"). Rick's own word in §8 ("populate observations or derived machine-generated information"). A fact Rick set is a
**decision**; a fact a machine produced is an **observation**. Not "meta-metadata" (it describes the footage, not the metadata) and
not "machine intel" (it sounds like it reasons; it records). Every observation carries who made it (`by = engine@version`, the model
and prompt hash for a model), when, and its evidence; a decision always outranks an observation; an observation never supports the
inference that produced it.

**Where (three homes, see `docs/design/data_organization_2026_10_31.md` — the full table-by-table map, also rendered as a PDF for Rick):**
1. **`catalog.sqlite`** — observations that have earned a seat, as ordinary rows beside Rick's decisions: `captions` / `caption_runs`,
   `transcripts`, `inferred_dates` (range, confidence, source, reason — never the 8B's era, DECISIONS 2026-11-01), `dossiers`, `sound_prints` / `perceptual_prints` stamps,
   `footage_likeness` / `footage_membership`, `duplicate_*`, `media_checks`, and (v14) `provenance_assertions`. They get there only
   through the app's one committer, from the helper's journal. Searchable, backed up, fixity-checked, never deleted.
2. **Sidecar stores** the engines own, regenerable bulk the app reads directly: `audio-fingerprints.sqlite` (landmarks),
   `model-lab.sqlite` (every raw model output with run, model and prompt hash; segments; vectors; append-only by trigger),
   `metadata_cache.sqlite` (the ffprobe cache, keyed by path + size + mtime).
3. **The helper's files** (`background/queue`, `checkpoints`, `journal/*.jsonl`): work in transit, atomic publish, append-only journal.
`.scratch/` is the lab bench: per-clip bench records, frames, Rick's review verdicts; thrown away, never in git.

**Rick's priorities that shape the analyzer (2026-10-31):** the valuable years are **1960–2010, before the phone**; the older the file, the
more valuable, so the analyzer walks **oldest first** (by the best date bound it has) and modern phone footage last — its own
metadata dates it anyway. The People tab's **birthdays, sex and descriptions** are constraints the machine must use: a baby walking for
the first time and a birthdate in the roster bound a file to a window (constraint propagation — also in Rick's architecture note);
a known hair colour or build narrows a face match. The Household Roster (A7) is that filter.

**On caching, since Rick asked:** observations keyed by content digest are never recomputed for an unchanged file — the captioner
skips a digest with a `caption_runs` row for the same model, transcripts and prints likewise. The ffprobe cache is keyed by path +
size + mtime, so a move or a touch re-probes (cheap, by design). Verify and fixity verbs re-hash on purpose: that is their job. If an
MFO verb visibly repeats work on unchanged files, that is a bug against this rule and should be named (BACKLOG, "MFO verb repeats").

## 12. Purpose, in Rick's terms

Rapid dev means the app is started and stopped all day. Every start kills the captioner, the fingerprint backfill,
the model lab run. The Macs sit idle all night with 96 GB and 64 GB of RAM. The work that absorbs the family media
(captions, transcripts, fingerprints, era guesses, event evidence) should keep running whether or not the window is
open, should be visible and stoppable from outside the app, and should never risk the catalog. The app becomes what
Rick says it essentially is: the UI/UX, plus the one committer.

## 13. Options weighed

| Option | Survives quit | Own name/icon | Permissions | Code sharing | Verdict |
|---|---|---|---|---|---|
| **A. Helper app in the bundle, `SMAppService` login-item agent** | yes (launchd `KeepAlive`) | yes | one extra FDA grant, once | links the same Core + a new engine target | **Chosen.** Apple's current pattern; survives reboot; user-visible in Login Items; sandbox-free like the app. |
| B. Same binary, `--background` mode (today's `--find-tag` shape) | yes if detached | no — shows as "VideoScan" twice | shares the app's grants | trivial | Rejected by Rick (10/30). Also fragile: spawned-detached processes are not supervised; #395 turned the Find Tag daemon off for this. |
| C. XPC service inside the bundle (`Contents/XPCServices`) | **no** — dies with the app | no | shares | trivial | Wrong lifetime. |
| D. LaunchDaemon (root, `/Library/LaunchDaemons`) | yes | yes | runs outside the login session: no TCC grants for user media, no Vision/CoreML context, wrong user for App Support | hard | Wrong user. |
| E. Separate app (second `.app` in /Applications) | yes | yes | one grant | separate target | Same as A with a worse install story (two things to copy, two signatures to keep in step). A keeps it inside one bundle. |

Option A, with one honest caveat: `SMAppService.register()` makes macOS show a "VideoScan added items that can run
in the background" notification and the item appears under Login Items; Rick can switch it off there at any time,
and the app must read `SMAppService.status` and say so in Settings instead of assuming.

## 14. Shape

```
  VideoScan.app (UI/UX + the one committer)                 VideoScan Background.app (launchd agent, same bundle)
  ┌─────────────────────────────────────────┐   XPC         ┌──────────────────────────────────────────────┐
  │ MFO window ── BackgroundJobsClient ─────┼──control/───▶ │ JobSupervisor ── one job at a time per lane   │
  │ Settings ▸ Background (status, on/off)  │◀──progress──  │  ├ ModelLabJob (A0…)                          │
  │ CatalogCommitter ◀── JournalApplier ◀───┼── files ──────┼──┤ CaptionJob · FingerprintJob · …            │
  └─────────────────────────────────────────┘               │  └ Schedule + holds; thermal/memory pause    │
            │ read/write                                    │ writes: sidecars/*.sqlite · journal/*.jsonl   │
            ▼                                               │ reads : catalog.sqlite (read-only door), media│
     catalog.sqlite  ◀────────────────── read-only ─────────┘ logs  : ~/Library/Logs/VideoScan/background.log│
                                                            └──────────────────────────────────────────────┘
```

C++ reading: the service is a separate process hosting a `JobSupervisor` (a work queue with one worker per lane);
`BackgroundJobsClient` in the app is a proxy object over an `NSXPCConnection` (think CORBA stub, but typed by a
Swift protocol); the journal is a write-ahead log the app replays into the catalog under its existing transaction.

### 14.1 Targets

| Target | Kind | Holds |
|---|---|---|
| `VideoScanCore` (exists) | SwiftPM | pure types, store, commit door, fingerprints, triangulator — unchanged |
| **`VideoScanEngine`** (new) | SwiftPM or framework | engine code that both processes need and that today lives in the app target without `VideoScanModel` coupling: `CaptionRunner`, `extractFramesForCaptioning`, `ProcessRunner`/ffmpeg wrappers, `LogSink`, the sidecar stores, the model-lab types. Moved file by file, each move a compile-proven no-behaviour-change commit. Nothing in it may import SwiftUI or touch `VideoScanModel` (a sensor greps for it). |
| **`VideoScan Background`** (new) | macOS app target, no windows, `LSUIElement`, `LSBackgroundOnly` | `main.swift` (NSApplication `.prohibited`, like `--find-tag`, because Vision/CoreML/MLX need an app context), `JobSupervisor`, `XPCListener`, `Backoff`, the job types |
| `VideoScan` (exists) | app | adds `BackgroundJobsClient`, `JournalApplier`, Settings ▸ Background; **removes** each engine as it moves (rule 4) |
| `videoscan-bg` | small CLI (in `swift_cli/`) | `status`, `pause`, `resume`, `stop`, `enqueue <job>`; talks XPC; used by the nightly and by Rick with the app closed |

### 14.2 Lifecycle

- **Registration.** The Settings checkbox (Release build, catalog master only) calls
  `SMAppService.agent(plistName:).register()` / `unregister()` and nothing else. The plist (in
  `Contents/Library/LaunchAgents/`) declares `MachServices`, `RunAtLoad`, `KeepAlive {SuccessfulExit: false, Crashed:
  true}`, `ProcessType: Interactive`, `ThrottleInterval 10`, `ExitTimeOut 30` (sources and reasons:
  launchd.plist(5); `.scratch/helper-schedule-bp.md` at the time of the change). `Background` and the unspecified
  `Standard` type both throttle CPU and I/O; the priority comes from QoS instead.
- **Resident while registered (2026-11-04, replacing "on demand, exit when idle").** `register()` bootstraps the
  agent at once and at every login. A crash or an error exit restarts it (throttled to one spawn per 10 s). A clean exit 0
  (SIGTERM from `unregister()` or logout) leaves it down, so off means not running. There is no idle exit.
- **A plist change needs a re-registration.** `SMAppService.h` says to re-register when the plist or the executable
  changes, and to unregister first if the executable changed. The app does not do this automatically, so after an
  update that changes the plist, Rick unticks and re-ticks the checkbox once.
- **The schedule.** `JobSupervisor` with a `JobSchedule` (`JobSchedule.swift`): every 30 s it reads the catalog's
  `generations.generation` through the read-only door. It plans at start, every 10 minutes and on a generation change.
  For each scheduled kind with no active job and no hold, it asks the planner for the plan size (the job's own planner;
  EraPlanner for era), reports that size in `ServiceStatus.planned`, and enqueues a job when the plan is not empty.
  It runs only while it owns the state root (StateRootLock).
- **Failures hold.** A scheduled kind whose job ends `.failed` is held in `background/holds.json`:
  - after `failFastUnits = 5` identical systemic failures;
  - when every unit failed, whatever the cause ("nothing written");
  - after a START or admission refusal.

  The hold survives a restart and is released by Resume on its menu line, by a new build (the executable's size and mtime), or by new work. New work means the plan size differs from the first plan measured after the hold. A catalog commit that adds no work does not release it. (Fable review 2026-11-04: failure words carry a stderr tail that differs per spawn, so no words-based rule is stable.) A release drops the kind's old work item and plans one fresh job. The menu bar and Settings say why. This answers Codex #232 F4.
- **Pause** from the menu bar is kept per kind in `background/paused.json`. A restart adopts the job still paused, and Resume clears it.
- **Only the helper enqueues a scheduled kind.** XPC and the CLI refuse `era`, and the CLI keeps `--run era` for hand runs. A queue file goes with its job's OUTCOME.
- **Crash loops.** Before each unit, the checkpoint records that unit as in flight. A unit found in flight at 3 relaunches is quarantined: counted failed, skipped, and logged. A clean SIGTERM (unregister, logout) clears the mark first, so it never counts. The failure streak lives in the checkpoint, so the verdict survives a relaunch.
- **An older helper is said.** `ServiceStatus.build` names the running build. When it differs from the helper bundled in the app, Settings says "running an older build" with both build dates and offers Restart (2026-11-09: the checkbox became a heading with Start / Stop / Restart; Stop means off until Start).
- **Full Disk Access (note, 2026-11-04).** DTS (forum threads 694948, 661178) says TCC treats the containing app as
  the responsible code for a helper embedded in it, so the grant is the app's. This is not verified on the Ultra; the
  §8 point 6 wording stands until it is.
- **One resident model.** The service owns the "one resident MLX model" rule that `CaptionRunner` enforces today;
  the app no longer loads a VLM at all once Scene Captions has moved. A job's `ResourceProfile` (peak RAM, needs
  resident model, s/unit) is checked against `ProcessInfo.physicalMemory` minus a reserve before START.

### 14.3 Control and progress: XPC

One protocol, versioned, in `VideoScanEngine`:

```swift
@objc protocol BackgroundServiceXPC {
    func status(reply: @escaping (Data) -> Void)                       // ServiceStatus (jobs, lane, backoff state, version)
    func enqueue(_ request: Data, reply: @escaping (Data) -> Void)     // JobRequest → JobID or refusal (words)
    func pause(_ id: Data, reply: @escaping (Bool) -> Void)
    func resume(_ id: Data, reply: @escaping (Bool) -> Void)
    func stop(_ id: Data, reply: @escaping (Bool) -> Void)
    func subscribe(progress endpoint: NSXPCListenerEndpoint)           // app hands the service a callback endpoint
}
```

Payloads are `Codable` structs serialised to `Data` (one serializer, versioned with a `schema` field; a mismatch is a
refusal in words, like the catalog's). The service checks the caller's code signature (`SecCodeCheckValidity`
against the helper's own designated requirement, read at runtime) before accepting a connection — any process on the Mac can
otherwise open a Mach service. Progress is pushed at most 4×/s; the app's MFO row draws it exactly as it draws an
in-app job (`JobProgressSnapshot` is the same type).

If XPC is down (service disabled in Login Items, or not yet registered), the app says so in the MFO window in one
line and the verbs that need the service are disabled with the reason; nothing silently falls back to in-app.

### 14.4 Durable state: files

| What | Where (`~/Library/Application Support/VideoScan/background/`) | Shape |
|---|---|---|
| Queue | `queue/<jobID>.json` | the `JobRequest`; atomic write-then-rename; the supervisor scans it at start and on XPC `enqueue` |
| Checkpoints | `checkpoints/<jobID>.json` | last completed unit (digest + window); rewritten atomically per unit |
| Journal | `journal/<yyyy-mm-dd>.jsonl` (UTC day) | append-only, one line per observation, version 1, canonical JSON: `{at, by, confidence, evidence, field, id, job, state, subject_id, subject_kind, table, unit, v, value}`; `id` = SHA-256 of the line without `id` (the idempotence key); one `write(2)` + `F_FULLFSYNC` per unit; a torn tail is sealed and refused, never glued (`ObservationJournal.swift`) |
| Sidecars | `../model-lab.sqlite`, `../audio-fingerprints.sqlite`, `../picture-prints.sqlite` | as designed already; the service is their only writer once the engine has moved |
| Log | `~/Library/Logs/VideoScan/background.log` | same line format as `videoscan.log`, same `LogSink` class, its own file (two processes never append to one file) |
| Owner | `owner.lock` | advisory `flock(2)` held for the owner's life, contents "pid N · cli --run era · since HH:MM"; **one supervisor per state root** (2026-11-02): the service and a hand run share these folders, so whichever claims first runs the jobs; the other serves status, refuses `enqueue` in the holder's words and asks again every 30 s; the kernel drops a dead holder's lock (`StateRootLock.swift`) |

**The journal is the only road into the catalog.** `JournalApplier` in the app reads unapplied lines at launch and
every few minutes, applies them through `CatalogCommitter.commit(as:)` in batches keyed by digest (idempotent: a
line already applied is a no-op), marks the file applied with a `.applied` sidecar holding the last line offset, and
logs OUTCOME with rows before · rows after. Lines the catalog refuses (unknown digest, archived row and the field is
a name or date — rule 3, a rejected value — the veto trigger) are written to `journal/refused.jsonl` with the reason
and shown as a count in Catalog Status. The service never learns whether a line was applied; it does not need to.

### 14.5 The Mac's pause (was "Backing off"; 2026-11-04)

`Backoff` is one actor with one published state: `.full` or `.paused(reason)`. Thermal at serious or above pauses
until the Mac is back to nominal. Memory pressure at warning or critical pauses after the current unit. There is no keyboard,
lock-screen, night-window or app-heartbeat row, and no trickle. `.trickle` and `JobProgressSnapshot.waiting` still
decode so an older helper's payload reads correctly; this helper never produces them. Each job is a loop over units.
The supervisor checks Pause, Stop and the Mac's pause between units and runs units back to back. The worker
child is spawned with `Process.qualityOfService = .utility`, so interactive and user-initiated work outrank it. It is
never `.background`, which Apple says is "more likely" to run on the efficiency cores. The model stays loaded in the worker for
the whole job.

### 14.6 What may run in the service, and what never does

| Runs in the service | Stays in the app |
|---|---|
| anything that reads media and produces metadata: captions, transcripts, fingerprints, picture prints, model-lab runs, OCR, era claims, event evidence, fixity re-reads | anything that **moves, renames, deletes, trashes, re-encodes or promotes** media (data-risk paths, rule 10) — Rick is present for those |
| read-only catalog opens | every catalog write |
| nightly `--validate-catalog` (today a headless app run) — a later move | Hallie (paused), Family Tree writers, People writers |

The service binary **does not link the committer**: a sensor proves that `VideoScan Background` contains no symbol
from `CatalogCommitter`/`commit(as:)` and opens the catalog with `SQLITE_OPEN_READONLY` only. The archive choke
point is untouched because the service never has a delete verb.

## 15. The move, one engine at a time (no two-week outage)

*Rewritten 2026-11-01 to the effective handoff (Codex docs review F04). The original 10/30 step table, where step 1 was
the model lab's A0 and the order was still a question (§18 ruling 4), is in git history; ruling 4 was answered by
DECISIONS 2026-10-31.*

| Step | State | What it is |
|---|---|---|
| **0 — skeleton** | **built** | the helper target, plist, `SMAppService` registration, XPC protocol, `JobSupervisor` with a `NoOpJob`, `Backoff`, `videoscan-bg`, the MFO row for a service job. Off unless `background.service.enabled`; no Settings toggle yet. |
| **1 — the 8B era/OCR job** | **merged 2026-11-01** (`0656aee6`) | `EraJob` runs the seated 8B (`qwen3-vl-8b-4bit`, the A2 contract, pixels only; the file's own facts enter as deterministic bounds, never prompt text) through `ClipService` / `PythonClipWorker` (watchdog), oldest first, digests already seen by that signer skipped. Per window it writes `era.yearRange` and `ocr.date` observations and one `era.fused` per file to the journal; the app's `JournalApplier` commits them through the commit door into v14 `provenance_assertions`. UI: the inspector's "Machine era … · 8B, unconfirmed" line, Catalog Status's convergence and journal lines, era words in search. Started by hand (`--run era` / `--enqueue era`). A machine era is never a date (DECISIONS 2026-11-01). A file the model answered but that yields no fused range gets one `era.none` line (value `none`, evidence = windows tried / valid / refused; never an era, never a date), so the signer's caching rule skips it next run. A record with no fused range in which the model did not see the whole file (an era window or OCR still that was a generation error, a frame that would not rip) is not evidence: the unit writes no line at all — any line would cache it — and is retried next run (branch `fix/era-none-observation`, 2026-11-02; Codex F1/F2). A fused range wins over such a failure. |
| **2 — captions on the 8B** | **next** | `CaptionOrchestrator` → a `CaptionJob` in the helper on the 8B; uncaptioned files first, then a backfill; the 3B captioner then retires and the in-app captioner is **deleted** (rule 4: one engine). Contract below. |
| **3 — fingerprints** | planned | sound prints, picture prints backfills; row counts in sidecars before/after match an in-app run on the same fixture set; deleted in-app. |
| **4 — Content Analysis, Event Analysis evidence** | planned | transcripts (the Whisper worker becomes a child of the service), event evidence packets; the Analyze cycler stamps read the same; the Analyze pane becomes a view of service state. |
| **5 — nightly** | planned | `--validate-catalog` and the fixity re-read as service jobs enqueued by the nightly; the morning metrics line unchanged; the headless-app CLI modes retire. |

Each step is one branch, one gate, and a Codex pass when it writes the catalog through the applier (step 1: #187;
step 2 needs its own). Between steps the app is whole; a job that has not moved runs as it does today.

**Step 2, the caption journal contract.** It mirrors step 1's journal (§14.4, `ObservationJournal.swift`): one line
per caption the 8B produced, each with its `id` (SHA-256 of the canonical line, the idempotence key), its `by`
(`machine:<approach id>@r<revision>` for the 8B caption approach) and its `evidence` (window, frame times, prompt
hash), appended per unit (one file) and fsynced once per unit, the unit checkpointed only after its lines are whole.
The destinations are the existing `captions` (one row per `(digest, kind, seq)`, kinds `scene` / `ocrDate` /
`ocrText`, `at_s`, `text`) and `caption_runs` (one row per digest: `model`, `made_at`) — so a caption line carries
`table = "captions"` with kind, seq and time, and a file's run is one closing `caption_runs` line written after its
caption lines; the applier commits a file's captions and its run row together, so a run row never stands without its
captions. **A file the 8B looked at and found nothing in gets an explicit "none" line** (its `caption_runs` row with
no caption rows, the same shape as a transcript's empty text = "ran, found no speech"), so it is not retried every
run — the same rule as the era job's `era.none` (above). The applier gains `captions` / `caption_runs` as known
tables (today it refuses anything but `provenance_assertions` as `unknownTable`); every other refusal rule
(`unknownDigest`, `archivedNameOrDate`, `invalid`, torn tail) and the `refused.jsonl` count apply unchanged. Caching
(§11): a digest with a `caption_runs` row for the same model is never re-run.

Open: Rick —
1. **The 3B rows during the 8B backfill.** Today `caption_runs` holds one row per digest and `captions` refuses a
   different text at an occupied `(digest, kind, seq)` (trigger `captions_bound_conflict`), so the 8B cannot simply
   overwrite a 3B caption. Keep the 3B rows and skip those files, replace them (needs a supersession rule), or keep
   both (an additive migration keyed by model) — a schema question, so Rick's.
2. **The `by` / evidence for a caption row.** `captions` has no `by` or evidence column (only `provenance = 'bound'`);
   whether the journal's `by` and evidence land in `caption_runs.model` alone or in a new additive column is the same
   approval.

**Tests that already exist and bind to step 2** (cite these; extend, do not duplicate):
- Writer quartet on the applier: `VideoScanTests/JournalApplierWriterTests` (debounce window, write hold,
  viewer/master flip, quit with lines waiting → relaunch); truth and logic: `JournalApplierTruthTests`,
  `JournalApplierCodex187Tests`, `JournalApplierSensorTests` (all in `VideoScanTests/JournalApplierTests.swift`); Core:
  `ObservationJournalTests`, `JournalApplicationTests`, `JobSupervisorIsolationTests`, `JobSupervisorScaleTests`
  (`VideoScanCore/Tests/VideoScanCoreTests/Background/`).
- Caption truth: `CaptionDegenerateRefusalTests`, `CaptionDegenerateReaderRouteTests`,
  `CatalogStatusDegenerateOCRTests` (`VideoScanTests/CaptionDegenerateRefusalTests.swift`, GH #402: junk OCR is never
  date evidence on any route), `SceneCaptionsTests`, `CaptionOrchestratorTests`, and the archived-row rule
  `DossierArchivedAdmissionTests`. The cutover passes when these hold against journal-applied rows.
- Host and fixtures: the app suites run on the M4 (PROCESS §8, the default testbed); a live 8B smoke needs the Ultra
  (the model and the media are there). The five-container media matrix uses the existing extractor fixtures (§17).

## 16. Machines

- **Ultra:** the service runs big models beside the app whenever there is work, at utility QoS (2026-11-04).
- **M4:** the service runs `.full` all day on read-only model jobs and backfills against its catalog `.backup` copy
  and media over TB5 (STATUS 10/30); it is the natural home of the 3B model and of long benchmark runs.
- One service per Mac; they do not talk to each other. The nightly already knows both.

## 17. Tests (rule 8) and sensors

- **Logic:** `JobRequest`/`ServiceStatus` round-trip; version mismatch refuses in words; queue scan ignores
  partial files; checkpoint resume skips completed units; journal idempotence (apply twice = once); refused lines
  land in `refused.jsonl` with the rule that refused them.
- **Scale:** 100k queued units planned in budget; a 1 M-line journal applied in 256-line batches without blocking
  the UI (main-actor commit ≤ 0.1 s per batch); progress pushes capped at 4/s under a 10k-unit job.
- **Media matrix:** `CaptionJob` in the service yields a caption for mp4/h264, mov/prores, mkv/ffv1+pcm, mxf,
  avi/dv (the existing extractor fixtures, run through the service path).
- **Isolation:** `kill -9` the service mid-unit → relaunch resumes, no duplicate journal line; a corrupt checkpoint
  → the job restarts from zero and says so; the catalog missing or newer schema → read-only open refuses, jobs that
  need it wait, jobs that do not proceed; XPC from an unsigned client → refused; disk full on the journal →
  job pauses with `paused(disk)`, no truncated line (write-then-rename).
- **Sensors (lane):** (1) **no committer in the helper** — symbol scan of the built helper + a runtime check that
  its catalog handle is read-only; (2) **journal only** — a fake job that tries to open `catalog.sqlite` read-write
  is refused; (3) **schedule** — the helper plans by itself at launch and on a generation change, holds a failed kind across a
  restart, the app enqueues nothing (`BackgroundSettingsSensorTests.noAppCodeEnqueues`), the bundled plist carries the
  KeepAlive keys, and the worker child reports utility QoS (`JobScheduleTests`, `PythonClipWorkerQoSTests`,
  `BackgroundHelperBundleSensorTests`);
  (4) **one resident model** — two jobs declaring `needsResidentModel` never overlap; (5) **MFO lifecycle** —
  START/OUTCOME lines with counts in `background.log` for every job, including stopped and crashed ones
  (OUTCOME written by the supervisor on relaunch from the checkpoint).
- **Truth:** a service-produced fact shown in the UI carries `by = background:<job>@<version>` and its evidence, same
  as an in-app one; Catalog Status shows "N journal lines waiting / M refused".
- **Writer quartet** on `JournalApplier`: edit inside the debounce window, during a write hold, across a role flip,
  then relaunch — plus a Codex pass (it is a catalog writer).

## 18. Rulings wanted from Rick (one at a time)

1. **One extra permission grant** for the helper bundle (Full Disk Access + removable volumes, once, sticky under
   "VideoScan Local") — acceptable? It is the price of its own name and lifecycle. Default: yes. Rick Agrees.
2. **Name and icon:** "VideoScan Background" with the app icon badged (gear-in-arrows or clock, BACKLOG 10/28)?
3. ~~Exit-when-idle or always resident?~~ — **answered** (DECISIONS 2026-11-04): resident while registered; the helper owns its schedule.
4. ~~Step order~~ — **answered** (DECISIONS 2026-10-31): the 8B era/OCR job first (step 1, merged), captions second.

## 19. Sources

Apple: `SMAppService` (ServiceManagement, macOS 13+), "Updating helper executables from earlier versions of macOS",
`NSXPCConnection`/`NSXPCListener`, launchd.plist(5) (`KeepAlive`, `MachServices`, `ProcessType`, `LowPriorityIO`),
`ProcessInfo.thermalState`, `DispatchSource.makeMemoryPressureSource`, `CGEventSource.secondsSinceLastEventType`.
Repo: `App/main.swift` (`--find-tag`, the headless-Aqua arrangement this keeps), ARCHITECTURE §4 (MFO, the commit
door, LogSink), `docs/design/machine_intelligence.md` §3.5 (the first job), BACKLOG "Background helper looks
like the app" (Rick 2026-10-28), DECISIONS 2026-10-28 (signing identity), #395 (Find Tag daemon off).
