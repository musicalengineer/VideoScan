# Stage 0 — CodeQL triage, 2026-09-29

**Session:** on the M4 (bug-fix agent), finishing the part of `stage0-static-triage-2026-09-29.md` that the cloud session could not reach. Read-only as far as GitHub goes: no alert was dismissed.
**Source analysed:** the 17 open alerts from `gh api repos/musicalengineer/VideoScan/code-scanning/alerts?state=open --paginate`, all reported on `8898e444` (nightly run [#163](https://github.com/musicalengineer/VideoScan/actions/runs/36558911631)). Taint paths come from that run's `codeql-results` artifact (`swift.sarif`). Code read on `main` @ `3b1fc6b0`.

## One-screen summary

| Rule | Alerts | REAL | NOISE | NEEDS-MAC |
|---|---:|---:|---:|---:|
| `swift/cleartext-logging` (high) | 16 | 0 | 16 | 0 |
| `swift/cleartext-storage-preferences` (high) | 1 | 0 | 1 | 0 |
| **Total** | **17** | **0** | **17** | **0** |

**Bottom line:**
- **Every alert has one of three taint sources, and all three are family-tree data that CodeQL treats as "private" only because a variable is named `spouse`:**
  - `FamilyTreeView.swift:1761` — `if let spouse = marriage.spouse { model.select(spouse.id) }`
  - `HallieAppTurnCoordinator+PhotoCaption.swift:50-52` — `if statement.mentionsSpouse, let spouse { … spouse.name … }`
  - `VideoScanCore/ArchivistBiographyPolicy.swift:169-173` — `let spouselessMarriages = … "married \(date)"`
- CodeQL's Swift sensitive-data heuristic matches the identifier (marital status), then follows the value through 7–145 steps to a sink. The data is genealogy the app exists to show: names, GEDCOM / FamilySearch IDs, a marriage date. It is not a credential, a key, or health data.
- **The sinks are the app's own local file log** (`appLog.write` → `~/Library/Logs/VideoScan/videoscan.log`) and one `UserDefaults` key. `~/Library` and `~/Library/Logs` are `drwx------` on the M4 (checked 2026-09-29), so no other local account can read either. Neither leaves the machine.
- **This matches an existing, deliberate policy** (codex #861, restated at `HallieAppTurnCoordinator+Drill.swift:251-259`): names may go to the file log Rick reads; the unified-log (OSLog) stream gets them only as `.private`. None of the 17 alerts is on an OSLog call.
- **The count jump 11 → 17 (09-25 → 09-27)** is new Hallie / documents / family-tree logging lines reaching the same three sources, not a new class of flow.

### Nothing fixed, and why
No alert is REAL, so nothing was changed. Suppressing them in code (renaming `spouse`, or `// codeql[...]` comments) would hide the rule rather than answer it; the reasonable action is for Rick to **dismiss them on GitHub as "false positive" with a pointer to this doc**, or to add a CodeQL query filter for `swift/cleartext-logging` on `appLog.write`. That is his call; this triage did not dismiss anything.

### One adjacent observation (not a CodeQL alert)
`PersonDocumentLog.write(_:privateName:)` (`FamilyAssetStore+Documents.swift:157-162`) sends the line to OSLog with `privacy: .public` when no `privateName` is passed. Two such callers (`:298`, `:328`) put `written.lastPathComponent`, a document filename such as `Muriel death certificate.pdf`, in that line. That is a small leak of a name into the public unified log, inconsistent with codex #861. P3; not fixed here because it would change a log format (escalation rule) and it is not what CodeQL flagged. Suggested fix: pass the document filename as `privateName`, or log that path with `.private`.

---

## Per-alert classification

Scenario = what would have to be true for the alert to matter, and why it is not.

### Cleartext logging — family-tree navigation (source: `FamilyTreeView.swift:1761` `spouse`)

| # | Where | What is written | Class | Why |
|---:|---|---|---|---|
| 9 | `FamilyTreeLiveModel.swift:1316` | `select ignored — no person <id> in the installed tree` | NOISE | A GEDCOM / FamilySearch person ID, reached by clicking a spouse button. The file log is the audit trail for "why didn't my click do anything" (it exists because of past silent failures). Local, owner-only. |
| 8 | `FamilyTreeLiveModel.swift:1319` | `selected <name> (<id>)` | NOISE | Same path; the person's display name. Family-tree navigation is the product; the log names what was selected so a later "the tree jumped" report can be reconstructed. |

### Cleartext storage — `UserDefaults` (same source)

| # | Where | What is stored | Class | Why |
|---:|---|---|---|---|
| 1 | `FamilyTreeLiveModel.swift:1204` | `focusDefaults?.set(key, forKey: lastFocusDefaultsKey)` where `key = person.familySearchID ?? id` | NOISE | Restores the last-focused person at launch. A FamilySearch person ID is a public identifier on familysearch.org, and the prefs plist lives in the owner-only `~/Library/Preferences`. No name, no date. |

### Cleartext logging — Hallie pronunciation drill / picker (source: `HallieAppTurnCoordinator+PhotoCaption.swift:50-52` `spouse`)

The flow reaches the drill through the photo-caption subject list (a name Hallie might need to pronounce).

| # | Where | What is written | Class | Why |
|---:|---|---|---|---|
| 2 | `HallieAppTurnCoordinator+Drill.swift:246` | `logTaught(word:saidAs:)` call | NOISE | The name Rick taught and its phonetic spelling. The function's own doc (`:251-252`) states the policy: the name goes to the file log; OSLog gets it only at debug level, `.private`. |
| 3 | `HallieAppTurnCoordinator+Drill.swift:254` | `[hallie-voice] taught: <word> ← <saidAs>` | NOISE | Same line, inside `logTaught`. Needed to replay a mispronunciation report. |
| 4 | `HallieAppTurnCoordinator+Drill.swift:261` | `HalliePronunciationDrillMode.logLine(session)` | NOISE | Counts only (taught / judged-ok / skipped). CodeQL's path goes through `.taught`, an **Int**; no name reaches this sink. Over-approximation. |
| 5 | `HallieAppTurnCoordinator+Picker.swift:104` | `Picker.logLine(offered:)` | NOISE | Path is through `.round`, an Int page number, plus the candidate spellings on offer. Local file log only; OSLog gets counts only (`:105`). |

### Cleartext logging — Hallie turns (source: `ArchivistBiographyPolicy.swift:173` `spouselessMarriages`)

`spouselessMarriages` is a list of strings like `married 12 JUN 1954`. The long paths (72–108 steps) go from there through Hallie's shared answer/context values to whatever the turn logs.

| # | Where | What is written | Class | Why |
|---:|---|---|---|---|
| 7 | `HallieShellCLI.swift:1172` | `[hallie-general] lane=… reason=… — "<question prefix 120>"` | NOISE | Rick's own typed question, with the lane Hallie chose for it. The same question is already stored in full in `~/Library/Logs/VideoScan/Hallie/hallie-conversation-*.jsonl`, which the query harvest reads; this line adds the routing decision beside it. |
| 10 | `HallieShellCLI.swift:1196` | `verdict.logLine(question:ast:)` | NOISE | Same question, with the social-shape guard's verdict. Diagnostic for misrouted turns; local. |
| 11 | `HallieShellCLI.swift:1196` | (second path to the same sink, via `effectiveQuestion`) | NOISE | Duplicate of #10 with a different path. |
| 6 | `HallieShellCLI.swift:1277` | `[hallie-mode] rewrite: <note>` | NOISE | The mode gate's rewrite note (which question shape was rewritten to which). Diagnostic; local. |
| 12 | `HallieAppTurnCoordinator.swift:1302` | `[hallie] photo offer suppressed: <name> (<note>)` | NOISE | Why Hallie did not offer a photo of a named ancestor. Without it "why no photo of great-grandma?" is unanswerable from the log. |
| 17 | `HallieLineageAnswer+GedcomAwareness.swift:225` | `[hallie] <medium> offer suppressed: <name> (<note>)` | NOISE | Same, for the "no photographs existed in 1790" rule. |

### Cleartext logging — person documents (same source)

| # | Where | What is written | Class | Why |
|---:|---|---|---|---|
| 14 | `FamilyAssetStore+Documents.swift:337` | `[tree] added <kind> for <name> (<FSID>) — <file>, <size>` | NOISE | The audit line for adding a birth / death / marriage certificate to a person. It is written with `privateName:`, so OSLog gets `<name>` redacted; the file log keeps the name by design. |
| 16 | `FamilyAssetStore+Documents.swift:299` | `[tree] document <file> failed its read-back check … left in <dir>/ unlisted` | NOISE | CodeQL's path ends at `documentsDir.lastPathComponent`, which is always the literal `Documents`. The filename is the useful part: it names an orphaned file so Rick can find it. (See the OSLog observation above for the one real wrinkle on this line.) |
| 15 | `FamilyAssetStore+Documents.swift:329` | `[tree] document <file> could not be listed … left in <dir>/ unlisted` | NOISE | Same as #16. |
| 13 | `FamilyAssetStore+Documents.swift:163` | `appLog.write(line)` inside `PersonDocumentLog.write` | NOISE | The shared sink for #14–#16; its classification is theirs. |

---

## Appendix — method and provenance
- **Alerts:** `gh api …/code-scanning/alerts?state=open --paginate` → 17 alerts, numbers 1–17, all `most_recent_instance.commit_sha = 8898e444`.
- **Paths:** `gh run download 36558911631 -n codeql-results` → `swift.sarif` (17 results). For each result, the first and last three steps of its first code flow were read to name the source and the sink value.
- **Code:** every sink line and every source line was read on `3b1fc6b0`.
- **Permissions:** `ls -ld ~/Library ~/Library/Logs` → `drwx------` on the M4, 2026-09-29.
- **Not done:** no alert was dismissed on GitHub; no code was changed for CodeQL.
