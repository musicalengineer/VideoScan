# SOTA Research Sweep — Restoration, Recognition, VLM, Audio, Infra

**Date:** 2026-07-17
**Author:** Claude (cloud research session, directed by Rick)
**Method:** Five parallel web-research agents (video restoration, face recognition, VLM/semantic search, speech/audio, Apple-Silicon infra), each working from primary sources (GitHub releases, papers, Apple docs, HF model cards). All claims linked. Compared against what VideoScan already has: ArcFace w600k_r50 CoreML, Vision/dlib/hybrid engines, Qwen2.5-VL-3B-4bit via mlx-swift, Whisper worker, brute-force embedding search, person-eval harness with golden holdout.

**How to read this:** each section ends with a "for VideoScan" verdict. The Top Recommendations table is the short version. Nothing here is a directive — these are candidates for the cycle process; the eval harness is the arbiter for anything touching recognition.

---

## Top recommendations (ranked by ROI ÷ effort)

| # | Recommendation | Area | Effort | Why |
|---|---|---|---|---|
| 1 | **Quality-weighted track pooling** for face embeddings (MagFace-norm or ArcFace pre-norm L2 as free quality signal; drop bottom quartile, weighted-average per track) | Faces | Small | Highest-ROI recognition change for interlaced SD; no new model; A/B-able in the existing harness |
| 2 | **Deinterlace before face detection** (bwdif or `yadif_videotoolbox` at scan time; QTGMC for archival renders) | Faces + Restoration | Small | Field-aliased faces hurt both detection and embeddings; cheap to test |
| 3 | **Upgrade captioner: Qwen2.5-VL-3B → Qwen3-VL-4B/8B-Instruct-4bit** via mlx-swift-lm ≥3.x | VLM | Medium (repo migration is the real work) | Apache-2.0, large OCR + temporal gains, timestamp-grounded video mode, already in the Swift supported-models list |
| 4 | **Age-banded POI prototypes + temporal chaining** for Donna (child↔adult is unsolved by any model; engineering beats model swaps here) | Faces | Medium | NIST 2025 data: TAR falls from 98.5% (2-yr gap) to 71.3% (8-yr); multiple per-era prototypes chained through adjacent-year videos is the working strategy |
| 5 | **Semantic search: Qwen3-Embedding-0.6B-4bit via mlx-swift-lm native embeddings API + SQLite FTS5 hybrid** | Search | Medium | Swift-native, no Python sidecar; replaces substring search over captions/transcripts |
| 6 | **A/B AdaFace-R50/R100 and LVFace-S/B vs w600k_r50** on the golden holdout | Faces | Medium | AdaFace's low-quality-adaptive margin targets exactly the blurry-home-video regime; LVFace is the strongest 2025 open-weights model; both MIT-coded (cleaner than w600k's research-only terms) |
| 7 | **SeedVR2-3B as the AI-restore engine** (one-step diffusion, Apache-2.0 code+weights, MPS-supported via the numz pipeline) | Restoration | Large | The current practical SOTA for degraded real video; runnable on M4 Max unified memory |
| 8 | **Music/vocals separation before ASR** (Mel-RoFormer, MLX port exists) + VAD-gated Whisper to kill hallucination on music beds | Audio | Medium | Biggest real transcript-quality win for camcorder audio |
| 9 | **SoundAnalysis + CLAP audio-event tags** ("find the birthday parties") | Audio | Small–Medium | SoundAnalysis is zero-dependency native Swift, 300+ classes incl. laughter/singing/applause; CLAP adds free-text audio search |
| 10 | **SigLIP 2 / MobileCLIP2 frame embeddings** for caption-free visual search (Immich's current smart-search recipe) | Search | Medium | "Beach at sunset" retrieval that captions miss; MobileCLIP2 has official CoreML variants |

Also high-value, lower urgency: per-video body re-ID (OSNet) to carry a face-confirmed identity through face-away frames; speaker/voice ID as a corroborating identity signal (per-era voiceprints); Parakeet-v3 via FluidAudio as a fast Swift-native ASR pass.

---

## 1. Video restoration (film / VHS / DV → archive quality)

### Deinterlacing
- **QTGMC is still the gold standard in 2026** — no neural deinterlacer beats it. Lives in [havsfunc](https://github.com/HomeOfVapourSynthEvolution/havsfunc) (v34, Nov 2025, Unlicense) on VapourSynth; installable on Apple Silicon via Homebrew + [prebuilt arm64 plugin sets](https://github.com/yuygfgg/Macos_vapoursynth_plugins). Integration: `vspipe script.vpy - | ffmpeg` subprocess. The [vhs-decode wiki](https://github.com/oyvindln/vhs-decode/wiki/Deinterlacing) recommends it and notes DaVinci's "AI" deinterlacer produces artifacts (and claims Topaz internally uses bwdif).
- Fast tier in ffmpeg: `bwdif` (best quality/speed default), `estdif`, and **`yadif_videotoolbox`** (Metal — Apple-native, ideal for scan-time preprocessing). Community ranking is consistently QTGMC > bwdif > yadif.
- **No mature neural deinterlacer exists** ([chaiNNer #3044](https://github.com/chaiNNer-org/chaiNNer/issues/3044)); ML attempts have not beaten QTGMC.
- **Two-tier policy suggestion:** `yadif_videotoolbox`/`bwdif` inline for analysis passes (face detection, captioning); QTGMC → 59.94p for archival restoration renders.

### Denoise / tape artifacts
- Classical VapourSynth stack remains the consensus: motion-compensated TemporalDegrain2/SMDegrain, BM3D, KNLMeansCL on chroma planes for camcorder chroma noise; `FillBorders` for head-switching noise.
- **TAPE** ([miccunifi/TAPE](https://github.com/miccunifi/TAPE), WACV 2024, CC BY-NC 4.0 — fine for PolyForm-NC) is the one neural model targeting VHS artifacts specifically (mistracking, edge waving, scanline chroma loss). Research-grade, small community — experimental tier.
- Time-base errors are fundamentally capture-time problems; see vhs-decode below.

### Super-resolution / general restoration
- **SeedVR2 is the headline finding.** ([ByteDance-Seed/SeedVR](https://github.com/ByteDance-Seed/SeedVR), SeedVR2 = ICLR 2026): **one-step** diffusion transformer restoration, 3B/7B weights on HF, **Apache-2.0 code AND weights**. The official repo assumes H100s, but [numz/ComfyUI-SeedVR2_VideoUpscaler](https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler) (Apache-2.0, very active, v2.5.23 Dec 2025) adds FP8/GGUF 4-bit quantization + VAE tiling with **explicit MPS/Apple Silicon support** — runnable on the M4 Max (slow: minutes per SD clip-second, batch overnight territory). Integration shape: Python subprocess (core is plain PyTorch); not CoreML-convertible.
- **FlashVSR** (CVPR 2026, Apache-2.0, ~17fps on A100) is the watch-list successor but its sparse-attention kernel is CUDA-only — no Mac path today.
- Legacy tier (skip): BasicVSR++ (CUDA DCNv2 op, dormant), VRT/RVRT (CC-BY-NC, dormant, huge VRAM), Upscale-A-Video, STAR (multi-step diffusion, CUDA-only). Real-ESRGAN survives as `realesrgan-ncnn-vulkan` (runs on Apple Silicon via MoltenVK) but is frame-independent → temporal shimmer.

### Face-region restoration — with a hard boundary
- Best-in-class for video: **KEEP** ([jnjaby/KEEP](https://github.com/jnjaby/KEEP), ECCV 2024, NTU S-Lab non-commercial — OK for us): Kalman-style temporal propagation → far less flicker/identity drift than per-frame GFPGAN/CodeFormer. CodeFormer (S-Lab NC) still the stills default; RestoreFormer++ is the Apache-2.0 alternative.
- **Design constraint the whole 2025–26 literature confirms:** generative face restorers hallucinate — output faces are reconstructions, not evidence. The field's own response (FaceMe, AuthFace, CodeFormer++, NTIRE 2025 identity-preservation scoring) is the proof. **Restored frames must never feed the recognition/eval pipeline or person-evidence data.** Restoration output = display/keepsake derivative, always from untouched sources, clearly labeled. This should be written into the restoration feature's spec as a rule on day one — it aligns exactly with the existing archive-safety principle.

### Frame interpolation & colorization (brief)
- **Practical-RIFE v4.25/4.26** (MIT) is the VFI standard, and there's a **native MLX port**: [mlx-community/RIFE-4.25](https://huggingface.co/mlx-community/RIFE-4.25) (`pip install rife-mlx`, torch-free) — the cleanest possible Mac integration. Degrain before, re-grain after (grain breaks flow estimation).
- Colorization is the weakest Apple Silicon story: the active project ([dan64/vs-deoldify](https://github.com/dan64/vs-deoldify) v5.6.7, Apr 2026, ensembles DeOldify+DDColor+ColorMNet) is CUDA/Windows-oriented; ColorMNet needs a CUDA-only op. Pragmatic fallback: DDColor per-frame via PyTorch-MPS. Low priority.

### vhs-decode (the ceiling-setter)
- [vhs-decode](https://github.com/oyvindln/vhs-decode) v0.3.9 (Mar 2026, GPL-3.0, very alive): software-defined decode from raw FM RF off the tape head — software TBC, dropout compensation, [multi-capture median stacking](https://github.com/oyvindln/vhs-decode/wiki/TBC-median-stacking-guide), HiFi audio decode; macOS ARM binaries. Capture hardware from ~$30 (CX card). **If any original tapes still exist, RF capture is the archival-grade ingest path** — it defines the quality ceiling upstream of any AI. Worth a thought before more tapes/decks are disposed of. VideoScan could later accept `.tbc`+JSON as an input class via [tbc-video-export](https://github.com/JuniorIsAJitterbug/tbc-video-export) subprocess.

### A/V sync
- DV's unlocked audio (±⅓ frame wander) and 29.97-vs-30 pulls are the classic drift causes. ffmpeg `aresample=async=1` / MediaInfo audio-FPS ratio method for derived outputs; never resample originals.

### Commercial baseline
- Topaz (renamed "Topaz Video", now 1.6.x, $299): classic models run native CoreML/ANE on Mac; its diffusion "Starlight" models only partially reached Mac in 1.6.0. Its deinterlacer is reputedly bwdif — i.e. **the QTGMC + SeedVR2 open pipeline is credibly competitive with the commercial reference.** No first-party Apple video SR exists; a native Swift restoration app has an open lane.

### Suggested restoration pipeline shape (all stages write new files)
```
(best: vhs-decode RF/TBC) → QTGMC deinterlace 59.94p → MC denoise/chroma cleanup
  → optional SeedVR2-3B one-step restore/upscale
  → optional KEEP face pass (labeled derivative, never fed to recognition)
  → optional RIFE → encode (ProRes/FFV1 archival + H.264/HEVC access copies)
```

---

## 2. Face recognition & person ID

### Embedding models — A/B candidates
- **The license finding first:** InsightFace *code* is MIT but buffalo_l/w600k_r50 weights are "non-commercial research purposes only" — the weakest license position of any candidate. The README's ship-source-not-weights policy remains right; but if we're re-converting anyway, the MIT-coded alternatives below are cleaner.
- **AdaFace** ([repo, MIT](https://github.com/mk-minchul/adaface), CVPR 2022): quality-adaptive margin *designed for low-quality inputs* — exactly our regime. R50/R100 weights public (WebFace4M/12M). Same 112×112 → 512-d cosine shape: near drop-in (mind BGR + alignment preprocessing). **Top A/B candidate.**
- **LVFace** ([bytedance/LVFace](https://github.com/bytedance/LVFace), ICCV 2025 Highlight, code MIT, ONNX+PyTorch weights on HF): strongest 2025 open model (IJB-C ~97.7, ICCV-MFR winner). ViT → CoreML conversion needs attention-shape care for ANE. **Second A/B arm.** [TopoFR](https://github.com/DanJun6737/TopoFR) (NeurIPS 2024, IResNet family → easy conversion) as a third.
- Honest expectation: single-digit F1 movement on adult faces, possibly more on blurry frames (AdaFace). Nothing drastically beats w600k_r50 on clean data — the harness decides.
- Conversion note: **ONNX→CoreML is dead** (onnx-coreml archived 2023). Route: PyTorch weights → `coremltools.convert` (v9.0), or onnx2torch bridge. **ANE runs FP16 and conversions can silently cast — re-run the golden holdout after every conversion** and pin compute units. This should be a standing rule.

### Cross-age (child↔adult Donna) — the hard truth
- [NIST IFPC 2025 longitudinal child study](https://pages.nist.gov/ifpc/2025/presentations/35.pdf): best model (MagFace) TAR@0.1%FAR degrades 98.5% → 95.7% → 87.2% → **71.3%** at 2/4/6/8-year gaps; ages 3–5 worst. **No 2025+ model materially solves child↔adult.**
- Working strategy is engineering: **multiple age-banded prototypes per POI** (child-Donna, teen-Donna, adult-Donna…), matched via era metadata, **chained through temporally adjacent videos** (2-year-gap matches work where 15-year direct matches fail). Manual seeding of a few child-Donna exemplars per era is the highest-leverage human input in the system.
- **MagFace** ([repo](https://github.com/IrvingMeng/MagFace), Apache-2.0) won the NIST child comparison AND its embedding magnitude is a free quality score — dual-purpose candidate.

### Low-quality video recognition — highest ROI section
- **Track-level aggregation best practice:** face tracks (bbox-overlap + embedding similarity across adjacent samples) → per-frame embeddings → **quality-weighted average** (drop bottom quartile) → one unit-norm embedding per track. Quality weight can be free: MagFace magnitude or the pre-normalization L2 norm of the ArcFace embedding. Learned aggregators to A/B later: [CAFace](https://github.com/mk-minchul/caface) (NeurIPS 2022), [ProxyFusion](https://github.com/bhavinjawade/ProxyFusion-NeurIPS) (NeurIPS 2024) — small heads over existing embeddings, no engine swap.
- Dedicated low-res models if needed later: [PETALface](https://github.com/Kartik-3004/PETALface) (WACV 2025, LoRA adapters gated by input quality), [FaceMoE](https://github.com/Kartik-3004/FaceMoE) (2026, TinyFace rank-1 76.2% vs ~63–68 for standard ArcFace-class).
- FIQA models if the free quality signals underperform: CR-FIQA (check NC license), ViT-FIQA (2025).
- **Deinterlace before detection** — field aliasing hurts everything downstream.

### Detection, clustering, body re-ID
- Detector is not the bottleneck: SCRFD-10GF (what buffalo_l ships) remains the best accuracy/compute open detector; no 2025 model leapfrogs it. Keep Vision/SCRFD hybrid.
- **Skip GCN clustering** — trained for millions of faces/100k identities; a family archive (dozens of identities, extreme intra-class age variation) violates their assumptions. Improve the greedy/cluster→POI flow instead: quality-gated cluster seeding (only high-quality faces form clusters; low-quality assigned post-hoc) + age-banded sub-clusters per POI.
- **Per-video body re-ID is cheap and high-value:** face-confirm a track once, then a clothing/body embedding (OSNet via [torchreid](https://github.com/KaiyangZhou/deep-person-reid), MIT, small, CoreML-convertible) carries the label through face-away frames *within the same video* (same day, same clothes — the validity condition holds by construction). Don't attempt cross-video body re-ID. Watch: [SapiensID](https://github.com/mk-minchul/sapiensid) (CVPR 2025, unified face+body).

### Ecosystem check
- **Immich (v3, July 2026): still buffalo_l** — no model upgrade; the DeepFace-backend proposal was rejected. **PhotoPrism (May 2026) moved to pluggable ONNX recognition models** — the same architecture direction as our pluggable-engine design. VideoScan is at or ahead of ecosystem parity on recognition.

---

## 3. VLM captioning & semantic search

### Captioner upgrade
- **Qwen3-VL** (Oct 2025, Apache-2.0, 2B/4B/8B/32B dense + MoE): the small models match/beat much larger Qwen2.5-VL; OCR 10→32 languages; 256K context; **native video mode with text–timestamp alignment** — "at 00:42 the kids blow out candles" instead of per-frame captions. **Supported in mlx-swift TODAY** ([mlx-swift-lm supported models](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/supported-models.md), video input validated in the Swift port).
- **The real migration work:** MLXLLM/MLXVLM moved from `mlx-swift-examples` to [ml-explore/mlx-swift-lm](https://github.com/ml-explore/mlx-swift-lm) (3.x had breaking changes; latest 3.31.4, Jun 2026). One coordinated upgrade: mlx-swift 0.29.x → 0.31.x (wired-memory management, concurrency fixes — relevant to CaptionRunner) + mlx-swift-lm 3.x + model swap. The MLXSafety/`runMLX` wrapper pattern carries over.
- Measured on our actual hardware class ([vllm-mlx benchmarks](https://github.com/waybarrios/vllm-mlx/blob/main/docs/benchmarks/video.md)): Qwen3-VL-8B-4bit on M4 Max 128GB: 57 tok/s @2 frames → 4.3 tok/s @64 frames (6–13 GB RAM); M1 Max: Qwen3-VL-4B-3bit 29.5/17.9/9.9 tok/s @4/8/16 frames. **Keep clips ≤32 frames per inference.** Suggested split: 8B on the Studio, 4B on the MBP. Avoid "Thinking" variants for captioning.
- **Move from frame captions to clip captions** (shot/scene-level, timestamped) — composes with the existing `SceneCaption` timestamped shape.
- Watch: **Qwen3.5** (Feb 2026) is natively multimodal (Apache-2.0) but not yet in mlx-swift-lm; **Molmo 2** (Ai2, Dec 2025) is the best open video model (temporal pointing, tracking) but PyTorch-only — no MLX port yet. **Apple FastVLM** (0.5B, in mlx-swift-lm + CoreML) as a near-instant per-frame prepass tier if wanted.

### Semantic search (replaces substring)
- **Text:** mlx-swift-lm now has a **native Swift embeddings API** with `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` pre-registered ([embeddings.md](https://github.com/ml-explore/mlx-swift-lm/blob/main/skills/mlx-swift-lm/references/embeddings.md)) — semantic search over captions+transcripts with no Python sidecar. Pair with **SQLite FTS5** (BM25, built into system SQLite) for hybrid keyword+vector search in the same DB as the catalog.
- **Visual:** embed sampled frames with **SigLIP 2** (what Immich now ranks top for smart search: `ViT-SO400M-16-SigLIP2-384__webli`, [their eval](https://github.com/immich-app/immich/discussions/17135)) or **Apple MobileCLIP2** ([official CoreML variants](https://github.com/apple/ml-mobileclip)) → free-text visual search ("the beach at sunset") that captions miss. This is the proven Immich recipe, native-ized.

### Structured extraction & catalog Q&A
- Structured JSON tags (people count, indoor/outdoor, decade guess, activity): Qwen3-VL 4B/8B are much better JSON emitters than 2.5-VL-3B; Swift has no grammar-constrained decoding yet (schema-prompt + validate-retry pattern; [petrukha-ivan/mlx-swift-structured](https://github.com/petrukha-ivan/mlx-swift-structured)). **Apple Foundation Models framework** (macOS 26; WWDC26 added image input) gives guaranteed-schema `@Generable` structured output from the free on-device ~3B model — the natural home for cheap categorical fields once the OS ships; relevant to the media-kind classifier's VLM-confession signals too.
- Catalog Q&A/summarization sweet spot mid-2026: **Qwen3-30B-A3B-class small MoE** (~17–20GB at 4-bit, fast prefill, MLX-Swift-native) on both machines; gpt-oss-120b or Qwen3.5-122B-A10B on the 128GB Studio only.

---

## 4. Audio: ASR, diarization, restoration, events

### ASR
- On noisy far-field camcorder audio, **Whisper large-v3 (non-turbo) remains the robustness champion**; turbo trades timestamp precision and noise robustness for speed. Post-Whisper leaders on clean English: NVIDIA **Parakeet TDT v3** (CC-BY-4.0, crisper native token timestamps) — Swift-native via **[FluidAudio](https://github.com/FluidInference/FluidAudio)** (Apache-2.0, CoreML/ANE, ~190× RT on M4 Pro) or [parakeet-mlx](https://github.com/senstella/parakeet-mlx); **WhisperKit is now part of the Argmax OSS Swift SDK v1.0.0** (May 2026, MIT — WhisperKit + SpeakerKit + TTSKit).
- **Recommended shape:** VAD-gated always (kills the music-bed "thanks for watching" hallucinations) → Parakeet-v3 fast pass → Whisper large-v3 hard pass on low-confidence/enhanced audio, keep the better. All ASR resamples to 16kHz internally — 32 vs 48kHz sources are irrelevant to it.
- Apple's new **SpeechAnalyzer** (macOS 26): ~70× RT, free, native, but mid-tier-Whisper accuracy (14.0% vs 12.8% WER) — fine as a fast first pass someday, not the archive-quality pass.

### Diarization & voice ID (second identity signal)
- **pyannote 4.0 / speaker-diarization-community-1** (Sept 2025, CC-BY-4.0 gated, code MIT): better DER + an `exclusive_speaker_diarization` mode built for reconciling with ASR word timestamps. **Swift-native routes exist now:** SpeakerKit (Argmax, runs community-1 on CoreML, merges speaker labels into WhisperKit transcripts) or FluidAudio's diarization pipeline; [senko](https://github.com/narcotic-sh/senko) (MIT) does 1h in ~8s on M3 if speed matters.
- **Voice ID for family members is feasible as corroboration, not identification:** enroll per-person voiceprints (ECAPA/CAM++/TitaNet embeddings — already inside FluidAudio/sherpa-onnx) from face-confirmed clips, cosine-match diarized segments, fuse with face scores. Hard caveats: **children's voices shift drastically with age** (per-era enrollment needed, same pattern as age-banded face prototypes), <2–3s segments and overlapped speech degrade badly. Soft prior, never a sole label — fits the belief-vector design.

### Restoration
- **The biggest transcript win: separate vocals from music beds before ASR/diarization.** **BS/Mel-RoFormer** is SOTA (~2+ dB over htdemucs); an **MLX port exists** ([mel-roformer-vocals MLX](https://huggingface.co/mlx-community/mel-roformer-zfturbo-vocals-v1-mlx)). Demucs v4 (MIT, MPS) as the easy baseline.
- Speech enhancement: **DeepFilterNet3** (MIT/Apache, 48kHz full-band, real-time on CPU, Rust→arm64) as the cheap hiss pass; resemble-enhance regenerates speech but can hallucinate phonetics — **never feed enhanced audio to ASR without A/B**, enhancement often *hurts* WER. Dehum/declick = classic DSP (vDSP/ffmpeg `afftdn`/`adeclick`), not ML. Commercial bar: iZotope RX 12 (Apr 2026).
- Bandwidth extension (AudioSR etc.): lowest ROI — DV 32kHz already covers the speech band; skip.

### Events & music
- **Apple SoundAnalysis** (`SNClassifySoundRequest`, built-in): 300+ classes incl. laughter, applause, singing, crying — zero-dependency Swift; likely 80% of "find the birthday parties" on its own. Add **CLAP** embeddings (MIT, HF transformers, CoreML-convertible) for free-text audio search ("singing happy birthday").
- Music ID: **ShazamKit** (native; custom catalogs match fully offline — seed from the family's own music library); Chromaprint/AcoustID for identifying music *files*, not room audio.

---

## 5. Infra: MLX, CoreML, vector search, decode

- **MLX stack current versions:** mlx-swift 0.31.4 (wired memory management, mxfp4 quant, concurrency fixes), **mlx-swift-lm 3.31.4** (the mlx-swift-examples successor — migration required, see §3), mlx-vlm 0.6.x (Python; continuous batching, video CLI), mlx-lm 0.31.x. All MIT.
- **coremltools 9.0** (Nov 2025): PyTorch-only frontend (ONNX dead), macOS 26 targets, plus 8.3's MLModelValidator/Comparator/Inspector — the right tools for validating ArcFace-successor conversions against FP16/ANE drift.
- **Vector search: brute force is fine for a long time.** 100k × 512-d fp32 = 205MB; one query ≈ 1–5ms via Accelerate GEMV on M4 Max (memory-bandwidth-bound). **Verdict: SQLite BLOBs as source of truth + in-memory fp16 matrix + vDSP/BLAS cosine; adopt ANN only past ~500k vectors or for repeated all-pairs clustering.** When needed: **USearch** (v2.26, Apache-2.0, real maintained Swift SPM package) over sqlite-vec's ANN (still alpha, single-maintainer risk; fine as the storage layer via [SQLiteVec](https://github.com/jkrukowski/SQLiteVec)). This validates the Codex/immich-doc plan: exact search first, benchmark before HNSW.
- **Decode:** M4 hardware-decodes H.264/HEVC/ProRes/AV1; **DV and MPEG-2 are software-only on all Apple Silicon** (trivially real-time on M-class CPUs — not a problem, just a fact). Sampling shapes: `AVAssetImageGenerator` with generous tolerances for sparse keyframes; `AVAssetReader`+`CVPixelBuffer` (420f) → vImage/Metal downscale → zero-copy into CoreML/MLX for sequential passes. Nothing new from WWDC25/26 changes this; ffmpeg stays fallback-demuxer only.
- **Apple platform watch:** macOS 26 Foundation Models (on-device LLM, `@Generable`, WWDC26 image input; adapter training possible but per-OS-version); **Core AI** framework at WWDC26 (Core ML successor for transformers, macOS 27) — watch, don't migrate; Metal 4 tensor ops target M5's GPU neural accelerators — not relevant to M4/M1.
- **Multi-agent orchestration (validation):** the ecosystem converged on exactly VideoScan's pattern — git worktree per agent + file-based markdown mailbox + shared task state ([Osmani, "The Code Agent Orchestra"](https://addyosmani.com/blog/code-agent-orchestra/)). An MCP server exposing the mailbox is the cheap formalization path; A2A protocol is enterprise-weighted overkill for two local CLIs. The engineering-room design is on-trend, not behind.

---

## 6. License summary for a PolyForm-NC app

| Tier | Items |
|---|---|
| **Permissive (clean)** | SeedVR2 (Apache, code+weights), Practical-RIFE + RIFE-MLX (MIT), Qwen3-VL / Qwen3-Embedding / Qwen3.5 (Apache), AdaFace & LVFace code (MIT), MagFace (Apache), OSNet (MIT), WhisperKit/whisper.cpp (MIT), FluidAudio/sherpa-onnx (Apache), DeepFilterNet (MIT/Apache), Demucs (MIT), CLAP (MIT), USearch (Apache), sqlite-vec (MIT/Apache), mlx-* (MIT) |
| **Non-commercial (OK for us, note in NOTICE)** | CodeFormer & KEEP (NTU S-Lab 1.0), TAPE (CC BY-NC), CR-FIQA (verify) |
| **Gated/attribution** | pyannote community-1 (CC-BY-4.0, HF-gated), Parakeet/Canary (CC-BY-4.0), Apollo weights (CC-BY-SA) |
| **Research-only taint (ship source, never weights — existing policy)** | w600k_r50 / buffalo_l ("non-commercial research purposes only" — weakest license we depend on); all FR training datasets carry this taint; MIT-coded AdaFace/LVFace are the cleanest practical options |
| **GPL (subprocess-only isolation)** | ffmpeg GPL builds, vhs-decode, vs-mlrt, VapourSynth plugins |
| **Apple research licenses (check before shipping)** | FastVLM, MobileCLIP2 (LICENSE_MODEL terms) |

---

## 7. Suggested cycle candidates (for the Manager/Codex process)

1. **poi/track-pooling** — quality-weighted track aggregation (free MagFace-norm or pre-norm L2 signal). Gradeable immediately by the existing harness; likely the best accuracy-per-line-of-code in this document.
2. **poi/deinterlace-prepass** — `yadif_videotoolbox` before detection on interlaced sources; A/B on holdout.
3. **captions/qwen3-vl** — the mlx-swift-lm 3.x migration + Qwen3-VL-4B/8B + clip-level timestamped captions. (Blocked-ish: coordinate the repo migration as its own chunk.)
4. **poi/adaface-ab** — AdaFace-R50 CoreML conversion + third A/B arm vs w600k_r50 and LVFace-S; includes the FP16/ANE-drift holdout gate as a standing conversion rule.
5. **search/semantic** — Qwen3-Embedding-0.6B via MLXEmbedders + FTS5 hybrid; SigLIP2/MobileCLIP2 frame embeddings as phase 2.
6. **audio/vocals-split-asr** — Mel-RoFormer vocals split + VAD gating in the Whisper worker; A/B transcript quality on music-bedded fixtures.
7. **restore/seedvr2-spike** — offline spike: numz SeedVR2-3B GGUF on 3–5 representative Donna clips on the M4 Max; human eval + runtime numbers before any product integration.
8. **poi/age-banded-prototypes** — era-tagged multi-prototype POI profiles + temporal chaining; the child-Donna strategy.

*Items 1, 2, 4 are pure harness plays — the eval discipline already built is exactly what makes them cheap. Item 7 is the restoration flagship and the only one needing Python subprocess infrastructure.*
