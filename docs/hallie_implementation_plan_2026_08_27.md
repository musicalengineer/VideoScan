# Hallie — implementation plan (for Rick, morning of 2026-08-27)

*Status: DRAFT for Rick's review. Companion to `hallie_proposer_with_tools_design.md` (rev 3; rev 4 after codex's overnight review). Owners: Claude = design/implementation, codex = tests/review/measurement, Rick = decisions.*

## Decisions needed before coding (5 minutes)

| # | Decision | Recommendation |
|---|---|---|
| D1 | Transport: Ollama native tools vs constrained JSON | wait for codex's measurement (needs your direct ask in the Codex session) — default constrained JSON if not measured by Thursday |
| D2 | Speak `inference` claims to family viewers? | dev-mode only until eval shows 0 unverified facts for 2 weeks |
| D3 | CyberBrain strict loader: older builds refuse a brain with new optional fields | log unknown *optional* keys on read, stay strict on write |
| D4 | Heuristics registry now or after phase 1? | now (phase 0.10, ~1 day) |
| D5 | Model pin for the eval baseline | `qwen3.6:35b-a3b`; upgrades = golden-answer run |

## Week 1 (8/27–8/31): Phase 0 — the contract, no model

Goal: every piece the proposer will need exists, is deterministic, and is tested. Nothing user-visible changes.

| Day | Task (design §) | Owner | Done when |
|---|---|---|---|
| Wed | 0.1 `ClaimPayload`/`Citation`/`AnswerProposal` types (§3.1) | Claude | `ClaimPayloadCodableTests` green; unknown kinds rejected |
| Wed | 0.9 golden corpus: 8/25–8/26 live utterances → `tests/hallie_golden_2026_08.jsonl` (route/outcome/identity/evidence/zero-unverified-fact) | codex | corpus loads in `hallie_eval.py`; today's regex lane scored |
| Thu | 0.2 `ClaimVerifier` — one re-derivation per kind (validation table) over injected sources | Claude | `ClaimVerifierTests` per kind × {verified, wrong, missing, privacy}; `citationForgeryIsDropped` |
| Thu | 0.5 tool adapters (read-only, `ids`/`queryID`/`truncated`, byte caps) over existing APIs (§5.1) | Claude | `ToolAdapterTests` incl. privacy ceiling + 16,383-person timing |
| Fri | 0.3 canonical sentences (reuse `ArchivistBiographyPolicy`) + 0.4 inference whitelist | Claude | golden strings; unlisted kind dropped; never drives an action |
| Fri | 0.6 guard rules behind the verifier (photography floor, name-first, bare-surname, owner pin) | Claude | existing suites re-pointed; `GuardOrderTests` |
| Sat | 0.7 fallback plumbing (no proposal → today's executor, reason logged); 0.8 eval lanes `--lane proposer|regex`, unverified-fact counter, 3-run variance | Claude / codex | `FallbackTests`; `test_hallie_eval_lanes.py` |
| Sat | 0.10 Heuristics registry (`name, default, rationale, overrideKey`) — thresholds the verifier reads | Claude | registry lists every tunable Hallie uses; no literal thresholds remain in routes (grep sensor) |
| Sun | codex adversarial pass on phase 0: injection via tool data, citation forgery, partial tool failure, privacy | codex | findings → fixes before phase 1 |

Exit criteria: all phase-0 suites green in the nightly; regex lane baseline recorded per category; D1 decided.

## Week 2 (9/1–9/7): Phase 1 — proposer behind a flag

- `hallie.proposer.enabled` (default off). Ollama call with bounded orchestration (§8b): max 6 tool calls, 64 KB/result, 20 s end-to-end, cancellation, local hosts only.
- Shadow mode in the eval only: proposer answers scored beside regex; nothing spoken from it yet.
- Nightly report: per-category accuracy, unverified-fact count, schema-valid rate, tool-choice rate, p50/p95, timeout/fallback rate, variance.
- Exit: two categories (biography, kinship) meet the §7 retirement rule for 3 consecutive nights.

## Week 3+ : cutover per category (§8 phase 3)

Flip a category when it passes; delete its regex route in the same commit; keep fast deterministic paths that are materially better (stats, small talk, telling).

## Riding on the same contracts (Rick, 8/26 night)

- **Publish** — per-record visibility (`family | private | published`) plus *published segments* `[in, out]` with provenance, stored as data (catalog record + sidecar), enforced at the web/iPad layer **and** at Hallie's tool privacy ceiling (§4b), so an unpublished clip can neither be served nor described to a family viewer. No FCP: segments are metadata; playback honours them; a later "export published cuts" job can materialize them.
- **Donna's iPad** — a curation client of the existing write routes (date, publish, note, tag) with attribution ("dated by Donna, Aug 30"), not a second app model; the same CyberBrain/catalog contracts the proposer reads.
- **Fall opening to family** — gated on: 0 unverified facts across the golden corpus for 2 weeks, privacy adversarial suite green, Publish shipped.

## Not this week

Fine-tuning, model writes, removing the deterministic executor, ampersand-anything.
