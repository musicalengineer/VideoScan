# Immich & PhotoPrism face-pipeline audit (2026-08-01)

Source-level audit (shallow clones of both repos, current main) commissioned for the
per-person "Donna recipe" direction — what production photo managers actually do for
people recognition, and what is worth adopting in VideoScan. Verbatim agent report.

## Immich

**Models & runtime**
- Detection: InsightFace RetinaFace/SCRFD family via the `buffalo_l` pack default
  (`server/src/config.ts:312`, `machine-learning/immich_ml/models/facial_recognition/detection.py`
  — wraps `insightface.model_zoo.RetinaFace`, input 640x640, det_thresh default 0.7).
  Supported packs: `antelopev2, buffalo_s/m/l` (`models/constants.py`).
- Recognition: ArcFace ONNX (`ArcFaceONNX` + `insightface.utils.face_align.norm_crop`
  5-landmark alignment). buffalo_l = w600k_r50 ArcFace, 512-d.
- Runtime: ONNX Runtime, provider priority `CUDA > MIGraphX > OpenVINO > CoreML > CPU`.
  CoreML EP is first-class — the same models run ANE/GPU-accelerated on macOS. Batch
  axis patched into the ONNX graph at load for batched embedding.

**Clustering / person assignment** (`server/src/services/person.service.ts:459-541`)
- Not DBSCAN — incremental threshold-linking via pgvector kNN, one job per face:
  1. kNN for `minFaces` (default 3) neighbors within `maxDistance` 0.5 (cosine).
  2. Face is "core" if ≥ minFaces matches AND timeline-visible. Non-core faces are
     DEFERRED (re-queued) so core faces establish persons first — a clean two-phase
     pass without global reclustering.
  3. Assign to nearest match with a personId; else second kNN with `hasPerson: true`;
     else (core only) create a new person.
- Defaults: `minScore 0.7, maxDistance 0.5, minFaces 3`.
- Birthdate prior baked into the vector query: matches exclude persons whose
  `birthDate > asset.fileCreatedAt` (`search.repository.ts:366-370`).
- Full re-run: `force` unassigns only ML-sourced faces, cleans orphan persons,
  re-queues; nightly job skips if no new face since lastRun.
- User feedback: merge reassigns faces and inherits missing name/birthDate onto the
  primary; manual per-face reassign; `PersonCleanup` deletes faceless persons.

**Video handling — ONE frame only.** Detection runs on the asset preview image; for
videos that preview is a single ffmpeg frame chosen with `fps=12 ... thumbnail=12`
over intra-frames only (`-skip_frame nointra`) — "best of first ~12 keyframes"
(`server/src/utils/media.ts:473-513`). No multi-frame scanning at all.

**Quality gating**: only detector score (0.7). No min face size, no blur gate.
Re-detection dedups vs existing faces by IoU > 0.5 and preserves `manual`/`exif`
sourced faces while replacing `machine-learning` ones (SourceType provenance enum).

**Review data model**: `person` table has `name, birthDate, isHidden, isFavorite,
faceAssetId (cover), color`; unassigned faces have `personId = null`; hide vs delete
distinct; merge explicit.

## PhotoPrism

**Models & runtime**
- Detection: ONNX SCRFD 0.5g on 720px thumbnails (model input 640), default score
  0.50 (`internal/ai/face/README.md`, `engine_onnx.go:35`). Legacy pigo detector gone.
- Embedding: TensorFlow FaceNet, 512-d, 160px crops. All embeddings L2-normalized at
  every boundary (creation, midpoint, deserialization) so Euclidean == cosine.

**Clustering** (`internal/photoprism/faces_cluster.go`)
- Batch DBSCAN: `minPts=4, eps=0.64, Euclidean`; runs only when ≥ 8 new eligible
  faces. Each cluster becomes an `entity.Face` (person-cluster row) with stored
  normalized-centroid + `SampleRadius` capped at 0.42.
- Incremental matching (`faces_match.go`): every marker vs cluster centroids; accept
  if `dist ≤ SampleRadius + MatchDist(0.4)` outside collision radius; nearest wins.
  Candidate pruning via 6-bit sign-hash LSH bucket (~98% fewer distance evals).
- Collision resolution (`internal/entity/face.go:178-227`): when a face matches two
  named subjects, the cluster's CollisionRadius SHRINKS to just under the conflicting
  distance and past matches are revised (`ReviseMatches`); dist < 0.02 → cluster
  marked AmbiguousFace and pulled from auto-matching. User corrections literally
  tighten the geometry.
- `Optimize` merges same-subject manual clusters; a VETO list prevents freshly
  user-cleared markers from instant re-match.

**Quality gating — two-tier, production-tuned** (`internal/ai/face/config.go`)
- Detect/keep: `SizeThreshold=25px`, `ScoreThreshold=9` (SCRFD confidence × 100).
- Cluster eligibility much stricter: `ClusterSizeThreshold=60px`,
  `ClusterScoreThreshold=20` — small/low-confidence faces get markers but never seed
  or vote in clusters.
- Face kinds: `RegularFace / ChildrenFace / BackgroundFace / AmbiguousFace`.
  Child-like and background-like embeddings (matched vs curated static clusters) are
  EXCLUDED from auto-matching by default because they cluster unreliably.

**Video handling — also one frame**: ffmpeg preview still at a duration-dependent
offset (28s / 58s / 2m28s for >3m / >10m / >1h — skip intros/black leaders,
`internal/ffmpeg/encode/offset.go`).

## Worth stealing for VideoScan (ranked)

1. **Two-tier quality gates — loose to record, strict to cluster** (PhotoPrism
   25px/9 keep vs 60px/20 cluster). Most production-proven idea here: in home video
   most frames yield tiny/blurry faces — let them be MATCHED against known people
   but never let them DEFINE a person.
2. **Core-face two-phase incremental assignment** (Immich): a face only spawns a new
   person with ≥3 neighbors in threshold; otherwise defer and attach later. No global
   recluster on ingest. Combine with PhotoPrism DBSCAN(4, 0.64) as periodic batch.
3. **Birthdate prior inside the match query** (Immich): refuse matches to persons not
   yet born at asset date. One WHERE clause — Rick's priors design, proven cheap.
4. **Collision radius / ambiguous state** (PhotoPrism): when Donna's cluster starts
   absorbing the boys, one correction shrinks the acceptance radius and re-scores
   past matches; sub-0.02 collisions flag ambiguous instead of guessing. Best
   "two-wars error model" mechanism in either codebase.
5. **Face provenance + IoU-dedup on re-scan** (Immich SourceType): manual faces
   survive model upgrades; only ML faces replaced, matched old-to-new by IoU > 0.5.
6. **Normalized-centroid person prototype + capped learned radius** (PhotoPrism):
   person = L2-normalized mean embedding + radius (cap 0.42), accept ≤ radius + 0.4.
   Cheap, explainable in-process matcher shape.
7. **Veto list for user-cleared matches**: "not Donna" must stick across re-runs.
8. **Person data model**: isHidden/isFavorite/cover-face/merge-inherits/cleanup job.
9. **Sign-hash LSH bucketing** before exact distance, if matching ever profiles hot.
10. **Model choice validation**: both ship SCRFD + 512-d ArcFace/FaceNet ONNX;
    Immich treats CoreML EP as first-class — supports VideoScan's ArcFace/AdaFace
    path over Vision feature prints.

## Key negative finding

NEITHER product scans video for faces — both run detection on exactly one
ffmpeg-extracted preview frame. VideoScan's multi-frame temporal scanning is
genuinely beyond both. The only video-specific trick worth copying is PhotoPrism's
duration-scaled seek offsets for representative frames. Everything else transferable
is cluster hygiene, not video.
