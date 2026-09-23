# Archive Angel recommendation policy (schema 2)

Rick 2026-09-22: *"the AA selection criteria should be easily programmable so we can add/delete/change the criteria as needed… not hard coded, a user should be able to… guide the app on how it recommends."*

Every criterion the Archive Angel uses to recommend a file is **data** in one JSON rule set. You can change a number, switch a rule off, or add a rule of your own, without touching Swift.

## Where it lives

| Source | Path | Notes |
|---|---|---|
| Your override | `~/Library/Application Support/VideoScan/archive-angel/policy.json` | Optional. The app never creates it. |
| Bundled default | `ArchiveAngelPolicy.default.json` (in the app) | Byte-identical to the compiled-in rules (a test pins it). Copy entries from it as a starting point. |
| Compiled-in | `AngelRecommendationPolicy.builtIn` | Used if both files are unusable. |

The file is read once, when the app starts. **Quit and relaunch after editing it.**

**Refused, never half-read.** If your file cannot be read or parsed, or anything in it is unknown (a kind, a field, an operator, a value of the wrong type, a choice that isn't one of the field's values, a number out of range, a bad regular expression), the whole file is refused. The console and `videoscan.log` name every problem, and the bundled default runs instead. A key the app doesn't read (a typo like `"pionts"`) doesn't refuse the file; it is named in a notice.

**When the rules change, everything is re-scored.** The evidence sidecar is stamped with the policy's fingerprint. A different policy means a full re-score at the next sweep, which takes a few seconds.

## Your file holds only what you change

Your file is **merged over the built-in rules**:

- Objects (`weights`, `grades`, `tables`, `recommend`, `recommend.date`, `recommend.copies`) merge key by key.
- Rule lists (`floors`, `signals`, `recommend.exclude`, `recommend.vouch`) merge **by `id`**:
  - an entry with a built-in rule's `id` edits that rule in place (`{"id": "recentPhoneClip", "enabled": false}` switches it off);
  - an entry with a new `id` adds a rule. A new **signal** goes just before the `downloadCap` / `fatigue` adjusters. Anything else goes at the end.
- Everything else (`recommend.classes`, `tables.originality`, single values) replaces the default.

`"schemaVersion": 2` is required. A schema-1 file (just `weights`) is still accepted: its weights are used with today's default rules, and a notice says so.

So the smallest useful file is:

```json
{ "schemaVersion": 2, "name": "longer clips only", "weights": { "minimumDurationSeconds": 300 } }
```

## How a recommendation is made

1. **Floors** (`floors`) are checked in order. The first one that fires excludes the file, and its reason is the one you see.
2. **Signals** (`signals`) each add one printed evidence line. The score is the sum of the lines.
3. **Grades** (`grades`) turn the score into a letter: A ≥ `a`, B ≥ `b`, C ≥ `c`, D ≥ `d`, otherwise X.
4. **Classes** (`recommend`) put every file into exactly one class. These classes are the only numbers the app shows: the Archive tab's nudge sentence, the Angel strip's "N ready · M need a date · K prepared", the catalog's badge, and Show ▸ Archive Candidates.

| Class | Default rule |
|---|---|
| **Ready** | Passes the floors, AND (someone vouched: Important, ★★ or more, stage Ready/Master, OR grade A), AND dated to at least a year |
| **Needs a date** | Same as Ready, but not dated |
| **Worth a look** | Grade B, nobody vouched |
| **Not now** | Grade C/D, or nothing recommends it |
| **Excluded** | A floor fired, or an `exclude` rule matched (by default: marked an Extra copy) |
| **Another copy** | The same recording as a recommended copy (same duplicate group, or same name + length). The copy you marked Keep wins; otherwise the best-ranked copy does. |
| **Prepared** | Sitting in a prepared batch, waiting for your review |

archiveStage Ready/Master is a **vote** to archive. Only a real Master Archive copy (`onMasterArchive`, `archivedCopy`) means "already archived".

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

`match`, `notVideo`, `onMasterArchive`, `archivedCopy`, `notPlayable`, `pairedHalf`, `livePhotoMotion`, `recentPhoneClip` (`weights.recentPhoneClipYears`), `appCache` (`tables`), `derivativeOfOriginal`, `tooShort` (`weights.minimumDurationSeconds`; explicit picks use `explicitPickMinimumDurationSeconds`), `proxyStream` (`weights.minimumAverageKilobitsPerSecond`), `markedJunk`, `suspectedJunk`, `junkScore` (`weights.junkFloor`), `volumeOffline`, `resting` (the attention memory).

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
| number | `durationSeconds` `durationMinutes` `sizeMB` `averageKbps` `starRating` `junkScore` `tagCount` `useCount` `peopleCount` `year` (yours, else the inferred date) `captureYear` (camera/phone stamp) `duplicateGroupCount` | `==` `!=` `<` `<=` `>` `>=` | a number |
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
| `classes` | Ready, Needs a date, Worth a look (see above) | Ordered. The first match wins; no match means Not now. |
| `copies.collapseBy` | `duplicateGroup`, `nameAndDuration` | How copies of one recording are recognised (`sharedDuplicateGroup` = only groups of two or more) |
| `copies.prefer` | `userKeeper`, `best` | Which copy stays |
| `order` | `angelRank` | The order of the lists: `angelRank` (score, then most original) or `vouchPoints` (the old nudge's order) |

## `grades` and `tables`

- **`grades`**: `{a: 100, b: 60, c: 25, d: 1}`. They must rise.
- **`tables`**:
  - `originality` (codec → rank, 0 = most original; a tie-break only)
  - `originalityUnknown`
  - `deliveryCodecs` (used by the download cap)
  - `familyOriginFolders` (a leading `.` matches a suffix, like `.imovielibrary`)
  - `appCacheFolders`
  - `appCacheNamePattern` (a regular expression over the file stem)
  - `maxOriginalsPerKey`

## Deliberately NOT in the policy

The policy says **what** to recommend, not how the machine paces itself. These stay in code and change only through code review, because they protect the Mac's memory and your attention:

- the sweep cadence (at launch, 1 minute after an edit, every 15 minutes, in slices of 500 records);
- evidence freshness (24 h);
- the fresh-slot scan budget (200);
- the attention memory's cap of 12 events per file;
- the buffer rules.

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
- On the first run after a rules-version change, it logs once: `recommendation rules v10 → v11 — before: … now: …`.
