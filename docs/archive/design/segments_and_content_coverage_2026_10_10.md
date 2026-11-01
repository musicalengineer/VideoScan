# Segments and content coverage

*Design, 2026-10-10. Status: PROPOSED, no code changed. Author: Claude (design agent, worktree branch `design/segments-content-coverage-2026-10-10`). Trigger: the family demo miss — "the Hudsons at Thanksgiving 1984" is inside a 94-minute VHS capture and nothing in the catalog could say so, let alone where. Related: `docs/design/hallie_proposer_with_tools_design.md` §R6 (item 5 names this document), `docs/design/scene_captions_plan.md`, `docs/design/analyze_knowledge_and_storage_actions_2026-10-02.md`, `docs/project_goals.md` (goals 2 and 4).*

## 0. Summary

Rick's framing (2026-10-10): a segment is a **time marker inside a long tape** — "Breens at t=x, Donna at t=y, Hudson house at t=z" — searchable by tags such as "hudsons" or "bonnie". Face recognition alone failed because family members look too alike across decades, so the design leans on **cheap human tagging of time ranges** (mark in/out while watching, one keystroke, type a tag) with machine-proposed boundaries as a helper, not on identity recognition. Physically cutting files into sub-clips is not the goal; segments are metadata.

1. **A file is not an event.** Most of the archive is digitized tape: one record, 60–160 minutes, three or four occasions, several copies and re-encodes of the same footage. The catalog models one event per file. This design adds **segments**: time ranges inside footage, each with its own tags, people, event, place, date (with confidence and reason) and notes.
2. **Segments are keyed to content, not paths.** A segment belongs to the *footage*; every copy, re-encode and trim of that footage sees it through an alignment (offset, scale). FamilyArchive files stay byte-identical: segments are catalog metadata only, never file edits.
3. **The demo file was never analyzed because Analyze does not look at archived or in-triage records** (`CatalogWideMetadataCandidates.swift:46-47`). 74 archived and 41 in-triage FamilyArchive videos never entered the loop, and the log cannot say so because they are filtered out before counting. **Rick ruled 2026-10-10: Archived and In Triage media are analyzed** (read-only analysis, catalog metadata only). Most of the gap is fillable for free: 75 of the 94 FamilyArchive videos with no captions and no transcript have a same-footage sibling that already has them.
4. **Even "analyzed" tapes are not covered.** Every FamilyArchive video longer than 30 minutes (127 files, 154 h) carries 3 or 5 scene captions and one transcript blob with no timestamps. Coverage has to be measured per minute, not per file.
5. **Human first, machine second.** The primary input is Rick (or any family curator) watching a tape and pressing one key at the start and end of a moment, then typing "hudsons". Machines propose boundaries from timestamped Whisper segments, shot changes, burn-in dates and (as a weak signal only) face-set changes, so the human mostly confirms instead of scrubbing. Everything runs locally on Apple Silicon; the fleet shares work over the LAN only.
6. **Search returns moments, not files**: "show me the Hudsons at Thanksgiving" → the 1984 tape, segment "Thanksgiving at the Hudsons" starting 0:52:10, Play. Hallie gets `search_media` and `get_segment` tools under the data-class policy.

## 1. The case that failed, in catalog terms

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

## 2. Why the file was never Dossier-processed (coverage root cause)

### 2.1 The gate

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

### 2.2 Why the sibling's text did not help

Promote copies the dossier text from the source record to the archive copy (`VideoScanModel+MasterArchive.swift:1302-1310`; `snapshotClone` does the same, `VideoRecord+Clone.swift:115-129`). That is why the prores master has captions: its source had them before promotion. The hevc copy Rick opened was made by Archive Angel from a buffer record that had never been analyzed, then promoted — nothing to copy. Afterwards two mechanisms could have back-filled it and neither does text:

- **Byte-twin propagation** (`VideoScanModel+DateInference.swift:119`, "propagated from <uuid>") keys on `contentHash` / partialMD5+size. A re-encode has a different hash.
- **Footage-group sharing** ("footage-shared from <uuid>", confidence 0.95 on the hevc copy) shares the **date only**.

So the rule is: text is copied once, at promotion, from one parent; it never flows later or sideways. Content identity (the footage group) exists and is not used for text.

### 2.3 Size of the gap (FamilyArchive, live records only)

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

### 2.4 Fix shape (decided)

1. **Stage gate — RULED 2026-10-10 (Rick): Archived and In Triage media are analyzed.** `pfCatalogWideMetadataCandidates` admits `.archived` and `.reviewing`; `.trashed`, purged, set-aside and confirmed-junk stay out. It is read-only analysis that writes catalog metadata only, inside the 2026-09-27 ruling ("background jobs may add metadata (notes, transcripts, captions, verify results, footage groups) but never write an archived record's date or name"). The one thing to pin with a test before the gate opens: `applyDossier` must not write `inferredRecordDate`/`inferredDateReason`/`userDate` on an archived record — the date lane already skips archived rows for propagation; the dossier apply path needs the same guard. The Archive Angel `_improved` derivatives on the archive volume (the hevc copy Rick opened) become eligible the same way.
2. **Text carry-over by content identity.** A new cheap cycler ("Share text across copies"): for each footage group and each contentHash set, if one member has captions/transcript/OCR and another has none, copy them with provenance `textSource: "shared from <uuid> (same footage)"` and the alignment from §3.4 (identical length → offset 0; otherwise mapped). 75 files, 66 h, minutes of CPU, zero decode. This is the footage-group date-sharing rule extended to text.
3. **Log the exclusions.** The batch START line reports lifecycle exclusions by stage alongside the scope exclusions it already reports, and the OUTCOME line carries "N not eligible (stage)". A sensor fails when an eligible-by-ruling archived video has no text after a full pass.

## 3. The segment model

### 3.1 What a segment is

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

### 3.2 Storage

Three options were weighed:

| Option | Shape | For | Against |
|---|---|---|---|
| A. Inline on `VideoRecord` (`segments: [MediaSegment]`) | additive optional field, same migration as `footage`, `mediaReportCard` | smallest change; search index already reads records | duplicated across 5–7 copies of a tape; editing one copy strands the others; `catalog.json` (68 MB) grows with every copy |
| B. Content-keyed sidecar store (recommended) | `~/Library/Application Support/VideoScan/segments/segments.json`, one array of `MediaSegment`, keyed by `FootageKey`; `AtomicFilePublish` + generation counter like `CatalogStore` | one truth per footage; survives copies, re-encodes, renames, relocation; catalog save unaffected; the archive master can be deleted and re-promoted without losing the work | one more store to back up and to merge across machines; search index must join at build time |
| C. SQLite table | `segments` in `metadata_cache.sqlite` | queries by time range are native | the cache is a cache (`wasCacheHit`, rebuilt); a new schema is an escalation item; nothing here needs SQL yet |

**Recommend B.** Precedents for sidecars already exist (`ignored-content.json`, `archive-angel/evidence.json`, `date-inference/*.json`, the POI store). The record gets exactly one additive optional field, `footageAlignment` (§3.4), so a record can answer "where on the reference timeline am I" without opening the store. C++ reading: option A embeds a `std::vector` in every row; option B is a separate table with a foreign key, which is what you want when many rows reference one shared object.

The store is small: a 94-minute tape yields perhaps 10–40 segments; 268 FamilyArchive videos → a few thousand segments, each a few hundred bytes with evidence — under 5 MB. The search index (`CatalogSearchIndex.swift`) adds segment titles, people, event, place and tags to each record's haystack at build time by resolving the record's `FootageKey`; segment evidence text (transcript snippets, captions) joins the haystack only under the existing `transcript:` field token so plain search stays calm.

### 3.3 Content identity (`FootageKey`)

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

### 3.4 Alignment between copies (`FootageAlignment`)

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

### 3.5 Timecode where present

If a record carries a start `timecode`, segments can also be shown and entered in tape timecode (`01:32:50;12`), which is what Rick's older Avid bins and FCP projects reference. Conversion is `seconds = (frames(TC) − frames(startTC)) / rate`, drop-frame per SMPTE 12M. Reuse the existing `avidEditRate` when the stream rate is missing. This is display sugar on top of seconds; seconds remain the stored unit.

## 4. Marking moments: human first, machine-proposed boundaries second

### 4.0 The one-keystroke path (primary)

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

### 4.1 Machine-proposed boundaries (helper)

Four local signals, one fusion step, Rick confirms. The point of the proposals is to put `]` stops where the occasions change so the human presses `⏎` instead of scrubbing 94 minutes. Everything below runs on Apple Silicon with tools already in the repo or in Homebrew; nothing leaves the machine (§6). Face-set change is kept as a weak boundary signal (people walking in and out marks a scene change) and is never used to name who is in a segment unless a human confirms it.

#### Signals

| Signal | Tool (local) | What it yields | Cost per hour of video (M4 Max, est.) | Notes |
|---|---|---|---|---|
| **Timestamped speech** | `mlx_whisper` (venv-mlx), `whisper-medium-mlx-q4` — same worker, return `segments` | `[{start, end, text}]` ≈ one every 2–8 s; names, "happy birthday", "Thanksgiving", now-cues ("it's 1984") | 4–12 min/h (code measures 5–15× realtime, `CaptionOrchestrator+Dossier.swift:466`) | Today `whisper_worker.py` keeps only `result["text"]` (`handle_request`, ~line 91); `mlx_whisper.transcribe` already returns `segments`. One-line protocol change, additive. **Existing transcripts have to be re-run to get times.** |
| **Shot changes + gaps** | `ffmpeg -vf "scdet=threshold=10,blackdetect,freezedetect" -af silencedetect` in one pass, or AVFoundation + `VNGenerateImageFeaturePrintRequest` distance at 1 fps | boundary candidates with scores; black/silence spans = tape pauses, blank tape | hevc access copy via VideoToolbox: ~2 min/h; ffv1/prores SD master: 6–12 min/h (CPU decode) | Run on the **smallest decodable copy** in the footage group and map through alignment. Camcorder tapes have hard cuts at every record pause, which is exactly where occasions change. VHS noise causes false positives; the 2-minute floor and fusion absorb them. |
| **Face-set changes** (weak) | existing ArcFace CoreML / findtagd machine tier; `pf_cache.segments_json` already holds `{s,e}` spans per person | *how many* faces and whether the set changed (a room empties, new people arrive) — a boundary hint; identities are machine tier and not trusted for naming (Rick: look-alike family across decades) | 6–10 min/h at frame step 5 (≈ 6 fps); zero when cached | Optional stage. Make the cache content-keyed (store `contentHash` next to `video_path`) so copies reuse it. Living-family embeddings never leave the machine. |
| **Burn-in date / on-screen text** | Vision `VNRecognizeTextRequest` on a bottom-band crop, 1 frame / 10 s, from the same ffmpeg pass (`fps=0.1` thumbnails) | "NOV 22 1984", "PM 6:31"; a date change is a hard boundary; feeds `ocrDateCandidates` | ~1 min/h (360 frames × ~60 ms + shared decode) | Far cheaper than the VLM date prompt; keep the VLM prompt for frames Vision cannot read. Rare on 1984 VHS, common on 1990s camcorders. |
| **Scene captions per keyframe** | existing `MLXVLMCaptionRunner` (`CaptionRunner.swift:630`), Qwen2.5-VL-3B 4-bit, one keyframe per proposed segment | "a dinner table with a turkey…", searchable text per segment | ~2.5 s per prompt per frame (today: 3 frames × 3 prompts in ~10–20 s per file); at ~40 keyframes/h × 3 prompts ≈ 5 min/h; scene prompt only ≈ 1.7 min/h | Captions follow boundaries, not the other way round: caption the middle frame of each proposed segment, so a 94-minute tape gets 10–40 captions where it has 3 today. |

All five run on every Mac in the fleet; the VLM wants ≥ 16 GB (3B 4-bit ≈ 2.5 GB weights plus KV), Whisper medium ≈ 1 GB. The M1 Max (32 GB) is fine for all of them one at a time.

### 4.2 Fusion → proposals

1. Collect boundary candidates with a weight: burn-in date change 1.0, shot change 0.4 (0.7 when preceded by black/silence ≥ 3 s), a spoken occasion cue 0.6 placed at the cue's segment start, face-count/set change 0.3.
2. Cluster candidates within ±3 s; a cluster's score is the sum. Accept clusters ≥ 0.8.
3. Cut the timeline at accepted clusters; merge spans shorter than 120 s into a neighbour unless the span holds a strong cue (the birthday song, a burn-in date).
4. Label each span: `event` from the occasion lexicon hit inside it (`DateTriangulator.swift:246`), suggested `tags`/`people` from names **spoken** inside it that resolve to People-tab aliases or to existing tags ("Hudson" → `hudsons`), `date` from a now-cue or burn-in inside it, else the record's best date with the reason "from the tape's date", `title` = "<Event> with <two names>" or the first caption's subject. Face identities are not used for labels.
5. Write them `.proposed(method: "fusion", version: 1)`. Nothing is confirmed until a person presses `⏎`.

The Mark's-birthday × Thanksgiving tape is the canonical test: 36 "happy birthday" hits in the first half, "thanksgiving" and the Hudson introduction later, Donna present throughout; a correct run yields at least two segments with different events on one record.

### 4.3 Confirming

In the Inspector, a **Moments** section (family word for segments; §8) lists proposals as dashed rows with the title, time range and a one-line "why" ("36× 'happy birthday' 1:27–2:40; 'Mr. Glenn Hudson' spoken at 52:14"). Actions: Confirm (`⏎`), Rename, Merge with next, Split here (at the player head), Not a moment (`⌫`). Confirm turns it plain and stamps `.confirmed`. The `I`/`O`/`M` keys of §4.0 work in the same view, so a session on one tape is: play, `]` to the next proposal, `⏎` or retitle, `I`/`O` for anything the machine missed. Proposals are visible only with the Curator toggle on (§5.1); confirmed and user moments are visible to everyone.

## 5. Search and surfacing

### 5.1 Catalog UI (calm by default)

- **Table.** No new column. Records that have confirmed moments show a small chapters glyph next to the duration (the filmstrip precedent). Curator toggle adds a faint count ("3 moments · 2 proposed").
- **Search.** `CatalogSearchIndex` includes moment title/people/event/place/tags in the haystack. A hit inside a moment ranks the record and remembers the moment: the row's tooltip and the Inspector open on that moment. Field tokens: `moment:hudsons`, `event:thanksgiving`, `people:` already exists and gains segment people (confirmed only in the plain lane).
- **Play from there.** Double-click a moment in the Inspector, or Return on a search hit, seeks the existing preview player (`CatalogHelpers.swift:1387`, `VideoPlayer(player:)`) with `player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)` after the item is `.readyToPlay`. The time shown is the record's own time (reference time mapped through `footageAlignment`), so the hevc copy and the ffv1 master both land on the Hudsons.
- **Archive tab.** The decade timeline gets a per-video moment strip only under Curator; the occasion cue a video already shows for everyone is now derived from confirmed moments when present (a tape with Birthday and Thanksgiving shows both cues).
- **No O(records) work in view bodies.** Haystack joins happen at index build; the Inspector resolves one record's moments through a `[UUID: [MediaSegment]]` memo keyed by `referenceRecordID`, invalidated by the store's generation.

### 5.2 Hallie (agent lane and local lane)

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

### 5.3 Data classes and the cloud lane

Per the rev-6 policy: segment titles, event, people names, place, dates and evidence *summaries* are `familyText` and may travel to the cloud lane. Transcript segments and captions are text derived from pixels and audio of living family; **default `familyMedia` until Rick rules** (open question carried from rev 6, decision line in §8). `search_media` serializes snippets only when the endpoint class allows; a poisoned-endpoint sensor proves a `remote` endpoint never receives a `transcript`/`caption` field.

## 6. Privacy

Rick's 2026-10-10 ruling: pixels and audio of living immediate family never leave the machine. Consequences for this design:

- Every proposer in §4.1 is local: MLX Whisper, ffmpeg, Vision, ArcFace CoreML, Qwen-VL via MLX. No remote caption or transcription API, ever, for family media.
- Fleet backfill (§7) moves **audio and keyframes between Rick's own Macs over the LAN** (SMB mount or `ssh`/`rsync` on `.local`). This is "the machine" in the plural; it needs an explicit yes (§8). Default if no ruling: FamilyArchive work runs only on the volume host (M4 today, M5 Ultra later).
- Work packets on laptops are deleted after their results are merged; a sensor checks the staging folder is empty after a job finishes.
- Logs never carry transcript text or caption text (the `ArchiveLogPrivacyTests` precedent): START/OUTCOME lines name files and counts.
- The segment store is family data under Application Support, never in git (privacy rule, 2026-08-03).

## 7. Backfill plan (MFO jobs)

### 7.1 Shape

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

### 7.2 Hours (FamilyArchive, 165.4 h of video)

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

## 8. Decisions for Rick (one per line, with a recommendation)

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

## 9. Phased plan with tests (five dimensions each)

Branch per phase; merge after boundary sensors run; tests before Rick's spot test.

### Phase 0 — Coverage (1–2 days)

Scope: gate change (ruled), lifecycle exclusions logged, text-share cycler, Whisper worker returns segments (additive `segments` key; Swift ignores it until phase 1), `videoUnreadable` → `needsReformat`, Analyze dashboard shows "not eligible (stage)" counts.

- Logic: `pfCatalogWideMetadataCandidates` includes `.archived`/`.reviewing`, excludes `.trashed`; `applyDossier` on an archived record writes text, never `inferredRecordDate`/`userDate`; text-share copies captions+transcript to a same-group sibling with provenance and refuses when the target already has text.
- Scale: 100k synthetic records (20 % archived, 2,000 footage groups): candidate filter < 50 ms; text-share pass < 2 s; Debug ceiling via `PerformanceLane.debugCeiling`.
- Media matrix: mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv fixtures through the serial loop with a stub `CaptionRunner`; the worker protocol test parses a `segments` payload from each.
- Isolation: poisoned `analysisScope_includeAudioOnly` and a stale `DossierActiveVolumes` in UserDefaults do not change which stages a video record passes.
- Sensor: a FamilyArchive-shaped fixture catalog (archived masters, in-triage copies, one re-encode) run through a full pass ends with 0 eligible videos lacking text; a second sensor fails when the OUTCOME line omits the stage-exclusion count.

### Phase 1 — Segment model, store, one-keystroke marking, play-from (3–4 days)

Scope: `MediaSegment`, `FootageKey`, `FootageAlignment` (identity + equal-length only) in VideoScanCore; `SegmentStore` with atomic publish and generation; the `I`/`O`/`M` marking keys and tag entry in the preview player (§4.0); Inspector "Moments" with Rename/Delete; search haystack join incl. `moment:`/tag tokens; seek in the preview player; Archive tab cue from moments. This phase alone makes "hudsons" findable on the 1984 tape after one viewing, with no machine help.

- Logic: store round-trips; resolution order (id → hash → group); equal-length alignment; haystack contains moment words and tags; token classification (tag vs person vs event) from typed text; seek target mapped through alignment; `I` then `O` creates exactly one `.user` moment, `O` before `I` is a no-op with a hint.
- Scale: 100k records + 300k segments: index build < 3 s extra, Inspector memo lookup < 1 ms, no O(records) in view bodies (the house ForEach rule test).
- Media matrix: seek to a moment start in each of the five fixtures lands within one frame (`AVPlayerItem` time check), including the `.mxf` audio-only case which must refuse gracefully.
- Isolation: a damaged `segments.json` (truncated, foreign keys) loads as empty with a logged outcome and never blocks catalog load; a poisoned generation counter cannot overwrite a newer store.
- Sensor: the 1984 fixture (a synthetic two-event file with two aligned copies of different length) — a moment authored on copy A is found by search and seeks correctly on copy B.

### Phase 2 — Alignment across copies (3 days)

Scope: timecode alignment, dense perceptual fingerprint v2 + correlation, manual two-point alignment, re-anchor when the reference changes, content-keyed `pf_cache`.

- Logic: drop-frame and non-drop timecode math against known vectors; correlation finds a planted offset of 17 min 3 s in a 76-min subset; scale 1.001 detected.
- Scale: 100k alignments resolved < 1 s; correlation of 6,000 × 6,000 hashes < 1 s.
- Media matrix: fingerprint v2 on all five fixtures; a trimmed `test_` copy of each aligns to its source.
- Isolation: fingerprint recipe version bump marks every stored alignment stale without touching segments.
- Sensor: segment positions on every copy in a three-member synthetic group agree within 0.5 s after re-anchoring to a different reference.

### Phase 3 — Proposers and fusion (1 week, overnight runs)

Scope: `transcribe-v2` consumer (spoken cues with times), ffmpeg scdet/black/silence pass, Vision OCR, face-count changes from `pf_cache` (weak, optional), fusion, proposal UI (`⏎`/`⌫`/Merge/Split), the MFO "Analyze footage" job with fleet packets.

- Logic: fusion on hand-built evidence yields the expected cuts; the 120 s floor merges a 40 s span unless it holds the birthday cue; names resolve through People aliases; `rejectedPeople` cannot appear confirmed.
- Scale: fusion over 10k candidates per tape < 100 ms; 100k records' proposals load lazily.
- Media matrix: scdet and OCR pass runs on all five fixtures (synthetic hard cut at 2.0 s and a burned-in "JUN 21 1991" via `drawtext`), fixtures prefixed `test_`.
- Isolation: the fleet merge refuses a JSONL packet whose `contentHash` does not match a catalog record; staging folder is empty after OUTCOME.
- Sensor: the synthetic Mark's-birthday × Thanksgiving fixture (TTS "happy birthday" ×6 at 1:20–2:40, a hard cut, a different speaker saying "Thanksgiving") produces ≥ 2 proposals with different events; the log carries no transcript text.

### Phase 4 — Captions per moment and Hallie tools (1 week)

Scope: `captions-v2`, `search_media`/`get_segment`, `momentFor` claim + verifier, `playMedia(recordID, atSeconds)` action, data-class enforcement.

- Logic: tool results omit snippet fields for a `remote` endpoint; verifier drops `.proposed` segments from facts; action derives only from verified claims.
- Scale: `search_media` over 100k records + 300k segments < 200 ms p95.
- Media matrix: caption keyframe extraction on all five fixtures with a stub VLM.
- Isolation: poisoned endpoint policy (remote marked local) is caught by the adapter sensor; a missing MLX venv degrades to no captions with an outcome line, not a failure.
- Sensor: eval corpus gains "show me the Hudsons at Thanksgiving" and "Matt's birthdays" against the fixture store; both answer with a verified moment and an offered play action.

## 10. Risks

- **Footage group id instability** rewrites `groupID` on every run; mitigated by `FootageKey` resolving through the reference record and hash, never storing `groupID`.
- **False boundaries on noisy VHS** (tracking, dropouts) inflate proposals; the floor, fusion weights and Curator-only visibility keep them out of the family view until confirmed. Measure precision on the first ten tapes before widening.
- **Whisper hallucination on music and silence** (the 26-minute wedge precedent) — deadline rule stays (`max(60, 2× duration)`), silence spans from the ffmpeg pass are excluded from cue mining.
- **Re-transcription cost** (~21 h) competes with the demo-week machine budget; it is overnight work and resumable per stamp.
- **Fleet merge conflicts**: two machines writing the same record; the merge is single-writer on the volume host, keyed by content hash, append-only JSONL in, one catalog save out.
- **Store orphaning**: a reference record purged or deleted leaves segments pointing at a hash; they re-attach on rescan (resolution rule 2) and the store's audit lists unattached segments under Curator.
- **Privacy leak through logs or packets**: pinned by the no-text-in-logs sensor and the empty-staging sensor; LAN-only transport is an explicit decision (8.5).
- **Search calm**: adding transcript snippets to plain search would make every tape match "mark"; snippets stay behind the `transcript:` token.

## 11. Appendix: Swift notes for a C++ reader

- `struct` with `var` fields and `Codable` ≈ a POD with a generated serializer; passing it is a copy, so the store hands out values and takes edited values back (`store.upsert(segment)`), no aliasing bugs.
- `enum SegmentEvidence` with associated values ≈ `std::variant<Spoken, FacePresent, …>`; `switch` over it must be exhaustive, which is how new evidence kinds force every consumer to decide what to do.
- `FootageKey` resolution is a free function over the catalog's indexes (`record(forPath:)` is O(1) already; add `records(forContentHash:)` and `records(inFootageGroup:)`), not a method on the record — the record should not know about the store.
- The store's atomic publish is write-temp-then-rename (`AtomicFilePublish`, load-bearing per the rename-wedge note); never `replaceItemAt`.
- Main-actor rule: the store is `@MainActor` like `CatalogStore`; the proposers run off-actor (`@concurrent` where they are `nonisolated async`, per the approachable-concurrency trap note) and hand back value arrays.
