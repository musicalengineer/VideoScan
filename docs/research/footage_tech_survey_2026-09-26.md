# Same/Similar footage detection — technology survey (Sept 2026)

Context checked first: `docs/find_original_design.md` (2026-09-23) already defines tiers T0–T4 and a "guitar case" spike; `PerceptualHash.swift` (dHash, ±2-index offsets) and `PerceptualFingerprinter.swift` (32 frames/file via ffmpeg) are on main; `AudioTranscriber.swift`/`WhisperWorkerTranscriber.swift` run Whisper via Python; `ArcFaceEngine.swift`/`AdaFaceEngine.swift` produce 512-d face embeddings; `CaptionRunner.swift` runs Qwen2.5-VL via MLXVLM. No audio fingerprinting exists yet (grep: only design docs mention it). This survey slots into that design rather than replacing it.

## A. SAME footage (copies, re-encodes, trims, re-captures)

### Audio fingerprints (the strongest signal, and the only one that bridges A/V halves)
- **Olaf** — C, landmark (Shazam-style) hashes, LMDB, decodes via ffmpeg; reports query/reference **offsets**; ~80× real-time query, ~2000× indexing on many cores. AGPL-3.0. CPU only; ~1 min per hour of footage. Fails on: silent/music-bed footage, speed drift >~1–2% (VHS wow/flutter, different capture-card clocks). https://github.com/JorenSix/Olaf
- **Panako 2.x** — Java, constant-Q peaks; tolerates **±10% time-scale and pitch** (the VHS-vs-DV re-capture case), reports match start/stop in query AND reference plus time factor. AGPL, JDK 11+, research-grade. https://0110.be/releases/Panako/Panako-2.1/readme.html
- **Chromaprint/fpcalc** — LGPL-2.1, Homebrew; designed for near-identical music, "trades robustness for search speed"; fpcalc defaults to the first 120 s (override with `-length`). Offsets recoverable by histogramming hash-offset differences. Weakest on degraded room audio. https://github.com/acoustid/chromaprint , https://github.com/acoustid/notebooks/blob/master/fingerprint-matching.ipynb
- **ShazamKit custom catalog** — native, offline, `SHSignatureGenerator` + `SHCustomCatalog`, match returns `matchOffset` in the reference. Caveats: one match per query, "undefined" which signature wins when references share content (Apple engineer), so all-pairs dedup needs chunked 10–15 s queries and repeated passes; behaviour on hissy room audio unmeasured. Zero new dependencies. https://developer.apple.com/forums/thread/710225 , https://developer.apple.com/videos/play/wwdc2022/10028/
- **Neural fingerprints** (NMFP ISMIR-2025, TensorFlow, AGPL, ~200 MB; PeakNetFP for 50–200% time-stretch) — most degradation-robust, but music-trained, Python-only; spike-only. https://github.com/raraz15/neural-music-fp , https://github.com/guillemcortes/peaknetfp
- **Own Swift landmark hasher** (Accelerate vDSP FFT, peak pairs → 32-bit hashes, offset histogram voting) is ~300 lines and avoids AGPL. The classic Shazam patent Panako flags (US6990453, filed 2001) is past its term; not legal advice.

### Video fingerprints
- **Existing dHash** — right for re-encodes; on VHS it breaks on letterbox/pillarbox differences, head-switching noise, luma shifts. Fix cheaply: crop-detect + per-frame normalize, hash per shot (`scdet`) instead of 32 normalized positions, allow full offset search.
- **ffmpeg MPEG-7 `signature` filter** — already in Homebrew ffmpeg; `detectmode=full` reports whole and **partial matches with frame ranges** (temporal alignment for free); thresholds `th_d/th_dc/th_xh/th_di/th_it`. CUNY TV used it on 1,700 archival videos; false positives on visually uniform material. Decode-bound (~2–5 min/hour SD). https://ffmpeg.org/doxygen/trunk/vf__signature_8c.html , https://blog.americanarchive.org/2017/04/20/adventures-in-perceptual-hashing/
- **vPDQ / TMK+PDQF (Meta)** — vPDQ: 1 fps PDQ hashes, matches clips inside longer videos, macOS arm64 wheel, LGPL/BSD; no temporal offset (frames treated as a set). TMK: fixed 256 KB signature, same-length videos only; near-perfect on format/resolution/compression changes, collapses on crops/title cards. https://github.com/facebook/ThreatExchange/tree/main/vpdq , https://ar5iv.labs.arxiv.org/html/1912.07745 , PHVSpec benchmark (Tech Coalition 2024) rates vPDQ competitive but open systems below commercial Videntifier on crop/border/speed.
- **SSCD (Meta, MIT)** — self-supervised copy-detection descriptor, torchscript, 512-d; the strongest published answer to "same picture, badly degraded"; Core ML conversion needed. https://github.com/facebookresearch/sscd-copy-detection
- **Vision `VNGenerateImageFeaturePrintRequest`** — native, ANE, free; semantic rather than copy-oriented (a different Thanksgiving table can sit close). Use as B evidence, not A.

### The two hard cases
- **1994 VHS capture vs 2008 DV re-capture of the same tape**: audio is the same signal through different decks → landmark hashes match if speed drift is small; Panako's time-scale tolerance is the safety net. Video needs crop/aspect normalization then SSCD or MPEG-7; raw dHash Hamming will fail.
- **Audio-only vs video-only Avid halves**: no content method matches audio to picture directly. Bridge them: audio half → audio FP → any A/V file; video half → MPEG-7/dHash → the same A/V file; agree on offsets ⇒ pair. Keep the existing UMID/timecode Correlate as T0.

## B. SIMILAR content (same event, different camera)

- **SigLIP 2 base-256 Core ML** (Apache-2.0, 768-d, 176 MB image encoder) — 100% of ops on the ANE, **5.2 ms/image on M5 Pro** (3.5 ms GPU), 202 photos/s end-to-end. At 1 fps that is ~20 s of ANE time per hour of footage; decode dominates. Text tower gives free NL search ("thanksgiving dinner 1990s"). https://huggingface.co/FluidInference/siglip2-base-patch16-256-coreml
- **MobileCLIP2** (Apple, TMLR 2025) — S2/B variants, ANE-tuned, iOS demo; code MIT, weights under Apple research terms. https://github.com/apple/ml-mobileclip
- **Core AI (macOS 27)** — new inference framework with `imageEncode()` dense embeddings, ANE+GPU scheduling, PyTorch converter. macOS 27 only; the M4 stays on 26.7 for now, so treat as next-quarter. https://developer.apple.com/videos/play/wwdc2026/326/
- **V-JEPA 2 / 2.1** (Meta, MIT, MLX ports exist) — true video-level temporal embeddings on the GPU; experimental, ViT-L cost roughly 10–50× SigLIP per clip; spike only. https://github.com/facebookresearch/vjepa2 , https://github.com/lukasugar/vjepa2.1-mlx
- **SpeechAnalyzer (macOS 26)** — native, 12–40× real-time (1.5–5 min per hour on an M2 Pro), WER 2.1%/4.6% clean/noisy vs Whisper small 3.7%/8.0%. Replaces the Python Whisper worker for English; keep WhisperKit (ANE, large-v3-turbo ~9× RT) for other languages. Transcripts → BM25 + embedding similarity = "same event" evidence (same names, same jokes). https://lyonesse.app/blog/apple-speech-api-benchmark.html , https://justvoice.ai/blog/whisper-benchmark-apple-silicon-m3-m4
- **Cues from existing code**: face identity sets per file (ArcFace/AdaFace, Jaccard overlap), `DateTriangulation`, Vision OCR of burned-in datestamps, the Qwen2.5-VL dossier captions. All weak individually; fused they answer "another Thanksgiving in the 90s".
- Failure modes on analog: SigLIP embeddings drift with heavy noise/colour cast (embed a denoised/contrast-normalized frame); transcripts fail on music beds and crosstalk; faces already know their VHS limits (AdaFace was chosen for that).

## Hardware fit (M5 Ultra 96 GB, M4 Max, M1 Max)
- ANE (32 cores on M5 Ultra; fp16/int8): SigLIP2, MobileCLIP2, Vision, SpeechAnalyzer, ArcFace/AdaFace. Run several Core ML instances; predictions serialized per the MLE5 lesson.
- GPU (80 cores + neural accelerators): MLX work — V-JEPA, SSCD if left in PyTorch/MLX, Qwen-VL captions, WhisperKit.
- CPU/VideoToolbox: decode is the real budget. Hardware H.264/HEVC/ProRes decode ~40× RT; DV/MPEG-2/FFV1 are software, ~15–25× RT per core. Audio hashing and dHash are noise by comparison. Spinning drives, not silicon, set the pace (reuse `MediaVolumeGate`).

## Ranked recommendation

**A — spike first (1–2 days, guitar case + one VHS/DV pair):**
1. Audio landmark FP with offsets: Olaf as a subprocess vs ShazamKit custom catalog, side by side; Panako only if speed drift shows up. Decision rule per the design doc: ship native if offsets hold on room audio.
2. ffmpeg `signature detectmode=full` as T3 temporal alignment for silent/music-bed footage; keeps dHash as the cheap pre-filter.
3. SSCD → Core ML for the degraded-copy tier; measure against dHash on the VHS pair before committing.

**B — spike first:**
1. SigLIP2 base Core ML on 1 fps frames, per-shot mean-pooled; brute-force cosine over ~100k shot vectors in vDSP (no vector DB needed).
2. SpeechAnalyzer replacing the Whisper worker for English; transcript similarity as second signal.
3. Evidence fusion: SigLIP + transcript + face-set overlap + date band, thresholds tuned on hand-labelled groups. V-JEPA later.

**"Melt silicon" pipeline for the M5 Ultra (one decode pass per file):**
AVAssetReader/VideoToolbox decode → fan-out: (a) 8 kHz mono PCM → Swift landmark hasher (CPU, Accelerate); (b) `scdet` shot cuts + 1 fps frames → crop-normalize → dHash (CPU) + SigLIP2 (ANE ×4 instances) + SSCD (GPU) + Vision faces→ArcFace (ANE, existing); (c) audio → SpeechAnalyzer (ANE/CPU). Per-volume I/O gating; 4–6 files in flight. Rough budget for ~3,000 catalog-hours: decode-bound ~1–3 nights; embeddings ≈ 5 MB/hour at frame level, kilobytes at shot level; audio hashes ~1–3k/min. Store per-file: shot list, dHash[], SigLIP[], SSCD[], landmark hashes, transcript, face-ID set — then all matching is in-memory and re-runnable as models improve.

Sources not linked above: TMK/vPDQ overview https://github.com/facebook/ThreatExchange ; PHVSpec https://technologycoalition.org/wp-content/uploads/Tech-Coalition-Video-Hash-Benchmark-Paper.pdf ; Panako paper https://archives.ismir.net/ismir2014/paper/000122.pdf ; M5 Ultra specs https://www.apple.com/newsroom/2026/08/apple-introduces-new-mac-studio-with-m5-max-and-m5-ultra/ ; ANE architecture paper https://arxiv.org/abs/2606.22283 ; Core AI intro https://developer.apple.com/videos/play/wwdc2026/324/ ; VideoPrism (Google, weights released, license unverified) https://github.com/google-deepmind/videoprism
