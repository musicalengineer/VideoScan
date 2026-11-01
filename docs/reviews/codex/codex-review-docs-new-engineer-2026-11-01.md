# Codex review — Docs as a new principal engineer 2026-11-01

- Range: `1e4d2927..HEAD`
- Credits spent: unavailable
- Tokens: 351121
- Finding count: 23
- Verdict: fix — A new engineer can understand the project, but must reconcile superseded instructions before implementing background-service step 2.
- Run: 2026-11-01T21:36:51Z (cycle #188, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 23
Verdict: fix — A new engineer can understand the project, but must reconcile superseded instructions before implementing background-service step 2.

**1. Time to competence**

The initial read-first pass took under a minute of machine-assisted reading, followed by cross-checks. The complete reading window was **7 minutes 39 seconds**, within the 45-minute limit. That is not a human onboarding benchmark: the map, CLAUDE, Charter, Architecture, Process and Status contain about **15,600 words**, before skimming Decisions and Backlog. I would budget a human **75–100 minutes**, including those skims.

After that set, I could start **a scoped review of a catalog-writer change**: ownership, safety contracts, review requirements and test gates are discoverable. I could also prepare the caption-migration brief.

I could not confidently implement the caption cutover. The missing ingredient is a single account of **what exists now and precisely what step 2 changes**. The documents supply substantial detail, but require the newcomer to resolve its applicability.

I read **26 live Markdown files**—25 under `docs/`, plus `CLAUDE.md`—and all **nine slides as text**. DECISIONS and BACKLOG were skimmed. I excluded the frozen catalog-contract fixture from the eight live design documents. No sources, archive contents or `.scratch/` contents were opened; nothing was changed.

**2. The task test: move captions into the helper**

The useful reading path was:

| Documents needed | What they supplied |
|---|---|
| `CLAUDE.md`; `docs/PROCESS.md` §§2, 4–6, 8 | Authority, review gate, testing expectations and test machines. |
| `docs/ARCHITECTURE.md` §§10.1, 10.6–10.7 | Commit ownership, jobs versus cyclers, state ownership. |
| `docs/STATUS.md` “Background step 1 — MERGED”; `docs/DECISIONS.md` October 31–November 1 entries | The existing era service, approved v14 scope, and captions moving to the 8B. |
| `docs/design/background_service.md` §§3.1–3.6, 4, 6 | Process boundary, journal, migration row and failure tests. |
| `docs/design/machine_intelligence.md` §§2–3, Part II | Existing captioner, model interfaces and model inventory. |
| `docs/design/data_organization_2026_10_31.md` §§1C, 3–4 | Caption tables, helper files and output destinations. |
| `docs/guides/developer.md`; `docs/guides/testing.md`; `docs/practices/swift_playbook.md` §§1, 3–4, 6 | Implementation locations, test procedures and relevant patterns. |
| `docs/reviews/codex.md`, background-journal row and brief template | Previous applier findings, recorded closure and review format. |

For this task, I opened and then set aside `provenance.md` after the assertion boundary; `catalog.md` after its current-store summary and jobs/cyclers distinction; and `video_llm_benchmarks.md` after the A2/A3 evidence. The remainder of those files did not advance the caption handoff.

I read `people_events.md`, `hallie.md`, `cleanup_and_operations.md`, the archive and role guides, the roster review and the deck for this audit; I would close them during step 2 unless its scope expanded.

I had to reconcile these twice:

- **Current service state:** STATUS’s opening versus its merged section; the service document’s current preface versus its original migration table.
- **Observation storage:** background-service §0.7, machine-intelligence Part II “Where model outputs live,” and the data map’s “The three homes.”
- **Who writes the catalog:** Architecture §10.1 and several background-service introductions before reaching §3.4.
- **Jobs versus cyclers:** catalog Part II §§3–4, its later “governing distinction,” and Architecture §10.6.

**F04 — Make the step-2 handoff self-contained.** At `docs/design/background_service.md:366`, **“The move, one engine at a time,”** step 1 still means model-lab A0, while the current preface describes the merged 8B era job. Step 2 names the moving types and destination tables, but I did not find:

- A caption-specific journal contract explaining completion, partial/empty results, and the relationship between caption rows and `caption_runs`.
- A clear account of the existing 3B results during 8B backfill: the migration table promises “nothing changed,” while the dated ruling deliberately changes the model.
- Concrete test selectors implementing “caption truth tests” and the writer quartet, together with the applicable host/fixture requirements.

The generic tests are substantial; they are not absent. What is missing is their binding to this particular cutover. Document the settled behavior and remaining decisions here, without making the reader reconstruct them.

**3. Per-file disposition**

Finding IDs identify distinct changes. Repeated IDs below and in later answers count once.

| File and section | Disposition and reason |
|---|---|
| [docs/README.md](/Users/rickb/dev/VideoScan/docs/README.md:5), “Read first” and subsystem map | **Keep — read, no findings.** A useful entry point with purpose and status cues. |
| [CLAUDE.md](/Users/rickb/dev/VideoScan/CLAUDE.md:12), “Hard rules” | **Keep — read, no findings.** Compact authority and ownership are clear. |
| [docs/Purpose-and-Charter.md](/Users/rickb/dev/VideoScan/docs/Purpose-and-Charter.md:71), “Claude Feedback” under §§4–6 | **Rewrite — F15.** Preserve Rick’s purpose and principles; replace repeated implementation and process explanations with links to their authorities. |
| [docs/ARCHITECTURE.md](/Users/rickb/dev/VideoScan/docs/ARCHITECTURE.md:109), §§10.0, 10.5, 10.8 | **Rewrite — F01/F02/F08.** Integrate the newer rules into the contracts instead of placing corrections above superseded contracts. |
| [docs/PROCESS.md](/Users/rickb/dev/VideoScan/docs/PROCESS.md:62), “Escalate to Rick before” | **Rewrite — F22.** “Non-additive schema changes” contradicts CLAUDE rule 6’s approval requirement for schema changes; make the escalation list agree with the rulebook. |
| [docs/STATUS.md](/Users/rickb/dev/VideoScan/docs/STATUS.md:5), “Read first,” “Next,” “Waiting on Rick” | **Rewrite — F05.** Remove superseded next steps, already-granted approvals and retired document names; leave one current starting state. |
| [docs/DECISIONS.md](/Users/rickb/dev/VideoScan/docs/DECISIONS.md:201), dated rulings | **Keep — skimmed, no findings.** Historical disagreement belongs in this append-only record; dates let the reader resolve it. |
| [docs/BACKLOG.md](/Users/rickb/dev/VideoScan/docs/BACKLOG.md:183), “Docs still to write” and “Done” | **Rewrite — F06.** Remove settled work from the active queue and reduce embedded mini-designs to unresolved tasks with pointers. |
| [docs/design/background_service.md](/Users/rickb/dev/VideoScan/docs/design/background_service.md:149), “Outputs,” §§3–7 | **Rewrite — F03/F04.** Reconcile output rules and replace the original migration sequence with the effective handoff. |
| [docs/design/catalog.md](/Users/rickb/dev/VideoScan/docs/design/catalog.md:26), Part II §§3–6 | **Rewrite — F07.** Separate the built contract from superseded proposals; the document explicitly says the registry/scheduler’s correspondence to the build is unknown. |
| [docs/design/machine_intelligence.md](/Users/rickb/dev/VideoScan/docs/design/machine_intelligence.md:179), “Where output goes,” “Phases,” “Rulings wanted” | **Rewrite — F02/F03.** Update the operative sections for approved v14 and the current restriction on machine-era dates. |
| [docs/design/provenance.md](/Users/rickb/dev/VideoScan/docs/design/provenance.md:111), “Data model — schema changes,” Part II | **Rewrite — F02.** Distinguish shipped migrations from future tables; remove superseded DDL/workflow alternatives from the active specification. |
| [docs/design/people_events.md](/Users/rickb/dev/VideoScan/docs/design/people_events.md:239), Part II “Storage” and “Content identity” | **Rewrite — F09.** Mark or reconcile the segment proposal’s old JSON and sampled-identity assumptions against the current catalog contracts before someone implements it. |
| [docs/design/hallie.md](/Users/rickb/dev/VideoScan/docs/design/hallie.md:49), “Purpose and reading map,” “Grounded composition and its limits” | **Rewrite — F08.** Present one current translation/composition contract and a current reading map; relocate the historical handoff narrative. |
| [docs/design/data_organization_2026_10_31.md](/Users/rickb/dev/VideoScan/docs/design/data_organization_2026_10_31.md:350), catalog inventory and §4 | **Rewrite — F02/F03.** Refresh the explicitly schema-13 inventory for the documented v14 state, and correct the era-output mapping. |
| [docs/design/cleanup_and_operations.md](/Users/rickb/dev/VideoScan/docs/design/cleanup_and_operations.md:9), Parts I–III | **Keep — read, no findings.** Dated proposals remain relevant because they await disposition; that status is explicit. |
| [docs/guides/developer.md](/Users/rickb/dev/VideoScan/docs/guides/developer.md:105), “Data-risk code” | **Rewrite — F10.** Replace the incomplete duplicate review map with the authoritative Architecture §6 map; catalog commit paths should not disappear between the two. |
| [docs/guides/testing.md](/Users/rickb/dev/VideoScan/docs/guides/testing.md:406), §§4–7 | **Rewrite — F11.** Produce a current runbook from the accumulated notes: “M1-first” and a built nightly labelled “PROPOSED… No code yet” are actionable misdirection. |
| [docs/guides/operations.md](/Users/rickb/dev/VideoScan/docs/guides/operations.md:108), “Verdict,” “Phases,” “Storage layout” | **Rewrite — F12.** Distinguish the built runner from planned verdict/green-reference behavior; retain current diagnostics and archive resolved incident narratives. |
| [docs/guides/provenance_roles.md](/Users/rickb/dev/VideoScan/docs/guides/provenance_roles.md:1), role definitions | **Keep — read, no findings.** Short, concrete and usable without reconstructing the design history. |
| [docs/guides/media-archive.md](/Users/rickb/dev/VideoScan/docs/guides/media-archive.md:8), “Purpose and status,” “Cleanup,” “Outstanding decisions” | **Rewrite — F01/F13.** Reconcile permanent-removal language and replace the September implementation baseline with current operating status. |
| [docs/practices/swift_playbook.md](/Users/rickb/dev/VideoScan/docs/practices/swift_playbook.md:53), “House rules” and §2 skeleton | **Rewrite — F14.** Align reusable instructions with today’s contracts: the template still invites new `VideoScanModel` extensions prohibited by CLAUDE rule 12. Retain the useful pattern/example structure. |
| [docs/practices/invariants.md](/Users/rickb/dev/VideoScan/docs/practices/invariants.md:323), MediaOps MOPS-1, MOPS-14, MOPS-16 | **Rewrite — F01/F18/F23.** Reconcile removal wording and restructure the two enormous invariants while preserving stable IDs and machine-readable area markers. |
| [docs/reviews/codex.md](/Users/rickb/dev/VideoScan/docs/reviews/codex.md:42), “Invariants to attack” template | **Rewrite — F01.** Change the example’s “moment of unlink” to the current Trash operation; keep the excellent distinction between verdict and recorded closure. |
| [docs/reviews/household_roster_feasibility.md](/Users/rickb/dev/VideoScan/docs/reviews/household_roster_feasibility.md:1), “Rules” through “Verdict” | **Keep — read, no findings.** Definitions, denominators, limitations and conclusion are connected. |
| [docs/reviews/video_llm_benchmarks.md](/Users/rickb/dev/VideoScan/docs/reviews/video_llm_benchmarks.md:346), A3 run status and OCR section | **Rewrite — F19.** A deliberately finished subset is labelled “Partial run,” and unrun OCR is displayed as zero-percent results; distinguish selection, incompleteness and “not measured.” |

For the slides, paths below are relative to `docs/design/architecture_deck/slides/`:

| File and slide heading | Disposition and reason |
|---|---|
| `cover.html`, “Software architecture and design” | **Keep — read, no findings.** Useful orientation. |
| `context.html`, “Context and problem statement” | **Keep — read, no findings.** Connects purpose to priorities. |
| `components.html`, “Each tab answers one question” | **Keep — read, no findings.** A useful workflow-to-source map. |
| `system.html:34`, “Architecture and system context” | **Rewrite — F20.** Scope “media is only ever read” to the relevant analysis boundary. |
| `dataflow.html:37`, “Ingest → Manage → Archive” | **Rewrite — F20.** The same blanket read-only statement contradicts its own copy, repair and Trash operations. |
| `stack.html:34`, “The fleet” | **Rewrite — F21**, plus **F08** in its Hallie description. Correct the catalog-master host and the composition boundary. |
| `catalog.html:15`, “What it holds” | **Rewrite — F02.** Reconcile the schema-14 label with the schema-13 inventory/count it summarizes. |
| `performance.html`, “Where the time goes” | **Keep — read, no findings.** Its two pipelines explain bottlenecks better than a technology list. |
| `uiux.html`, “The verbs, content analysis, the background service” | **Keep — read, no findings.** The paired input/work/output summaries are useful orientation. |

**4. Contradictions**

These are reproducible by following the first instruction and then comparing the second; no code execution is necessary.

| Finding | Disagreement, with locations | Current reading |
|---|---|---|
| **F01 — Removal policy** | `docs/ARCHITECTURE.md:112`, **“Safety rules that hold everywhere”**: “say ‘permanently’ when not.” `docs/DECISIONS.md:62`, **2026-10-09 — Trash only**: “The app never deletes permanently.” `docs/guides/media-archive.md:360`, **“Cleanup and post-promotion protection,”** also allows a permanent path. | The October 9 ruling and current CLAUDE rule 2 govern: Trash failure holds. Remove the older permission from live instructions. |
| **F02 — Migration scope** | `docs/design/provenance.md:157`, **“v14 `v9_provenance` … needs Rick’s approval,”** presents the broad migration. `docs/DECISIONS.md:203`, **2026-11-01 — Schema v14 approved**, says “nothing else in v14” beyond assertions and the veto trigger. | November 1 wins. The document’s own current preface agrees; its operative DDL headings do not. |
| **F03 — Era observations becoming dates** | `docs/design/machine_intelligence.md:184`, **“Where output goes,”** specifies “`inferred_dates` with a new `source = 'era:<approach>'`.” `docs/DECISIONS.md:202`, **2026-11-01 — Observations are never shown as a date**, says the era “does not enter `inferred_dates`, the triangulator or any filter” pending convergence and Rick’s ruling. | The November 1 restriction governs. Preserve the distinct allowance for human-word search in the following ruling. |
| **F05 — Starting state** | `docs/STATUS.md:8`, **“Read first”**: “step 0 only.” The same file at line 35: **“Background step 1 — MERGED 11/01.”** | The dated merged section, its SHA and the November 1 schema decision are current. The opening and pending-approval lists must catch up. |
| **F08 — What Hallie’s model sees** | `docs/ARCHITECTURE.md:184`, **“Family Tree, People, Hallie”**: “the model never sees catalog content.” `docs/design/hallie.md:199`, **“Grounded composition and its limits”**: “The model sees a bounded approved plan.” | The August 17 composition account explicitly qualifies the older August 14 wording recorded in DECISIONS; HAL-1 in `invariants.md` also allows phrasing a verified plan. State translation and composition separately. |
| **F21 — Catalog master** | `docs/design/architecture_deck/slides/stack.html:34`, **“The fleet”**: M4 is “catalog sync master.” `docs/DECISIONS.md:190`, **2026-10-27 — Catalog master is the M5 Ultra**, says the M4 “is now a viewer.” | October 27 names the effective configuration and explains the stale code default. The deck should describe that configuration. |
| **F22 — Approval boundary** | `docs/PROCESS.md:63`, **“Escalate to Rick before”**: “non-additive schema changes.” `CLAUDE.md:18`, **Hard rule 6**: schema changes “are additive, through a migration, and Rick approves them.” | CLAUDE is the designated rulebook; the November 1 explicit approval of additive v14 corroborates it. |

**5. Repetition**

Some repetition is helpful: a slide overview and a detailed contract serve different reading tasks. The following copies create maintenance work without supplying that distinction.

| Finding | Repeated passages | Copy that should survive |
|---|---|---|
| **F15** | Charter §4 **“Claude Feedback — the Mixture-of-Experts idea”** repeats the model approach in `machine_intelligence.md` §§0, 5; Charter §5 **“Claude Feedback — the background analyzer service”** repeats `background_service.md` §§0.5, 3; Charter §6 repeats PROCESS’s testing and modes. | Preserve the owner’s intent in the Charter. Keep implementation explanation in the subsystem design and procedure in PROCESS. |
| **F16 — Three storage homes, three explanations** | `background_service.md:199`, **“Where the machine intelligence lives”**; `machine_intelligence.md:402`, **“Where model outputs live”**; `data_organization_2026_10_31.md:344`, **“The three homes, in one paragraph.”** | Keep the definition and transport explanation in background-service §0.7, and the detailed location tables in the data map. Replace the repeated narrative elsewhere with links. |
| **F10** | `ARCHITECTURE.md:78`, **“Data-risk code”**, and `guides/developer.md:105`, **“Data-risk code.”** The latter’s omission of catalog commit paths shows the cost of duplication. | Architecture §6 owns the review map; the developer guide links to it. |
| **F02** | `provenance.md`, Part I **“Where this supersedes the 10/22 lightweight design,”** followed by the complete older **Part II — Provenance, lightweight**. | Keep the effective specification, carrying forward any unique applicable material; the superseded draft belongs in the archive already provided for it. |

**6. Undefined or overloaded terms**

**F17 — Add a small domain glossary at the architecture entry point, with links from specialist usages.** The problem is usually late or scattered definition, not complete absence.

| Term and location | What a newcomer must distinguish |
|---|---|
| **Observation / assertion / decision:** `background_service.md` §0.7; `provenance.md` “Data model”; `DECISIONS.md` | Observation means machine-produced information; an assertion is a stored claim that may later be human-confirmed; decision also means a project ruling. Their relationship needs one explicit explanation. |
| **Cycler / MFO:** `CLAUDE.md` rule 5; `ARCHITECTURE.md` §§4, 10.6; `catalog.md` Part II “The governing distinction” | MFO expands to Media File Operations, but duration alone is not the final distinction: continuous metadata maintenance and person-started jobs differ. The late correction is currently necessary to understand earlier text. |
| **Sensor / gauntlet / lane:** `PROCESS.md` §4; `guides/testing.md` §§1, 3; `catalog.md` §4.3 | A sensor is a regression guard, not a hardware sensor; the gauntlet is a particular test pipeline; lane can mean a test stage, scheduling class or operation path. Qualify the latter. |
| **Master:** `guides/provenance_roles.md`; `DECISIONS.md` October 27; `provenance.md` “Find Master” | A provenance role, catalog-writer machine and matching reference are different concepts. Use “catalog master,” “preservation master” or “reference master” as applicable. |
| **Witness:** `ARCHITECTURE.md` §10.1; `machine_intelligence.md` Part II “What a model may never see” | A durable high-water witness is a storage mechanism; a pixels-only witness is a model’s evidentiary boundary. The unqualified noun hides that difference. |
| **Carrier:** `provenance.md` “Purpose” and “Data model”; deck `dataflow.html` | Define the physical recording medium before introducing carrier tables and spans; distinguish it from the digital file/container and its transfer date. |

**7. Density**

These were the three hardest passages to retain in one pass:

1. **F18 — `docs/practices/invariants.md:337`, MediaOps “MOPS-14.”** One numbered paragraph contains the proof rule, two directory walks, race checks, device identity, stamp semantics, rollback revisions, exceptions and test inventory. **A decision table** would separate observed condition, permitted result and refusal reason. Keep the stable invariant ID and put supporting mechanics underneath it.

2. **F23 — `docs/practices/invariants.md:339`, MediaOps “MOPS-16.”** Admission, draining, staging, publishing, quitting, recovery copies and three import phases are nested inside one item. **A sequence/state diagram** would expose the order and interruption branches; the surrounding prose could then describe exceptions without repeatedly restating the sequence.

3. **F07 — `docs/design/catalog.md:390`, “The content steward,” through “One election, two stewards.”** User exploration, proposed interface, trial decisions, safeguards and later implementation evidence accumulate without a concise effective contract. **A cut** would help most: retain the resulting responsibilities and applicable rules, archive the negotiation.

The deck does **not** resolve these passages. Its catalog slide explains ownership, not import/quit ordering; its data-flow slide explains the product workflow, not the filesystem proof; its components slide names Triage without resolving the steward’s successive proposals. It is useful orientation, but mostly summarizes at a different level.

**8. The four words**

- **Organized:** The README’s read-first route and subsystem map work well, but `catalog.md` Part II and `provenance.md` Parts I–II make the reader organize historical layers inside the destination.
- **Non-repetitive:** Short contracts with links are effective, but the three storage-home explanations and Charter’s repeated engineering responses show that file consolidation has not yet removed substantial prose duplication.
- **Relevant:** Ownership, safety boundaries and test expectations directly support engineering work, while resolved incidents in `guides/operations.md` “Storage layout” and obsolete setup instructions in `guides/testing.md` interrupt the current task.
- **Clear:** The provenance-role guide and standing Codex verdict table let a stranger act, but STATUS’s conflicting starting states and the background-service migration table prevent the same confidence for step 2.

## Brief

# Codex brief — read the docs as a new principal engineer (2026-11-01)

## Output contract (first two lines of your answer, exactly)
```
Credits spent: <amount> | Finding count: <N>
Verdict: <merge | fix | block> — one sentence
```
Here `merge` means "a new engineer can work from these docs as they are", `fix` means "usable, with the listed changes", `block` means "not yet usable".

## Who you are for this pass
A principal engineer who has never seen VideoScan, joining a one-developer macOS project (Swift 6, SwiftUI, SQLite, local ML) that has an owner (Rick) and two agents (Claude, Codex) working from the same documents. You are not judging whether the designs are right. You are judging whether the WRITING lets a stranger act: organized, non-repetitive, relevant, clear, concise.

## Scope — read only these, in this order, nothing else in the repo
1. `docs/README.md` (the map), then the read-first set it names: `CLAUDE.md`, `docs/Purpose-and-Charter.md`, `docs/ARCHITECTURE.md`, `docs/PROCESS.md`, `docs/STATUS.md`, `docs/DECISIONS.md` (skim: it is an append-only record), `docs/BACKLOG.md` (skim).
2. The eight live design docs under `docs/design/*.md` and the slide text under `docs/design/architecture_deck/slides/*.html` (read the HTML as text: headings, paragraphs, list items; ignore the styling).
3. `docs/guides/*.md`, `docs/practices/*.md`, `docs/reviews/*.md`.
Do NOT open `docs/archive/`, the Swift or Python sources, or `.scratch/`. Time-box: stop reading after 45 minutes of wall time and report on what you read.

## The questions, in this order
1. **Time to competence.** How long did the read-first set take, and after it, could you start a task? Which task could you start, which could you not, and what was missing?
2. **The task test.** You are asked to build step 2 of the background service (the caption job moves into the helper). List the docs you needed, the ones you opened and closed, what you had to read twice because two files said it, and what no file said.
3. **Per file**: one line each — keep / merge into <file> / archive / rewrite — with the reason. Count the live `.md` files you read.
4. **Contradictions**: two places that disagree, quoted with file and section, and which one is current (dates and DECISIONS decide).
5. **Repetition**: passages that say the same thing in two or more files, with both locations; say which copy should survive.
6. **Undefined or overloaded terms**: words used before they are defined, or used two ways (candidates: observation, assertion, cycler, MFO, sensor, gauntlet, lane, decision, master, witness, carrier).
7. **Density**: the three densest passages a human cannot read in one pass, and for each whether a table, a diagram or a cut would fix it. Does the architecture deck cover what a dense passage needed, or does it repeat the prose?
8. **The four words**: organized, non-repetitive, relevant, clear — one sentence of verdict each, with the strongest evidence for and against.

## Rules
- Quote file paths and section headings for every finding; a finding without a location does not count.
- Do not propose designs, features or code. Do not rewrite documents; say what to change.
- Nothing here is confidential beyond the repo itself; the family media and its paths are not in these docs and must not appear in your answer.
- Finding count = the number of distinct items under questions 3–7 that you recommend acting on.
