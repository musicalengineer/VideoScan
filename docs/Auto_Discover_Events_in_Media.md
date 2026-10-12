# Auto-Discover Events in Catalog Media

**Status:** Design proposal and experiment plan; not an implemented feature.  
**Date:** October 11, 2026  
**Project:** VideoScan

## Purpose

Help Rick discover, group, and associate family events across the media catalog: birthdays, vacations, Christmas, Thanksgiving, weddings, anniversaries, graduations, reunions, performances, and everyday family gatherings.

VideoScan could crawl cataloged media in the background, collect evidence from pictures, speech, people, dates, and existing metadata, and automatically propose associations with events. The result would be an archive browsable by what happened, who was there, and approximately when it happened—even when filenames and folders provide little help.

The central question is: **“Which recordings belong to the same family memory?”**

Examples of the intended experience:

- “Show me all the birthday celebrations we have.”
- “Find videos from our vacation at the beach.”
- “Which clips belong to Christmas 1998?”
- “Show Thanksgiving gatherings with Donna.”
- “Find the other recordings from this event, including files on another drive.”
- “Which events appear in this two-hour tape transfer?”

Initial experiments would use video. The conceptual design should also accommodate cataloged still photographs and audio recordings where the catalog supports them.

## Why Hugging Face is useful

Hugging Face provides a practical place to discover models, inspect model cards and evaluations, download model weights, and compare approaches. Supported models can run locally, allowing family media and derived indexes to remain on Rick's machines. Using the Hub as a model source does not require using hosted inference for the archive. See the [Hub overview](https://huggingface.co/docs/hub/models) and [local-use guide](https://huggingface.co/docs/hub/local-apps).

The experiment should begin with pretrained models and a separate Python environment. Fine-tuning is a later option if evaluation demonstrates a specific gap and enough labeled examples exist. Production Swift integration should follow evidence that the feature is useful.

Candidate directions from the initial discussion:

| Experiment | Potential benefit to VideoScan | Starting candidate |
|---|---|---|
| Scene and activity search | Find birthday cakes, Christmas trees, beaches, snow, or someone playing guitar | [Google SigLIP 2 Base](https://huggingface.co/google/siglip2-base-patch16-224), which supports image-text retrieval and zero-shot image classification |
| Speech search | Find remembered conversations or spoken event names and jump to the relevant passage | [Whisper Small](https://huggingface.co/openai/whisper-small) as an initial transcription baseline |
| Suggested descriptions | Produce searchable descriptions and candidate tags from sampled frames or short clips | [Qwen3-VL-2B-Instruct](https://huggingface.co/Qwen/Qwen3-VL-2B-Instruct) as a small vision-language candidate |
| Better Person Finder matches | Recover difficult matches across age, lighting, motion blur, and camera quality | Evaluate specialized face-recognition candidates against the existing Person Finder baseline; no replacement selected |

These are starting candidates, not claims that they are the best available models or that they already meet VideoScan's needs. Runtime support, Apple Silicon acceleration, memory consumption, licensing, and accuracy on family footage must be measured for each candidate. A Hub listing alone does not establish suitability for a Mac deployment.

Model cards describe intended uses, limitations, evaluations, and licensing, with varying completeness. Record the exact model revision, preprocessing settings, runtime, and license when selecting a candidate. See [Hugging Face's model-card documentation](https://huggingface.co/docs/hub/model-cards).

**Recommended first experiment:** local scene search using SigLIP 2, followed by event grouping. This adds a capability that complements finding Donna and gives us a measurable starting point without immediately requiring a large generative model.

## Distinguish event categories from individual events

The feature needs two levels of organization:

1. **Event category:** birthday, vacation, Christmas, Thanksgiving, wedding, or another reusable label.
2. **Event instance:** a particular celebration or trip, such as “Christmas 1998” or “Summer beach vacation—year uncertain.”

Recognizing a Christmas tree may support a Christmas-related category. It does not establish the year, identify the household, or prove that two recordings show the same celebration. Likewise, a cake alone does not distinguish a birthday from an anniversary or wedding.

An event may span several days and locations, especially a vacation. A vacation may contain a birthday celebration. A single recording may cover several unrelated events. Therefore:

- Associate events with time ranges inside videos as well as whole files.
- Allow multiple associations where appropriate.
- Support optional parent/child relationships, such as a birthday during a vacation.
- Preserve an “unknown” or “uncertain” result rather than forcing every segment into a category.
- Permit grouping an apparent shared event before its type or date is known.

## Evidence available to the crawler

| Evidence | What it can contribute | Important ambiguity |
|---|---|---|
| Sampled frames and short sequences | Decorations, cakes, candles, gift opening, beaches, travel scenes, gatherings, activities | Similar scenes recur across different years and occasions |
| Speech and singing | “Happy birthday,” names, destinations, holiday greetings, or an explicitly spoken date | Transcription can be wrong, particularly with music, silence, or noisy tape audio |
| Person Finder results | Suggested participants and queries such as “Donna at a birthday party” | Identity confidence must remain separate from event confidence |
| Capture metadata | Approximate date, time, camera, and location when present | Digitization, copying, and editing can replace or obscure original dates |
| Filenames, folders, and existing notes | Labels such as “Christmas 1998,” tape numbers, or trip names | A folder may contain mixed events or inherited incorrect labels |
| On-screen text, if later evaluated | Camcorder date overlays, signs, titles, or destination names | OCR errors and incorrect camera clocks require corroboration |
| Relationships among recordings | Nearby capture times, related scenes, matching participants, or overlapping footage | Copies and edits must not count as independent corroborating observations |
| Rick's confirmations and corrections | Reliable event names, dates, membership, and exclusions | Corrections need to survive model upgrades and rescans |

Store the origin of each piece of evidence. Distinguish capture time, filesystem time, transfer time, and user-supplied dates. Preserve date ranges and uncertainty rather than inventing an exact day.

Thanksgiving is a useful stress case: a family dinner is weak evidence by itself. Date context, an existing folder label, or spoken references could strengthen the association. Holiday dates should guide interpretation, not dictate it; families may celebrate on a different day.

## Proposed analysis pipeline

### 1. Select eligible catalog items

Work from the existing catalog and user-selected scope. Consider new or changed items, items with incomplete analysis, and explicitly requested rescans. Treat unavailable volumes as deferred work. A disconnected drive must not cause its previously discovered event associations to disappear.

Use existing stable catalog identity where available, and record a source fingerprint sufficient to detect stale analysis. Paths alone are inadequate when files move. Handle duplicate or derivative recordings as related evidence without changing existing duplicate-detection behavior.

### 2. Sample media at bounded cost

Decode a limited set of frames using a reproducible sampling policy. Start with coarse temporal coverage, then examine promising intervals more closely. Evaluate scene-boundary sampling as an alternative or supplement.

Retain timestamps so every finding can take the user back to its source. Short events may fall between samples; the evaluation must measure this failure mode explicitly. No sparse-sampling approach should claim complete discovery.

Extract audio for transcription only when enabled and useful. Audio-only recordings can contribute speech evidence; video-only media can contribute visual evidence.

### 3. Create reusable observations

Compute image embeddings for semantic search and compare frames with candidate event descriptions. An embedding is a numeric representation used to rank similarity between a frame and a query such as “a birthday cake with lit candles.”

Cache observations so changing a search phrase or grouping rule does not require decoding the archive again. Additional passes could supply transcripts, person matches, OCR, and generated descriptions.

Generative descriptions are suggestions with source references. They must not invent names, dates, family relationships, or authoritative catalog facts. Scene understanding and personal identity recognition require separate evaluation.

### 4. Propose event categories and boundaries

Aggregate evidence across neighboring frames and audio intervals. Suggest an event category, a time range, and a concise explanation, for example:

> Possible birthday celebration, 00:12:30–00:17:45. Cake with candles appears in several samples; “happy birthday” appears in the transcript.

Embedding similarity is a ranking score, not a calibrated probability. Establish thresholds on labeled family footage and distinguish weak single-cue guesses from corroborated suggestions. A displayed percentage should require demonstrated calibration.

### 5. Group recordings into event instances

Retrieve plausible candidate neighbors using date ranges, semantic similarity, participants, location clues, and known media relationships. Evaluate whether they describe the same occasion.

Avoid comparing every catalog item with every other item. At archive scale, candidate retrieval and bounded comparisons are necessary. Also guard against similarity chains: if A resembles B and B resembles C, that does not establish that all three belong to one event.

Strong conflicts, such as reliable dates years apart, should prevent automatic grouping. Missing dates should lower certainty rather than automatically exclude a candidate. Keep recurring holiday celebrations separate unless the evidence supports a shared instance.

### 6. Publish reversible associations

The crawler may automatically attach high-confidence **suggested** associations to catalog items and event groups. Keep lower-confidence candidates available for review without cluttering the main event view.

User-confirmed membership, names, dates, and explicit exclusions take precedence over later model output. Rescanning may add new suggestions but should not silently rewrite confirmed decisions or repeatedly reintroduce a rejected association under the same evidence.

Associations are derived catalog information. Discovery does not rename, move, re-encode, or modify source media, and does not alter existing recovered MXF pair data.

## Background crawling behavior

The intended product behavior is gradual enrichment of the catalog while VideoScan remains responsive.

- Provide an explicit enable/disable control, selected volumes or folders, pause/resume, and an optional processing schedule.
- Begin with background processing while the app is open. Running after the app quits would be a separate design decision.
- Give foreground catalog operations, playback, and Person Finder work priority.
- Bound concurrent decoders, model batch sizes, memory, disk reads, and cache growth; use backpressure between stages.
- Check cancellation between bounded units of work and checkpoint progress for restart recovery.
- Resume interrupted work without creating duplicate associations or repeating completed analysis unnecessarily.
- Detect unavailable volumes and changed source files before publishing results.
- Apply bounded retries and record actionable failures for corrupt or unsupported media. One bad file must not stall the queue.
- Invalidate only affected derived results when source content, model revision, or analysis settings change. Preserve user decisions.
- Show progress by analyzed, pending, deferred, and failed items, along with cache use and the active processing stage.
- Publish prepared, incremental UI updates. Do not perform catalog-wide analysis or O(records) grouping in SwiftUI view bodies.

Model downloads and the scope of analysis should be visible to the user. The proposed default is local inference; hosted demos can be explored with non-sensitive sample media without making cloud processing part of the archive workflow.

## Suggested user experience

An **Events** view could show suggested and confirmed event groups with representative thumbnails, approximate dates, participants, and the number of associated recordings or segments.

Opening an event would show its media timeline, evidence for membership, and direct playback at relevant timestamps. Useful actions include:

- Confirm, rename, or dismiss an event suggestion.
- Accept or reject individual media associations.
- Split an incorrectly combined group or merge two groups from the same occasion.
- Correct dates, locations, categories, and participant labels.
- Add a recording manually or ask for more candidate matches.
- Filter by category, person, date range, location, or confirmation state.

A query such as “Donna at Christmas” would combine independently supported person and event evidence. The UI should make it possible to inspect either source of uncertainty.

Later, confirmed events could supply selections to an existing clip-extraction or compilation workflow. Discovery itself should not automatically generate edited videos or large exports.

## Conceptual information to retain

This is a list of information needs, not an approved database schema:

| Concept | Required information |
|---|---|
| Analysis record | Media identity/fingerprint, model and runtime revisions, sampling policy, status, and completion time |
| Observation | Source media, timestamp or interval, evidence type, result, and provenance |
| Event category | Reusable label and optional user-defined descriptions |
| Event instance | Stable identity, name, categories, approximate date/location, confirmation state, and optional parent event |
| Event association | Media/time range, event identity, supporting evidence, score semantics, and suggested/accepted/rejected state |
| User correction | User-supplied values and membership decisions that override automatic proposals |

Embeddings from incompatible model revisions must not be compared as if they occupied the same feature space. Index rebuilds should be explicit and recoverable.

Persistence, dependency selection, indexing technology, and worker scheduling require a separate implementation review. This proposal does not authorize new dependencies, threading changes, database migrations, or log format/path changes.

## Experiment and evaluation plan

### Phase 1: Scene-search proof of value

Use 50–100 representative clips and approximately 20 written searches. Include old tape transfers, modern digital video, low light, motion blur, short scenes, and mixed-event recordings. Manually identify relevant clips and intervals before scoring the models.

Begin with SigLIP 2 in an isolated Python experiment on the M5. Keep frame sampling fixed when comparing candidates so model quality is not confused with decoding or sampling changes. Verify the selected runtime on that machine before scaling up.

Measure:

- Useful matches among the first ten results and relevant clips missed.
- Processing time per video hour, separating decoding and inference costs.
- Peak memory, cache/index size, and query latency.
- Misses attributable to sparse sampling, poor source quality, or model interpretation.

### Phase 2: Event discovery and grouping

Label a small set of actual events, including repeated holidays across years, similar-looking family gatherings, vacations spanning several days, unrelated scenes on the same tape, and copies or edits of the same footage.

Compare visual-only evidence with visual plus date/path evidence, then add transcription or other signals only when they improve results. Include difficult negatives: an ordinary dinner versus Thanksgiving, a decorated room without a celebration, and a wedding cake versus a birthday cake.

Measure category precision/recall, event-membership precision/recall, incorrect merges, unnecessary splits, and the amount of user correction required. Favor conservative suggestions when uncertainty is high: a falsely merged family event can undermine trust more than a missed suggestion.

Separate threshold tuning from final evaluation by event or source tape, not by adjacent frames. Keep duplicate and near-duplicate footage together in the split to avoid inflated results.

### Phase 3: Bounded background prototype

Exercise incremental processing, pause/resume, cancellation, restarts, unavailable volumes, corrupt media, changed files, and cache limits. Measure foreground responsiveness while analysis runs.

Follow the project's five testing dimensions when implementation begins:

1. **Logic:** category decisions, grouping constraints, segment boundaries, and preservation of corrections.
2. **Scale:** 100,000 synthetic catalog records with explicit time/memory budgets; separately measure inference on a representative real-media sample.
3. **Media matrix:** synthetic `test_*` fixtures covering mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, and avi/dv, plus missing audio/video streams and malformed inputs.
4. **Isolation:** poisoned UserDefaults/cache/path state, incompatible model artifacts, and disconnected volumes must not contaminate results.
5. **Sensor:** retain regression checks for false event merges, correction persistence, bounded queue behavior, and catalog-scale responsiveness.

Route UI-touching evaluation to the M5 or M1, or an explicitly declared M4 quiet window, consistent with project machine policy.

### Phase 4: Integration decision

Proceed to an app implementation only after the pilot demonstrates useful discovery, manageable correction effort, and acceptable processing/storage costs. Set numerical acceptance budgets from the baseline and intended user experience before the final comparison; do not select them after seeing which model wins.

Face-recognition improvements remain a parallel research opportunity. Their key measure is additional true matches at an acceptable false-positive rate, especially among similar-looking relatives. A better event classifier does not establish a better identity matcher.

## Recommended starting scope

Build a local experiment that indexes sampled video frames, supports semantic searches, and proposes birthday, Christmas, Thanksgiving, and vacation associations. Use dates and existing labels as evidence, and produce a reviewable report with thumbnails, timestamps, candidate groups, and explanations.

This first experiment should answer two questions: **Can we find family moments that the present catalog cannot easily reveal, and can we group those moments with little enough correction to be useful?** The findings should determine which additional models and production changes are worth pursuing.
