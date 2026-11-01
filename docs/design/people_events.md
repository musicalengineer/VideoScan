# People, events and segments — who is in it, which memory it belongs to, how the family is related

Status: built — 2026-11-01, with one part proposed and one parked. Built: Triage ▸ Events v1, the related-score ladder, the audio fingerprint engine (stamped overnight), Compare Media, kinship inference, CyberBrain's writer and Hallie's AnswerPlan boundary, GEDCOM import/export. Proposed, not built: segments (Part II). Parked: recognition across footage (frozen 2026-10-23; Find & Tag and the People tab stay).

"Which recordings belong to the same family memory?" and "who is in it, and how are we related?" — the MANAGE stage's knowledge of people and occasions. Events group recordings by occasion on evidence that keeps its source (capture adjacency says *which* event, models only *what kind*), Rick confirms, and a dismissed suggestion does not come back on the same evidence. A ladder of evidence (identical copy → same recording / clip of → recorded at the same time → same occasion → related) relates two recordings in words, not a blended score. The family tree (GEDCOM) is the fact store for the ancestors; the People tab holds the living immediate family; kinship is derived from four stored primitives; CyberBrain holds what the family knows as inspectable data, never as model weights. Segments (proposed) would mark moments inside a long tape.

**Contents:** Part I — The built designs, summarised, with their open questions verbatim · Part II — Segments and content coverage (proposal, 2026-10-10, whole) · Part III — GEDCOM export and import (guide, whole) · Part IV — Family Tree research sources (summaries).

*Consolidated 2026-11-01 (DECISIONS 2026-11-01). Full texts of the summarised designs are in `docs/archive/design/` (and `docs/archive/guides/facial-recognition.md`, `docs/archive/research/`) with their names; code comments cite their sections there. Contracts: `docs/ARCHITECTURE.md` §10.8. Models (faces, captions, embeddings): `docs/design/machine_intelligence.md` Part II.*

# Part I — The built designs

## Events (unified design v2, 2026-10-12; Triage ▸ Events v1 built)

`docs/archive/design/events_design.md`. Ten principles govern it: models say *what kind* of event, capture adjacency says *which*; two levels (category and instance), with associations on ranges inside files as well as whole files; identical recording, shared footage and event membership are never confused; evidence keeps its source (capture, file, transfer, folder, OCR and Rick's dates are never blended, and event duration is not date uncertainty); suggest, then confirm, with Rick's decisions stored apart from model output; no circular corroboration; nothing touches media; local by default; calm, honest words with no percentages until calibrated on Rick's footage; Rick's attention is the scarce resource. Its open questions, verbatim:

*From `events_design.md` §11 (2026-10-12).*

#### 11. Open questions for Rick (one at a time)

1. Cloud use on derived *text* (captions, transcripts): allowed for later labelling steps, or local only?
2. Should confirmed events become visible in the Catalog (tags/folders), or stay inside Events?
3. Which categories matter most beyond the holiday set — music jams, school events, first days, Berklee sessions?

## Related score — the ladder of evidence (2026-10-14; `RelatedScore` built)

`docs/archive/design/related_score_2026_10_14.md`. Two recordings get one headline word, decided by the strongest evidence that holds, with every supporting and contradicting line underneath — a ladder, not a weighted sum: 6 identical copy (same whole-file SHA-256) · 5 same recording / clip of (audio landmarks at one offset, or the video barcode for silent footage) · 4 recorded at the same time · 3 same occasion (Events inputs, people, transcripts, captions, folder labels; no reliable-date conflict) · 2 related (same people, place or season, another day) · 1 no connection found. Its open questions, verbatim:

*From `related_score_2026_10_14.md` §7.*

#### 7. Open questions for Rick (one at a time)

1. Should rung 4 ("recorded at the same time") merge two Events
   suggestions automatically, or only pre-answer the question?

## Audio fingerprint engine (2026-10-14; built, stamped overnight)

`docs/archive/design/audio_fingerprint_2026_10_14.md`. The question is containment — "is this 90-second clip cut from that 16-minute master?" — which is copy detection with time alignment, not semantic similarity; a Shazam-style landmark fingerprint on the audio is the robust, cheap, local tool (audio survives container changes that break video stream hashes). Decode (`AudioPCMDecoder`) → fingerprint (`AudioFingerprint`) → match (`AudioFingerprintMatcher`, verdicts with an offset in seconds). Results on 2026-10-14: the synthetic matrix green (every positive at the expected verdict within 0.014 s, 15/15 negatives different, margin 7.6×); a 60-minute master fingerprints in 2.5 s (budget 6 s), 13.3 KB per minute. RMS normalisation and a `dt ± 1` probe were added to get there.

## Compare Media — the Event Analyzer view (2026-10-15; built as `CompareMediaView`)

`docs/archive/design/event_analyzer_compare_media_2026_10_15.md`. Replaces the Catalog's "Compare these two files": a verdict band (SAME EVENT · CLIP FROM SAME EVENT with its offset · SAME EVENT, DIFFERENT CAPTURE · DIFFERENT EVENTS), a filmstrip of significant frames (never leaders), eight recommendation rules that weigh the verdict against what the archive already holds, and the evidence behind each line from engines that already exist. Its rulings, verbatim:

*From `event_analyzer_compare_media_2026_10_15.md` §8.*

#### 8. Rulings

1. **No DVD-rip exception (Rick, 2026-10-15).** A DVD rip is a transfer like any other;
   the physical disc in the box is the backup ("I still have the actual DVD … a box of
   DVDs, tapes, CDs, DATs"). R3 applies when the archived master covers the rip end to end
   (sound coverage at one offset over the whole length); minutes only the rip holds turn
   the verdict yellow (R5, keep both) and are named in the band. Example: a 2026 FFV1
   ClearClick capture of Christmas 1995 against its 2006 DVD rip → SAME EVENT, R3, the
   4.2 GB rip goes, the disc stays in the box.
2. **Older generations first.** The archive's centre of gravity is the 1940s–1990s, where a
   capture may be the only copy of an afternoon that exists; post-2010 footage has copies
   to spare. So for content dated before 2000, R4 ("this transfer is better — promote it")
   is offered before any removal rule, and R3 never removes the only transfer of a
   recording that is not yet archived (that is R6).

## Kinship inference (2026-08-29, Rick "go"; built as `FamilyKinshipInference`)

`docs/archive/design/kinship_inference_design.md`. Only four relations are stored primitives — parent, child, spouse, sibling (sibling only when the shared parents are not both recorded) — and every other relation (grandparent, aunt/uncle, cousin, in-laws) is derived by path composition over that graph, joined to the GEDCOM graph through anchors (a People profile anchored to a tree person). Validation on save is deterministic (no self-relation, no parent cycle, at most two parents, no duplicate). Derived relations are reviewed once per change set, not per row. Siblings default to full; no step or adoptive relations in this generation. Two Codex amendments (2026-08-29, 2026-09-02) were accepted.

## CyberBrain — the family knowledge architecture (2026-08-16; built through the writer and the AnswerPlan)

`docs/archive/design/cyberbrain_design.md`. Hallie's private, durable knowledge layer: family-tree facts, curated biographies, attributed anecdotes, archive evidence and conversational context, without training any of it into a model. The central rule: family knowledge lives in inspectable data; a model may interpret a question and phrase an approved answer, but it is never the authority for a family fact (DECISIONS 2026-08-16). A source hierarchy, stable identity, dated and disputed facts kept with their sources, privacy rules, and an AnswerPlan boundary before Hallie speaks. It is written only through `CyberBrainWriter` under a root lock (ARCHITECTURE §10.8). Its decisions requested before Phase 1, verbatim:

*From `cyberbrain_design.md` §16 (2026-08-16). CyberBrain code has shipped since (`CyberBrainWriter`, the loader, index and corrections); DECISIONS records the central rule (2026-08-16) but not each answer below, so treat them as the record of what was asked.*

#### 16. Decisions requested before Phase 1 code

1. Confirm **CyberBrain** as the UI/product name and
   `Breen Family CyberBrain` as the default archive display name.
2. Approve the proposed private/family/public privacy levels.
3. Decide whether a manually curated People-profile note may be imported as
   `probable`, or must always enter as `uncertain` pending review.
4. Approve a persisted UUID migration for People profiles.
5. Choose whether initial authoring is JSON/Markdown-only or includes a small
   in-app editor in Phase 1.

All other Phase 1 work can remain additive and read-only until these decisions
are settled.

## Facial recognition and person search (guide, 2026-09-16; recognition frozen 2026-10-23)

`docs/archive/guides/facial-recognition.md`. Two workflows: Person Finder / Search (scan video for a selected person, report time segments, extract and compile clips) and Find & Tag (a per-person recipe that writes machine-tier catalog tags). Engines: Vision (the default), ArcFace and AdaFace (CoreML), Hybrid; neither workflow confirms on the user's behalf. On 2026-10-23 Rick froze the recognition machinery: POI search across footage is no longer the strategy (ARCHITECTURE §3, People). The People tab remains the source of truth for the inner circle's dates and profiles. Recognizing people is now proposed as a constraint problem — the household roster for a date window, with model attributes only, never names (`docs/reviews/household_roster_feasibility.md`, Charter §4).

# Part II — Segments and content coverage (proposal, 2026-10-10)

*From `design/segments_and_content_coverage_2026_10_10.md`, whole; archived at `docs/archive/design/`. Still a proposal: no segment model is in the source on 2026-11-01. Its §8 decisions are open.*

> **Superseded assumptions — read before implementing (Codex docs review F09, 2026-11-01).** This proposal predates the
> SQLite cutover (2026-10-18) and the catalog contracts (`docs/ARCHITECTURE.md` §10.1). Where it says otherwise, the
> contracts win: (1) **storage** — §3.2's JSON sidecar (`segments/segments.json`, option B) and "a new schema is an
> escalation item" are superseded: curated knowledge lives in `catalog.sqlite`, keyed by digest, written only through
> the one commit door, as an additive migration Rick approves (CLAUDE.md rule 6); `catalog.json` is frozen history;
> (2) **identity** — §3.3's `referenceContentHash` as `contentHash` (`v1:`, head‖middle‖tail‖size) is superseded:
> identity is the **whole-file SHA-256** (`content.digest`), and a sampled `v1:` hash never says "same" (§10.2); the
> `FootageKey` should name the reference content by digest; (3) Rick's knowledge attaches to **content**, so a segment
> is keyed to a digest plus an alignment, never to a record UUID or a path. The segment model, alignment and marking
> workflow (§§3.1, 3.4–5) are unaffected. §8's decisions stay open.


*Design, 2026-10-10. Status: PROPOSED, no code changed. Author: Claude (design agent, worktree branch `design/segments-content-coverage-2026-10-10`). Trigger: the family demo miss — "the Hudsons at Thanksgiving 1984" is inside a 94-minute VHS capture and nothing in the catalog could say so, let alone where. Related: `docs/design/hallie_proposer_with_tools_design.md` §R6 (item 5 names this document), `docs/design/scene_captions_plan.md`, `docs/design/catalog.md`, `docs/ARCHITECTURE.md` (goals 2 and 4).*

### 0. Summary

Rick's framing (2026-10-10): a segment is a **time marker inside a long tape** — "Breens at t=x, Donna at t=y, Hudson house at t=z" — searchable by tags such as "hudsons" or "bonnie". Face recognition alone failed because family members look too alike across decades, so the design leans on **cheap human tagging of time ranges** (mark in/out while watching, one keystroke, type a tag) with machine-proposed boundaries as a helper, not on identity recognition. Physically cutting files into sub-clips is not the goal; segments are metadata.

1. **A file is not an event.** Most of the archive is digitized tape: one record, 60–160 minutes, three or four occasions, several copies and re-encodes of the same footage. The catalog models one event per file. This design adds **segments**: time ranges inside footage, each with its own tags, people, event, place, date (with confidence and reason) and notes.
2. **Segments are keyed to content, not paths.** A segment belongs to the *footage*; every copy, re-encode and trim of that footage sees it through an alignment (offset, scale). FamilyArchive files stay byte-identical: segments are catalog metadata only, never file edits.
3. **The demo file was never analyzed because Analyze does not look at archived or in-triage records** (`CatalogWideMetadataCandidates.swift:46-47`). 74 archived and 41 in-triage FamilyArchive videos never entered the loop, and the log cannot say so because they are filtered out before counting. **Rick ruled 2026-10-10: Archived and In Triage media are analyzed** (read-only analysis, catalog metadata only). Most of the gap is fillable for free: 75 of the 94 FamilyArchive videos with no captions and no transcript have a same-footage sibling that already has them.
4. **Even "analyzed" tapes are not covered.** Every FamilyArchive video longer than 30 minutes (127 files, 154 h) carries 3 or 5 scene captions and one transcript blob with no timestamps. Coverage has to be measured per minute, not per file.
5. **Human first, machine second.** The primary input is Rick (or any family curator) watching a tape and pressing one key at the start and end of a moment, then typing "hudsons". Machines propose boundaries from timestamped Whisper segments, shot changes, burn-in dates and (as a weak signal only) face-set changes, so the human mostly confirms instead of scrubbing. Everything runs locally on Apple Silicon; the fleet shares work over the LAN only.
6. **Search returns moments, not files**: "show me the Hudsons at Thanksgiving" → the 1984 tape, segment "Thanksgiving at the Hudsons" starting 0:52:10, Play. Hallie gets `search_media` and `get_segment` tools under the data-class policy.

### 1. The case that failed, in catalog terms

Read-only facts from `~/Library/Application Support/VideoScan/catalog.json` (version 6, 13,792 records, saved 2026-10-10 21:07Z). Thirty-one records match "Thanksgiving 1984". The footage behind the demo exists as three footage groups plus loose clips:

| Record | Where | Stage | Length | Codec / size | Dossier | Text |
|---|---|---|---|---|---|---|
| `1984-xx-xx_1984-xx-xx_Thanksgiving-1984_Improved_slp.mov` (the one Rick opened) | FamilyArchive/1984 | Archived · Master | 93.8 min | hevc 3.0 GB | none | none |
| `1984-xx-xx_Thanksgiving-1984_Improved_slp.mov` (same footage group `12E65CE9`) | FamilyArchive/1984 | Archived · Master | 93.8 min | prores 18.8 GB | 2026-07-14 | 3 captions, 44,061-char transcript |
| `1984-11-xx_Thanksgiving_1984.mkv` (was `Mark_Bday_Thanksgiving_1984.mkv`) | FamilyArchive/1984 | Archived · Master | 96.0 min | ffv1 40.3 GB | 2026-07-15 | 3 captions, 45,227-char transcript |
| `Mark_Bday_Thanksgiving_1984.mkv` (byte-identical original) | MediaExpansion | Cataloged | 96.0 min | ffv1 40.3 GB | 2026-10-03 | same text; date reason "spoken now-cue 'keep going on thanksgiving… 1984'; age 1 fits Mark (born 1983)" |
| `…Thanksgiving-1984-partial-2.dv` + `.mov`, `_02.mov`, `.vs.preserve.mkv` | FamilyArchive/1984 and /Undated | Archived / In Triage | 76.9 min | dv, hevc, ffv1 | dv only (catch-up) | 3 captions, 37,686-char transcript on the dv |
| `AtHudsons-Thanksgiving-1984.mov`, `HudsonThanksgiving1984-Glen.mov` | LaCie, Projects, ~/Movies | In Triage / Cataloged / Trashed | 4.0 / 1.9 min | dv | yes | 3 captions, 2,683 chars |

What the data already knew and could not surface:

- The transcript of the prores sibling contains *"next to him we have Mr. Glenn Hudson, who works for Northwest Orient Airlines"* — one hit, but the transcript is a single string (`VideoRecord.swift:312-317`: "Whisper produces a single text blob, not per-frame entries"), so there is no time to seek to. It also contains "happy birthday" 36 times and "thanksgiving" 3 times: two events on one tape, unlocatable.
- The three captions sit at 4:41, 46:54 and 89:07 (`framesEvenlySpaced(framesPerFile: 3, …)`, `CaptionOrchestrator.swift:283`). A 94-minute tape gets one frame per half hour.
- The `.dv` partial carries a start timecode `00:40:40:00`; the `.mkv` and `.mov` copies carry none. The footage grouper already knows the hevc copy and the prores copy are the same footage (`footage.groupID 12E65CE9`, role `reEncode`) and shared the **date** across them ("footage-shared from …") but not the captions or the transcript.
- `detectedPeople: ["Donna"]` is a per-file bag. The PersonFinder cache (`personfinder_cache.sqlite`, table `pf_cache`, column `segments_json`) already holds per-person presence spans `{s, e, ad, bd}` for 7,346 paths — keyed by path, so a copy or rename loses them.

### 2. Why the file was never Dossier-processed (coverage root cause)

#### 2.1 The gate

`startCatalogWideDossier` builds its candidate list through `pfCatalogWideMetadataCandidates` (`CaptionOrchestrator+Dossier.swift:248-251`), whose first test is the lifecycle gate:

```swift
// VideoScan/VideoScan/Catalog/CatalogWideMetadataCandidates.swift:44-47
return records.filter { rec in
    let stage = rec.lifecycleStage
    guard stage == .cataloged || stage == .workbench else { return false }
```

The header comment (lines 9-11) says why: "skips Archived, Deleted, Trashed, In Triage. The intent is 'live media we might still consume', not media already retired" (2026-06-04 roadmap, Q5 option c). That predates Promote: every archive copy is created with `lifecycleStage = .archived` (`VideoScanModel+MasterArchive.swift:1281`), so **by construction no FamilyArchive master ever enters the Dossier loop.** The per-volume `startAnalyzing` path uses the same predicate (`CaptionOrchestrator+Dossier.swift:112-123`), so "Analyze" on the FamilyArchive row has the same hole.

The 11:36 log line — `0 processed, 1155 skipped (1155 already analyzed, 0 missing, 0 protected), 28 failed` (`CaptionOrchestrator+DossierSteps.swift:198`) — is honest about the 1,183 records that passed the gate (`dossierSkipReason`, `:95-101`, found a `dossierProcessedAt` on 1,155 of them). It is silent about the 1,264 scope exclusions it does log one line earlier and about the lifecycle exclusions it never counts. The dashboard tooltip even lists "Archived = already put away" as a category, so the UI presents the gap as intended.

The 28 "failed" are `CaptionRunnerError` case index 2 = `videoUnreadable` (`CaptionRunner.swift:133-143`): Avid audio-essence MXFs probing as Video+Audio, plus a few reference movies. They fail in under a second each and are re-tried on every pass; a side fix is to flag them `needsReformat` the way `flagUndecodableIfExtractorBailed` does for the 0-scene case.

#### 2.2 Why the sibling's text did not help

Promote copies the dossier text from the source record to the archive copy (`VideoScanModel+MasterArchive.swift:1302-1310`; `snapshotClone` does the same, `VideoRecord+Clone.swift:115-129`). That is why the prores master has captions: its source had them before promotion. The hevc copy Rick opened was made by Archive Angel from a buffer record that had never been analyzed, then promoted — nothing to copy. Afterwards two mechanisms could have back-filled it and neither does text:

- **Byte-twin propagation** (`VideoScanModel+DateInference.swift:119`, "propagated from <uuid>") keys on `contentHash` / partialMD5+size. A re-encode has a different hash.
- **Footage-group sharing** ("footage-shared from <uuid>", confidence 0.95 on the hevc copy) shares the **date only**.

So the rule is: text is copied once, at promotion, from one parent; it never flows later or sideways. Content identity (the footage group) exists and is not used for text.

#### 2.3 Size of the gap (FamilyArchive, live records only)

"Live" = not purged, not set aside, not superseded: 659 of 679 FamilyArchive records. 390 are audio-only (Pro Tools and Berklee sessions, out of Analysis Scope by default); **268 are video, 165.4 h.**

| FamilyArchive video (268 files, 165.4 h) | Files | Hours |
|---|---|---|
| no `dossierProcessedAt` | 116 (74 Archived, 41 In Triage, 1 Cataloged) | 91.1 |
| no scene captions | 94 | 78.8 |
| no transcript | 100 | 78.9 |
| neither captions nor transcript | 94 | 78.8 |
| …of which a same-footage or same-bytes sibling HAS text (carry-over, no decode needed) | 75 | 66.0 |
| …genuinely never analyzed anywhere (13 Archived, 5 In Triage, 1 Cataloged; 8 over an hour) | 19 | 12.8 |
| longer than 30 min | 127 | 154.4 |
| longer than 30 min with ≤ 5 captions | **127 of 127** | 154.4 |

(The Manager's testing agent counted 527/679 with no `dossierProcessedAt` including purged and audio-only records; the two counts agree once scope is matched.) Whole catalog for the upper bound: 5,451 live videos, 490.4 h; 906 (132.1 h) have no text at all.

The last two rows are the real finding. Per-file coverage of FamilyArchive video is 65 %; **per-minute coverage of long tapes is effectively zero**, because 3–5 captions and an untimed transcript cannot place an event. The "✓ analyzed" on the dashboard must become a per-analyzer, per-minute coverage figure (the Analyze-as-coverage-view direction already agreed 2026-09-26).

#### 2.4 Fix shape (decided)

1. **Stage gate — RULED 2026-10-10 (Rick): Archived and In Triage media are analyzed.** `pfCatalogWideMetadataCandidates` admits `.archived` and `.reviewing`; `.trashed`, purged, set-aside and confirmed-junk stay out. It is read-only analysis that writes catalog metadata only, inside the 2026-09-27 ruling ("background jobs may add metadata (notes, transcripts, captions, verify results, footage groups) but never write an archived record's date or name"). The one thing to pin with a test before the gate opens: `applyDossier` must not write `inferredRecordDate`/`inferredDateReason`/`userDate` on an archived record — the date lane already skips archived rows for propagation; the dossier apply path needs the same guard. The Archive Angel `_improved` derivatives on the archive volume (the hevc copy Rick opened) become eligible the same way.
2. **Text carry-over by content identity.** A new cheap cycler ("Share text across copies"): for each footage group and each contentHash set, if one member has captions/transcript/OCR and another has none, copy them with provenance `textSource: "shared from <uuid> (same footage)"` and the alignment from §3.4 (identical length → offset 0; otherwise mapped). 75 files, 66 h, minutes of CPU, zero decode. This is the footage-group date-sharing rule extended to text.
3. **Log the exclusions.** The batch START line reports lifecycle exclusions by stage alongside the scope exclusions it already reports, and the OUTCOME line carries "N not eligible (stage)". A sensor fails when an eligible-by-ruling archived video has no text after a full pass.

### 3. The segment model

#### 3.1 What a segment is

A segment is a claim about a stretch of **footage**: "from 52:10 to 1:08:40 of the 1984 Thanksgiving tape is Thanksgiving dinner at the Hudsons' with Glenn and Joy Hudson, Donna, Rick, Mark; November 1984 (estimated); place: Hudsons' house". It carries its own evidence and its own confidence, and it belongs to the footage, not to any one file.

```swift
// VideoScanCore (value types; Codable, Hashable, Sendable)
public struct MediaSegment: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    /// The footage this segment is about (§3.3). Not a path, not a record id.
    public var footage: FootageKey
    /// Position on the footage's reference timeline, in seconds.
    public var start: Double
    public var end: Double
    /// Family words. "Thanksgiving at the Hudsons"
    public var title: String
    /// Normalized occasion from the existing lexicon (DateTriangulator.occasions):
    /// "Thanksgiving", "Birthday", "Christmas", "Trip"…; nil when unknown.
    public var event: String?
    public var people: [SegmentPerson]       // name/UUID + confirmed|machine
    public var place: String?                // same conventions as userPlace
    public var date: String?                 // reduced-precision ISO like userDate: "1984-11"
    public var dateConfidence: Float?
    public var dateReason: String?           // the WHY, Rick's rule (GH #201)
    public var tags: [String]
    public var notes: String
    /// Who made it and whether a person has confirmed it.
    public var origin: SegmentOrigin         // .user | .proposed(method:version:) | .confirmed(from:)
    public var evidence: [SegmentEvidence]   // what the machine saw, each with its own time
    public var createdAt: Date
    public var modifiedAt: Date
}

public struct SegmentPerson: Codable, Hashable, Sendable {
    public var personID: UUID?               // People tab UUID when known
    public var name: String                  // display name / alias as spoken
    public var confirmed: Bool               // Rick said so vs. machine tier
}

public enum SegmentEvidence: Codable, Hashable, Sendable {
    case spoken(at: Double, text: String, cue: String)       // "happy birthday", a name, a now-cue
    case facePresent(name: String, from: Double, to: Double, score: Float)
    case shotChange(at: Double, score: Float)
    case burnIn(at: Double, text: String)                      // "NOV 22 1984"
    case caption(at: Double, text: String)                     // VLM scene caption of a keyframe
    case gap(from: Double, to: Double, kind: String)           // black, silence, tape noise
}
```

C++ reading: `MediaSegment` is a plain struct with value semantics (a copy is a copy); `SegmentEvidence` is a tagged union (`std::variant`) whose cases carry payloads; `Codable` is the generated serializer. Nothing here is a class with identity — segments live in a store (§3.2) and are looked up, not pointed at.

Rules, matching the rulings already in force:

- **Machine tier is visible as machine tier.** A `.proposed` segment is dashed in the UI and worded as a suggestion ("looks like a birthday"); `.confirmed`/`.user` segments are plain. Angel's "words not grades" and "signal over noise" apply: a proposal must clear a 2-minute floor unless it carries a strong cue (the birthday song, a burn-in date change).
- **People in a segment never contradict the record.** A `rejectedPeople` name on the record cannot appear confirmed in a segment of it.
- **Segments never touch files.** No file edits, no `00_Index` entry, no ledger line. Archived masters remain fixed content. `Update…` (rename/date) leaves segments untouched because they are keyed by content, not path.
- **Search never matches a `.proposed` person claim as a fact** (Hallie's confirmed-tag-only rule, §5).

#### 3.2 Storage

Three options were weighed:

| Option | Shape | For | Against |
|---|---|---|---|
| A. Inline on `VideoRecord` (`segments: [MediaSegment]`) | additive optional field, same migration as `footage`, `mediaReportCard` | smallest change; search index already reads records | duplicated across 5–7 copies of a tape; editing one copy strands the others; `catalog.json` (68 MB) grows with every copy |
| B. Content-keyed sidecar store (recommended) | `~/Library/Application Support/VideoScan/segments/segments.json`, one array of `MediaSegment`, keyed by `FootageKey`; `AtomicFilePublish` + generation counter like `CatalogStore` | one truth per footage; survives copies, re-encodes, renames, relocation; catalog save unaffected; the archive master can be deleted and re-promoted without losing the work | one more store to back up and to merge across machines; search index must join at build time |
| C. SQLite table | `segments` in `metadata_cache.sqlite` | queries by time range are native | the cache is a cache (`wasCacheHit`, rebuilt); a new schema is an escalation item; nothing here needs SQL yet |

**Recommend B.** Precedents for sidecars already exist (`ignored-content.json`, `archive-angel/evidence.json`, `date-inference/*.json`, the POI store). The record gets exactly one additive optional field, `footageAlignment` (§3.4), so a record can answer "where on the reference timeline am I" without opening the store. C++ reading: option A embeds a `std::vector` in every row; option B is a separate table with a foreign key, which is what you want when many rows reference one shared object.

The store is small: a 94-minute tape yields perhaps 10–40 segments; 268 FamilyArchive videos → a few thousand segments, each a few hundred bytes with evidence — under 5 MB. The search index (`CatalogSearchIndex.swift`) adds segment titles, people, event, place and tags to each record's haystack at build time by resolving the record's `FootageKey`; segment evidence text (transcript snippets, captions) joins the haystack only under the existing `transcript:` field token so plain search stays calm.

#### 3.3 Content identity (`FootageKey`)

The problem with every existing key:

- `fullPath` dies on copy, rename, relocation (`originalFullPath` exists for exactly this reason).
- `contentHash` (`v1:<sha256>` over head‖middle‖tail‖size) identifies bytes; a re-encode has new bytes.
- `footage.groupID` identifies the footage but is rewritten by every Find Similar Footage run ("stable-ish: the smallest member record id", `FootageMembership.swift:116-118`): a new member with a smaller UUID changes it.
- `derivedFrom` gives lineage only for files this app made.

So `FootageKey` is a **resolved identity, not a stored one**:

```swift
public struct FootageKey: Codable, Hashable, Sendable {
    /// The record the segment was authored against (the "reference copy"):
    /// the archive master when there is one, else the likely original.
    public var referenceRecordID: UUID
    /// Byte identity of that reference at authoring time. Lets a segment
    /// re-attach when the reference record is purged and the file re-scanned.
    public var referenceContentHash: String
}
```

Resolution for a record R, in order, stopping at the first hit:
1. `R.id == referenceRecordID` → alignment identity.
2. `R.contentHash == referenceContentHash` → byte twin → alignment identity.
3. R and the reference share `footage.groupID` (or R.derivedFrom chains to the reference) → `R.footageAlignment` (§3.4) when present and ≥ `likely`; otherwise the segment is shown with the "position approximate" word and no seek.
4. Otherwise not applicable.

When the archive master is itself the reference, every copy elsewhere inherits the segments; when a better master is promoted later, a one-line "re-anchor" moves `referenceRecordID` (the alignment between old and new reference is known from the footage group).

#### 3.4 Alignment between copies (`FootageAlignment`)

```swift
public struct FootageAlignment: Codable, Hashable, Sendable {
    /// reference_time = offset + scale * this_time
    public var offsetSeconds: Double
    public var scale: Double                 // 1.0 normally; 1.001 for 29.97 vs 30, 25/23.976 for PAL/film transfers
    public var confidence: FootageConfidence // reuse: .certain/.likely/.possible
    public var method: String                // "equal-length", "timecode", "fingerprint", "audio", "manual"
    public var computedAt: Date
}
```

How it is computed, cheapest first (all local, no re-encode):

1. **Equal length.** `|durA − durB| ≤ 1 frame` (the grouper already computes "Δ1 frame", `FootageGrouping.swift:811-815`) → offset 0, scale 1, `.certain` for byte twins, `.likely` for re-encodes. Covers the hevc/prores/ffv1 trio above.
2. **Timecode.** When both records carry `timecode` (ffprobe `timecode` tag; the `.dv` partial has `00:40:40:00`, 98 FamilyArchive videos have one), offset = TC_A − TC_B at the stream's frame rate, drop-frame aware (`;` separator). DV, MXF and ProRes from Avid/FCP usually carry it; VHS captures almost never do.
3. **Dense perceptual fingerprint.** The stored fingerprint (`StoredPerceptualFingerprint.swift`, GH #293) is 32 frames for the whole file — a 3-minute grid on a 94-minute tape, too coarse to align a trim. Add a `v2` recipe at 1 hash/s (5,640 × 8 B = 45 KB for that tape) and align by maximizing Hamming agreement over candidate offsets (a 1-D cross-correlation; `vDSP` if it ever matters, but 5,640 × 5,640 comparisons is 32 M UInt64 popcounts — under a second). This handles `partial-2` (76:51) inside the full tape and the Avid `Part1` (41:12). Compute the dense fingerprint from the smallest decodable copy and share it across the group.
4. **Audio fingerprint** (fallback when picture differs too much — denoised vs raw): ffmpeg `chromaprint` (`-f chromaprint`) on 16 kHz mono, same correlation. Only if 3 fails on real tapes; not in phase 1.
5. **Manual.** Rick picks the same moment in two copies in the player; one click writes `.certain`/"manual".

A record stores at most one alignment (to its footage reference). Alignments are machine-derived and trusted only while `method`'s recipe version and the file's size still match — the `isCurrent` pattern of the fingerprint.

#### 3.5 Timecode where present

If a record carries a start `timecode`, segments can also be shown and entered in tape timecode (`01:32:50;12`), which is what Rick's older Avid bins and FCP projects reference. Conversion is `seconds = (frames(TC) − frames(startTC)) / rate`, drop-frame per SMPTE 12M. Reuse the existing `avidEditRate` when the stream rate is missing. This is display sugar on top of seconds; seconds remain the stored unit.

### 4. Marking moments: human first, machine-proposed boundaries second

#### 4.0 The one-keystroke path (primary)

Rick's experience is that face recognition cannot carry this: siblings, parents and children look alike across decades, and the 1984 tape already has `detectedPeople: ["Donna"]` for every copy and nothing else. So the design's primary input is a person watching the tape, and the cost of a mark has to be a keystroke, not a form.

In the preview player (Catalog Inspector, Archive tab, and a dedicated "Watch & mark" window that is just the player plus a moments list):

| Key | Action |
|---|---|
| `I` | mark in at the play head (or move the current in point) |
| `O` | mark out; the moment is created immediately as `.user` with title "Untitled moment" and the type field focused |
| type `hudsons⏎` | first token becomes a tag; `hudsons thanksgiving⏎` becomes two tags; a token that matches a People-tab name or alias (`donna`, `bonnie`) becomes a person; a token in the occasion lexicon becomes the event |
| `M` | one-key marker: a zero-length moment at the head ("Donna at t=y"); it can be widened later with `I`/`O` |
| `[` `]` | jump to the previous / next boundary (confirmed moment edge or machine proposal) |
| `⏎` on a proposal | confirm it as-is; `⌫` rejects it |
| `J` `K` `L` | the editor convention: back / pause / forward, `L` twice for 2× |

No dialog, no mouse. The moments list scrolls with the head; the current moment's title is editable in place. Everything typed is catalog metadata in the segment store; the file is never touched and nothing is cut. A moment can also be created from a search hit in the transcript ("hudson" → the player lands at the spoken line and `I`/`O` take it from there).

Tags are free text in canonical display form, matched case-insensitively, the same `WorkflowTags` conventions as record tags. "hudsons" and "bonnie" are tags first; if "Bonnie" is in the People tab the segment also records her as a person, so Hallie's `find_person` route works, but nothing requires People-tab identity for a tag to be searchable.

#### 4.1 Machine-proposed boundaries (helper)

Four local signals, one fusion step, Rick confirms. The point of the proposals is to put `]` stops where the occasions change so the human presses `⏎` instead of scrubbing 94 minutes. Everything below runs on Apple Silicon with tools already in the repo or in Homebrew; nothing leaves the machine (§6). Face-set change is kept as a weak boundary signal (people walking in and out marks a scene change) and is never used to name who is in a segment unless a human confirms it.

##### Signals

| Signal | Tool (local) | What it yields | Cost per hour of video (M4 Max, est.) | Notes |
|---|---|---|---|---|
| **Timestamped speech** | `mlx_whisper` (venv-mlx), `whisper-medium-mlx-q4` — same worker, return `segments` | `[{start, end, text}]` ≈ one every 2–8 s; names, "happy birthday", "Thanksgiving", now-cues ("it's 1984") | 4–12 min/h (code measures 5–15× realtime, `CaptionOrchestrator+Dossier.swift:466`) | Today `whisper_worker.py` keeps only `result["text"]` (`handle_request`, ~line 91); `mlx_whisper.transcribe` already returns `segments`. One-line protocol change, additive. **Existing transcripts have to be re-run to get times.** |
| **Shot changes + gaps** | `ffmpeg -vf "scdet=threshold=10,blackdetect,freezedetect" -af silencedetect` in one pass, or AVFoundation + `VNGenerateImageFeaturePrintRequest` distance at 1 fps | boundary candidates with scores; black/silence spans = tape pauses, blank tape | hevc access copy via VideoToolbox: ~2 min/h; ffv1/prores SD master: 6–12 min/h (CPU decode) | Run on the **smallest decodable copy** in the footage group and map through alignment. Camcorder tapes have hard cuts at every record pause, which is exactly where occasions change. VHS noise causes false positives; the 2-minute floor and fusion absorb them. |
| **Face-set changes** (weak) | existing ArcFace CoreML / findtagd machine tier; `pf_cache.segments_json` already holds `{s,e}` spans per person | *how many* faces and whether the set changed (a room empties, new people arrive) — a boundary hint; identities are machine tier and not trusted for naming (Rick: look-alike family across decades) | 6–10 min/h at frame step 5 (≈ 6 fps); zero when cached | Optional stage. Make the cache content-keyed (store `contentHash` next to `video_path`) so copies reuse it. Living-family embeddings never leave the machine. |
| **Burn-in date / on-screen text** | Vision `VNRecognizeTextRequest` on a bottom-band crop, 1 frame / 10 s, from the same ffmpeg pass (`fps=0.1` thumbnails) | "NOV 22 1984", "PM 6:31"; a date change is a hard boundary; feeds `ocrDateCandidates` | ~1 min/h (360 frames × ~60 ms + shared decode) | Far cheaper than the VLM date prompt; keep the VLM prompt for frames Vision cannot read. Rare on 1984 VHS, common on 1990s camcorders. |
| **Scene captions per keyframe** | existing `MLXVLMCaptionRunner` (`CaptionRunner.swift:630`), Qwen2.5-VL-3B 4-bit, one keyframe per proposed segment | "a dinner table with a turkey…", searchable text per segment | ~2.5 s per prompt per frame (today: 3 frames × 3 prompts in ~10–20 s per file); at ~40 keyframes/h × 3 prompts ≈ 5 min/h; scene prompt only ≈ 1.7 min/h | Captions follow boundaries, not the other way round: caption the middle frame of each proposed segment, so a 94-minute tape gets 10–40 captions where it has 3 today. |

All five run on every Mac in the fleet; the VLM wants ≥ 16 GB (3B 4-bit ≈ 2.5 GB weights plus KV), Whisper medium ≈ 1 GB. The M1 Max (32 GB) is fine for all of them one at a time.

#### 4.2 Fusion → proposals

1. Collect boundary candidates with a weight: burn-in date change 1.0, shot change 0.4 (0.7 when preceded by black/silence ≥ 3 s), a spoken occasion cue 0.6 placed at the cue's segment start, face-count/set change 0.3.
2. Cluster candidates within ±3 s; a cluster's score is the sum. Accept clusters ≥ 0.8.
3. Cut the timeline at accepted clusters; merge spans shorter than 120 s into a neighbour unless the span holds a strong cue (the birthday song, a burn-in date).
4. Label each span: `event` from the occasion lexicon hit inside it (`DateTriangulator.swift:246`), suggested `tags`/`people` from names **spoken** inside it that resolve to People-tab aliases or to existing tags ("Hudson" → `hudsons`), `date` from a now-cue or burn-in inside it, else the record's best date with the reason "from the tape's date", `title` = "<Event> with <two names>" or the first caption's subject. Face identities are not used for labels.
5. Write them `.proposed(method: "fusion", version: 1)`. Nothing is confirmed until a person presses `⏎`.

The Mark's-birthday × Thanksgiving tape is the canonical test: 36 "happy birthday" hits in the first half, "thanksgiving" and the Hudson introduction later, Donna present throughout; a correct run yields at least two segments with different events on one record.

#### 4.3 Confirming

In the Inspector, a **Moments** section (family word for segments; §8) lists proposals as dashed rows with the title, time range and a one-line "why" ("36× 'happy birthday' 1:27–2:40; 'Mr. Glenn Hudson' spoken at 52:14"). Actions: Confirm (`⏎`), Rename, Merge with next, Split here (at the player head), Not a moment (`⌫`). Confirm turns it plain and stamps `.confirmed`. The `I`/`O`/`M` keys of §4.0 work in the same view, so a session on one tape is: play, `]` to the next proposal, `⏎` or retitle, `I`/`O` for anything the machine missed. Proposals are visible only with the Curator toggle on (§5.1); confirmed and user moments are visible to everyone.

### 5. Search and surfacing

#### 5.1 Catalog UI (calm by default)

- **Table.** No new column. Records that have confirmed moments show a small chapters glyph next to the duration (the filmstrip precedent). Curator toggle adds a faint count ("3 moments · 2 proposed").
- **Search.** `CatalogSearchIndex` includes moment title/people/event/place/tags in the haystack. A hit inside a moment ranks the record and remembers the moment: the row's tooltip and the Inspector open on that moment. Field tokens: `moment:hudsons`, `event:thanksgiving`, `people:` already exists and gains segment people (confirmed only in the plain lane).
- **Play from there.** Double-click a moment in the Inspector, or Return on a search hit, seeks the existing preview player (`CatalogHelpers.swift:1387`, `VideoPlayer(player:)`) with `player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)` after the item is `.readyToPlay`. The time shown is the record's own time (reference time mapped through `footageAlignment`), so the hevc copy and the ffv1 master both land on the Hudsons.
- **Archive tab.** The decade timeline gets a per-video moment strip only under Curator; the occasion cue a video already shows for everyone is now derived from confirmed moments when present (a tape with Birthday and Thanksgiving shows both cues).
- **No O(records) work in view bodies.** Haystack joins happen at index build; the Inspector resolves one record's moments through a `[UUID: [MediaSegment]]` memo keyed by `referenceRecordID`, invalidated by the store's generation.

#### 5.2 Hallie (agent lane and local lane)

Two read-only tools, same shape in both lanes (the rev-6 rule: same tools, different control loop):

```
search_media { query: String, people?: [personID], years?: [Int], event?: String, limit?: Int }
  → [{ recordID, segmentID?, start?, end?, title, year?, evidenceKind: "confirmedTag" | "moment" | "transcript" | "caption" | "filename" }]
     + queryID             dataClass: familyText (titles, names, years, filenames); the transcript/caption snippet
                           field is OMITTED unless the lane's data-class policy allows it (§6)

get_segment { segmentID, forRecordID? }
  → { title, event, people[confirmed only], place, date, dateReason, start, end (mapped to forRecordID when given),
      alignment: {method, confidence}, evidenceSummary: ["36× 'happy birthday'", "Donna on screen 48 min"] }
```

Claims: add `momentFor(personID | event, segmentIDs)` beside `mediaFor` (`hallie_proposer_with_tools_design.md` §3, line 132). The verifier re-derives each cited segment from the store and keeps only `.confirmed`/`.user` segments for spoken facts; `.proposed` ones are "possible" wording, as `mediaCandidate` is today. The offered action is `playMedia(recordID, atSeconds)`, derived in Swift from a verified `momentFor` claim, never from model prose. "Show me the Hudsons at Thanksgiving" therefore becomes: `find_person(Hudson)` → `search_media(people: [Glenn Hudson, Joy Hudson], event: "Thanksgiving")` → one verified moment → "In the 1984 Thanksgiving tape, from 52:10. Shall I play it?"

#### 5.3 Data classes and the cloud lane

Per the rev-6 policy: segment titles, event, people names, place, dates and evidence *summaries* are `familyText` and may travel to the cloud lane. Transcript segments and captions are text derived from pixels and audio of living family; **default `familyMedia` until Rick rules** (open question carried from rev 6, decision line in §8). `search_media` serializes snippets only when the endpoint class allows; a poisoned-endpoint sensor proves a `remote` endpoint never receives a `transcript`/`caption` field.

### 6. Privacy

Rick's 2026-10-10 ruling: pixels and audio of living immediate family never leave the machine. Consequences for this design:

- Every proposer in §4.1 is local: MLX Whisper, ffmpeg, Vision, ArcFace CoreML, Qwen-VL via MLX. No remote caption or transcription API, ever, for family media.
- Fleet backfill (§7) moves **audio and keyframes between Rick's own Macs over the LAN** (SMB mount or `ssh`/`rsync` on `.local`). This is "the machine" in the plural; it needs an explicit yes (§8). Default if no ruling: FamilyArchive work runs only on the volume host (M4 today, M5 Ultra later).
- Work packets on laptops are deleted after their results are merged; a sensor checks the staging folder is empty after a job finishes.
- Logs never carry transcript text or caption text (the `ArchiveLogPrivacyTests` precedent): START/OUTCOME lines name files and counts.
- The segment store is family data under Application Support, never in git (privacy rule, 2026-08-03).

### 7. Backfill plan (MFO jobs)

#### 7.1 Shape

One MFO job kind, **"Analyze footage"** (verb chip "Analyzing"), conforming to `MediaFileOperationJob` (`MediaFileOperations.swift:582`): collapsed row with "N of M · current file · time left", Pause/Stop, double-click for per-item results, START/progress/OUTCOME to console + `catalog.log` + `videoscan.log`. The 2026-10-02 ruling puts continuous cyclers on the Analyze surface; this backfill is a bounded run Rick starts, so it is an MFO row; after the backfill the same stages become cyclers ("Transcribe", "Moments") on the Analyze coverage view with per-minute coverage figures.

Work unit = one footage group, not one file: pick the analysis copy (archive master if it decodes, else the smallest decodable access copy), produce one result, apply to the reference, share to the siblings by alignment. This alone turns 268 files into ~190 groups and skips the 40 GB FFV1 masters whose hevc twin decodes 10× faster.

Stages per group, in order, each resumable by its own stamp (the analyzer-registry idea from 2026-09-26: a record is due for an analyzer when its stamp is missing or older than the analyzer version):

1. `text-share` — carry over existing text by content identity (no decode).
2. `audio-extract` — `ffmpeg -vn -ac 1 -ar 16000` → 16 kHz mono WAV (115 MB per hour of tape). Volume host only.
3. `transcribe-v2` — Whisper with segments. Any machine with the WAV.
4. `shots-ocr` — one ffmpeg pass on the analysis copy: scdet/black/silence + 0.1 fps thumbnails; Vision OCR on the thumbnails. Volume host or any machine with the access copy.
5. `faces` (optional, weak signal) — reuse `pf_cache` when present (make it content-keyed), else ArcFace on the analysis copy; counts and set changes only, never names.
6. `moments-propose` — fusion (§4.2), CPU, seconds per tape.
7. `captions-v2` — VLM on one keyframe per proposed moment.

Fleet transport: the M4 (volume host) exports packets per group — WAV plus the thumbnail set, ~150 MB per hour of tape — to a staging share; laptops pull, run stages 3/5/7, write results as JSONL; the M4 merges (precedent: `scripts/merge_dossier_jsonl.py`, `dossier-merger-offsets.json`, `DossierDashboardView+FleetStats.swift`). The 40 GB masters never cross the wire.

#### 7.2 Hours (FamilyArchive, 165.4 h of video)

Rates are the code's own measurements where they exist and marked estimates where they do not; the first night of the backfill replaces the estimates.

| Stage | Rate | Arithmetic | Machine hours |
|---|---|---|---|
| 1 text-share | — | 75 files, JSON only | ~0.1 |
| 2 audio-extract | ~100× realtime (stream copy + resample) | 165.4 h / 100 | 1.7 |
| 3 transcribe-v2 | 8× realtime (measured 5–15×) | 165.4 h / 8 | 20.7 (13.8 on the Ultra at 12×) |
| 4 shots-ocr | 30× realtime on hevc copies, 8× on SD prores/ffv1; assume 2/3 of hours have an hevc copy | 110 h / 30 + 55 h / 8 | 3.7 + 6.9 = 10.6 |
| 5 faces (optional) | 6× realtime; assume half the hours already cached | 83 h / 6 | 13.8 |
| 6 moments-propose | seconds per tape | 190 groups | ~0.2 |
| 7 captions-v2 | 40 keyframes/h × 3 prompts × 2.5 s = 300 s/h (est.) | 165.4 h × 300 s | 13.8 (4.6 with the scene prompt only) |
| **Total** | | | **≈ 61 machine-hours** with faces; **≈ 47 without**; ≈ 31 without faces, scene-only captions and the Ultra on Whisper |

Spread over the fleet by lane, respecting the RAM rule (≤ 2 heavy processes on the M4 before midnight) and "no UI automation while Rick works":

| Machine | Lane | Hours | Nights (8 h window) |
|---|---|---|---|
| M5 Ultra 96 GB (when it arrives; M4 until then) | transcribe-v2 + captions-v2 | 13.8 + 13.8 = 27.6 | 3.5 |
| M4 Max 64 GB (volume host) | audio-extract, shots-ocr, text-share, propose, merge | 1.7 + 10.6 + 0.3 = 12.6 | 1.6 |
| M5 Pro 48 GB | faces (half) | 6.9 | 0.9 |
| M1 Max 32 GB | faces (half) | 6.9 | 0.9 |

Wall clock ≈ 4 nights, bounded by the Whisper + VLM lane; 2 nights if the M5 Pro takes the captions. Before the Ultra arrives, the M4 carries its own lane plus Whisper: ≈ 33 h, 4–5 nights. The whole-catalog upper bound (490 h of live video, 132 h with no text) scales linearly: ~3× these numbers, ~180 machine-hours, which is why the backfill is FamilyArchive first (the archive set is the keeper; copies elsewhere inherit through content identity or get deleted under the delete-excess-copies goal).

### 8. Decisions for Rick (one per line, with a recommendation)

Already ruled 2026-10-10: Archived and In Triage media ARE analyzed by Dossier (read-only analysis, catalog metadata only); segments are metadata and files are never cut; human time-range tagging is primary, identity recognition is not relied on.

1. **Keyboard map for marking** (`I`/`O`/`M`/`[`/`]`/`⏎`/`⌫`, `JKL` transport). Recommend **adopt as proposed**; it is the editor convention Rick knows from Avid/FCP.
2. **Segment store**: content-keyed sidecar (`segments/segments.json`) vs inline on each record. Recommend **sidecar**; one truth per footage.
3. **Family word in the UI**: "Moments" vs "Chapters" vs "Scenes". Recommend **Moments** (Hallie can say "the moment at the Hudsons'"; "chapter" sounds like a DVD).
4. **Re-run Whisper on already-transcribed tapes to get timestamps** (~21 machine-hours for FamilyArchive). Recommend **yes**; untimed transcripts cannot seek and the backfill reads every tape anyway.
5. **LAN work packets to the laptops** (16 kHz audio and 0.1 fps thumbnails of living family, Rick's own Macs, LAN only, deleted after merge). Recommend **yes, LAN only**; otherwise the backfill is M4/Ultra-only and takes ~5 nights instead of ~2–4.
6. **Data class of transcripts and captions for Hallie's cloud lane**: `familyText` (may go to the cloud) vs `familyMedia` (local only). Recommend **`familyMedia` for now**; moment titles/people/dates are `familyText` and are enough for "show me the Hudsons at Thanksgiving".
7. **Proposal visibility**: proposals under the Curator toggle only; confirmed moments for everyone. Recommend **yes** (calm by default; the future family viewer never sees machine tier).
8. **Minimum moment length**: 120 s floor with strong-cue override. Recommend **yes**, borrowed from Angel's 2-minute floor; tune after the first ten tapes.
9. **Which copy is analyzed per footage group**: archive master if it decodes, else smallest decodable access copy, results shared by alignment. Recommend **yes**; it skips the 40 GB FFV1 decodes.
10. **VLM for captions-v2**: keep Qwen2.5-VL-3B 4-bit now; step to a 7B on the M5 Ultra and let the version stamp re-queue. Recommend **3B now, measure, then decide**.
11. **Side fix**: flag the 28 `videoUnreadable` records `needsReformat` so they stop re-failing every pass. Recommend **yes**, folded into phase 0.

### 9. Phased plan with tests (five dimensions each)

Branch per phase; merge after boundary sensors run; tests before Rick's spot test.

#### Phase 0 — Coverage (1–2 days)

Scope: gate change (ruled), lifecycle exclusions logged, text-share cycler, Whisper worker returns segments (additive `segments` key; Swift ignores it until phase 1), `videoUnreadable` → `needsReformat`, Analyze dashboard shows "not eligible (stage)" counts.

- Logic: `pfCatalogWideMetadataCandidates` includes `.archived`/`.reviewing`, excludes `.trashed`; `applyDossier` on an archived record writes text, never `inferredRecordDate`/`userDate`; text-share copies captions+transcript to a same-group sibling with provenance and refuses when the target already has text.
- Scale: 100k synthetic records (20 % archived, 2,000 footage groups): candidate filter < 50 ms; text-share pass < 2 s; Debug ceiling via `PerformanceLane.debugCeiling`.
- Media matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv fixtures through the serial loop with a stub `CaptionRunner`; the worker protocol test parses a `segments` payload from each.
- Isolation: poisoned `analysisScope_includeAudioOnly` and a stale `DossierActiveVolumes` in UserDefaults do not change which stages a video record passes.
- Sensor: a FamilyArchive-shaped fixture catalog (archived masters, in-triage copies, one re-encode) run through a full pass ends with 0 eligible videos lacking text; a second sensor fails when the OUTCOME line omits the stage-exclusion count.

#### Phase 1 — Segment model, store, one-keystroke marking, play-from (3–4 days)

Scope: `MediaSegment`, `FootageKey`, `FootageAlignment` (identity + equal-length only) in VideoScanCore; `SegmentStore` with atomic publish and generation; the `I`/`O`/`M` marking keys and tag entry in the preview player (§4.0); Inspector "Moments" with Rename/Delete; search haystack join incl. `moment:`/tag tokens; seek in the preview player; Archive tab cue from moments. This phase alone makes "hudsons" findable on the 1984 tape after one viewing, with no machine help.

- Logic: store round-trips; resolution order (id → hash → group); equal-length alignment; haystack contains moment words and tags; token classification (tag vs person vs event) from typed text; seek target mapped through alignment; `I` then `O` creates exactly one `.user` moment, `O` before `I` is a no-op with a hint.
- Scale: 100k records + 300k segments: index build < 3 s extra, Inspector memo lookup < 1 ms, no O(records) in view bodies (the house ForEach rule test).
- Media matrix: seek to a moment start in each of the five fixtures lands within one frame (`AVPlayerItem` time check), including the `.mxf` audio-only case which must refuse gracefully.
- Isolation: a damaged `segments.json` (truncated, foreign keys) loads as empty with a logged outcome and never blocks catalog load; a poisoned generation counter cannot overwrite a newer store.
- Sensor: the 1984 fixture (a synthetic two-event file with two aligned copies of different length) — a moment authored on copy A is found by search and seeks correctly on copy B.

#### Phase 2 — Alignment across copies (3 days)

Scope: timecode alignment, dense perceptual fingerprint v2 + correlation, manual two-point alignment, re-anchor when the reference changes, content-keyed `pf_cache`.

- Logic: drop-frame and non-drop timecode math against known vectors; correlation finds a planted offset of 17 min 3 s in a 76-min subset; scale 1.001 detected.
- Scale: 100k alignments resolved < 1 s; correlation of 6,000 × 6,000 hashes < 1 s.
- Media matrix: fingerprint v2 on all five fixtures; a trimmed `test_` copy of each aligns to its source.
- Isolation: fingerprint recipe version bump marks every stored alignment stale without touching segments.
- Sensor: segment positions on every copy in a three-member synthetic group agree within 0.5 s after re-anchoring to a different reference.

#### Phase 3 — Proposers and fusion (1 week, overnight runs)

Scope: `transcribe-v2` consumer (spoken cues with times), ffmpeg scdet/black/silence pass, Vision OCR, face-count changes from `pf_cache` (weak, optional), fusion, proposal UI (`⏎`/`⌫`/Merge/Split), the MFO "Analyze footage" job with fleet packets.

- Logic: fusion on hand-built evidence yields the expected cuts; the 120 s floor merges a 40 s span unless it holds the birthday cue; names resolve through People aliases; `rejectedPeople` cannot appear confirmed.
- Scale: fusion over 10k candidates per tape < 100 ms; 100k records' proposals load lazily.
- Media matrix: scdet and OCR pass runs on all five fixtures (synthetic hard cut at 2.0 s and a burned-in "JUN 21 1991" via `drawtext`), fixtures prefixed `test_`.
- Isolation: the fleet merge refuses a JSONL packet whose `contentHash` does not match a catalog record; staging folder is empty after OUTCOME.
- Sensor: the synthetic Mark's-birthday × Thanksgiving fixture (TTS "happy birthday" ×6 at 1:20–2:40, a hard cut, a different speaker saying "Thanksgiving") produces ≥ 2 proposals with different events; the log carries no transcript text.

#### Phase 4 — Captions per moment and Hallie tools (1 week)

Scope: `captions-v2`, `search_media`/`get_segment`, `momentFor` claim + verifier, `playMedia(recordID, atSeconds)` action, data-class enforcement.

- Logic: tool results omit snippet fields for a `remote` endpoint; verifier drops `.proposed` segments from facts; action derives only from verified claims.
- Scale: `search_media` over 100k records + 300k segments < 200 ms p95.
- Media matrix: caption keyframe extraction on all five fixtures with a stub VLM.
- Isolation: poisoned endpoint policy (remote marked local) is caught by the adapter sensor; a missing MLX venv degrades to no captions with an outcome line, not a failure.
- Sensor: eval corpus gains "show me the Hudsons at Thanksgiving" and "Matt's birthdays" against the fixture store; both answer with a verified moment and an offered play action.

### 10. Risks

- **Footage group id instability** rewrites `groupID` on every run; mitigated by `FootageKey` resolving through the reference record and hash, never storing `groupID`.
- **False boundaries on noisy VHS** (tracking, dropouts) inflate proposals; the floor, fusion weights and Curator-only visibility keep them out of the family view until confirmed. Measure precision on the first ten tapes before widening.
- **Whisper hallucination on music and silence** (the 26-minute wedge precedent) — deadline rule stays (`max(60, 2× duration)`), silence spans from the ffmpeg pass are excluded from cue mining.
- **Re-transcription cost** (~21 h) competes with the demo-week machine budget; it is overnight work and resumable per stamp.
- **Fleet merge conflicts**: two machines writing the same record; the merge is single-writer on the volume host, keyed by content hash, append-only JSONL in, one catalog save out.
- **Store orphaning**: a reference record purged or deleted leaves segments pointing at a hash; they re-attach on rescan (resolution rule 2) and the store's audit lists unattached segments under Curator.
- **Privacy leak through logs or packets**: pinned by the no-text-in-logs sensor and the empty-staging sensor; LAN-only transport is an explicit decision (8.5).
- **Search calm**: adding transcript snippets to plain search would make every tape match "mark"; snippets stay behind the `transcript:` token.

### 11. Appendix: Swift notes for a C++ reader

- `struct` with `var` fields and `Codable` ≈ a POD with a generated serializer; passing it is a copy, so the store hands out values and takes edited values back (`store.upsert(segment)`), no aliasing bugs.
- `enum SegmentEvidence` with associated values ≈ `std::variant<Spoken, FacePresent, …>`; `switch` over it must be exhaustive, which is how new evidence kinds force every consumer to decide what to do.
- `FootageKey` resolution is a free function over the catalog's indexes (`record(forPath:)` is O(1) already; add `records(forContentHash:)` and `records(inFootageGroup:)`), not a method on the record — the record should not know about the store.
- The store's atomic publish is write-temp-then-rename (`AtomicFilePublish`, load-bearing per the rename-wedge note); never `replaceItemAt`.
- Main-actor rule: the store is `@MainActor` like `CatalogStore`; the proposers run off-actor (`@concurrent` where they are `nonisolated async`, per the approachable-concurrency trap note) and hand back value arrays.

# Part III — GEDCOM export and VideoScan import

*From `guides/gedcom.md` (last verified 2026-08-24), whole; archived at `docs/archive/guides/`.*


Last verified: 2026-08-24

VideoScan uses a local GEDCOM file as its family-tree source of truth. Keep the
original export unchanged and treat online trees as research sources: distant
shared-tree relationships can be incomplete, disputed, or weakly sourced.

### Exporting an Ancestry tree

Ancestry exports the entire tree owned by the signed-in user. It does not offer
a generation-count option for GEDCOM export, and guests or editors cannot
export another owner's tree.

1. Open the tree in Ancestry.
2. In the left toolbar, choose **More** (the three-dot button), then
   **Tree Settings**.
3. Under **Manage your tree**, choose **Export tree**, then **Export**.
4. When generation finishes, choose **Download Your GEDCOM File**.
5. Unzip the downloaded file to obtain the `.ged` file.

Ancestry's current instructions are in
[Uploading and Downloading Trees](https://ancestrysupport.zendesk.com/hc/en-us/articles/53933352542867-Uploading-and-Downloading-Trees).

GEDCOM is primarily genealogical text and relationships. Ancestry photos and
other media are not embedded in the exported GEDCOM. Preserve those media
separately in the Master Archive.

#### When the export stops after only a few generations

Ancestry does not normally impose a six-generation limit on a whole-tree
export. Check the source tree for these common causes:

- Distant people visible onscreen are hints or members of someone else's
  public tree, not people attached to the owned tree.
- A parent-child relationship is missing somewhere in the line.
- The export came from a different owned tree.
- Suggested ancestors were viewed but never accepted and connected.

Open several of the distant ancestors before exporting and verify that each is
actually connected through parent relationships in the owned tree.

### Get Family Tree (in the app)

The Family Tree tab has a **Get Family Tree** button — in the sidebar header,
and on the demo-tree banner. It downloads your FamilySearch tree as a GEDCOM
without you leaving VideoScan, and without VideoScan ever handling your
password.

How it works:

1. Choose how many ancestor steps (1–40; 8, 12, 20 and 40 are one-tap
   presets — `-a 1` is you plus one generation of parents), whether to
   include spouses, and where to save the file.
2. VideoScan shows you the exact command it will run, then writes it to
   `~/Library/Application Support/VideoScan/family-tree/get-family-tree.command`
   and opens it in Terminal.
3. Terminal shows the command again and waits. You press Return, then type
   your FamilySearch password at `getmyancestors`' own prompt.
4. VideoScan watches for the file. When it ends with GEDCOM's `0 TRLR`
   marker, the tree is parsed and you are told how many people and how many
   generations it actually reached.
5. **Install family tree** copies it into `40_Family_Tree/GEDCOM/` and
   reloads the tab. Nothing is installed unless it parsed.

Requires `getmyancestors` (GPL, free):

```
python3 -m venv ~/dev/VideoScan/venv-genealogy
~/dev/VideoScan/venv-genealogy/bin/pip install getmyancestors
```

#### Why Terminal and not a button that just does it

`getmyancestors` authenticates by POSTing your username and password straight
at FamilySearch's login form; it does not use the OAuth browser flow.
`familysearch_api_notes.md` rules that VideoScan must never collect or proxy
that password, so the tool prompts for it directly on its own terminal. The
same seam keeps the tool's GPL license outside VideoScan's sources (a separate
process, like ffmpeg), and puts any failure — notably the day the tool's
borrowed third-party app key is revoked — in a window you are already reading.

#### Going deeper than eight generations

There is no eight-generation limit. `getmyancestors` does not rely on one
eight-generation ancestry response: it walks the existing parent frontier one
generation at a time, stops when no parents remain, and accepts any `-a`
value. A single twenty-step run is the preferred model for a sparse tree;
repeated eight-generation exports and `mergemyancestors` are not the normal
workflow. The sheet allows up to 40 steps — a product safety cap, not a
FamilySearch fact.

The proposed correction and the security/licensing reasons for retaining the
Terminal boundary are documented in
[VS app gets gedcom data using its own script loosely based on getmyancestors
or similar](vs_app_gets_gedcom_data_using_own_script.md).

Re-rooting on an end-of-line ancestor's FamilySearch person ID (`LF7T-Y4C`)
and merging with `mergemyancestors` is still useful to deepen ONE line without
re-pulling everything. Deep lines in the shared tree are user-submitted and
thinly sourced the further back they go — worth checking before Hallie
recites them as fact.

#### Telling Hallie which record is you

getmyancestors writes every person's FamilySearch ID into the GEDCOM
(`1 _FSFTID GVQV-NW3`). Give Hallie yours and "I" / "my" / your own name
resolve to that exact record before any name matching: open your person page
on FamilySearch (Family Tree → your name; the ID is shown under the name),
then either type it in the chat window's "Who is talking to her…" sheet
under **Your FamilySearch ID**, or run
`defaults write Rick-Breen.VideoScan hallie.ownerFamilySearchID GVQV-NW3`.
Leave it empty and she falls back to the tree root as before.

#### Asking Hallie

"Hallie, get more of the family tree" / "download the family tree from
FamilySearch" answers with a short explanation and a **Get Family Tree…**
chip that opens the same sheet. No language model is involved.

### Exporting from FamilySearch (manually)

FamilySearch does not currently provide direct GEDCOM export from its shared
Family Tree. Its help center recommends downloading with compatible third-party
genealogy software instead:

- [Downloading information from Family Tree](https://www.familysearch.org/en/help/helpcenter/article/how-do-i-download-information-from-family-tree)
- [Creating a GEDCOM file](https://www.familysearch.org/en/help/helpcenter/article/how-do-i-create-a-gedcom-file)

For macOS, the free edition of
[RootsMagic](https://rootsmagic.com/RootsMagic) is a practical option. It can
connect to FamilySearch, download tree information into a local database, and
export GEDCOM. Once the people are local, RootsMagic can select a person and
export a chosen number of ancestor or descendant generations; see
[RootsMagic's generation-selection instructions](https://support.rootsmagic.com/hc/en-us/articles/224924967-How-to-export-ancestors-and-descendant-of-a-selected-person).

A cautious FamilySearch workflow is:

1. Create a separate RootsMagic database.
2. Connect it to FamilySearch and start from the confirmed FamilySearch Person
   ID.
3. Download the desired ancestral lines.
4. Export a GEDCOM from the local database.
5. Compare it with the Ancestry export before adopting either as authoritative.

Living-person records are private in FamilySearch and may not connect or
download like the shared deceased-person tree. Long ancestral lines should be
reviewed for sources before they are presented by Hallie as family fact.

### Installing a new GEDCOM for VideoScan

The preferred Master Archive location is:

```text
<Master Archive>/40_Family_Tree/GEDCOM/
```

VideoScan selects the newest valid `.ged` file in its configured family-tree
locations. Use a dated filename, for example:

```text
ancestry-breen-family-2026-08-24.ged
```

Do not overwrite or delete the prior export until the new file has passed a
preflight comparison. Useful checks include:

- person and family counts;
- maximum ancestor depth;
- missing or broken parent, spouse, and child links;
- the expected English and Irish lines;
- connections among living immediate-family records;
- duplicate people and conflicting dates or places.

The Family Tree view currently displays a bounded number of generations around
the selected person. That display depth does not truncate the underlying GEDCOM
graph.

### Photos and the People tab

A new GEDCOM can improve family relationships and ancestral depth, but it does
not automatically bridge GEDCOM people to VideoScan People profiles or their
cover photos. That identity/photo bridge is a separate application concern.
Keep user-owned portraits under the Master Archive family-tree assets rather
than expecting an Ancestry or FamilySearch GEDCOM export to carry them.

### Future FamilySearch integration

VideoScan's proposed direct FamilySearch integration remains local-first and
read-oriented. The implementation and approval constraints are documented in
[familysearch_api_notes.md](../archive/research/familysearch_api_notes.md). Direct API data must not
silently overwrite the local GEDCOM.

# Part IV — Family Tree research sources

*Three studies behind the Record Finder, moved to `docs/archive/research/` on 2026-11-01; the code cites their sections there.*

- **FamilySearch API notes** (2026-08-22; `docs/archive/research/familysearch_api_notes.md`). Research only; no FamilySearch calls or credentials are implemented from it. BLOCKER (2026-08-25): FamilySearch verifies only registered businesses — sole proprietorships are not eligible, and there is no personal-use path — so VideoScan can have Sandbox (synthetic) access only; the rest of the note is sound guidance that cannot be exercised against real data. FamilySearch pull and refresh in the app are Rick-initiated (ARCHITECTURE §3).
- **Irish records — Record Finder design** (GH #230, 2026-09-30, proposed; `docs/archive/research/irish_records_design_2026-09-30.md`). There is no Irish FamilySearch: the records are split across about eight sites with four access models, and the two that matter most sit behind a browser challenge, so a pre-filled browser link is in and a scraper is out. Phase A "Record Finder": fix the dead links, add verified pre-filled searches, and an "I found it" bring-back that files the record as a person document and writes one CyberBrain `officialRecord` source. Phase B: the 1901/1911 census JSON API and the UK TNA Discovery API, inside the existing Research Person runner. Phase C (FamilySearch hints) parked on the production-key rule.
- **England & Wales, Scotland and UK-wide records — source survey** (2026-10-01; `docs/archive/research/uk_scotland_records_survey_2026-10-01.md`). Britain is better indexed than Ireland but the access model is the same — search by hand, bring the record back. FreeBMD / FreeCEN / FreeREG forbid software access; GRO and ScotlandsPeople need a login and forbid automation; only TNA Discovery qualifies for an automated adapter. It flagged the existing Find a Grave fetch as disallowed by that site's `robots.txt` since 2024-11-25 (a decision for Rick) and an ODbL route to a local FreeBMD extract.
