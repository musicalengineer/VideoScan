# Media Analyzer — Family-Specific Face Recognition

Research notes and implementation plan for solving VideoScan's core challenge:
reliably identifying individual family members across decades of home video.

**Status:** research / planning. No code yet. Diagnostic is the proposed first
build step.

**Related:**
- `docs/media_longterm_plan.md` — four-disposition lifecycle vision
- `docs/issue-06-custom-face-model.md` — earlier notes on custom models
- GitHub issue tracking the north star: identifying family across decades

---

## 1. Why generic face recognition fails on a family

Generic face embedders (Apple Vision FeaturePrint, ArcFace, dlib's ResNet) are
trained on datasets like MS-Celeb or VGGFace containing millions of *unrelated*
people. The training loss maximizes between-person separation across that
distribution — and that distribution does not look like Rick's family.

Three confounders dominate embedding distance for family video:

1. **Genetic similarity.** Siblings, parents/children, and often spouses share
   facial geometry. The embedder never learned to resolve this because random
   pairs in the training set don't share bone structure.

2. **Age drift within person.** Donna at 28 vs Donna at 58 lives in very
   different regions of embedding space. For a generic embedder, within-person
   distance (Donna-young vs Donna-old) often **exceeds** between-person
   distance (Donna-today vs her sister-today).

3. **Source drift.** VHS 480i at 6 Mbps vs iPhone 4K. Compression artifacts
   and interlace eat the fine features that drive identity.

For strangers, confounder (1) is tiny and identity dominates. For family
across decades, (1)+(2)+(3) collectively exceed identity.

**This is not an algorithm bug. It is a property of the feature space.**
No amount of threshold tuning will fix it. The embedder must either be
replaced, adapted, or augmented with a family-aware classifier on top.

---

## 2. ROI-ordered plan

### Tier 1 — Diagnostic first (do before anything else)

Before committing to training, quantify how confused the embedder actually is
on *this* family's data. Build a **family-confusion matrix**:

- For each pair of family members, compute all cross-person embedding
  distances among their reference photos (mean + stddev).
- For each person, compute within-person distances across age ranges.
- If within-person-across-ages distances overlap between-person distances,
  the embedder is proven unsuitable and the gap is sized.

**Output:** CSV + heatmap PNG. Rows = (person, age bucket), columns = same,
cell = mean embedding distance. Flags confusable pairs where between-person
distance < within-person distance.

**Effort:** one afternoon. ~200–300 lines. No app surgery.

**Decides:** whether Tier 2 (classifier on frozen embeddings) can work, or
whether Tier 3 (embedder fine-tuning) is required.

### Tier 2 — Family-specific classifier on frozen embeddings

Don't retrain the embedder — train a *classifier* on top of it.

- Extract ArcFace 512-D embeddings for every POI reference photo.
- Train a linear SVM or small MLP:
  `embedding → {Rick, Donna, Tim, Timmy, Matt, Dan, unknown}`
- Probability calibration gives confidence + "unknown" via threshold.
- **Key trick:** age-bucket each person (child/teen/adult/senior) as
  sub-classes, unified at decision time. Lets the classifier see Donna-25
  and Donna-55 as different clusters that both map to "Donna."

Why this beats nearest-neighbor matching: the decision surface can express
"within 0.4 of Donna's centroid AND further than 0.3 from Rick's centroid
→ Donna." Nearest-neighbor can't express that.

**Pipeline:** trained in Python, exported as CoreML, plugged in as a new
engine in the existing four-engine dispatch (alongside Vision, ArcFace,
dlib, Hybrid).

**Effort:** 1–2 weeks. Offline training script + CoreML export + Swift
engine plumbing.

### Tier 3 — Fine-tune the embedder (heavy lift — only if Tier 2 plateaus)

Take pretrained ArcFace, freeze early layers, fine-tune final layers with
triplet loss on family pairs. Produces a new embedder where, e.g., Donna
and her sister are explicitly pushed apart in the feature space.

- Requires ~100+ photos per person.
- PyTorch + `facenet-pytorch` or InsightFace training code.
- Export via `coremltools` to ANE-friendly CoreML.

This is the "train a model on my family" goal in its strongest form. But
Tier 2 typically gets 80% of the way for 20% of the work — do the
diagnostic first to decide if Tier 3 is needed.

### Tier 4 — Active learning loop (ongoing, cheap)

Accept a two-stage pipeline:

1. **Coarse stage:** generic FD finds "face present, clip ≥ 30s" → marks
   "needs review."
2. **Fine stage:** family classifier assigns IDs with confidence.
3. **Human stage:** Rick reviews low-confidence matches; corrections
   become new training data.

Every review session improves the next model. Over a year the classifier
becomes specific to *this* family, *these* videos, *these* decades. This
is the real long-term play.

---

## 3. Data sourcing — the binding constraint

Classifier quality is gated by per-person-per-decade photo coverage:

| Tier           | Photos per person per decade |
|----------------|------------------------------|
| Minimum viable | 20–30                        |
| Good           | 50–100                       |

Existing POI reference photos likely skew recent. Filling in, e.g.,
"Donna-in-the-90s" probably means scraping the already-scanned video
collection (ironic bootstrap: you need the classifier to build the
classifier).

**Bootstrap source:** Apple Photos' People album. Per Issue #18 analysis,
identity metadata can't be imported via public PhotoKit API, but the
curated photos themselves can be pulled by hand through PhotosPicker.
Rick's Apple Photos library is already the best-curated training set
for his own family.

---

## 4. Two-stage pipeline — Rick's own insight

> "Maybe they're good enough for 'are there people in this video,
> is it longer than 30 seconds, mark as needs review.'"

This is the correct framing and it maps cleanly onto the tiers:

- Generic FD → **triage** (cheap, fast, runs on every file)
- Family classifier → **identification** (run on triage survivors)
- Human review → **correction + training data** (closes the loop)

This decomposition is far more tractable than an end-to-end
"find Donna" problem. It also lets the four existing FD engines
stay useful — they become the triage layer, not the identity layer.

---

## 5. Recommended next step

**Don't start training yet. Build the diagnostic first.**

- Run all three engines (Vision, ArcFace, dlib) over every POI reference
  photo.
- Compute the family-confusion matrix.
- Produce CSV + heatmap.
- Flag confusable pairs.

That matrix tells us:
- Which family members the current embedders can/can't separate.
- Across which age ranges.
- Whether Tier 2 or Tier 3 is the correct next investment.

No model training until we've measured the problem.

**Implementation choice:** pure Python script under `scripts/` — fastest
to iterate, uses existing face engines Rick is already set up with.
Output is a PNG + CSV; no Swift/app changes needed for the diagnostic
itself. App integration comes in Tier 2 when we have a trained model to
plug in.
