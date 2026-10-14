# Events v1 — implementation plan (2026-10-14)

**Status:** plan accepted by the Manager 2026-10-14 15:00 for a first build on a
branch while Rick spot-tests Cleanup. Design authority: `docs/design/events_design.md`
(v2). Rick's instruction: "then begin the event identifier and aggregator."
Questions in section 8 are for Rick; the build proceeds under the stated defaults.

## 1. The job, in Rick's words

**"Which recordings belong to the same family memory?"** v1 narrows it to: show
me the birthdays, the Christmases, the Thanksgivings (and the jams); group them
by occasion from what the catalog already knows; let me say yes, no, rename,
split or merge; and remember what I said.

Goals served: 2 (recognize and organize events), 4, 6, 7. Goal 3 is NOT served:
grouping never marks a clip covered (design §1.3, §5).

## 2. Smallest useful v1 slice

**In**
- **Identity:** one witness per stored full SHA-256 (`VideoScanModel.storedFullDigest`);
  A/V pair halves (`pairGroupID`) fold into one witness. Every copy's folder/file
  name contributes a label to that witness. `footage` lineage is shown as evidence
  ("same footage as X, likely"), never collapsed. Rows In the Trash / Removed /
  Missing are excluded by the removal marker.
- **Units:** the whole file is the recording range; the decision key carries an
  optional `(start, end)` so in-file ranges can arrive in v1.1 without migration.
- **Observations with source:** timestamped captions (`sceneCaptions`), the untimed
  transcript (`audioTranscript`), name words (`EventLabeler.nameLabels`), calendar
  and birthday labels (`EventLabeler` + `AngelFamilyBirthdays.readPeopleTab()`),
  dates with source (`userDate` > camera > inferred + range > folder year),
  confirmed people.
- **Categories (rules only):** the prototype's nine (Birthday, Christmas,
  Thanksgiving, Easter, Halloween, Wedding, Beach / vacation, Music / performance,
  Graduation) as a pure Swift rule table with negative cues. Strength is a word:
  "seen and said", "seen", "said", "name only", "date only".
- **Capture runs and instances (conservative):** members join a run when they share
  a folder OR are dated within 4 days with a non-folder date; bounded span 14 days;
  folder-year-only dates never chain; folder label + folder-derived date count as
  one source; categories must be compatible; a reliable date conflict blocks.
  Anything weaker is a proposed link shown as a question.
- **One question:** "Same occasion, or different years?" for two suggestions in
  one category with the same folder and dates > 14 days apart or no dates.
- **Page:** Triage ▸ Events review queue with confirm / rename / split / merge /
  dismiss / accept-or-reject member; filters by category and state; Open via the
  existing opener; thumbnails from `PreviewDiskCache`.
- **Durable decisions** in `events-decisions.json` (section 3).
- **Metrics:** the planner emits the counts-only `events_latest.json` object
  (`EVENTS_KEYS` in tools/publish_metrics.py); `scripts/events_prototype.py`
  retires once the app writes the file.

**Deferred (design §5):** LLM adjudication, derived-date suggestions (stage E),
in-file ranges and segmentation of long tapes, hierarchies, perceptual / SigLIP
backfills, cross-run links beyond the one question, Compare Footage hand-off,
Catalog tags for confirmed events, ledger mirroring.

## 3. Data model (no VideoRecord field, no catalog migration)

`events-decisions.json` under App Support/VideoScan (test host → per-process temp
dir, the `IgnoredContentStore.defaultDirectory` discipline). Rick's word; the only
authority.
- `EventsDecisionFile { storeVersion = 1, savedAt, events: [EventRecord], decisions: [EventDecision] }`
- `EventRecord { id: UUID, name, categories: [String], state: .confirmed | .dismissed, createdAt, updatedAt, note? }`
- `ContentRange { contentKey: String (full digest; "pair:<pairGroupID>"; "id:<recordID>"), start: Double?, end: Double? }`
- `EventDecision` (Codable with a `kind` string; unknown kinds are preserved on save):
  `.member(eventID, ContentRange, .accepted | .rejected)`, `.differentOccasions(a, b)`,
  `.merged(from:, into:)`, `.categoryRejected(range, category)`,
  `.suggestionDismissed(suggestionKey, facts)` — a dismissed suggestion returns only
  when the facts (member count, evidence count) move.
- Persistence: `AtomicFilePublish.write(…, durability: .fullFsync)` off-main, `.prev`
  kept. A NEWER `storeVersion` makes the store read-only and the page says so; it is
  never treated as empty. Writes are O(1) in memory + one save.
- Keys are content, not path or record id: a rescan, a moved drive or a regrouped
  suggestion cannot orphan a decision.

## 4. Pipeline

| Stage | v1 | Runs as |
|---|---|---|
| A identity + observations | `VideoScanModel.eventsInputs()` — ONE main-actor O(records) projection into Sendable `EventsRow` | main actor, from a handler, never a body |
| B capture runs | `EventsPlanner.runs(_:)` pure | `Task.detached` inside `buildEventsPlan()` |
| C categories | `EventCategoryRules.evidence(row)` pure (VideoScanCore) | same task |
| D instances + question | `EventsPlanner.plan(rows:decisions:birthdays:)` pure | same task |
| F decisions | `EventsDecisionStore` | main actor; save off-main |
| E dates | deferred | — |

No new MFO job or cycler in v1; inputs come from existing cyclers. If the real build
crosses the one-minute rule it becomes `EventsAnalyzeJob` in the CleanupTrashJob
shape. Scale test pins 100k rows ≤ 10 s Release.

## 5. Triage ▸ Events page (mirror of Cleanup)

- `EventsStore` (`static let shared`): `plan`, `builtAt`, `isBuilding`, `filter`,
  cached `numbers`; `refresh(model:)`; `confirm`, `rename`, `dismiss`, `split`,
  `merge`, `setMember`, `answer` = one store mutation + off-main save +
  `plan.reapply(decisions)`.
- `EventsPlan: Sendable` — `suggestions`, `confirmed`, `questions`, `leftOut`, totals.
- `EventSuggestion`, `EventMember`, `EvidenceLine { words, source, timestamp? }`.
- `EventsWords` (pure, pinned).
- `EventsPane`: header + question + "Checked HH:MM" + Refresh; filter chips;
  `LazyVStack` of `EventCardRow`; a Questions strip when any exist.
- `EventDetailSheet`: members with evidence lines, Open, accept/reject, Rename,
  "These are different occasions", Merge with….
- `EventsSidebarRow` under `CleanupSidebarRow` in `TriageView.sidebar`;
  `showingEvents` beside `showingCleanup`.

## 6. Files

Create: `VideoScanCore/Sources/VideoScanCore/EventCategoryRules.swift`;
`VideoScan/Events/EventsPlan.swift`; `VideoScan/Events/EventsDecisionStore.swift`;
`VideoScan/Events/VideoScanModel+Events.swift`; `VideoScan/Catalog/EventsPane.swift`;
`VideoScan/Catalog/EventDetailSheet.swift`; tests below.
Touch: `Catalog/TriageView.swift` (sidebar row + pane branch); `docs/design/events_design.md`
status line. Not touched: `VideoRecord`, the catalog DTO, `MediaLedgerEvent`,
`EventLabeler`, any media file.

## 7. Tests (five dimensions)

- Logic — `EventCategoryRulesTests`: seenAndSaidBirthdayIsStrong, tvSaysHappyBirthdayIsWeak,
  mentionsChristmasIsNotChristmas, musicPerformanceFromCaptionOnly, folderNameAloneIsNameOnly.
  `EventsPlanTests`: copiesCollapseToOneWitnessWithBothFolderLabels, pairHalvesAreOneWitness,
  lineageIsEvidenceNeverMembership, folderYearOnlyDatesNeverChain, spanBoundStopsThreeHourGapChaining,
  folderLabelAndFolderDateAreOneSource, yearsApartDateConflictBlocksMerge,
  twoBirthdaysOnSuccessiveWeekendsStayApart, candlesIndoorsAndKidsOutsideCanBeOneParty,
  sameOccasionQuestionAppearsForSameFolderDifferentYears, membershipNeverMarksCovered.
  `EventsDecisionStoreTests`: confirmSurvivesRegroupedSuggestionIDs, differentOccasionsSurvivesRerun,
  rejectCategoryIsNotRejectMembership, dismissedComesBackOnlyWhenFactsChange,
  decisionsKeyedByContentSurviveRescanPathChange, newerStoreVersionIsReadOnlyNotEmpty,
  unknownDecisionKindIsPreservedOnSave.
- Scale — `EventsPlanScaleTests`: plansOneHundredThousandRowsWithinBudget,
  eventsInputsIsOneMainActorPass, reapplyDecisionsIsNotAFullRebuild.
- Media matrix — not applicable in v1 (no media opened); say so in the test header.
- Isolation — `EventsIsolationTests`: storeUnderTestHostNeverTouchesRealAppSupport,
  poisonedDecisionsFileLoadsWhatItCanAndRefusesToOverwrite, missingPeopleProfilesMeansNoBirthdaysNotACrash.
- Sensor — `EventsSensorTests`: paneBodyReadsOnlyTheStore, sidebarCountMatchesPlanNumbers,
  wordsArePinned, statsObjectHasExactlyTheMetricsKeys.

## 8. Risks and Rick's questions

Risks: untimed transcripts make long tapes look like one event (the card says so);
rule precision in Swift is unmeasured (v0 marks = dev set; challenge set with Rick
before any gate); the decisions file is a new source of truth (read-only-on-newer,
unknown-kind-preserved); build time on 10k rows must be measured first.

Questions for Rick (defaults in parentheses; one at a time):
- Q1. Which records are in scope — the prototype's active filter sees 10,177, Rick
  says ~6,700 (default: the same rows the Archive Angel assesses).
- Q2. Should a confirmed event show in the Catalog as a tag or column? (default: no, Events only)
- Q3. Which categories beyond the nine come first — jams, Berklee, school, first days? (default: the nine)
- Q4. Dismiss: "not an event" vs "not this category" — one button or two? (default: one button, store keeps both)
- Q5. "Open" = QuickTime (default) or the in-app player seeking to the caption's moment?
