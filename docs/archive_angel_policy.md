# Archive Angel recommendation policy (schema 2)

Rick 2026-09-22: *"the AA selection criteria should be easily programmable so we can add/delete/change the criteria as needed… not hard coded, a user should be able to… guide the app on how it recommends."*

Every criterion the Archive Angel uses to recommend a file is **data** in one JSON rule set. You can change a number, switch a rule off, or add a rule of your own, without touching Swift.

## Where it lives

| Source | Path | Notes |
|---|---|---|
| Your override | `~/Library/Application Support/VideoScan/archive-angel/policy.json` | Optional. The app never creates it. |
| Bundled default | `ArchiveAngelPolicy.default.json` (in the app) | Byte-identical to the compiled-in rules (a test pins it). Copy entries from it as a starting point. |
| Compiled-in | `AngelRecommendationPolicy.builtIn` | Used if both files are unusable. |

The file is read once, when the app starts — off the main thread, so a bad file can never freeze the app. It must be a regular file (a symlink to one is fine) of at most 1,000,000 bytes; the app never reads more than that. Until it has loaded (a few milliseconds), assessment waits and Prepare asks you to try again. **Quit and relaunch after editing it.**

**Refused, never half-read.** If your file cannot be read or parsed, or anything in it is unknown (a kind, a field, an operator, a value of the wrong type, a choice that isn't one of the field's values, a number out of range, a bad stem pattern), the whole file is refused. The console and `videoscan.log` name every problem, and the bundled default runs instead. A key the app doesn't read (a typo like `"pionts"`) doesn't refuse the file; it is named in a notice.

**When the rules change, everything is re-scored.** The evidence sidecar is stamped with the policy's fingerprint. A different policy means a full re-score at the next sweep, which takes a few seconds.

## Your file holds only what you change

Your file is **merged over the built-in rules**:

- Objects (`weights`, `grades`, `tables`, `recommend`, `recommend.date`, `recommend.copies`) merge key by key.
- Rule lists (`floors`, `signals`, `recommend.exclude`, `recommend.vouch`) merge **by `id`**:
  - an entry with a built-in rule's `id` edits that rule in place (`{"id": "recentPhoneClip", "enabled": false}` switches it off);
  - an entry with a new `id` adds a rule. A new **signal** goes just before the `downloadCap` / `fatigue` adjusters. Anything else goes at the end.
- Everything else (`recommend.classes`, `tables.originality`, single values) replaces the default.

`"schemaVersion": 2` is required, as an integer (`true`, `2.0` and `"2"` are refused). A schema-1 file (just `weights`) is still accepted: its weights are used with today's default rules, and a notice says so.

So the smallest useful file is:

```json
{ "schemaVersion": 2, "name": "longer clips only", "weights": { "minimumDurationSeconds": 300 } }
```

## How a recommendation is made

1. **Floors** (`floors`) are checked in order. The first one that fires excludes the file, and its reason is the one you see.
2. **Signals** (`signals`) each add one printed evidence line. The score is the sum of the lines.
3. **Grades** (`grades`) turn the score into a letter: A ≥ `a`, B ≥ `b`, C ≥ `c`, D ≥ `d`, otherwise X.
4. **Classes** (`recommend`) put every file into exactly one class. These classes are the only numbers the app shows: the Angel strip's "N ready · M need a date · K prepared", the catalog's badge, and Show ▸ Archive Candidates.

| Class | Default rule |
|---|---|
| **Worth a look** (`absurdBitrate`, rules v12) | Would be recommended (vouched, or grade A/B) but averages 1 Gbit/s or more — a broken encode (a 43 GB file for 37 s) until you have looked. Reason: "Unusually large for its length — check it before archiving" |
| **Needs a date** (`recentDigitization`, rules v12) | Would be Ready, but the machine's date is within the last year, no camera or phone is named in the tags, no date of yours, and the codec is a digitizer's or an editor's (FFV1, ProRes, DV, MPEG-2, MJPEG) — a tape converted this year, dated by its conversion. Reason: "Dated 2026, but it looks like a digitization of older footage — confirm when it was filmed". A year you type ends it |
| **Ready** | Passes the floors, AND (someone vouched: Important, ★★ or more, stage Ready/Master, OR grade A), AND dated to at least a year |
| **Needs a date** | Same as Ready, but not dated |
| **Worth a look** | Grade B, nobody vouched |
| **Not now** | Grade C/D, or nothing recommends it |
| **Excluded** | A floor fired (including the default `extraCopy` floor: a copy you marked Extra copy — switchable, not a safety floor), or an `exclude` rule matched |
| **Another copy** | The same recording as a recommended copy (same footage group from Find Similar Footage, same duplicate group, or same name + length). The copy you marked Keep wins; then, in a footage group, its likely original; otherwise the best-ranked copy does. |
| **Prepared** | Sitting in a prepared batch, waiting for your review |

archiveStage Ready/Master is a **vote** to archive. Only a real Master Archive copy (`onMasterArchive`, `archivedCopy`) means "already archived".

## Safety floors — these cannot be turned off, by design

Six floors guard against recommending a file the archive must never receive twice or cannot receive at all (the delete-safety principle: refuse over guess):

| Floor | Excludes |
|---|---|
| `notVideo` | audio-only files, stills, un-probed files |
| `onMasterArchive` | a file in the Master Archive, or one that already has its copy there |
| `angelWorkingCopy` | a companion Archive Angel prepared in its own buffer (`~/Movies/VideoScan Buffer/ArchiveAngel`) — never material of its own (rules v12) |
| `archivedCopy` | a file whose content (or original) is already archived — including the other members of a **footage group** (Find Similar Footage, Likely or stronger) whose likely original is archived (rules v12) |
| `fileGone` | a record Relocate marked Manually Deleted or Salvage Failed |
| `volumeOffline` | a file on a volume that isn't mounted |

A `policy.json` that disables one of these, narrows it with `when`, sets `starExempt`, sets `explicitPicks: false`, or changes its kind or reason is **refused whole**. The log names the safety floor, and the bundled default runs. `recommend.useAngelFloors: false` still honours them. You may change their `note` and `line`.

**The safety floors are their own pass** (codex #1643). The reason a file shows is the *first* floor that fires in policy order — so an offline 30-second tape reads "Too short", the lasting reason, not "Volume offline". But every file is also checked against the six safety floors separately, and that result is stored on its own. The classes exclude a file on any safety hit, whichever floor fired first and whatever `useAngelFloors` says.

Separately from the floors, the recommendation counts are re-checked against the live catalog about half a second after any catalog change. A record that has been purged, set aside or superseded, or that Promote would refuse (already promoted, an archive copy), stops being counted, listed or badged immediately. It doesn't wait for the next sweep. The counts, the catalog filter, the row badge, the record's class and Prepare all read **one** effective class — the stored class, then the prepared/promoted batches, then this live check — so a badge can never say "Promote me" for a file the counts left out.

Prepare also looks at copies live. If you mark a different copy **Keep** after the last assessment (A was Ready, B was Another copy, you mark B Keep), Prepare re-decides that recording's copies from the current catalog and prepares B — it doesn't wait for the next sweep.

## Rules

A rule is an object. Only `id` and `kind` are required.

| Key | Default | Meaning |
|---|---|---|
| `id` | — | Unique in its list; how an override refers to the rule |
| `kind` | — | What the rule does (tables below) |
| `enabled` | `true` | `false` switches the rule off |
| `when` | `[]` | Conditions, all of which must hold. Required for `match`. On a built-in kind, it narrows the rule to the files it names. |
| `points` | `0` | `match` signal: points (−10000…10000). Vouch: points (a `stars` vouch gives this many per star). |
| `line` | `""` | The text shown: the evidence line, the vouch reason, or the exclusion reason |
| `note` | `""` | Free text for people: why the rule exists |
| `starExempt` | `false` | Floors only: a file with any star passes this floor |
| `explicitPicks` | `true` | Floors only: `false` means the floor applies to the Angel's own proposals, not to "Prepare with Archive Angel" on files you selected |
| `vouches` | `true` | Vouch rules only: `false` means a note, not a vouch (for example "the copy to keep") |
| `rejection` | none | `match` floors only: report a built-in reason by name (`"tooShort"`, `"alreadyArchived"`…). If omitted, the reason is "Excluded by a rule in your recommendation policy" followed by the rule's `line`. |

### Floor kinds (`floors`)

`match`, `notVideo`, `onMasterArchive`, `angelWorkingCopy`, `archivedCopy`, `notPlayable`, `pairedHalf`, `livePhotoMotion`, `recentPhoneClip` (`weights.recentPhoneClipYears`), `appCache` (`tables`), `derivativeOfOriginal`, `tooShort` (`weights.minimumDurationSeconds`; explicit picks use `explicitPickMinimumDurationSeconds`), `proxyStream` (`weights.minimumAverageKilobitsPerSecond`), `markedJunk`, `suspectedJunk`, `junkScore` (`weights.junkFloor`), `volumeOffline`, `resting` (the attention memory).

### Signal kinds (`signals`)

`match`, `stars`, `confirmedPeople`, `machinePeople`, `playHistory` (`playHistoryPerDoubling` × log2(1+plays), capped, plus the recent-play bonus inside `playedRecentlyDays`), `richness`, `date`, `duration` (the tape tiers), `formatAtRisk`, `onlyCopy`, `unassignedVolume`, `audioProblem`, `downloadCap`, `fatigue`.

`downloadCap` and `fatigue` act on the total of the lines above them, so keep them last.

### Vouch and exclude kinds (`recommend.vouch`, `recommend.exclude`)

- Vouch rules can use `match` or `stars`.
- Exclude rules can use `match` only.

## Conditions

A condition is `{ "field": …, "op": …, "value": … }`. To say "any of these", write `{ "any": [ condition, … ] }`. All the conditions in a `when` list must hold. Text is compared case-insensitively. A number the file doesn't have (for example `year` on an undated file) never matches.

| Type | Fields | Operators | Value |
|---|---|---|---|
| text | `filename` `path` `videoCodec` `deviceModel` `volumeName` | `==` `!=` `contains` `notContains` `hasPrefix` `hasSuffix` · `in` `notIn` | a string · a list of strings |
| number | `durationSeconds` `durationMinutes` `sizeMB` `averageKbps` `starRating` `junkScore` `tagCount` `useCount` `peopleCount` `year` (yours, else the inferred date) `captureYear` (camera/phone stamp) `yearsAgo` (this year minus the year the one date rule places the file under — the year Promote would file it by; unknown when undated, so it never matches) `duplicateGroupCount` | `==` `!=` `<` `<=` `>` `>=` | a number |
| names | `people` (confirmed) `machinePeople` (detected + suspected) | `contains` `notContains` · `in` `notIn` | a string · a list |
| choice | `mediaDisposition` (unreviewed, important, recoverable, suspectedJunk, confirmedJunk) · `archiveStage` (none, healthy, masterAssigned, backedUp, readyForArchive, archived, manuallyDeleted, salvageFailed) · `duplicateDisposition` (none, keep, review, extraCopy) · `volumeRole` (unassigned, system, workspace, backup, cloud, archive) | `==` `!=` `in` `notIn` | a case name, or the label the app shows ("Suspected Junk") |
| true/false | `isPhoneClip` `isLivePhotoMotion` `isHumanMarked` `hasUserNotes` `formatAtRisk` `isOnlyCopy` `isPairedHalf` `volumeOnline` `isOnMasterArchive` `hasArchivedDuplicate` `hasDuplicateGroup` `hasUserDate` `hasCaptions` `hasOCRText` | `==` `!=` | `true` / `false` |
| class rules only | `grade` (A–X) · `eligible` · `vouched` · `dated` · `vouchPoints` | as above | |

## `recommend`

| Key | Default | Meaning |
|---|---|---|
| `useAngelFloors` | `true` | A floor exclusion (grade X) makes the file Excluded |
| `exclude` | Extra copy | Exclusions that only apply to the classes |
| `vouch` | Important 3 · ★★+ 1 per star · stage Ready 2 · stage Master 1 · Keep (a note) | Who vouched, and how strongly |
| `date.minimum` | `"year"` | `day` / `month` / `year` / `decade`, or `readinessKnown`, which asks Promote's own date check (ArchiveReadiness) |
| `classes` | absurdBitrate, recentDigitization, Ready, Needs a date, Worth a look (see above) | Ordered. The first match wins; no match means Not now. A class rule may carry a `line` — the reason a person reads when that rule assigns the class; `{year}` in it is replaced by the date rule's year. |
| `copies.collapseBy` | `footageGroup`, `duplicateGroup`, `nameAndDuration` | How copies of one recording are recognised. `footageGroup` = the group **Find Similar Footage** recorded (copies, re-encodes, transcodes, exports of one recording); `sharedDuplicateGroup` = only duplicate groups of two or more |
| `copies.prefer` | `userKeeper`, `footageOriginal`, `best` | Which copy stays. `footageOriginal` = the footage group's likely original (the lowest rank Find Similar Footage gave) |
| `order` | `angelRank` | The order of the lists: `angelRank` (score, then most original) or `vouchPoints` (the old nudge's order) |
| `prepare` | `["ready", "worthALook"]` | The classes Prepare Batch takes, in this order: class first, then score. Add `"needsDate"` to opt in to undated keepers. Within a duplicate group, the copy you marked Keep is prepared. |

### One recommendation per footage group (Find Similar Footage, 2026-09-23)

When **Find Similar Footage** has run, every file it grouped carries its footage group and its rank in it (0 = the likely original). With the defaults above:

- only groups Find Similar Footage rated **Likely or stronger** collapse; a Possible group is shown to you, never decided for you;
- keys are merged: a file in a footage group AND a duplicate group joins both, so a byte copy seen only through its duplicate group and its twin seen through the footage group are one recording (never two Ready rows, never both in a batch);
- the recommended lists, the counts, the catalog badge and Show ▸ Archive Candidates show **one** file per footage group — the copy you marked Keep, else the group's likely original, else the best-ranked — and the others become **Another copy** ("Same footage as X — that one is recommended");
- a prepared batch takes at most one member of a footage group (the same rule as a duplicate group).

**To turn it off**, list the collapse keys without it:

```json
{ "schemaVersion": 2, "name": "no footage groups",
  "recommend": { "copies": { "collapseBy": ["duplicateGroup", "nameAndDuration"],
                             "prefer": ["userKeeper", "best"] } } }
```

The groups are metadata guesses (Identical / You confirmed / Likely / Possible). Nothing about them lets the Angel archive, delete or date anything; they only decide which copy is *recommended*.

## `grades` and `tables`

- **`grades`**: `{a: 100, b: 60, c: 25, d: 1}`. They must rise.
- **`tables`**:
  - `originality` (codec → rank, 0 = most original; a tie-break only)
  - `originalityUnknown`
  - `deliveryCodecs` (used by the download cap)
  - `familyOriginFolders` (a leading `.` matches a suffix, like `.imovielibrary`)
  - `appCacheFolders` (rules v12 adds `personsearchresults`, Person Finder's output folder)
  - `appCacheStemNames`, `appCacheStemNumbered`, `appCacheStemGlobs` — what counts as an app's cache/render file by its **stem** (the filename without its extension). Compared case-insensitively, always against the whole stem:
    - `appCacheStemNames`: bare tool nouns (default `cache render proxy proxies preview thumb thumbnail temp tmp`). `Cache.mov` matches; `Cache Cod 1998.mov` does not.
    - `appCacheStemNumbered` (default `true`): a noun may carry a number — one optional separator (space, `_` or `-`) and then digits: `Cache-30`, `render_7`, `tmp12`.
    - `appCacheStemGlobs` (default `*_compilation_*` — Person Finder's `Donna_compilation_39_h264_720p…` exports, rules v12): extra patterns. Literal text, where `*` means "any characters": `render*` (starts with), `*_proxy` (ends with), `clip*final` (both), `*cache*` (contains). At most one `*`, or exactly two when they are the first and last character. A pattern of only `*` is refused (it would match every file). Up to 100 patterns and 500 names, each at most 100 characters.

    **There are no regular expressions in the policy** (codex #1643). A user-supplied pattern could freeze the app: one passed every check and then took more than 2 seconds on a 30-character name, and another hung the check itself. These stem rules are matched in time proportional to the name's length, whatever you write. The defaults match exactly what the old pattern `^(cache|render|proxy|proxies|preview|thumb|thumbnail|temp|tmp)([ _-]?\d+)?$` matched (a test pins this).

    An older file that still has `appCacheNamePattern`: if it is exactly the old default (copied from the bundled file), or a plain list like `^(Scratch|Render Temp)$`, it is read as the same rule and a notice asks you to rename the key. Anything else refuses the whole file, with the reason.
  - `maxOriginalsPerKey`

## Deliberately NOT in the policy

The policy says **what** to recommend, not how the machine paces itself. These stay in code and change only through code review, because they protect the Mac's memory and your attention:

- the sweep cadence (at launch, 1 minute after an edit, every 15 minutes, in slices of 500 records);
- evidence freshness (24 h);
- the fresh-slot scan budget (200);
- the attention memory's cap of 12 events per file;
- the buffer rules;
- Angel Checks' pacing (docs/archive_angel_wise_design.md §4): the top 20 recommendations are looked at, one Verify Audio at a time, only after 120 s without you touching the app (the Catalog's thumbnails and every Archive Angel button count as touching it) and while no other file operation of any kind is running, at most 12 checks started an hour and 200 started per launch (a skipped file — missing, already being verified — costs nothing), each file at most once per launch. A Prepare pressed while a check reads that same file waits for the check's verdict instead of being refused. The switch ("Check Sound in the Background", `archiveAngel.checksEnabled`) is a preference, not a policy rule;
- Keep footage groups current (§5): Find Similar Footage runs once after the first complete assessment of a launch when the last automatic run started more than a day ago (or never — the time is kept in `archiveAngel.footageLastAutoRunAt`), and again after a catalog change at most every 6 h (`archiveAngel.footageAutoEnabled`).

## Worked examples

Each example below is a complete `policy.json`. The test suite loads these exact texts (`AngelRecommendationPolicyTests`, "WORKED EXAMPLE 1–3").

### 1. Never recommend clips under 5 minutes

```json
{
  "schemaVersion": 2,
  "name": "Rick: nothing under 5 minutes",
  "floors": [
    { "id": "underFiveMinutes", "kind": "match",
      "when": [ { "field": "durationMinutes", "op": "<", "value": 5 } ],
      "line": "Under 5 minutes — usually a piece of a longer original",
      "explicitPicks": false }
  ]
}
```

- It applies to starred files too (no `starExempt`).
- A clip you select yourself and send with "Prepare with Archive Angel" still goes (`explicitPicks: false`).
- The one-number alternative is `"weights": { "minimumDurationSeconds": 300 }`. The difference: that raises the built-in `tooShort` floor and reports "Too short".

### 2. Boost anything with Donna

```json
{
  "schemaVersion": 2,
  "name": "Rick: Donna first",
  "signals": [
    { "id": "donna", "kind": "match",
      "when": [ { "any": [ { "field": "people", "op": "contains", "value": "Donna" },
                           { "field": "machinePeople", "op": "contains", "value": "Donna" } ] } ],
      "points": 40, "line": "Donna is in it" }
  ]
}
```

- The rule adds 40 points and prints "Donna is in it".
- It is placed before the download cap automatically.
- 40 points lifts a C (25–59) to a B, or a B to an A. To make her files Ready whatever their score, add a vouch rule instead, under `"recommend": {"vouch": [ … ]}`.

### 3. Ignore 2020s phone clips

```json
{
  "schemaVersion": 2,
  "name": "Rick: no 2020s phone clips",
  "floors": [
    { "id": "phone2020s", "kind": "match",
      "when": [ { "field": "isPhoneClip", "op": "==", "value": true },
                { "field": "captureYear", "op": ">=", "value": 2020 } ],
      "line": "A 2020s phone clip" }
  ]
}
```

The built-in `recentPhoneClip` floor already skips phone clips under 10 years old. It moves with the calendar, and it spares files you pick yourself. This rule is different in both ways:

- it is fixed to the 2020s;
- it applies to your own picks too.

A phone clip with no camera date has no `captureYear`, so this rule doesn't fire for it. The built-in rule treats such a clip as recent.

### More one-liners

- Switch off the phone-clip rule: `"floors": [ { "id": "recentPhoneClip", "enabled": false } ]`
- Restore the old "stage ≥ Master means already archived" behaviour (rules v10):
  ```json
  "floors": [ { "id": "stageMeansArchived", "kind": "match", "rejection": "alreadyArchived",
                "when": [ { "field": "archiveStage", "op": "in",
                            "value": ["masterAssigned", "backedUp", "readyForArchive", "archived", "manuallyDeleted", "salvageFailed"] } ] } ]
  ```
  This rule goes at the end of the floors, not second as in v10. The same files are excluded; only the reason shown for a few of them differs.
- Stop 1-star files from counting as vouched: they already don't (the `stars` vouch needs `starRating >= 2`). To lower the bar: `"recommend": { "vouch": [ { "id": "stars", "when": [ { "field": "starRating", "op": ">=", "value": 1 } ] } ] }`

## Checking what you changed

- At launch, the console says `Archive Angel: using your recommendation rules "<name>" from …`, or `refused … — <every problem>`.
- After each sweep, it logs `Archive Angel Assessment: done: A … · ready N · needs a date M · worth a look K · …`.
- On the first run after a rules-version change, it logs once: `recommendation rules v11 → v12 — before: … now: …`.

## Rules v12 (2026-09-25) — truthful readiness

Measured on the live catalog that morning and fixed as data (docs/archive_angel_wise_design.md §3): the `angelWorkingCopy` safety floor; a footage group's archived original excludes its other members (`archivedCopy`); the `absurdBitrate` and `recentDigitization` class rules and the `yearsAgo` field; `personsearchresults` and `*_compilation_*` in the app-cache tables. Outside the policy, in the ONE date rule (`RecordDateResolver`): a container stamp with no camera behind it (a transcoder's, or of unknown origin) loses to a filename year that disagrees by more than two years — `DickyDonnaDancing1992.mov` stamped 2026-04-03 by Apple ProRes 422 is filed under 1992 (low confidence), not 2026. Every v11 evidence file re-scores.
