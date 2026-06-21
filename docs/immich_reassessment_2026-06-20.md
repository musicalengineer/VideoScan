# Immich → VideoScan Reassessment (grounded)

**Date:** 2026-06-20
**Supersedes the framing of:** `docs/immich_ideas.md`
**Codebases read:** VideoScan @ `~/dev/VideoScan`, Immich @ `~/dev/immich` (shallow, HEAD `b24a617`)
**Scope:** correct `immich_ideas.md`'s wrong premise, then classify each Immich concept HAVE / PARTIAL / MISSING against the *actual* VideoScan code with file:line, and recommend with effort (S ≈ <1 day, M ≈ 2–4 days, L ≈ 1–2 weeks).

---

## The single most important correction to `immich_ideas.md`

> `immich_ideas.md` reads as a build-it-from-scratch plan: "Add an ArcFace embedding backend (CoreML EP)… Persist 512-d embeddings… add the birthdate prior…" (§4, items 1–5).

**That premise is wrong. VideoScan already has the ArcFace path.** It is built, wired into the engine dispatch, and shipping:

- ArcFace CoreML backend, 512-d L2-normalized embeddings, cosine match — `VideoScan/VideoScan/ArcFaceEngine.swift` (676 lines), embedding at `:156-245`, cosine at `:249-254`.
- The recognition model `models/w600k_r50.mlmodelc` (+ `.mlpackage`) **is InsightFace buffalo_l's ArcFace R50** — same family Immich defaults to. Conversion script `scripts/convert_arcface_coreml.py:43-54` bakes the `(px-127.5)/127.5` normalization and 112×112 input.
- Pluggable engine enum `.vision / .arcface / .dlib / .hybrid` — `PersonFinderTypes.swift:72-75`; dispatched in `PersonFinderModel+JobLifecycle.swift:processOneVideo` (switch at the recognitionEngine) and `PersonFinderEngineDispatch.swift:pfRunArcFaceEngine` (~`:142-212`).
- CoreML compute units already `.all` (ANE-eligible) — `ArcFaceEngine.swift:82, 103, 124, 138`.
- Unsupervised clustering exists — `scripts/cluster_faces.py` (HDBSCAN, `:~390-421`), driven by `IdentifyFamilyModel.swift` / `IdentifyFamilyView.swift`.
- A birthdate prior exists as code — `IdentityNarrowing.swift:38-107` (`pfIdentityCandidates`).

So the value of Immich is **not** the ArcFace idea (we have it). The value is four specific architectural moves VS has *not* made: a **vector index**, **online greedy assignment with embedding persistence**, **wiring the birthdate prior into matching**, and **proper 5-landmark alignment**. Everything below is ranked by that lens.

---

## RANKED — highest-value MISSING / PARTIAL first

| # | Item | State | Effort | Why it matters for finding Donna |
|---|------|-------|--------|----------------------------------|
| 1 | **Proper 5-landmark `norm_crop` alignment before ArcFace** | MISSING | M | ArcFace R50 was trained on landmark-warped 112×112 crops. VS feeds a bbox-centered square (roll-derotated only). Misalignment is the **largest silent accuracy loss** in the current ArcFace path — it directly costs cross-decade Donna recall. Cheapest single quality win. |
| 2 | **Persist embeddings + local vector index (sqlite-vec / Faiss HNSW)** | MISSING | M–L | Today every scan re-embeds every frame and there is *no* archive-wide face store. Persisting embeddings turns "scan whole archive for Donna" from O(re-embed everything each run) into "embed once, query forever." Prereq for #3, #4. |
| 3 | **Online greedy assignment + core/deferred two-pass** | MISSING (only reference-photo matching) | L | Lets Donna be found from *accumulated good frames*, not a single hand-picked reference photo — the exact failure mode for a 30-years-younger face. Robust to blurry video frames (they stay deferred). |
| 4 | **One-click naming of an unnamed cluster (cluster → POI in one step)** | PARTIAL | S–M | VS can cluster and name, but naming a cluster does **not** mint/append a POI usable by the matcher. Closing that loop means "name the Donna cluster once" feeds every future scan. |
| 5 | **Birthdate prior wired into the matcher** | PARTIAL (post-hoc UI only) | S | `pfIdentityCandidates` computes plausibility but never filters/biases a match. Wiring it as a candidate filter is a near-free precision gain that suppresses impossible matches (e.g. matching "Donna" in a video predating her birth). |
| 6 | buffalo_l vs s/m / antelopev2; RetinaFace@640 vs Vision detection | HAVE recog / PARTIAL detect | S–M | We already run the right *recognition* model. Detection is Vision, not RetinaFace; the real gap is the landmarks it does **not** emit (see #1). |
| 7 | ANE / compute-unit + concurrency strategy | HAVE (with a caveat) | S | Already `.all`. The global serialization lock caps ArcFace throughput; safe to keep, but it's the perf ceiling once #1–#3 land. |

---

## Item-by-item

### 1. Current matching vs a local vector index

**State: HAVE brute-force pairwise; MISSING any index. Recommend: persist + index (M–L).**

How VS matches today — confirmed O(n) pairwise, no index:

- The hot loop is `ArcFaceEngine.swift:421-425`: for each detected face's embedding, iterate **every** reference embedding and keep the best cosine.
  ```swift
  var bestCosine: Float = -1
  for ref in referenceEmbeddings {
      let cosine = arcfaceCosine(embedding, ref)
      if cosine > bestCosine { bestCosine = cosine }
  }
  ```
- `arcfaceCosine` is a plain 512-wide dot product — `ArcFaceEngine.swift:249-254`.
- References are loaded per job and cached **in RAM only** (`ScanJob.assignedArcFaceEmbeddings`, set in `PersonFinderEngineDispatch.swift` ~`:172-188`). Nothing is written to disk.
- Repo-wide grep for `faiss|sqlite-vec|hnsw|vec0` → **no hits.** Confirmed: no vector store anywhere.

Immich's equivalent: HNSW + cosine `<=>` as a single SQL query, `search.repository.ts:329` (distance), `:347` (`distance <= maxDistance`); index params `ef_construction=300, m=16` at `face-search.table.ts:7-9`.

**Where it pays off.** With a handful of Donna reference photos and a per-frame inner loop, the pairwise cost is trivial — an index buys **nothing** for the *current* reference-photo workflow. The index matters the moment you do #2/#3: persist the embedding of every detected face across the whole archive and query "who is this / is this Donna" against millions of stored faces. Rough threshold: pairwise scan of N stored faces stays sub-millisecond into the low hundreds of thousands; an HNSW index becomes worth the complexity around **~10⁵–10⁶ stored face embeddings** (a realistic multi-decade family archive). Use **sqlite-vec** over Faiss: single-file, no daemon, no Postgres, plays nicely with a Swift `Process`/SQLite layer and matches VS's "no vendor/server" preference. **Effort: M** to persist + sqlite-vec brute-force (KNN), **L** if you also build the HNSW index and tune it.

### 2. Online greedy assignment + core/deferred two-pass

**State: MISSING. VS does reference-photo matching only. Recommend: adopt for ingest (L).**

VS has no incremental assignment. Each scan answers "does *this video* contain *this reference person*"; it never accumulates an identity from the faces it sees. The only "assignment-like" code is the offline HDBSCAN clustering (`cluster_faces.py`), which is batch, not online.

Immich's online greedy logic (verified, lines shifted from the doc):
- core test — `person.service.ts:503-505`: `matches.length >= minFaces && asset.visibility === Timeline`.
- deferred re-queue — `:506-510`: non-core faces re-queued with `deferred:true`.
- second search restricted to named faces — `:513-526` (`hasPerson: true`, and note it passes `minBirthDate`).
- new-person creation for a core face with no match — `:528-532`.
- A "person" is a bag of face rows, matched face-to-face by kNN — **no centroids**.

**Fit for VS:** excellent, *and arguably better than for Immich*, because VS's front-end already samples many frames and groups consecutive hits into temporal segments (`ArcFaceEngine.swift:440-483`). Greedy + core/deferred is the natural way to let many mediocre video frames vote an identity into existence without a single perfect reference photo. This is the real unlock for cross-decade Donna. **It depends on #2's persistence/index** to be tractable. **Effort: L.**

### 3. minBirthDate prior

**State: PARTIAL — computed, never applied to matching. Recommend: wire as a filter (S).**

VS already has the birthdate math: `IdentityNarrowing.swift:38-107` (`pfIdentityCandidates`) marks a candidate impossible when `born after recordDate` (plausibility 0) and even handles death dates. But it runs **after** matching to rank UI suggestions; it does **not** gate or bias which faces match.

Immich applies it inside the search: `search.repository.ts:337-341` adds `person.birthDate IS NULL OR person.birthDate <= minBirthDate`, and `handleRecognizeFaces` passes `minBirthDate: asset.fileCreatedAt` (`person.service.ts:521`). A cheap, effective identity prior.

For VS: once embeddings/persons are persisted (#2/#3), drop a candidate whose recorded birthdate is after the video's record date. Even before that, the prior can suppress impossible POIs in the matcher. **Effort: S** (the date logic already exists; it just needs to be in the match path, not the report path).

### 4. Unsupervised "who's here" + one-click cluster naming

**State: PARTIAL. Recommend: close the cluster→POI loop (S–M).**

What VS has:
- Clustering — `cluster_faces.py` HDBSCAN (`:~390-421`), FaceNet embeddings (separate model from the ArcFace match path — worth noting the inconsistency).
- Review/naming UI — `IdentifyFamilyModel.swift` (phases idle/scanning/clustering/reviewing) and `IdentifyFamilyView.swift`; apply-back in `VideoScanModel+FamilyTagging.swift`.
- POI persistence — `POIStorage.swift`: `~/Library/Application Support/VideoScan/POI/<name>/profile.json` + reference image files. **No embeddings persisted in the POI** — profile + photos only.

What's missing for true one-click naming: naming a cluster tags catalog rows, but it does **not** create or extend a POI that the ArcFace matcher then uses. The Immich model — embed everything, group, name the group once, and that name now *is* the identity used for all future matching — is not closed in VS. Closing it: on "name this cluster → Donna," write the cluster's representative embeddings into the Donna POI (which presumes #2's embedding persistence) so subsequent scans match against them. **Effort: S–M**, gated on #2. Secondary cleanup: unify on ArcFace embeddings for clustering so the cluster and the matcher share an embedding space (today cluster=FaceNet, match=ArcFace).

### 5. Apple Silicon / ANE + the concurrency bug

**State: HAVE compute-units; the concurrency strategy is a deliberate throughput cap. Recommend: keep, revisit later (S).**

Current config: every `MLModel` load sets `config.computeUnits = .all` (`ArcFaceEngine.swift:82, 103, 124, 138`) — ANE-eligible, same intent as Immich's CoreML EP `"MLComputeUnits": "ALL"` (`ort.py:157-164`). Immich additionally ships a hand-rolled `ann/` `.mlmodelc` Neural-Engine backend (`machine-learning/ann/`); VS does not need that — `.mlmodelc` + `.all` already targets the ANE.

The concurrency bug interaction (this is the important part): `ArcFaceEngine.swift:14-30, 49-67` documents that even **distinct** `MLModel` instances trip `MLE5BindEmptyMemoryObjectToPort` under heavy concurrent inference. The current mitigation is **two-layered**:
1. A fresh `MLModel` per `getModel()` (`:78-148`), and
2. A **global** `arcfacePredictionLock` serializing **all** `model.prediction(from:)` calls (`:30, :202-221`), plus `VSCatchObjCException` to downgrade the MLE5 NSException from SIGABRT to a logged miss.

So yes — the compute-unit / instance strategy interacts directly with the bug: `.all` routes work through MLE5/ANE, which is where the race lives, and the chosen fix is to **serialize globally**. That makes ArcFace inference single-threaded app-wide regardless of job count. The stress repros (`scripts/run_arcface_super_stress.sh`, `run_arcface_parallel_repro.sh`) exist to exercise exactly this. Consequence: with #1–#3 landed, this lock is the throughput ceiling. Options later: a small fixed pool of serialized model actors (bounded parallelism that empirically stays under the MLE5 race), or pin ArcFace to `.cpuAndGPU` to dodge MLE5 entirely and measure the accuracy/speed tradeoff. **Effort: S** to experiment; leave the lock until a measured need.

### 6. Model & detection choices; alignment

**State: recognition HAVE; detection/alignment PARTIAL (the alignment gap is item #1). Recommend: add landmarks + norm_crop (M).**

- Recognition: VS's `w600k_r50` **is** buffalo_l's ArcFace R50 — already the right cross-decade choice. buffalo_s/m are smaller/faster but lower-accuracy; antelopev2 is the alternative pack. **No change recommended** — buffalo_l is correct for family faces across decades.
- Detection: VS uses **Vision** (`VNDetectFaceRectanglesRequest`, revision 3 — `ArcFaceEngine.swift:289`), not RetinaFace@640. Vision detection is fine and ANE-accelerated. The decisive difference is **landmarks**: Immich's RetinaFace emits 5 landmarks used by `norm_crop` (`recognition.py:77`) to produce a canonical 112×112; VS does **not** request landmarks anywhere (no `VNDetectFaceLandmarks`, no `leftEye/noseTip`, no `norm_crop` — repo grep empty).
- **Alignment — the gap:** `pfNormalizeFaceCrop` (`PersonFinderDetection.swift:105-140`) takes the bounding box, expands it 70%, **de-rotates by roll only**, and scales to a square. That is *not* the 5-point affine warp ArcFace expects. Feeding non-canonically-aligned crops to an ArcFace model trained on `norm_crop` output is a systematic, silent embedding-quality loss.

**Recommendation (this is item #1):** switch detection to `VNDetectFaceLandmarksRequest`, take the 5 canonical points (eyes, nose, mouth corners), and apply an InsightFace-equivalent `norm_crop` affine warp to 112×112 before `arcfaceEmbedding`. Vision's 76-point landmarks map cleanly to the 5 ArcFace reference points. **Effort: M.** Highest accuracy-per-effort change in the whole list.

### 7. Perf at archive scale ("scan whole archive, find Donna")

**State: characterized below.** The real bottlenecks, in order:

1. **Re-embedding everything every run** — no persisted embedding store, so each archive scan redoes detection+ArcFace on every sampled frame. Fixing this (#2) is the single biggest archive-scale win; the pairwise match cost itself is negligible by comparison.
2. **Global ArcFace serialization** (`arcfacePredictionLock`, `ArcFaceEngine.swift:30`) — caps ArcFace inference to one prediction at a time across all jobs. Fine today; a ceiling once embeddings are cached and many faces are queued.
3. **I/O-bound decode** — consistent with the existing perf baseline (scan ~85–90% I/O bound). Frame decode + the `SeekingFrameProvider`/`FramePrefetcher` transport dominate wall time; RAM pre-staging remains the top I/O lever.
4. **Matching is NOT a bottleneck** at current scale — pairwise cosine over a few references is free. It only becomes one if you store the whole archive's faces and skip an index (the #2 → index rationale).

Net: at archive scale the wins are **persist-once embeddings (#2)** and **alignment quality (#1)** — not a faster matcher.

---

## Cross-reference to `immich_ideas.md`

`immich_ideas.md` §4's adaptation sketch is directionally right but mis-prioritized because it assumes ArcFace must be built. Re-anchored:
- §4.1 "Add an ArcFace backend" — **already done** (`ArcFaceEngine.swift`). Replace with **"add 5-landmark norm_crop alignment to the existing backend"** (this doc #1).
- §4.2 "persist embeddings in a vector store" — still the right next step (#2), now correctly a *prerequisite*, not item #2 of equal weight.
- §4.3 greedy assignment (#3), §4.4 birthdate prior (#5 — note the date code *already exists*, just unused in matching), §4.5 cluster naming (#4 — note clustering+naming UI *already exist*, only the cluster→POI write-back is missing).
