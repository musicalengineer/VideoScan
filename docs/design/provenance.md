# Provenance — what each file is and where it came from

Status: in flight — 2026-11-10. Built: Provenance ▸ Set Role (schema v13 `provenance_roles`, its one writer; Codex merge 10/26) and Phase A, Find Master by sound (`VideoScan/Provenance/`). Landed with background step 1: schema v14 `provenance_assertions` with the veto trigger, exactly the C2 table and nothing else (approved 2026-11-01; Part I "Data model ▸ Shipped"). Not built: the carrier / capture-setup / capture-event tables (their own migration, later), Phase B picture timeline, Phases C–E except C2's first slice (estimated provenance from one rule, confirmable; 2026-11-10); Phase F is cut. Open rulings: STATUS "Open rulings wanted" items 1–2.

Every master in the archive should know its story — which tape it came from, when and how it was digitized, what kind of copy it is — captured once, by Rick, not reconstructed later (Part II, 10/22). Part I (10/26) is the design built on that: retroactive provenance for the files already catalogued, from the engines that already exist (sound and picture prints, the DV datecode, the 8B era witness), every value carrying its state (`inferred · confirmed · corrected · rejected`) and a trigger that refuses to re-propose a rejected value. What each role means, in Rick's words, is `docs/guides/provenance_roles.md`.

**Contents:** Part I — Provenance, retroactive (design, 2026-10-26) · Part II — a pointer to the archived 10/22 lightweight draft · Part III — The research it rests on (summaries; originals archived).

# Part I — Provenance, retroactive (design, 2026-10-26)


*Rick said "design it" on 2026-10-26. This builds on `provenance_lightweight_2026_10_22.md` (the workflow and the
records), `docs/archive/research/provenance_deep_dive_2026-10-23.md` (vocabulary, per-field state, backfill rules) and
`docs/archive/research/provenance_retroactive_fingerprinting_2026-10-25.md` (phases A–F, the engines that already exist).
It repeats none of them where a pointer will do. Phase A is written to be implemented as-is; B–E are written to be
planned from.*

## Ruled 2026-10-26 (best practice, Rick)

Rick, 11:00: "follow best practices for all those questions, design and implement." Recorded in `docs/DECISIONS.md`.

| # | Question (10/25 deep dive §10) | Ruling |
|---|---|---|
| 1 | Film scans | 8 mm / Super 8 scans are one more **source kind** (a carrier format), no special pipeline. The cadence analysis is built only once Rick says where the scans are. |
| 2 | First picture-fingerprint run | The **155 FamilyArchive Masters** first (they are what everything else should resolve to), then **LaCieWorkspace**, then the rest. |
| 3 | Front door | Ship **Provenance ▸ Find Master (sound only)** first, as Phase A, before the Provenance sheet. |
| 4 | VLM benchmark results | Per-clip results (year guesses on named family footage) stay in `.scratch/`; only **aggregates** (MAE, fraction within ±5 years, per decade) go in the repo. |

Standing, not reopened: `00_Index/Provenance.csv` + `Carriers.csv` beside the v3 manifest, never manifest v4
(2026-10-23). Rule 13: every model is local; nothing of living immediate family (pixels, audio) goes to a cloud model.

## Purpose, in Rick's terms

Every master in the archive should know its story — which tape it came from, when and how it was digitized, and
which other files in the catalog are copies, clips or later transfers of it. The July 2026 VHS batch and the 2008
DV captures lost that story; this design recovers as much of it as the evidence allows. The machine proposes, with
its evidence and a confidence on every guess; Rick confirms per tape, not per file; a value he rejects is never
proposed again. A fact shown as provenance comes from evidence (a matched sound print, a matched picture
timeline, a camera's recorded date), never from a folder name alone (Charter §2.2: "machine generated needing human
confirmation").

## What exists vs what is new

| Piece | Today | This design |
|---|---|---|
| Content identity | `content(digest)` whole-file SHA-256 | unchanged; every new row keys on it |
| Sound print | Wang-2003 landmarks, `AudioFingerprint` + `AudioFingerprintMatcher` (pair verdicts with offset, coverage, span); sidecar `audio-fingerprints.sqlite` (209 MB, 25.1 M landmarks, 5,348 fingerprinted digests, 3,576 with ≥ 20 landmarks); stamp `sound_prints` | **A:** a catalog-wide inverted index (job artefact, not persisted) and a two-stage finder whose verdict is the existing pair matcher's |
| Picture print | v1: 32 frames at normalised positions, 64-bit dHash, `perceptual_prints` (4 rows) — cannot align a cut clip | **B:** v2 1 fps timeline, 256-bit PDQ-class hash + quality, crop/strip/field normalisation, sidecar `picture-prints.sqlite`, stamp `picture_prints` |
| Pair compare | Compare Media (sound strips), Compare Footage (Python barcode) | unchanged; they keep their jobs |
| Relation "X is inside Y at t" | none (`lineage` kinds are edit verbs; `supersessions` empty) | **C1:** `content_excerpts`, append-only machine evidence, no direction |
| Per-field provenance + veto | none (`people_tags` shows the bug) | **C2:** `provenance_assertions` with the rejected-value veto trigger |
| Carrier / capture records | none | **C2:** `capture_setups`, `carriers`, `capture_events`, `carrier_spans`, `file_provenance` (10/23 shape) |
| Archive copy | v3 manifest, ledger mirror | **C3:** `Provenance.csv`, `Carriers.csv`, `Provenance_README.txt` regenerated under the index lock |
| DV recording dates | nothing reads them (937 DV rows, 120.7 h) | **D:** dvrescue `rdt` reader → inferred dates and spans |
| VLM era guess | Qwen2.5-VL-3B captions (date/scene/text prompts) | **E:** research gate; ships only on a passing benchmark |
| CLIP event clustering | none | **cut** (see Phase F) |

### Where this supersedes the 10/22 lightweight design

| 10/22 said | Now | Why |
|---|---|---|
| Manifest v4 columns | `Provenance.csv` beside the v3 manifest | ruled 2026-10-23 |
| `file_provenance` carries a carrier column and an inferred/confirmed bit | carrier links are `carrier_spans` (ranges, several tapes per file, several files per tape); machine drafts live in `provenance_assertions` with a state per field | 10/23 deep dive; one bit cannot hold who said so, the correction, or the veto |
| "FFV1 · 720×480 · 29.97 → VHS" | folder + encoder (`Lavf61.7.100`, 1280×720p30) + birth date | the old rule matches zero July files |
| Schema "v13" for all provenance tables | shipped: v13 = `provenance_roles`, v14 = `provenance_assertions` only; `picture_prints` (B), `content_excerpts` (C1) and the carrier tables (C2) each wait for their own migration | each migration gets its own approval and its own rollback-free proof |
| "SHA-256 match to an existing Master inherits provenance" | kept for byte-identical copies; a **proven excerpt** (sound/picture) is only *evidence* shown on the sheet, never inheritance | similarity never creates lineage (2026-09-23) |

Everything else in 10/22 (Ingest → Identify → Confirm → Archive, logging, born-digital has no tape, confirm per tape)
stands and is Phase C.

## Shape (how it fits)

- **Engines in Core, pure and value-typed**: `AudioCatalogIndex`, `AudioMasterFinder` (A); `PictureTimeline`,
  `PictureTimelineMatcher` (B); `ProvenanceResolver` (C2). No I/O inside matchers; stores are the only SQLite code.
- **App side, one folder `VideoScan/VideoScan/Provenance/`**: MFO jobs, their plans (pure), answer wording (pure),
  detail views. **No `extension VideoScanModel`.** Phase A needs no feature store: the job owns its results (the
  `PairCompareJob` pattern). Phase C2 introduces `ProvenanceStore` (a `@MainActor` feature store injected through the
  environment, #337) for the sheet's state.
- **One engine per verb (rule 4)**: the sound verdict is always `AudioFingerprintIndex.match` (the pair matcher); the
  finder only chooses which pairs to ask. The picture verdict is always `PictureTimelineMatcher`. Every caller (Find
  Master, the C1 sweep, Compare Media) goes through them.
- **Writes**: Phase A and B write no provenance. B writes its sidecar then its catalog stamp (the audio order). C
  writes through the one commit door (`CatalogCommitter`), never a side connection.

## The sidecar databases

| File | Phase | Holds | Key |
|---|---|---|---|
| `audio-fingerprints.sqlite` | exists | landmark blobs ("VSAF" v2) | `(content_digest, size_bytes, engine_version)` |
| `picture-prints.sqlite` | B | per-second hash timeline blobs ("VSPT" v1) | same |

Both live in `~/Library/Application Support/VideoScan/` beside `catalog.sqlite`; never beside media; never in git.

Open/close/WAL rules (the audio store's, plus the 10/26 rulings), for every sidecar:

1. **One connection per store object**, behind an `NSLock` (≈ `std::lock_guard` around each public method). A job
   opens the store when it starts and drops it when it ends (`sqlite3_close_v2` in `deinit`). Views never open a
   sidecar. No `ATTACH` to the catalog: there is no cross-database transaction, so the write order is fixed —
   **sidecar first, then the catalog stamp** — and a sidecar row with no stamp is harmless (found as "shared").
2. **WAL, `synchronous=NORMAL`**, a `schema(version)` table. Open refuses, with words, before any media is read:
   folder not writable, not a database, schema newer than the build.
3. **Read-only opens restore a missing `-wal`** (create-only, never truncating) when the folder is writable, and
   otherwise refuse ("last closed by another program") — DECISIONS 2026-10-26 (#386).
4. **Nothing ever deletes a `-wal` or `-shm`**, including on a refused open — DECISIONS 2026-10-26 (#387).
5. **Long reads page**: an iteration takes the lock per page of 256 rows (keyset paging on the primary key), so a
   Find Master index build never blocks a running Fingerprint Sound job's `put` for more than one page.
6. **End of job**: `PRAGMA wal_checkpoint(PASSIVE)`; never `TRUNCATE` while another job may hold the store.
7. Backup: the sidecars are expensive to rebuild (audio = one full read of 7.55 TB), so the nightly App Support backup
   copies them with SQLite `.backup`, like the catalog. (Check the backup job covers them; issue if not.)

## Data model — schema changes (all additive; **each needs Rick's approval**, rule 6)

Ledger kinds (`captured`, `carrierInspected`, `provenanceConfirmed`, `transferSuperseded`, `excerptConfirmed`) are
values in `ledger.kind` (plain TEXT), appended at the end of `MediaLedgerEvent.Kind` — no migration.

### Shipped

| Schema | Migration | What | Approved | DDL (the source of truth) |
|---|---|---|---|---|
| v13 | `v8_provenance_roles` | `provenance_roles`: digest → role, decided_at, source_missing, note; append-only; newest row per digest is the role; no row = Unknown. Written only by Provenance ▸ Set Role through the commit door. | Rick 2026-10-26 | `docs/design/catalog_sqlite_schema_v1.sql` §17 |
| v14 | `v9_provenance_assertions` | `provenance_assertions` with the veto trigger and the two append-only triggers — the C2 table, nothing else (DECISIONS 2026-11-01). Background step 1 writes machine observations into it (`era.yearRange`, `era.fused`, `ocr.date`, state `inferred`, by `machine:<approach id>@r<revision>`) through the app's `JournalApplier`. | Rick 2026-11-01 | `docs/design/catalog_sqlite_schema_v1.sql` §18 (`CatalogDataSchemaTests` diffs it against `CatalogProvenanceAssertionsSchema.swift`) |

**v14, the assertions table, in one paragraph.** One row per (subject, field, value) claim, append-only: the machine
*infers* (with a required confidence, kept for calibration, never shown); only the catalog's owning user (the literal
`'rick'`, DECISIONS 2026-11-01) *confirms, corrects or rejects*. The veto trigger silently ignores (`RAISE(IGNORE)`, so a
batch survives) an inferred value whose latest human decision on that same (subject, field, value) is `rejected`; the
writer reads `changes() == 0` and logs "vetoed". UPDATE and DELETE are refused: the history is the table. The pattern is
the one the catalog uses for dates (`user_dates` beside `inferred_dates`): typed tables will hold what Rick confirmed,
`provenance_assertions` holds every machine draft, every human decision and every veto; display = the typed value if
Rick set it, else the best inferred assertion no rejection vetoes (`ProvenanceResolver`, pure, Phase C2). Until those
typed tables exist, an assertion is shown only as its own labelled line, never as the fact (DECISIONS 2026-11-01).

### Designed, not built (each its own migration, number and approval)

| Table | Phase | What |
|---|---|---|
| `picture_prints` | B | The catalog stamp for a v2 picture timeline (mirrors `sound_prints`); the hashes live in the sidecar `picture-prints.sqlite`. |
| `content_excerpts` | C1 | Append-only machine evidence that one content lies inside / equals / overlaps another; no direction (2026-09-23). |
| `capture_setups`, `carriers`, `capture_events`, `carrier_spans`, `file_provenance` | C2 | The confirmed records, 10/23 deep-dive shape; rows never deleted; a correction updates the typed row and appends `rejected`(old) + `corrected`(new) assertions in one commit. |

The draft DDL for all of them, as written on 10/26 (when it was numbered v13 / v14), is archived verbatim at
`docs/archive/design/provenance_schema_draft_2026_10_26.md`; treat it as a starting point for each migration's
approval, not as approved text. Role codes are ours; `Provenance.csv` writes the PBCore word beside each
(`preservation` → `Preservation`, `access` → `Copy: Access`, `edit` → `Master: production`, `test` → `Work tapes`,
`bornDigital` → `Original`).

## Phase A — Provenance ▸ Find Master, by sound (implementation-ready)

**What Rick gets.** Right-click one or more rows in the Catalog ▸ **Provenance ▸ Find Master**. An MFO row runs for a
few seconds; its detail lists, for each selected file, every other content in the catalog whose **sound** lines up
with it: "same recording", "this file's sound is inside *Cape-1993-archive.mkv* from 12:40 to 13:20", "contains this
file's sound", or "shares 42 s with". Each line shows offset, coverage, matching landmarks and "sound" as the proof,
and a Reveal-in-Catalog button. A negative answer says what was searched. Nothing is written anywhere except log lines.

**Schema change: none.** No catalog write, no sidecar write, no ledger event (no record changes).

### The engine (Core, two stages, one verdict)

Stage 1 finds *candidates* cheaply across the whole sidecar; stage 2 asks the existing pair matcher about each. The
verdict a user sees is always `AudioFingerprintIndex.match` — byte-for-byte the code Compare Media runs (rule 4).

**`AudioCatalogIndex`** (new, `VideoScanCore/AudioCatalogIndex.swift`). A compressed-sparse-row inverted index over
every compatible print (C++ analogy: `std::vector<uint32_t> offsets(1<<24 + 1)` plus one flat `std::vector<Posting>`,
filled by counting sort — no per-hash heap arrays, unlike `AudioFingerprintIndex`'s dictionary of arrays).

```swift
public struct AudioCatalogIndex: Sendable {
    public struct Document: Sendable, Equatable {        // ordinal = position in `documents`
        public let key: AudioFingerprintStore.Key       // sha256:<hex>, size
        public let durationSeconds: Double
        public let complete: Bool
        public let landmarks: Int
    }
    public struct BuildReport: Sendable, Equatable {
        public var indexed = 0, landmarks = 0
        public var notWholeFileKey = 0          // 'v1:' (sampled) keys: a hint, never identity (rule 6)
        public var otherRecipe = 0              // made by an older recipe: not comparable
        public var tooFewLandmarks = 0          // < AudioMatchPolicy.minMatchedLandmarks: can never match
        public var unreadable = 0               // blob failed to decode; listed by key in `unreadableKeys`
        public var unreadableKeys: [AudioFingerprintStore.Key] = []
    }
    public let recipeID: UInt32
    public let documents: [Document]
    // offsets[h] ..< offsets[h+1] are the postings of hash h (hash space is 24 bits: f1 9 | f2 9 | dt 6)
    // postings: (documentOrdinal: UInt32, anchorFrame: UInt32)
    public static func build(store: AudioFingerprintStore,
                             recipeID: UInt32 = AudioFingerprintParameters.default.recipeID,
                             progress: @Sendable (Int, Int) -> Void,
                             isCancelled: @Sendable () -> Bool) throws -> (AudioCatalogIndex, BuildReport)
    public func postings(of hash: UInt32) -> ArraySlice<Posting>
}
```

Build = two paged passes over the sidecar (count per hash, then fill), so peak memory is the index itself, never the
decoded prints. A print whose hash is ≥ 2^24 refuses that print (counted unreadable), never the build.

MEMORY (worst case, documented in the file): `offsets` 2^24 × 4 B = 67 MB fixed + 8 B per posting. Today 25.1 M
landmarks → **≈ 268 MB**; 2× today's archive → ≈ 470 MB. A hard cap `maxPostings = 100_000_000` (867 MB) refuses
the build with words ("the sound index would need N MB") rather than grow without bound.

**`AudioMasterFinder`** (new, `VideoScanCore/AudioMasterFinder.swift`):

```swift
public struct AudioMasterFinderPolicy: Sendable, Equatable {
    public var candidateCount = 10           // stage-2 pair matches per query
    public var minCandidateVotes = 8         // stage-1 floor (stage 2 still needs 20 matched landmarks)
    public var maxPostingsPerHash = 128      // a hash this common catalog-wide says nothing about WHERE
    public var maxVotingLandmarks = 20_000   // longer queries vote with an even subsample; stage 2 uses all
    public var match = AudioMatchPolicy.default
    public static let `default` = AudioMasterFinderPolicy()
}
public struct AudioMasterCandidate: Sendable, Equatable {
    public let key: AudioFingerprintStore.Key
    public let match: AudioMatch               // from AudioFingerprintIndex.match — the one verdict
}
public enum AudioMasterRefusal: Sendable, Equatable {
    case otherRecipe(query: UInt32, index: UInt32)
    case tooLittleSound(landmarks: Int)        // < policy.match.minMatchedLandmarks
}
public enum AudioMasterSearch: Sendable, Equatable {
    case found([AudioMasterCandidate], searched: Int)   // ranked; .different dropped
    case noneFound(searched: Int)                       // searched = index.documents.count − 1
    case refused(AudioMasterRefusal)
}
public enum AudioMasterFinder {
    public static func find(query: AudioFingerprint, queryKey: AudioFingerprintStore.Key,
                            in index: AudioCatalogIndex,
                            load: (AudioFingerprintStore.Key) throws -> AudioFingerprint?,
                            policy: AudioMasterFinderPolicy = .default) rethrows -> AudioMasterSearch
}
```

Stage 1: each query landmark (subsampled evenly to `maxVotingLandmarks`) probes `hash` and its `dt ± 1` neighbours
(the matcher's `deltaFrameTolerance`), skips postings lists longer than `maxPostingsPerHash`, and votes into a
dictionary keyed `(document, (tMaster − tQuery) / 16)` — one-second offset bins. A document's score is its best bin
plus both neighbours. The query's own digest is excluded. The top `candidateCount` documents with ≥
`minCandidateVotes` go to stage 2. Stage 2: `load(key)` the candidate's full print, `AudioFingerprintIndex(master:)
.match(query)`. Ranking: `sameRecording` › `containedInMaster` › `masterContainedInQuery` › `overlap` ›
`inconclusive`; within a verdict, coverage then matched landmarks. Vote memory: ≤ 20,000 × 3 × 128 = 7.7 M entries in
the pathological case (≈ 150 MB transient); typical < 1 MB.

**Store addition** (`AudioFingerprintStore.swift`): `public func forEachFingerprint(engineVersion:pageSize: = 256,
_ body: (Key, Result<AudioFingerprint, Error>) throws -> Bool) throws` — keyset-paged, lock per page, a row that will
not decode is passed as `.failure` (the build counts it), never thrown.

**CLI** (`AudioFingerprintCLI.swift`): `videoscan-audio-match find <file> --sidecar <dir>` — fingerprints the file (or
takes `sha256:<hex>:<size>`), builds the index, prints ranked answers and the build report. Read-only. This is how the
acceptance numbers are produced and how Rick can spot-check from a terminal.

### The app side (`VideoScan/VideoScan/Provenance/`, new folder)

| File | Type | Responsibility |
|---|---|---|
| `FindMasterPlan.swift` | `struct FindMasterPlan` (pure) | From a snapshot of the selected records → `[FindMasterQuery]` (record id, name, `Key`) and `[FindMasterRefusal]` with reasons; and a `[digest: FindMasterLabel]` snapshot (name, path, archived, live/removal state) for candidates. Built once when the job starts (O(records) once, never in a view body). |
| `FindMasterAnswer.swift` | `enum FindMasterAnswer` (pure) | The words: one sentence + one log line per answer and per refusal. Truth tests target this file. |
| `FindMasterJob.swift` | `@MainActor final class FindMasterJob: @MainActor MediaFileOperationJob` | Opens the sidecar, builds the index off-main, runs the finder per query, publishes results; Pause/Stop; START/progress/OUTCOME. |
| `FindMasterDetailView.swift` | SwiftUI view | The MFO row's detail: per query, the ranked answers and Reveal in Catalog. |
| `FindMasterMenuItem.swift` | SwiftUI `View` | `Menu("Provenance") { Button("Find Master") }`, embedded in `tableContextMenu` (`Catalog/CatalogContent+FolderTable.swift`). Reads the selection and `model.records` to build the plan; starts the job on the MFO center. Not a model extension. |
| `MediaOps/MediaFileOperations.swift` | edit | `static let findMaster = Self("findMaster", hasDetailView: true, style: …)` (badge "MASTER?", log verb "find master", a fill distinct from the others — the nightly sensor checks). |

Refusals the plan makes before any search (each one a sentence, never "no master found"):

| Record state | Answer |
|---|---|
| no whole-file SHA-256 | "Not hashed yet — run Fill In Full Hashes; a sampled hash is not identity." |
| no `sound_prints` stamp | "No sound print yet — run Fingerprint Sound." |
| stamp `noAudio` / measured silence | "No sound to match. Picture matching comes with the picture timeline (Phase B)." |
| stamp with < 20 landmarks | "Too little sound to match (N landmarks; 20 needed)." |
| print made by another recipe | "Its sound print is from an older recipe — re-run Fingerprint Sound." |

**The job.** `canPause = true` (a gate checked between sidecar pages and between queries); Stop cancels at the same
points. Progress: "Reading sound prints — page N of M", then "Searching i of n". Off-main work runs in one detached
task (C++: a worker thread); results hop to the main actor per query. If the sidecar cannot be opened the job ends
before reading, with the store's refusal words.

Log lines (one sink, `fileOpsLog` + `videoscan.log` + `catalog.log`):

```
START find master — 3 files; sound index from audio-fingerprints.sqlite
find master: sound index — 3,576 contents, 24.9 M landmarks, 4.1 s (skipped: 0 sampled-hash keys, 0 older recipe, 1,772 too little sound, 0 unreadable)
find master: Clip 03.dv sha256:a7010c01… → no content shares its sound (searched 3,575 sounded contents; 1,014 have no sound track; 122 not fingerprinted)
find master: Montana-2.mkv sha256:… → inside Montana-1.mkv sha256:… 00:12:40–00:13:20 (offset 760.2 s, coverage 0.93, 412 landmarks, sound, recipe 0x…)
OUTCOME find master — 3 searched · 1 found inside another · 0 same recording · 1 none found · 1 refused (no sound print) · 4.6 s
```

### Phase A tests (names, what each asserts)

Core, `VideoScanCore/Tests/VideoScanCoreTests/` (Swift Testing):

| Test | Dimension | Asserts |
|---|---|---|
| `AudioCatalogIndexTests.buildCountsEveryLandmarkOnce` | logic | postings total = Σ landmarks of indexed docs; each (doc, frame) reachable from its hash |
| `AudioCatalogIndexTests.sampledKeysAndOtherRecipesAreCountedNotIndexed` | truth | `v1:` keys and foreign recipes appear in the report counts and in no posting |
| `AudioCatalogIndexTests.unreadableBlobIsCountedAndBuildContinues` | isolation | one poisoned blob → `unreadable == 1`, key listed, all others indexed |
| `AudioCatalogIndexTests.hashBeyond24BitsRefusesThatPrintOnly` | isolation | crafted print with an out-of-range hash → counted unreadable |
| `AudioCatalogIndexTests.poisonedOrNewerSidecarRefusesBeforeBuild` | isolation | not-a-DB and schema+1 files throw the store's named failure; no partial index |
| `AudioCatalogIndexTests.buildRefusesOverPostingCap` | isolation | a cap of 1,000 with 1,001 landmarks → refusal with the MB figure |
| `AudioCatalogIndexTests.pagingDoesNotHoldTheLockAcrossPages` | isolation | a `put` from another task completes while a build is mid-iteration |
| `AudioCatalogIndexScaleTests.twentyFiveMillionLandmarks` (`.scale`) | scale | 5,000 synthetic prints, 25 M landmarks: build < 15 s, resident growth < 400 MB on the fleet; 1,000 queries < 60 s total |
| `AudioMasterFinderTests.clipIsFoundInsideItsMaster` | logic | 40 s cut at 312.4 s → `.containedInMaster`, |offset − 312.4| ≤ 0.1 s |
| `AudioMasterFinderTests.reencodeIsSameRecording` | logic | AAC 64k of the master → `.sameRecording` |
| `AudioMasterFinderTests.masterQueryListsItsClips` | logic | master as query → its clips as `.masterContainedInQuery` |
| `AudioMasterFinderTests.verdictIsExactlyThePairMatchers` | one engine | for every candidate, the finder's `AudioMatch` == `AudioFingerprintMatcher.match(query:master:)` |
| `AudioMasterFinderTests.ownDigestIsNeverACandidate` | logic | a query that is in the index never matches itself |
| `AudioMasterFinderTests.unrelatedQueryReportsWhatWasSearched` | truth | `.noneFound(searched: N − 1)` — never `.found([])` |
| `AudioMasterFinderTests.tooLittleSoundIsRefusedNotNoneFound` | truth | 12-landmark query → `.refused(.tooLittleSound(12))` |
| `AudioMasterFinderTests.otherRecipeQueryIsRefused` | truth | `.refused(.otherRecipe)` |
| `AudioMasterFinderTests.catalogWideHumIsCappedAndClipStillFound` | isolation | a hash present in every doc (> cap) is skipped; the true master still ranks first |
| `AudioMasterFinderTests.rankingOrder` | logic | same › contained › contains › overlap › inconclusive; ties by coverage |
| `AudioMasterFinderAcceptanceTests` (frozen before the code; slow lane, not sensors) | media matrix + logic | 30 synthetic masters (60–900 s, the existing `AudioFingerprintFixtures` renderer), 100 clips at seeded offsets, 3 qualities (AAC 64k / AAC 128k / PCM), 10 muted, wrapped as mp4/h264+aac, mov/prores+pcm, mkv/ffv1+pcm, mxf, avi/dv. **Bars:** recall ≥ 0.95 on sounded clips ≥ 10 s; zero false containers; |offset error| ≤ 0.1 s; muted clips are refused, never "none found". Numbers printed; bars never loosened to go green. |

App, `VideoScanTests/`:

| Test | Dimension | Asserts |
|---|---|---|
| `FindMasterPlanTests.eachRefusalReason` | logic/truth | the five refusal rows above, one record each, correct reason |
| `FindMasterPlanTests.hundredThousandRecordSnapshot` | scale | plan + label map for 100k records < 1 s |
| `FindMasterAnswerTests.sentenceCarriesItsEvidence` | truth | every positive sentence contains verdict, time span, offset, coverage, landmark count and "sound" |
| `FindMasterAnswerTests.neverClaimsDirection` | truth | no sentence says a file *is* "the master" or "original"; it says "inside", "contains", "same recording", "shares" |
| `FindMasterAnswerTests.negativeSaysWhatWasSearched` | truth | "none" sentences carry searched / no-sound-track / not-fingerprinted counts |
| `FindMasterJobTests.startAndOutcomeOnceWithCounts` | logic | exactly one START and one OUTCOME; OUTCOME counts sum to the selection |
| `FindMasterJobTests.stopMidRunSaysStopped` | logic | Stop after query 1 of 3 → OUTCOME "stopped", 1 searched, 2 not started |
| `FindMasterJobTests.pauseHoldsBetweenQueries` | logic | paused job does not start query 2 until resumed |
| `FindMasterJobTests.unopenableSidecarRefusesBeforeReading` | isolation | read-only folder / poisoned file → refusal words, zero queries run |
| `FindMasterJobTests.writesNothing` | isolation/integrity | catalog generation unchanged; sidecar file size, mtime and `-wal` unchanged after a run |
| `FindMasterSensorTests` (sensor lane) | sensor | `Provenance/FindMaster*.swift` contain no `commit(`, `saveCatalog`, `.put(`, `removeItem`, `trashItem`, `extension VideoScanModel`; no `AudioMatchVerdict` is constructed outside Core; `.findMaster` is a registered kind with a detail view; `tableContextMenu` contains the Provenance menu |

Rule 8's catalog-writer dimension (debounce, write hold, role flip, relaunch) does not apply: Phase A writes nothing.
Not data-risk code (rule 10) — no Codex pass required; a scoped pass is cheap and welcome.

### Phase A cost

From the live numbers (25.1 M landmarks, 209 MB of blobs) and the matcher's measured footprint: index build ≈ 4–8 s
on the M4 Max (two sequential reads of 209 MB + counting sort; measure in the scale test), ≈ 268 MB resident while the
job runs, freed at the end. A query: stage 1 milliseconds; stage 2 ≤ 10 pair matches at ≈ 10–50 ms each for hour-long
candidates → **under a second per selected file**. M5 Ultra: same (memory-bound and single-threaded per query). The
index is rebuilt per run; cache it in a store only if Rick finds the 5 s wait annoying.

## Phase B — Picture timeline v2 (silent footage, and a second proof)

**Builds.** `PictureTimeline` (Core): per second one 256-bit PDQ-class hash (64×64 luminance by area filter → 16×16
DCT via Accelerate `vDSP` → median threshold) plus a 0–100 quality score (gradient energy; ≤ 49 = black/flat/fade,
excluded from votes). Normalisation decided per file before hashing: black-bar crop from a 20-frame `cropdetect`
sample; for interlaced analog sources (≤ 576 lines, `idet` says interlaced) one field and the bottom 10 % excluded
(camcorder stamps, deck OSD). The recipe id covers every knob. `PictureTimelineMatcher` (Core): the audio matcher's
algorithm on picture — offset vote in 1 s bins (Hamming ≤ 31 = a hit), coverage over usable seconds, longest run,
the v1 coincidence bound kept, the same decision table shape (`PictureMatchPolicy`) and the same verdict enum
cases. Candidate search is a linear SIMD scan (1.6 M hashes for the archive ≈ 52 MB; 256-bit popcount is 4
instructions) — multi-index hashing only if a measurement says so.

**One engine.** "Fingerprint Pictures…" (the existing MFO job) is re-pointed at v2: same lanes per volume, same
checkpoints, sidecar first then the `picture_prints` stamp; order FamilyArchive (ruling 2), then LaCieWorkspace, then
the rest. Find Master gains picture: the finder runs both and reports proof `sound`, `picture` or `both` (offsets
agree within 1 s). Disagreeing offsets → "inconclusive: sound and picture disagree", never a pick.

**Schema.** `picture_prints` ("Data model ▸ Designed, not built") — its own migration, needs approval.

**Cost (derived; B0 measures three files per codec family before promising).** Decode dominates; the hash is
microseconds per frame. At 30 fps an hour is 108k decoded frames:

| Codec (live hours) | Decoder | Est. M4 Max, minutes per hour of footage | M5 Ultra |
|---|---|---|---|
| hevc (57.8 h), h264 (50.4 h) | VideoToolbox | 2–3 | ≈ 1–2 (two media engines) |
| prores (65.7 h) | ffmpeg, multi-thread | 2.5–4.5 | ≈ 1.5–3 |
| dvvideo (120.7 h) | ffmpeg | 0.6–1.2 (read-bound on HDD ≈ 1.5) | same |
| mjpeg (43.1 h), dnxhd (23.7 h) | ffmpeg | 2–3.5 | ≈ 1.5–2.5 |
| ffv1 1280×720 (67.8 h) | ffmpeg, slice threads | 6–12 | ≈ 4–8 |

First run, FamilyArchive (164.7 h: hevc 46, ffv1 45, prores 33, dv 24, h264 10): ≈ 9–12 h on one lane on the M4 Max —
one overnight, on the fleet in Rick's away window. LaCieWorkspace (137 h) a second night. Sidecar ≈ 33 B per second ≈
55 MB for the archive.

**Tests.** Logic: the A corpus plus letterboxed (4:3 in 16:9), stretched, date-stamped strip, interlaced, fades, and
**static-scene negatives** (two different synthetic "living rooms" with the same background and different motion —
the Christmas-morning false positive; must stay `.different` with the coincidence bound reported). Scale: 1.6 M-hash
linear scan for a 60 s query < 0.5 s; 100k-row plan < 1 s. Media matrix: the five containers × the codecs above,
measured decode throughput printed per family. Isolation: poisoned picture sidecar; a file that decodes 0 frames is
listed, not stamped; a drive that leaves mid-lane. Sensor: the job writes sidecar before stamp; v1 rows untouched.
Truth: a `noPicture` stamp only from a measured decode; quality-≤ 49 seconds never count as evidence.

## Phase C — Evidence, the Provenance sheet, and the archive copy

Three shippable slices; C2 and C3 are the 10/22 design's phases 1 and 2.

**C1. Excerpt evidence (`content_excerpts`, its own migration).** Job: **"Find Masters for All…"** (Catalog menu) —
runs the A/B finder for every sounded or pictured content, archived first, and appends one `content_excerpts` row per
non-`different` verdict through `CatalogCommitter` (checkpoint every 100 contents; Stop finishes the current one).
Re-runs insert-or-ignore on the unique key, so they are idempotent. Cost: the A index once (5 s) + ≤ 1 s per
content ≈ **1–1.5 h** for 5,000 contents; with picture, add the scan (minutes). Tests: rule-8 writer set — an excerpt
insert inside the debounce window, during a write hold, across a role flip, then relaunch: every row present exactly
once; the no-update/no-delete triggers seen to refuse; 100k-content plan; the Clip 03 worked example (10/23 §4) as a
truth test: it must find only its byte copies, nothing else.

**C2. Assertions, drafts and the Provenance sheet (`provenance_assertions` shipped in v14; the carrier tables in a later migration).** `ProvenanceStore` (feature store, #337),
`ProvenanceResolver` (pure display rule), `ProvenanceDraftJob` (MFO: writes `inferred` assertions from the 10/23 §4
rules — July folder + encoder + birth date, born-digital make/model, `YYYY-MM-DD_HH-MM-SS` names, excerpts from C1 as
`excerptOf` with the excerpt's numbers as evidence). The sheet, Triage ▸ **Needs provenance** filter, grouped by
proposed tape, Confirm tape → typed rows + `confirmed` assertions + ledger `provenanceConfirmed` in one commit. Rick
owns the sheet's look; this proposes the 10/23 §2 conventions (inferred grey italic with evidence one click away,
confirmed normal, corrected ✎, rejected behind "ruled out"). Tests: the veto — reject "Hi8" → re-run the draft job →
the trigger ignores it, the job logs "vetoed", the sheet never shows it (truth); confirm, correct, reject each
survives relaunch; an assertion row shows its evidence and confidence (truth); writer set as C1; 100k assertions
resolve < 1 s.

**C2, first slice built 2026-11-10 (DECISIONS 2026-11-10, "estimated provenance is shown as PROVISIONAL").** One rule
(`vhsCapture2026`: original path under `Converted_VHS_Tapes_2026`, FFV1 in Matroska, ≥ 20 min; within a source folder
files are related by NAME first — equal lowercased stems, or one continuing the other at a separator (whole tokens:
`tape_1` / `tape_10` are not related) — then duration: unrelated → its own
tape, a master; related and within 1 % → one tape, one master, the rest alternate captures; related to a clearly
longer file → left unclassified, it may be a trim)
writes `inferred` `role` / `carrier` rows, and `captureSetup` only when the file's own embedded creation date is in
2026. What stands is the NEWEST machine row per field (never an older one after a reject); a run withdraws an
estimate it no longer makes with an inferred `role` = `unknown` row; Confirm is a compare-and-swap on what was shown;
Rick's Set Role wins on every surface, and Unknown after a Confirm makes it provisional again (review 2026-11-10). Core `Provenance/ProvenanceResolver.swift` (the rule, what
stands, the words); app `Provenance/ProvenanceEstimateStore.swift` (Estimate, Confirm, Not Right),
`ProvenanceEstimateJob.swift` (MFO), `ProvenanceEstimateMark.swift` (the Archive glyph, the row menu, the Inspector
line). Differences from the text above: the store is `ProvenanceEstimateStore` and the job `ProvenanceEstimateJob`;
`ProvenanceResolver` also holds the rule, not only the display reduction; no sheet and no Triage filter (the Archive
row menu confirms a selection); no typed carrier tables and no ledger `provenanceConfirmed` event (Confirm writes
`confirmed` assertions and the `provenance_roles` row in one commit); no date or name field is asserted (the door
refuses `tapeYear` / `digitizedOn` on archived content — the capture month is read at display time from the embedded
creation date, the tape year from the year folder the archive filed the copy under, omitted when that is only the
capture's own year); an alternate capture names its master by the archive's file name, and not at all once the
master's estimate no longer stands;
evidence is shown, confidence never is (2026-11-01 ruling, over "shows its evidence and confidence" above). Not
built: the born-digital, name-pattern and `excerptOf` rules.

**C3. Promote gate + travelling copy.** Promote requires role and carrier-or-born-digital; "Archive with provenance
unknown" override with a reason, logged (the un-probeable override's pattern). `Provenance.csv`, `Carriers.csv`,
`Provenance_README.txt` regenerated whole (temp + rename) under `ArchiveIndexLock`. Only *confirmed* relations reach
the CSV. **Data-risk (rule 10): `Archive/` writer → safety-critical skill + scoped Codex pass.** Tests: the gate
refuses and the override logs its reason; a crash between temp and rename leaves the old CSV whole; the v3 manifest
bytes are unchanged by any provenance action (sensor); a CSV row exists for every archived content and none for an
unconfirmed excerpt (truth).

## Phase D — The free lineages (deterministic, no model)

- **dvrescue** (MediaArea, BSD-3; add to `Brewfile`, verify the formula) per DV file → per-frame `rdt`
  (recorded date-time), `tc`, `rec_start`. Writes `inferred` assertions: `eventDate` ranges per stretch ("camera
  clock", confidence 0.7, drift warning), and `sameCarrier` between two files whose `rdt` ranges abut or overlap.
  937 DV rows + 322 DV-25 MXF, 120.7 h: ≈ 13 GB per hour read once → **≈ 3 h, read-bound** on the workspace HDDs.
- **Encoder chains**: `probe_extra` signatures (`Lavf61.7.100` + 1280×720p30 = the July setup) → `captureSetup`
  drafts; ffmpeg `idet` on progressive-flagged H.264 finds interlaced pixels → "later-generation re-encode of an analog
  transfer" as evidence (one cheap pass, minutes per hour).
- **Project files**: FCPXML `media-rep` paths and iMovie library event names → `inferred` `editOf` assertions;
  parse only, never admit (the #383 skip stays).

D needs C2's assertion table; it ships after C2. Tests: 30 DV masters, `rdt` dates against the 18 known capture
dates (aggregate in repo); a synthetic FCPXML with three assets; dvrescue missing → refused with the Homebrew line.

## Phase E — VLM era guess (research gate, ruling 4)

The 10/25 §5 benchmark, run locally on Qwen2.5-VL-3B (M4 Max) and Qwen3-VL-32B 4-bit (M5 Ultra, only if `MLXVLM`
video input is verified): 200 clips with a trusted date, stratified by era. Per-clip results in `.scratch/`; the repo
gets MAE and the fraction within ±5 years per decade. The `era` claim kind ships (confidence ≤ 0.3, ±7 years, ranked
below folder year, never on an archived row, never over a human) **only if MAE < 7 years on the VHS and DV strata.**
Otherwise E ends as a research note. Cost: 200 × 3 frames at ≈ 1–3 s each ≈ 10–30 min.

## Phase F — CLIP event suggestions: **cut**

No published evaluation shows CLIP clustering finds home-video *events*, Events v1 already clusters by folder, date and
words, and the 18 confirmed events are too few to tune on. It earns no keep here. Proposed as one BACKLOG line (not added by this commit); revisit
only if Events leaves a measured gap. SSCD-style copy descriptors are cut for the same reason until B leaves a
measured residue of crops and overlays.

## Failure modes — refused, not guessed

| Situation | What happens |
|---|---|
| Query has no SHA-256, no print, no sound, too few landmarks, other recipe | Refused before search, with the reason (A table). Never "no master found". |
| Sidecar missing, unwritable, poisoned, newer, missing `-wal` | Job refuses before reading, store's words; `-wal` restored only per #386; nothing deleted (#387) |
| A sidecar row will not decode | Counted and listed; build continues |
| Candidate print is incomplete (4 h decoder cap) | The matcher's completeness rules: can be "contains", never "same"; shown as such |
| Sound says one offset, picture another | "Inconclusive — sound and picture disagree", both numbers shown |
| Static scene / silence | Silence is evidence for nothing; low-quality frames excluded; coincidence bound printed |
| Containment found | Geometry only. Which file is the better or original transfer is Rick's decision, aided by Compare Media's stated criteria; supersession needs proof + criterion + confirmation (2026-10-23) |
| A machine re-proposes a rejected value | The trigger ignores the insert; the job logs "vetoed" |
| A candidate has no live copy | Shown with its removal state ("In the Trash", "Missing"); never hidden, never offered as a keeper |
| Index would exceed its cap | Refused with the MB figure |
| dvrescue / ffmpeg missing | Refused with the Homebrew command |

## Out of scope

Cloud models of any kind for family media (rule 13). Writing tags into archived files. Manifest v4. Rewriting
`lineage`. Auto-confirming anything, auto-superseding anything, auto-deleting anything. Film-cadence analysis
(ruling 1, until Rick locates the scans). Capture-time tooling (10/22 phase 3: vrecord-style capture, viewing proxies)
— unchanged, later. PRNU and C2PA (10/25 §7: not worth it here). A persistent sound index.

## Risks

| Risk | Mitigation |
|---|---|
| Users read "Find Master" as "this is the original" | Wording never claims direction (truth test); the menu name is Rick's to change |
| Stage-1 cap/subsample drops a true master | Acceptance recall bar ≥ 0.95, hum test; candidates are then verified by the unchanged matcher, so precision cannot drop |
| 1,772 fingerprinted digests have < 20 landmarks; 1,014 have no sound | Phase B exists for them; the A answer says so |
| 6,179 stamps are engine v2; if any recipe differs they are "not comparable" | The build report counts them on the first run; re-run Fingerprint Sound on those only |
| FFV1 decode slower than estimated | B0 measurement before the overnight; one lane per drive regardless |
| Static-scene false positives in picture | Coincidence bound, quality filter, sound tie-break, explicit negative fixtures |
| Charter §2.2 wants a provenance gate at **ingest**; 10/22 put it at **Promote** | Open Charter question on STATUS; C2/C3 use one `ProvenanceGate.isComplete` so either place calls the same check |
| A later provenance migration rejected or reshaped | A ships without one; B and C each wait on their own approval |
| Sidecars not in backups | Check the backup job in B; issue if missing |

# Part II — Provenance, lightweight (2026-10-22): archived

The 10/22 draft (records, workflow, backfill, logging, its questions) is archived whole at `docs/archive/design/provenance_lightweight_2026_10_22.md`. Part I §"Where this supersedes the 10/22 lightweight design" lists what changed; everything else in it (Ingest → Identify → Confirm → Archive, the logging lines, born-digital has no tape, confirm per tape) stands and is Phase C.

# Part III — The research it rests on

*Both studies moved to `docs/archive/research/` on 2026-11-01 (CLAUDE.md: research lives in `.scratch/`); the designs above took what is still true.*

- **Provenance deep dive (2026-10-23)** — `docs/archive/research/provenance_deep_dive_2026-10-23.md`. A read-only review of the 10/22 draft against the code and a catalog backup, under Rick's four lenses. Its findings, in its own summary: the draft's shape is right; add `capture_setups` (one device chain, many tapes) and move shelf number, generation, videographer and tape year onto the carrier so Rick answers each once per tape; the draft's "FFV1 · 720×480 · 29.97 → VHS" rule matches zero July files (every July capture is 1280×720, 30 fps, `Lavf61.7.100`), so the July batch is inferred from folder + encoder + birth date; the travelling copy is `00_Index/Provenance.csv` + `Carriers.csv`, regenerated like the ledger mirror, never a rewritten v3 manifest; every field carries its state with a veto trigger; ≈ 60 minutes of Rick's time for the 142 Masters and the July batch when the app drafts per tape.
- **Retroactive provenance and video fingerprinting (2026-10-25)** — `docs/archive/research/provenance_retroactive_fingerprinting_2026-10-25.md`. The answer to an outside agent spec and blueprint: two-thirds of that pipeline already existed (the 32-frame picture prints, the Compare Footage aligner, the bundled VLM captioner with its OCR date candidates, the audio landmark matcher stamped on most live video rows); what was missing was small — a fixed-rate picture *timeline* so a cut clip can slide against its master, and the evidence table. It proposed phases A–F; Part I is the design that followed (F, CLIP event suggestions, cut).
