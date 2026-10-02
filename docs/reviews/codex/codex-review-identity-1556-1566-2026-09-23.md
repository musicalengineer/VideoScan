# Review of Hallie routing and family identity requests #1556–#1566

Reviewed by Codex QA on 2026-09-23. Current source pinned to
`e68fd7cef20488bd30f15cedce41c05ed6ca5b0c`; original corrections inspected at
`679741dadfe99ebfadf88e0049051e6066f8d090` (copula) and
`80287be071d556c010a06817900f5a585cd4c472` (identity redirection).
Request text came from the historical mailbox audit under
`~/Library/Logs/VideoScan/review_backlog_20260923/`.

This is a source review. No app, UI, test host, media operation, live archive
migration or remote operation was run. Historical test counts reported by
Claude are not represented as independent validation. Production source was
not edited.

## Per-request disposition

| Request | Disposition |
| --- | --- |
| #1556 | Copula correction approved within its narrow scope. Mixed kinship/media routing design question answered below; broader behavior remains unimplemented. |
| #1559 | Same copula verdict at the submitted commit and current pin. Transcript-render performance was not measured here; #1564 subsequently identifies the earlier regression claim as load-sensitive. |
| #1564 | Identity hardening reviewed. Three substantive consistency findings remain in current code, plus the migration recovery caveat below. No claim that the live migration was damaged. |
| #1565 | The original hidden-name-to-preferred-person correction is present and sound for fresh-cache `people(matching:)` queries. This does not close the broader identity consistency findings. |
| #1566 | Family/relationship ruling design question answered; graph-loading bypass inventory completed within app source. Known parent-family issue remains unresolved. |

## Findings

All line references below refer to the pinned current source.

### 1. MAJOR — Hide/Unhide does not invalidate Hallie's cached identity rulings

`VideoScan/VideoScan/FamilyAssetStore.swift:126–140` defines the cache key
without the identity-rulings file. Lines 202–211 construct that key and return
the existing entry before reloading rulings. The file is read only after a
cache miss, at lines 243–244.

`VideoScan/VideoScan/FamilyTreeLiveModel.swift:1934–1953` saves an updated ruling
and mutates its own graph. It invalidates `PersonPhotoCenter`, but not
`FamilyGraphSharedCache`.

**Trigger:** Hallie loads a tree, then Rick hides or unhides a record in the
Family Tree tab. Subsequent Hallie turns continue to use the previous ruling
until another cache dependency changes or the process restarts. Editing the
rulings file directly also leaves the existing cache valid.

**Correction:** Include a rulings revision in the cache's validity and propagate
successful identity changes coherently to all query views. A save should not
leave consumers disagreeing about the active ruling.

### 2. MAJOR — the shared cache returns two different identity views

`VideoScan/VideoScan/FamilyAssetStore.swift:238` constructs `outcome` with the
overlaid graph. Lines 239–269 then apply suppression and redirects to a separate
local `graph` value. Line 280 caches both the ruled `graph` and the earlier
unruled `outcome`.

`VideoScan/VideoScan/FamilyTreeLiveModel.swift:760–769` uses `shared.outcome` for
the installed tree while building its launch bundle from `shared.loaded`.
Lines 1152–1153 install `outcome.graph`; there is no corresponding application
of the identity decisions to that graph during installation. Hallie's normal
graph getter uses the ruled `loaded.graph`.

**Trigger:** Start with a valid duplicate/hide ruling already on disk and load
through the shared cache. The installed Family Tree graph lacks suppression
and redirects even though Hallie's graph and the launch-bundle graph carry
them. Separate sidebar filtering can hide rows, but it does not repair the
installed graph's query semantics.

`GedcomFamilyGraph` is a value type: roughly a copied C++ struct. Mutating the
local copy cannot update `outcome.graph`.

**Correction:** Construct the returned/cached outcome from the final ruled
graph, so the two API views and their downstream consumers agree. This
divergence was also present at the original `80287be0` correction.

### 3. MAJOR — identity suppression is bypassed by other query APIs

`VideoScan/VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph.swift:677–693`
applies suppression and preferred-person redirection to `people(matching:)`.
However, `people(withSurname:)` at lines 640–647 returns its index results
without either rule. `VideoScan/VideoScan/HallieSurnameRoster.swift:84–88`
passes those people directly into the roster.

`VideoScan/VideoScan/HallieLineageAnswer+Superlatives.swift:39–44` uses either
all raw graph people or the unfiltered surname results. A hidden erroneous
record can therefore reappear in a family roster or win an earliest-born or
longest-lived answer even when a name lookup correctly hides it.

Relationship queries have the same gap:
`GedcomFamilyGraph.swift:857–876` resolves the selected parent's pointer directly
through `people`, ignoring suppression and preferred-person redirection.
The parent-family selection implementation also reads raw family/person
records. This is the underlying class of issue raised in #1566, independent
of whether that particular three-family fixture happens to rank a good family
first.

**Correction:** Apply human identity rulings consistently in the query
projection, including lists, ranking and relationship traversal. Retain raw
records separately as source evidence; do not erase them merely to make
every query observe the ruling.

## Routing assessment and recommendation (#1556 / #1559)

The copula correction remains unchanged between `679741da` and the current
pin. The `sentenceVerbs` set in `HallieModeClassifier.swift:253–256` excludes
`is/are/was/were` and retains substantive verbs. The submitted tests exercise
the reported short follow-ups and existing standalone-question behavior.
No substantive defect was found in this narrow change.

The mixed kinship/media behavior is still open:
`HallieModeClassifier.swift:194–206` resolves proper-name subjects and otherwise
leaves conflicting cues unknown. An explicit retrieval request such as
"find videos of my brother Tim" should be eligible for catalog retrieval
after resolving the kinship subject. Do not extend that shortcut to mixed
factual questions such as "how old was Dad in this video": those need both
media date and tree identity/vitals.

Recommendation: use the existing narrow retrieval-intent concept for retrieval
requests; represent genuinely cross-source questions explicitly when that
capability is implemented. Until then, clarification is preferable to routing
a mixed factual question to a lane that confidently answers something else.
This report recommends a boundary; it does not authorize or implement an
architectural change.

## Family/relationship design answer (#1566)

Per-person identity rulings are appropriate, but filtering one name-search
entry point is insufficient. A ruling that two person records represent the
same human does not establish that their family records are duplicates:
adoption, remarriage, different partners and relationship assertions must
remain expressible.

Canonicalize explicitly verified person identities in a derived relationship
view while retaining original assertions and provenance. Explicit family or
relationship rulings are useful for cases not settled by person identity.
Key them durably by source identity/provenance; raw GEDCOM xrefs alone change
across re-pulls. Do not infer "same family" merely from a shared mother.

The current `HiddenPersonLeavesFamilyRecordsBehindTests.swift` still marks the
issue as known. Its fixture/assertion checks two stored FAMC links, rather
than the three-family answer path described in #1566. A green known-issue
result is therefore not evidence of correct parent resolution.

## Other graph construction paths

The claim that every caller necessarily gets a ruled graph is too strong.
Besides the inconsistent shared-cache return described above:

- Explicit Hallie `--gedcom` file/folder loading in
  `HallieShellCLI.swift:303–311` bypasses `FamilyGraphSharedCache`.
- Injected/local tree loaders use their own loader paths in
  `FamilyTreeLiveModel.swift:771–783` and its synchronous loading path.
- Pull/merge and single-person refresh code construct raw graphs for ingestion.

Raw ingestion and explicitly injected fixtures are legitimate. They should
remain distinguishable from a ruled user-facing query graph. Normal Hallie
default loading, kinship self-loading and the normal tree path do use the
shared cache, but that alone does not establish consistency.

## Migration recovery caveat (#1564)

`scripts/migrate_people_folders.py:272–276` performs `shutil.move` before
writing its journal entry. The subsequent flush is not a durable filesystem
acknowledgement. Interruption between move and journal write can leave a moved
file absent from the undo manifest.

Undo at lines 312–321 checks whether paths exist, not whether the destination
still contains the original file. If that path has been reused or replaced,
undo can move the replacement into the original person's folder as though it
were the migrated file. A stronger recovery protocol needs durable move
intent and identity verification before reversal.

These are source-confirmed recovery limitations. No assertion is made that
the historical 56-file migration encountered them. Its live manifest and
archive contents were not manipulated or certified by this review.

## Existing validation and limits

Inspected tests cover fresh-cache name redirection, plain hiding, identity-file
round trips, duplicate chains/cycles and local menu hiding/persistence.
`MergedExportRebaseTests` covers the documented provenance-binding refusal
and single-artifact rebase path. These are useful scoped checks; they do not
establish live-cache coherence, equality of cache return views, or application
of rulings to surname/superlative/relationship queries.

No new runtime result is claimed in this report. The testing agent was asked
for an optional bounded pure-Core probe of the query-API bypass; any completed
result should be recorded separately with its exact artifact and revision.
The outstanding behavior and design work above remains open; the requested
review itself is complete.
