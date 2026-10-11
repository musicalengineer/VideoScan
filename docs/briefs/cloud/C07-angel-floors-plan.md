# C07 — Archive Angel rule language: verify C06 item 2 and write the refactor plan (read-only)

Brief id: `C07-angel-floors-plan`. Inherits every rule in `docs/briefs/cloud/README.md`.
Output: ONE report at `docs/reviews/cloud/C07-angel-floors-plan.md`. Push to the branch your
session allows (name it `cloud/C07-angel-floors-plan` if you can; otherwise say which branch in
"Blockers"). Time box: ~60 minutes.

## Why
C06 (`docs/reviews/cloud/C06-switch-to-types.md`, item 2) found that `AngelField` (49 cases)
and `AngelRuleKind` hide kind tags behind about 14 `default:` arms. A new flag field read
through `candidateFlag` silently reads `false`, and a new floor missing from `floorFires`
silently never fires. The safety floors include `onMasterArchive` and `angelWorkingCopy`.
Rick wants this fixed after the Triage delete work, and this brief prepares that refactor night.

## Read only
- `VideoScan/VideoScan/ArchiveAngel/Recommend/AngelRuleLanguage.swift`
- `VideoScan/VideoScan/ArchiveAngel/Recommend/ArchiveAngelScorer+Rules.swift`
- callees you must follow to settle a claim (list them), and the tests that cover these files
  (grep `VideoScan/VideoScanTests/` for `AngelField`, `AngelRuleKind`, `floorFires`,
  `candidateFlag`).
Do not explore elsewhere.

## Deliver
1. **Verify C06 item 2, claim by claim**: each `default:` arm (file:line), what it returns, and
   whether a missing case would be silent today (REAL) or is caught elsewhere (NOISE: say by
   what). Also the hand-written duplicate floors list (`AngelRuleSection.allowedKinds`) and the
   `mediaFloorFires` split.
2. **Today's guarantee inventory:** for every floor and every flag field, is there a test that
   fails if it stops firing or reading? Make a table: floor/field · pinned by (test name) or
   UNPINNED.
3. **The refactor plan** (C06's shape: nested `FlagField` / `NumberField` / … enums under an
   `AngelField` with a payload, and `AngelRuleKind` = match | stars | floor(AngelFloor) |
   signal(AngelSignal)), as ordered, behaviour-preserving commits:
   - commit 1: characterization tests first (an oracle over every field × a fixed candidate set,
     and every floor × fixtures that should and shouldn't fire), which must pass on today's code;
   - the reshape steps, with the JSON/persisted rule names kept byte-identical (name every
     place rule names are decoded or written: rule files, UI, logs);
   - the expected CCN of `floorFires` / `candidateFlag` afterwards;
   - what could break, and the test that catches each.
4. **Risk call:** does this touch anything that decides whether a file is deleted or archived
   (data-risk), and so needs a codex pass under the spend policy? Name the exact functions.

Header per README rule 4; "Finding count" = verified C06 claims (REAL) + new issues found.
